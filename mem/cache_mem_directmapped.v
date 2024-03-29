/**********************************************************************
 * DO WHAT THE FUCK YOU WANT TO AND DON'T BLAME US PUBLIC LICENSE     *
 *                    Version 3, April 2008                           *
 *                                                                    *
 * Copyright (C) 2021 Luke Wren                                       *
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

// This is just the memory component of a cache -- it's not useable without an
// external cache control state machine and bus interfaces. This cache
// captures the address input directly into the tag and data memories, and
// provides both hit status and read data on the next cycle, so is suitable
// for use on AHB-Lite with 0-wait-state read hits.
//
// The cache line size, W_LINE, must be a power of two multiple of W_DATA
// (including 1 * W_DATA). For example, if:
//
//   W_ADDR = 32
//   W_DATA = 32
//   W_LINE = 128
//   DEPTH  = 256
//
// This will implement a 4 kilobyte cache (256 lines of 128 bits), with a 256
// deep by 21 wide tag memory (20 tag bits plus one valid bit), and a 1024
// deep by 32 wide data memory. The cache controller would fill cache lines
// with four consecutive word writes, which may come from a single downstream
// data burst.

module cache_mem_directmapped #(
	parameter W_ADDR = 32,       // Address bus width
	parameter W_DATA = 32,       // Data bus width, data memory port width
	parameter W_LINE = W_DATA,   // Amount of data associated with one tag
	parameter DEPTH =  256,      // Capacity in bits = W_LINE * DEPTH
	parameter TRACK_DIRTY = 0,   // 1 if used in a writeback cache,
	                             // 0 for write-thru or read-only
	parameter TMEM_PRELOAD = "", // Tag memory hex preload file
	parameter DMEM_PRELOAD = "", // Data memory hex preload file

	parameter W_OFFS = $clog2(W_LINE / 8),            // do not modify
	parameter W_INDEX = $clog2(DEPTH),                // do not modify
	parameter W_INDEX_EXTRA = $clog2(W_LINE / W_DATA) // do not modify
) (
	input  wire                clk,
	input  wire                rst_n,

	// Tag memory access (note any write must follow a matching read)
	input  wire [W_ADDR-1:0]   t_addr,
	input  wire                t_ren,
	input  wire                t_wen,
	input  wire                t_wvalid,
	input  wire                t_wdirty,

	// Line status, valid following assertion of t_ren
	output wire                hit,
	output wire                dirty,
	output wire [W_ADDR-1:0]   dirty_addr,

	// Data memory access
	input  wire [W_ADDR-1:0]   d_addr,
	input  wire                d_ren,
	input  wire [W_DATA/8-1:0] d_wen,
	input  wire [W_DATA-1:0]   wdata,
	output wire [W_DATA-1:0]   rdata
);

localparam W_TAG = W_ADDR - W_INDEX - W_OFFS;
localparam W_TMEM = W_TAG + 1 + TRACK_DIRTY;

wire [W_TAG-1:0]                 t_addr_tag;
wire [W_INDEX-1:0]               t_addr_index;
wire [W_OFFS-1:0]                t_addr_offs;

wire [W_TAG-1:0]                 d_addr_tag;
wire [W_INDEX+W_INDEX_EXTRA-1:0] d_addr_index;
wire [W_OFFS-W_INDEX_EXTRA-1:0]  d_addr_offs;

assign {t_addr_tag, t_addr_index, t_addr_offs} = t_addr;
assign {d_addr_tag, d_addr_index, d_addr_offs} = d_addr;

// ----------------------------------------------------------------------------
// Tag memory update

wire [W_TMEM-1:0] tmem_rdata;
wire [W_TMEM-1:0] tmem_wdata;
wire              tmem_wen = t_wen;

wire [W_TAG-1:0]  tmem_rdata_tag   = tmem_rdata[W_TAG-1:0];
wire              tmem_rdata_valid = tmem_rdata[W_TAG];
wire              tmem_rdata_dirty;

assign tmem_wdata[W_TAG:0] = {t_wvalid, t_addr_tag};

generate
if (TRACK_DIRTY) begin: tmem_has_dirty
	assign tmem_rdata_dirty = tmem_rdata[W_TAG + 1];
	assign tmem_wdata[W_TAG + 1] = t_wdirty;
end else begin: tmem_has_no_dirty
	assign tmem_rdata_dirty = 1'b0;
end
endgenerate

// ----------------------------------------------------------------------------
// Status signals

reg [W_TAG-1:0] t_addr_tag_prev;
always @ (posedge clk or negedge rst_n) begin
	if (!rst_n) begin
		t_addr_tag_prev <= {W_TAG{1'b0}};
	end else if (t_ren) begin
		t_addr_tag_prev <= t_addr_tag;
	end
end

assign hit = tmem_rdata_valid && tmem_rdata_tag == t_addr_tag_prev;
assign dirty = tmem_rdata_valid && tmem_rdata_dirty;

generate
if (TRACK_DIRTY) begin: gen_dirty_addr
	reg [W_INDEX-1:0] addr_index_prev;
	always @ (posedge clk or negedge rst_n) begin
		if (!rst_n) begin
			addr_index_prev <= {W_INDEX{1'b0}};
		end else if (t_ren) begin
			addr_index_prev <= t_addr_index;
		end
	end
	assign dirty_addr = {tmem_rdata_tag, addr_index_prev, {W_OFFS{1'b0}}};
end else begin: no_dirty_addr
	assign dirty_addr = {W_ADDR{1'b0}};
end
endgenerate

// ----------------------------------------------------------------------------
// Cache memories

// Important assumption is that rdata remains constant when ren is not asserted

sram_sync #(
	.WIDTH        (W_DATA),
	.DEPTH        (DEPTH * W_LINE / W_DATA),
	.PRELOAD_FILE (DMEM_PRELOAD),
	.BYTE_ENABLE  (1)
) dmem (
	.clk   (clk),
	.wen   (d_wen),
	.ren   (d_ren),
	.addr  (d_addr_index),
	.wdata (wdata),
	.rdata (rdata)
);

sram_sync #(
	.WIDTH        (W_TMEM),
	.DEPTH        (DEPTH),
	.PRELOAD_FILE (TMEM_PRELOAD),
	.BYTE_ENABLE  (0) // would be nice to have a bit-enable, but RmW works too :)
) tmem (
	.clk   (clk),
	.wen   (t_wen),
	.ren   (t_ren),
	.addr  (t_addr_index),
	.wdata (tmem_wdata),
	.rdata (tmem_rdata)
);

`ifdef FORMAL
always @ (posedge clk) if (rst_n) begin
	assert(!(t_wen && t_ren));
	assert(!(|d_wen && d_ren));
end
`endif

endmodule
