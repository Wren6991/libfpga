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

module ahb_cache_readonly #(
	parameter W_ADDR = 32,
	parameter W_DATA = 32,
	// Cache line width must be be power of two times W_DATA. The cache will fill
	// one entire cache line on each miss, using a naturally-aligned burst.
	parameter W_LINE = W_DATA,
	parameter TMEM_PRELOAD = "",
	parameter DMEM_PRELOAD = "",
	parameter DEPTH =  256 // Capacity in bits = DEPTH * W_CACHELINE.
) (
	// Globals
	input wire                clk,
	input wire                rst_n,

	// Upstream AHB-Lite slave
	output wire               src_hready_resp,
	input  wire               src_hready,
	output wire               src_hresp,
	input  wire [W_ADDR-1:0]  src_haddr,
	input  wire               src_hwrite,
	input  wire [1:0]         src_htrans,
	input  wire [2:0]         src_hsize,
	input  wire [2:0]         src_hburst,
	input  wire [3:0]         src_hprot,
	input  wire               src_hmastlock,
	input  wire [W_DATA-1:0]  src_hwdata,
	output wire [W_DATA-1:0]  src_hrdata,

	// Downstream AHB-Lite master
	input  wire               dst_hready_resp,
	output wire               dst_hready,
	input  wire               dst_hresp,
	output wire [W_ADDR-1:0]  dst_haddr,
	output wire               dst_hwrite,
	output wire [1:0]         dst_htrans,
	output wire [2:0]         dst_hsize,
	output wire [2:0]         dst_hburst,
	output wire [3:0]         dst_hprot,
	output wire               dst_hmastlock,
	output wire [W_DATA-1:0]  dst_hwdata,
	input  wire [W_DATA-1:0]  dst_hrdata
);

localparam BURST_SIZE = W_LINE / W_DATA;

// ----------------------------------------------------------------------------
// Cache control state machine

localparam W_STATE           = 3;
localparam S_IDLE            = 3'd0;
localparam S_CHECK           = 3'd1;
localparam S_MISS_WAIT_BURST = 3'd2;
localparam S_MISS_WAIT_LAST  = 3'd3;
localparam S_MISS_DONE       = 3'd4;
localparam S_ERR_PH0         = 3'd5;
localparam S_ERR_PH1         = 3'd6;

reg [W_STATE-1:0]    cache_state;
reg [W_ADDR-1:0]     src_addr_dphase;

// Status signal from cache:
wire cache_hit;

wire src_aphase_active = src_hready && src_htrans[1] && !src_hwrite;

always @ (posedge clk or negedge rst_n) begin
	if (!rst_n) begin
		src_addr_dphase <= {W_ADDR{1'b0}};
	end else if (src_aphase_active) begin
		src_addr_dphase <= src_haddr;
	end
end

wire [W_STATE-1:0] s_next_or_idle = src_aphase_active ? S_CHECK : S_IDLE;

wire last_aphase_of_burst;
wire dst_data_capture;

always @ (posedge clk or negedge rst_n) begin
	if (!rst_n) begin
		cache_state <= S_IDLE;
	end else case (cache_state)
		S_IDLE: begin
			cache_state <= s_next_or_idle;
		end
		S_CHECK: begin
			if (cache_hit) begin
				cache_state <= s_next_or_idle;
			end else begin
				// IDLE-to-OKAY rule means we don't need to check hready before going to
				// next dst aphase, because this aphase must complete immediately.
				cache_state <= BURST_SIZE > 1 ? S_MISS_WAIT_BURST : S_MISS_WAIT_LAST;
			end
		end
		S_MISS_WAIT_BURST: if (dst_hready) begin
			if (dst_hresp) begin
				cache_state <= S_ERR_PH0;
			end else if (dst_data_capture) begin
				if (last_aphase_of_burst)
					cache_state <= S_MISS_WAIT_LAST;
			end
		end
		S_MISS_WAIT_LAST: if (dst_hready) begin
			if (dst_hresp)
				cache_state <= S_ERR_PH0;
			else
				cache_state <= S_MISS_DONE;
		end
		S_MISS_DONE: begin
			// Purpose of this state is really to allow us to register the downstream
			// hrdata before passing to upstream hrdata
			cache_state <= s_next_or_idle;
		end
		S_ERR_PH0: begin
			cache_state <= S_ERR_PH1;
		end
		S_ERR_PH1: begin
			// src is permitted but *not required* to deassert its next transfer during S_ERR_PH0.
			cache_state <= s_next_or_idle;
		end
	endcase
end

// ----------------------------------------------------------------------------
// Burst address generation

// Also need to provide a flag for when the burst data phase address matches
// the upstream request, so that the correct word can be captured and passed
// upstream. We don't return the data early, since this would also cause an
// AHB-Lite master to drop its next address, but we can still save a cycle by
// forwarding the registered data instead of reading back from the cache.

parameter W_BURST_ADDR = $clog2(W_LINE / W_DATA);
parameter [2:0] BUS_SIZE_BYTES = $clog2(W_DATA / 8);

wire [W_ADDR-1:0] burst_addr_aphase;
wire [W_ADDR-1:0] burst_addr_dphase;
wire dst_dphase_addr_matches_src_addr;

generate
if (BURST_SIZE == 1) begin: no_fill_ctr

	// Source address is aligned down, since transfer is size of data bus.
	assign burst_addr_aphase = {src_addr_dphase[W_ADDR-1:BUS_SIZE_BYTES], {BUS_SIZE_BYTES{1'b0}}};
	assign burst_addr_dphase = burst_addr_aphase;

	assign dst_dphase_addr_matches_src_addr = 1'b1;
	assign last_aphase_of_burst = 1'b1;

end else begin: has_fill_ctr

	// We don't want a 32 bit counter :)
	reg [W_BURST_ADDR-1:0] burst_addr_ctr;
	reg burst_ctr_prev_matched_src;

	always @ (posedge clk or negedge rst_n) begin
		if (!rst_n) begin
			burst_addr_ctr <= {W_BURST_ADDR{1'b0}};
			burst_ctr_prev_matched_src <= 1'b0;
		end else if (cache_state == S_MISS_DONE) begin
			burst_addr_ctr <= {W_BURST_ADDR{1'b0}};
			burst_ctr_prev_matched_src <= 1'b0;
		end else if (dst_hready && ((cache_state == S_CHECK && !cache_hit) || cache_state == S_MISS_WAIT_BURST)) begin
			burst_addr_ctr <= burst_addr_ctr + 1'b1;
			burst_ctr_prev_matched_src <= burst_addr_ctr == src_addr_dphase[BUS_SIZE_BYTES +: W_BURST_ADDR];
		end
	end

	wire [W_ADDR-W_BURST_ADDR-BUS_SIZE_BYTES-1:0] src_addr_dphase_passthrough =
		src_addr_dphase[W_ADDR-1:BUS_SIZE_BYTES+W_BURST_ADDR];

	assign burst_addr_aphase = {src_addr_dphase_passthrough,  burst_addr_ctr,         {BUS_SIZE_BYTES{1'b0}}};
	assign burst_addr_dphase = {src_addr_dphase_passthrough, {burst_addr_ctr - 1'b1}, {BUS_SIZE_BYTES{1'b0}}};

	assign dst_dphase_addr_matches_src_addr = burst_ctr_prev_matched_src;
	assign last_aphase_of_burst = &burst_addr_ctr;

end
endgenerate

// ----------------------------------------------------------------------------
// Cache interfacing

// For read-only cache, we never pass different addresses to tmem/dmem.
wire [W_ADDR-1:0] cache_addr;
wire [W_DATA-1:0] cache_wdata;
wire [W_DATA-1:0] cache_rdata;
wire              cache_ren;
wire              cache_fill;

assign cache_ren = src_aphase_active;
assign cache_addr = cache_state == S_MISS_WAIT_BURST || cache_state == S_MISS_WAIT_LAST ? burst_addr_dphase : src_haddr;

assign cache_wdata = dst_hrdata;
assign cache_fill = dst_data_capture;

cache_mem_directmapped #(
	.W_ADDR       (W_ADDR),
	.W_DATA       (W_DATA),
	.W_LINE       (W_LINE),
	.DEPTH        (DEPTH),
	.TMEM_PRELOAD (TMEM_PRELOAD),
	.DMEM_PRELOAD (DMEM_PRELOAD),
	.TRACK_DIRTY  (0)
) cache_mem (
	.clk        (clk),
	.rst_n      (rst_n),

	.t_addr     (cache_addr),
	.t_ren      (cache_ren),
	.t_wen      (cache_fill),
	.t_wvalid   (1'b1),
	.t_wdirty   (1'b0),

	.hit        (cache_hit),
	.dirty      (/* unused */),
	.dirty_addr (/* unused */),

	.d_addr     (cache_addr),
	.d_wen      ({W_DATA/8{cache_fill}}),
	.d_ren      (cache_ren),
	.wdata      (cache_wdata),
	.rdata      (cache_rdata)
);

// ----------------------------------------------------------------------------
// Downstream bus handling

// Generate downstream request

assign dst_haddr = burst_addr_aphase;

// NSEQ for first access, SEQ for following accesses.
localparam HTRANS_IDLE = 2'b00;
localparam HTRANS_NSEQ = 2'b10;
localparam HTRANS_SEQ = 2'b11;

// Registered flag, high in second phase (ph1) of downstream error response,
// so we can terminate the burst cleanly.
reg dst_err_ph1;
always @ (posedge clk or negedge rst_n) begin
	if (!rst_n) begin
		dst_err_ph1 <= 1'b0;
	end else begin
		dst_err_ph1 <= dst_hresp && !dst_hready;
	end
end

assign dst_htrans =
	dst_err_ph1                          ? HTRANS_IDLE :
	cache_state == S_CHECK && !cache_hit ? HTRANS_NSEQ :
	cache_state == S_MISS_WAIT_BURST     ? HTRANS_SEQ  : HTRANS_IDLE;

assign dst_hready = dst_hready_resp;

// Capture and route downstream response

assign dst_data_capture = (
	cache_state == S_MISS_WAIT_BURST ||
	cache_state == S_MISS_WAIT_LAST) && dst_hready_resp && !dst_hresp;

reg [W_DATA-1:0] dst_hrdata_reg;
always @ (posedge clk or negedge rst_n) begin
	if (!rst_n) begin
		dst_hrdata_reg <= {W_DATA{1'b0}};
	end else if (dst_data_capture && dst_dphase_addr_matches_src_addr) begin
		// Pick out the correct word to forward on to src once burst finishes.
		dst_hrdata_reg <= dst_hrdata;
	end
end

assign src_hrdata = cache_state == S_MISS_DONE ? dst_hrdata_reg : cache_rdata;

assign src_hready_resp =
	cache_state == S_IDLE ||
	(cache_state == S_CHECK && cache_hit) ||
	cache_state == S_MISS_DONE ||
	cache_state == S_ERR_PH1;

assign src_hresp = cache_state == S_ERR_PH0 || cache_state == S_ERR_PH1;

// Tie off unused or fixed controls

assign dst_hwrite = 1'b0;
assign dst_hmastlock = 1'b0;
assign dst_hprot = 4'b0011;

assign dst_hburst = BURST_SIZE == 1  ? 3'b000 : // SINGLE
                    BURST_SIZE == 4  ? 3'b011 : // INCR4
                    BURST_SIZE == 8  ? 3'b101 : // INCR8
                    BURST_SIZE == 16 ? 3'b111 : // INCR16
                                       3'b001 ; // INCR
assign dst_hsize = BUS_SIZE_BYTES;
assign dst_hwdata = {W_DATA{1'b0}};

endmodule
