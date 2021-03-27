/**********************************************************************
 * DO WHAT THE FUCK YOU WANT TO AND DON'T BLAME US PUBLIC LICENSE     *
 *                    Version 3, April 2008                           *
 *                                                                    *
 * Copyright (C) 2018-2020 Luke Wren                                  *
 *                                                                    *
 * Everyone is permitted to copy and distribute verbatim or modified  *
 * copies of this license document and accompanying software, and     *
 * changing either is allowed.                                        *
 *                                                                    *
 *   TERMS AND CONDITIONS FOR COPYING, DISTRIBUTION AND MODIFICATION  *
 *                                                                    *
 * 0. You just DO WHAT THE FUCK YOU WANT TO.                          *
 * 1. We're NOT RESPONSIBLE WHEN IT DOESN'T FUCKING WORK.             *
 *                                                                    *
 *********************************************************************/

 // AHB-lite to synchronous SRAM adapter with no wait states. Uses a write
 // buffer with a write-to-read forwarding path to handle SRAM address
 // collisions caused by misalignment of AHBL write address and write data.
 //
 // Optionally, the write buffer can be removed to save a small amount of
 // logic. The adapter will then insert one wait state on write->read pairs.

module ahb_sync_sram #(
	parameter W_DATA = 32,
	parameter W_ADDR = 32,
	parameter DEPTH = 1 << 11,
	parameter HAS_WRITE_BUFFER = 1,
	parameter PRELOAD_FILE = ""
) (
	// Globals
	input wire clk,
	input wire rst_n,

	// AHB lite slave interface
	output wire               ahbls_hready_resp,
	input  wire               ahbls_hready,
	output wire               ahbls_hresp,
	input  wire [W_ADDR-1:0]  ahbls_haddr,
	input  wire               ahbls_hwrite,
	input  wire [1:0]         ahbls_htrans,
	input  wire [2:0]         ahbls_hsize,
	input  wire [2:0]         ahbls_hburst,
	input  wire [3:0]         ahbls_hprot,
	input  wire               ahbls_hmastlock,
	input  wire [W_DATA-1:0]  ahbls_hwdata,
	output wire [W_DATA-1:0]  ahbls_hrdata
);

// This should be localparam but ISIM won't allow the $clog2 call for localparams
// because of "reasons"
parameter  W_SRAM_ADDR = $clog2(DEPTH);
localparam W_BYTES     = W_DATA / 8;
parameter  W_BYTEADDR  = $clog2(W_BYTES);


// ----------------------------------------------------------------------------
// AHBL state machine and buffering

// Need to buffer at least a write address,
// and potentially the data too:
reg [W_SRAM_ADDR-1:0] addr_saved;
reg [W_DATA-1:0]      wdata_saved;
reg [W_BYTES-1:0]     wmask_saved;
reg                   wbuf_vld;
reg                   read_delay_state;

// Decode AHBL controls
wire ahb_read_aphase  = ahbls_htrans[1] && ahbls_hready && !ahbls_hwrite;
wire ahb_write_aphase = ahbls_htrans[1] && ahbls_hready &&  ahbls_hwrite;

// If we have a write buffer, we can hold onto buffered data during an
// immediately following sequence of reads, and retire the buffer at a later
// time. Otherwise, we must always retire the write immediately (directly from
// the hwdata bus).
wire write_retire = |wmask_saved && !(ahb_read_aphase && HAS_WRITE_BUFFER);
wire wdata_capture = HAS_WRITE_BUFFER && !wbuf_vld && |wmask_saved && ahb_read_aphase;
wire read_collision = !HAS_WRITE_BUFFER && write_retire && ahb_read_aphase;

wire [W_SRAM_ADDR-1:0] haddr_row = ahbls_haddr[W_BYTEADDR +: W_SRAM_ADDR];
wire [W_BYTES-1:0] wmask_noshift = ~({W_BYTES{1'b1}} << (1 << ahbls_hsize));
wire [W_BYTES-1:0] wmask = wmask_noshift << ahbls_haddr[W_BYTEADDR-1:0];

// AHBL state machine (mainly controlling write buffer)
always @ (posedge clk or negedge rst_n) begin
	if (!rst_n) begin
		wmask_saved <= {W_BYTES{1'b0}};
		addr_saved <= {W_SRAM_ADDR{1'b0}};
		wdata_saved <= {W_DATA{1'b0}};
		wbuf_vld <= 1'b0;
		read_delay_state <= 1'b0;
	end else begin
		if (ahb_write_aphase) begin
			wmask_saved <= wmask;
			addr_saved <= haddr_row;
		end else if (write_retire) begin
			wmask_saved <= {W_BYTES{1'b0}};
		end
		if (read_collision) begin
			addr_saved <= haddr_row;
		end
		if (wdata_capture) begin: capture
			integer i;
			wbuf_vld <= 1'b1;
			for (i = 0; i < W_BYTES; i = i + 1)
				if (wmask_saved[i])
					wdata_saved[i * 8 +: 8] <= ahbls_hwdata[i * 8 +: 8];
		end else if (write_retire) begin
			wbuf_vld <= 1'b0;
		end
		read_delay_state <= read_collision;
	end
end

// ----------------------------------------------------------------------------
// SRAM and SRAM controls

wire [W_BYTES-1:0] sram_wen = write_retire ? wmask_saved : {W_BYTES{1'b0}};
// Note that following a read collision, the read address is supplied during the AHBL data phase
wire [W_SRAM_ADDR-1:0] sram_addr = write_retire || read_delay_state ? addr_saved : haddr_row;
wire [W_DATA-1:0] sram_wdata = wbuf_vld ? wdata_saved : ahbls_hwdata;
wire [W_DATA-1:0] sram_rdata;

sram_sync #(
	.WIDTH(W_DATA),
	.DEPTH(DEPTH),
	.BYTE_ENABLE(1),
	.PRELOAD_FILE(PRELOAD_FILE)
) sram (
	.clk   (clk),
	.wen   (sram_wen),
	.ren   (ahb_read_aphase),
	.addr  (sram_addr),
	.wdata (sram_wdata),
	.rdata (sram_rdata)
);

// ----------------------------------------------------------------------------
// AHBL hookup


assign ahbls_hresp = 1'b0;
assign ahbls_hready_resp = !read_delay_state;

// Merge buffered write data into AHBL read bus (note that addr_saved is the
// address of a previous write, which will eventually be used to retire that
// write, potentially during the write's corresponding AHBL data phase; and
// haddr_saved is the *current* ahbl data phase, which may be that of a read
// which is preventing a previous write from retiring.)

reg [W_SRAM_ADDR-1:0] haddr_dphase;
always @ (posedge clk or negedge rst_n)
	if (!rst_n)
		haddr_dphase <= {W_SRAM_ADDR{1'b0}};
	else if (ahbls_hready)
		haddr_dphase <= haddr_row;

wire addr_match = HAS_WRITE_BUFFER && haddr_dphase == addr_saved;
genvar b;
generate
for (b = 0; b < W_BYTES; b = b + 1) begin: write_merge
	assign ahbls_hrdata[b * 8 +: 8] = addr_match && wbuf_vld && wmask_saved[b] ?
		wdata_saved[b * 8 +: 8] : sram_rdata[b * 8 +: 8];
end
endgenerate


endmodule
