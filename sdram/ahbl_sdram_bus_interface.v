/**********************************************************************
 * DO WHAT THE FUCK YOU WANT TO AND DON'T BLAME US PUBLIC LICENSE     *
 *                    Version 3, April 2008                           *
 *                                                                    *
 * Copyright (C) 2020 Luke Wren                                       *
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

// Translate AHBL burst requests into requests for the SDRAM scheduler, and
// match AHBL data width to SDRAM data width

`default_nettype none

module ahbl_sdram_bus_interface #(
	// parameter DECODE_COLUMN_MASK = 32'h0000_07fe,
	// parameter DECODE_BANK_MASK   = 32'h0000_1800,
	// parameter DECODE_ROW_MASK    = 32'h03ff_e000,
	parameter W_CADDR            = 10,
	parameter W_RADDR            = 13, // Fixed row:bank:column, for now
	parameter W_BANKSEL          = 2,
	parameter W_SDRAM_DATA       = 16,
	parameter N_MASTERS          = 1,
	parameter W_HADDR            = 32,
	parameter W_HDATA            = 32  // Do not modify
) (
	input  wire                           clk,
	input  wire                           rst_n,

	// Bus
	input  wire [N_MASTERS-1:0]           ahbls_hready,
	output wire [N_MASTERS-1:0]           ahbls_hready_resp,
	output wire [N_MASTERS-1:0]           ahbls_hresp,
	input  wire [N_MASTERS*W_HADDR-1:0]   ahbls_haddr,
	input  wire [N_MASTERS-1:0]           ahbls_hwrite,
	input  wire [N_MASTERS*2-1:0]         ahbls_htrans,
	input  wire [N_MASTERS*3-1:0]         ahbls_hsize,
	input  wire [N_MASTERS*3-1:0]         ahbls_hburst,
	input  wire [N_MASTERS*4-1:0]         ahbls_hprot,
	input  wire [N_MASTERS-1:0]           ahbls_hmastlock,
	input  wire [N_MASTERS*W_HDATA-1:0]   ahbls_hwdata,
	output wire [N_MASTERS*W_HDATA-1:0]   ahbls_hrdata,

	// Scheduler requests
	output reg  [N_MASTERS-1:0]           req_vld,
	input  wire [N_MASTERS-1:0]           req_rdy,
	output reg  [N_MASTERS*W_RADDR-1:0]   req_raddr,
	output reg  [N_MASTERS*W_BANKSEL-1:0] req_banksel,
	output reg  [N_MASTERS*W_CADDR-1:0]   req_caddr,
	output reg  [N_MASTERS-1:0]           req_write,

	// Data launch/capture. Read/write strobes are onehot0
	input  wire [N_MASTERS-1:0]           sdram_write_rdy,
	output wire [W_SDRAM_DATA-1:0]        sdram_write_data,

	input  wire [N_MASTERS-1:0]           sdram_read_vld,
	input  wire [W_SDRAM_DATA-1:0]        sdram_read_data
);

// Should be localparam but ISIM bug blah blah you get it
parameter LSB_OF_SDRAM_ADDR_IN_HADDR = $clog2(W_SDRAM_DATA / 8);

// We only support WRAP4 bursts. TODO decode this and give 2-phase ERROR if we
// get anything else. For now just embrace the jank

// ----------------------------------------------------------------------------
// AHBL -> scheduler requests

localparam HTRANS_IDLE = 2'b00;
localparam HTRANS_NSEQ = 2'b10;
localparam HTRANS_SEQ = 2'b11;
// we don't talk about BUSY

reg [N_MASTERS-1:0] burst_in_progress;

always @ (posedge clk or negedge rst_n) begin: ahbl_capture
	integer i;
	if (!rst_n) begin
		for (i = 0; i < N_MASTERS; i = i + 1) begin
			burst_in_progress[i]                    <= 1'b0;
			req_vld    [i                         ] <= 1'b0;
			req_caddr  [i * W_CADDR   +: W_CADDR  ] <= {W_CADDR{1'b0}};
			req_banksel[i * W_BANKSEL +: W_BANKSEL] <= {W_BANKSEL{1'b0}};
			req_raddr  [i * W_RADDR   +: W_RADDR  ] <= {W_RADDR{1'b0}};
			req_write  [i                         ] <= 1'b0;
		end
	end else begin
		for (i = 0; i < N_MASTERS; i = i + 1) begin
			// No change if burst continues:
			if (ahbls_hready[i] && ahbls_htrans[i * 2 +: 2] != HTRANS_SEQ) begin
				if (ahbls_htrans[i * 2 +: 2] == HTRANS_IDLE) begin
					// IDLE -> OKAY
					burst_in_progress[i] <= 1'b0;
				end else begin
					// NSEQ
					burst_in_progress[i]                    <= 1'b1;
					req_vld    [i                         ] <= 1'b1;
					req_caddr  [i * W_CADDR   +: W_CADDR  ] <= ahbls_haddr[i * W_HADDR + LSB_OF_SDRAM_ADDR_IN_HADDR +: W_CADDR];
					req_banksel[i * W_BANKSEL +: W_BANKSEL] <= ahbls_haddr[i * W_HADDR + LSB_OF_SDRAM_ADDR_IN_HADDR +  W_CADDR +: W_BANKSEL];
					req_raddr  [i * W_RADDR   +: W_RADDR  ] <= ahbls_haddr[i * W_HADDR + LSB_OF_SDRAM_ADDR_IN_HADDR +  W_CADDR +  W_BANKSEL +: W_RADDR];
					req_write  [i                         ] <= ahbls_hwrite[i];
				end
			end
			if (req_rdy[i])
				req_vld[i] <= 1'b0;
		end
	end
end

// ----------------------------------------------------------------------------
// Read data handling

parameter W_SHIFT_CTR = $clog2(W_HDATA / W_SDRAM_DATA);

wire [N_MASTERS-1:0] hrdata_vld;

generate
if (W_SDRAM_DATA == W_HDATA) begin: rdata_pass
	assign ahbls_hrdata = {N_MASTERS{sdram_read_data}};
	assign hrdata_vld =	sdram_read_vld;
end else begin: rdata_shift
	// Since we only serve whole data bursts at a time, there is only one read
	// burst in motion at a time: the read data shifter can be shared between all
	// masters, and their read data buses are common. Interestingly it *is*
	// possible for a read from one master to be concurrent with a write from
	// another master, due to the IO delays on SDRAM DQ launch and capture.

	reg [W_HDATA-W_SDRAM_DATA-1:0] rdata_shift_data;
	reg [W_SHIFT_CTR-1:0]          rdata_shift_ctr;

	always @ (posedge clk or negedge rst_n) begin
		if (!rst_n) begin
			rdata_shift_data <= {W_HDATA - W_SDRAM_DATA{1'b0}};
			rdata_shift_ctr <= {W_SHIFT_CTR{1'b0}};
		end else if (|sdram_read_vld) begin
			// Shift from left so that last read is most significant (little-endian).
			// Need to be careful with case where W_HDATA = 2 * W_SDRAM_DATA
			rdata_shift_data <= (rdata_shift_data >> W_SDRAM_DATA) | (sdram_read_data << (W_HDATA - 2 * W_SDRAM_DATA));
			rdata_shift_ctr <= rdata_shift_ctr + 1'b1;
		end
	end

	assign hrdata_vld = sdram_read_vld & {N_MASTERS{&rdata_shift_ctr}};
	assign ahbls_hrdata = {N_MASTERS{{sdram_read_data, rdata_shift_data}}};

end
endgenerate

// ----------------------------------------------------------------------------
// Write data handling

wire [N_MASTERS-1:0] hwdata_rdy;

generate
if (W_SDRAM_DATA == W_HDATA) begin: wdata_pass
	onehot_mux #(
		.N_INPUTS (N_MASTERS),
		.W_INPUT  (W_SDRAM_DATA)
	) sdram_wdata_mux (
		.in  (ahbls_hwdata),
		.sel (sdram_write_rdy),
		.out (sdram_write_data)
	);
	assign hwdata_rdy = sdram_write_rdy;
end else begin: wdata_shift

	wire [W_HDATA-1:0] hwdata_muxed;

	onehot_mux #(
		.N_INPUTS (N_MASTERS),
		.W_INPUT  (W_HDATA)
	) hwdata_mux (
		.in  (ahbls_hwdata),
		.sel (sdram_write_rdy),
		.out (hwdata_muxed)
	);

	reg [W_HDATA-W_SDRAM_DATA-1:0] wdata_shift_data;
	reg [W_SHIFT_CTR-1:0]          wdata_shift_ctr;

	always @ (posedge clk or negedge rst_n) begin
		if (!rst_n) begin
			wdata_shift_data <= {W_HDATA - W_SDRAM_DATA{1'b0}};
			wdata_shift_ctr <= {W_SHIFT_CTR{1'b0}};
		end else if (|sdram_write_rdy) begin
			wdata_shift_data <= |wdata_shift_ctr ? wdata_shift_data >> W_SDRAM_DATA : hwdata_muxed[W_HDATA-1:W_SDRAM_DATA];
			wdata_shift_ctr <= wdata_shift_ctr + 1'b1;
		end
	end

	assign sdram_write_data = |wdata_shift_ctr ? wdata_shift_data[W_SDRAM_DATA-1:0] : hwdata_muxed[W_SDRAM_DATA-1:0];
	assign hwdata_rdy = sdram_write_rdy & {N_MASTERS{&wdata_shift_ctr}};

end
endgenerate

// ----------------------------------------------------------------------------
// Bus handshaking

assign ahbls_hready_resp = ~burst_in_progress | hrdata_vld | hwdata_rdy;
assign ahbls_hresp = {N_MASTERS{1'b0}};

endmodule

`ifndef YOSYS
`default_nettype wire
`endif
