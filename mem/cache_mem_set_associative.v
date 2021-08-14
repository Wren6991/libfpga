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
//   N_WAYS = 2
//
// This will implement a 8 kilobyte cache (256 lines of 2 ways of 128 bits),
// with a 256 deep by 2x21 wide tag memory (20 tag bits plus one valid bit),
// and a 1024 deep by 2x32 wide data memory (speculatively pulling out 32
// bits from both data ways in one read). The cache controller would fill
// cache lines with four consecutive word writes, which may come from a
// single downstream data burst.
//
// Some additional controls are present to help the cache controller support
// the following maintenance operations:
//
// - Cleaning or invalidation of an address (index + tag)
// - Cleaning or invalidation of a cache set (index only)
//
// The cache controller can directly specify a particular way of the indexed
// set, rather than leaving it to this memory's internal way selector
// (which is based on tag match of the most recent lookup). Besides allowing
// the controller to search through all ways of a set when performing
// maintenance, this can also be used to support cache-as-SRAM modes.

module cache_mem_set_associative #(
	parameter N_WAYS = 1,        // Number of set-associative cache ways, any positive integer
	parameter W_ADDR = 32,       // Address bus width
	parameter W_DATA = 32,       // Data bus width, or equivalently, per-way data memory port width
	parameter W_LINE = W_DATA,   // Amount of data associated with one tag
	parameter DEPTH  = 256,      // Capacity in bits = W_LINE * N_WAYS * DEPTH
	parameter TRACK_DIRTY = 0,   // 1 if used in a writeback cache, 0 for write-thru or read-only
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

	// Read/write a particular way of the indexed set, no matter any previous
	// hit/miss. Needed for cache-as-SRAM modes, and for cleaning or
	// invalidating a cache set.
	input  wire                way_mask_direct,
	input  wire                way_mask_direct_en,

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
localparam W_TMEM_WAY = W_TAG + 1 + TRACK_DIRTY;
localparam W_TMEM = W_TMEM_WAY * N_WAYS;

wire [W_TAG-1:0]                 t_addr_tag;
wire [W_INDEX-1:0]               t_addr_index;
wire [W_OFFS-1:0]                t_addr_offs;

wire [W_TAG-1:0]                 d_addr_tag;
wire [W_INDEX+W_INDEX_EXTRA-1:0] d_addr_index;
wire [W_OFFS-W_INDEX_EXTRA-1:0]  d_addr_offs;

assign {t_addr_tag, t_addr_index, t_addr_offs} = t_addr;
assign {d_addr_tag, d_addr_index, d_addr_offs} = d_addr;

wire [N_WAYS-1:0] way_mask;


wire [W_TMEM-1:0]     tmem_rdata;
wire [W_TMEM_WAY-1:0] tmem_wdata_way;
wire                  tmem_wen = t_wen;

// ----------------------------------------------------------------------------
// Hit/miss check and way selection

// Hit if any way of the previously read set matches the previously read tag.

reg [W_TAG-1:0] t_addr_tag_prev;
always @ (posedge clk or negedge rst_n) begin
	if (!rst_n) begin
		t_addr_tag_prev <= {W_TAG{1'b0}};
	end else if (t_ren) begin
		t_addr_tag_prev <= t_addr_tag;
	end
end

reg [N_WAYS-1:0] valid_way;
reg [N_WAYS-1:0] hit_way;

always @ (*) begin: check_hit_way
	integer i;
	for (i = 0; i < N_WAYS; i = i + 1) begin
		valid_way[i] = tmem_rdata[W_TMEM_WAY * i + W_TAG];
		hit_way[i] = valid_way[i] && tmem_rdata[W_TMEM_WAY * i +: W_TAG] == t_addr_tag_prev;
	end
end

assign hit = |hit_way;

// If a tag read does not result in a hit, we select a random way
// (presumably for eviction).

reg [N_WAYS-1:0] random_way_mask_next;
reg [N_WAYS-1:0] random_way_mask;
reg [15:0] way_lfsr;

always @ (posedge clk or negedge rst_n) begin
	if (!rst_n) begin
		way_lfsr <= 16'h0001;
		random_way_mask_next <= ~({N_WAYS{1'b1}} << 1);
		random_way_mask <= ~({N_WAYS{1'b1}} << 1);
	end else begin
		way_lfsr <= way_lfsr << 1 | (way_lfsr[10] ^ way_lfsr[12] ^ way_lfsr[13] ^ way_lfsr[15]);
		// Do or do not rotate, based on LFSR output. Separated in time by a
		// cache miss, this gives ~uncorrelated masks.
		if (way_lfsr[0])
			random_way_mask_next <= random_way_mask_next << 1 | random_way_mask_next[N_WAYS - 1];
		// Only sample the mask rotator on a hit/miss check, to ensure all
		// following writes and data reads are directed to the same way
		if (t_ren)
			random_way_mask <= random_way_mask_next;
`ifdef FORMAL
		// The way mask must be one hot or 0 at all times (must not get the
		// same tag in both ways of a set).
		if (t_addr_tag_prev != 0)
			assert(~|(way_mask & way_mask - 1));
`endif
	end
end

assign way_mask =
	way_mask_direct_en ? way_mask_direct :
	|hit_way           ? hit_way         : random_way_mask;

// ----------------------------------------------------------------------------
// Generate dirty status and writeback address for the selected way of the
// last-read set.

// At this point we know whether any of the previously read tag lines contain
// the desired address. If that line exists, we can generate dirty status and
// dirty writeback address for it.

wire [N_WAYS-1:0] dirty_way;

generate
if (TRACK_DIRTY) begin: gen_dirty_addr

	genvar g;
	for (g = 0; g < N_WAYS; g = g + 1) begin: tmem_has_dirty_loop
		assign dirty_way[g] = tmem_rdata[W_TMEM_WAY * g + W_TAG + 1];
		assign tmem_wdata_way[W_TAG + 1] = t_wdirty;
	end

	reg [W_TAG-1:0] tag_of_selected_way;

	always @ (*) begin: mux_tmem_r_addr
		integer i;
		tag_of_selected_way = {W_TAG{1'b0}};
		for (i = 0; i < N_WAYS; i = i + 1) begin
			tag_of_selected_way = tag_of_selected_way |
				(tmem_rdata[W_TMEM_WAY * i +: W_TAG] & {W_TAG{way_mask[i]}});
		end
	end

	reg [W_INDEX-1:0] addr_index_prev;
	always @ (posedge clk or negedge rst_n) begin
		if (!rst_n) begin
			addr_index_prev <= {W_INDEX{1'b0}};
		end else if (t_ren) begin
			addr_index_prev <= t_addr_index;
		end
	end
	assign dirty_addr = {tag_of_selected_way, addr_index_prev, {W_OFFS{1'b0}}};

end else begin: no_dirty_addr

	assign dirty_way = {N_WAYS{1'b0}};
	assign dirty_addr = {W_ADDR{1'b0}};

end
endgenerate

assign dirty = |(way_mask & valid_way & dirty_way);


// ----------------------------------------------------------------------------
// Cache memories

// Important assumption is that rdata remains constant when ren is not asserted

wire [N_WAYS * W_DATA -1:0] dmem_rdata;
reg  [W_DATA-1:0] dmem_rdata_muxed;
assign rdata = dmem_rdata_muxed;

always @ (*) begin: mux_dmem_rdata
	integer i;
	dmem_rdata_muxed = {W_DATA{1'b0}};
	for (i = 0; i < N_WAYS; i = i + 1)
		dmem_rdata_muxed = dmem_rdata_muxed |
			(dmem_rdata[i * W_DATA +: W_DATA] & {W_DATA{way_mask[i]}});
end

reg [N_WAYS * W_DATA / 8 -1:0] dmem_wen;

always @ (*) begin: fanout_dmem_wen
	integer i;
	for (i = 0; i < N_WAYS; i = i + 1)
		dmem_wen[i * (W_DATA / 8) +: W_DATA / 8] = d_wen & {W_DATA / 8{way_mask[i]}};
end

sram_sync #(
	.WIDTH        (W_DATA * N_WAYS),
	.DEPTH        (DEPTH * W_LINE / W_DATA),
	.PRELOAD_FILE (DMEM_PRELOAD),
	.BYTE_ENABLE  (1)
) dmem (
	.clk   (clk),
	.wen   (dmem_wen),
	.ren   (d_ren),
	.addr  (d_addr_index),
	.wdata ({N_WAYS{wdata}}),
	.rdata (dmem_rdata)
);

// Fanout data to ways based on way selection mask. This cache does not assume
// bit write enable support on the tag RAM (as this is not available on e.g.
// iCE40) so we mux read data back into write data on ways we do not write.

assign tmem_wdata_way[W_TAG:0] = {t_wvalid, t_addr_tag};

reg  [W_TMEM-1:0] tmem_wdata;

always @ (*) begin: tmem_wdata_fanout
	integer i;
	for (i = 0; i < N_WAYS; i = i + 1)
		tmem_wdata[W_TMEM_WAY * i +: W_TMEM_WAY] = !way_mask[i] ?
			tmem_rdata[W_TMEM_WAY * i +: W_TMEM_WAY] : tmem_wdata_way;
end

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
