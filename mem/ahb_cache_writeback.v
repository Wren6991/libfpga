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

module ahb_cache_writeback #(
	parameter W_ADDR = 32,
	parameter W_DATA = 32,
	// Cache line width must be be power of two times W_DATA. The cache will fill
	// one entire cache line on each miss, using a naturally-aligned burst.
	parameter W_LINE = W_DATA,
	parameter TMEM_PRELOAD = "",
	parameter DMEM_PRELOAD = "",
	parameter DEPTH =  256 // Capacity in bits = W_DATA * DEPTH
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

localparam W_STATE = 5;

localparam S_IDLE              = 5'd0;  // No src data phase in progress

// During BURST states there is an overlapping dst dphase and dst aphase
// belonging to the same CLEAN/FILL operation; during LAST states there is a
// dphase only. For burst size of 1 (cache lines are bus-sized) we go straight
// to LAST, because there are no overlapping dphases/aphases belonging to a
// single operation e.g. FILL, though e.g. a CLEAN data phase will still
// overlap with a FILL address phase.

localparam S_READ_CHECK        = 5'd1;  // Cache status and read data are valid
localparam S_READ_CLEAN_BURST  = 5'd2;  // Writing back a dirty line before eviction
localparam S_READ_CLEAN_LAST   = 5'd3;
localparam S_READ_FILL_BURST   = 5'd4;  // Pulling in a clean line for reading
localparam S_READ_FILL_LAST    = 5'd5;
localparam S_READ_DONE         = 5'd6;  // Buffered read data response (cut external hrdata path)

localparam S_WRITE_CHECK       = 5'd7;  // Cache status is valid
localparam S_WRITE_CLEAN_BURST = 5'd8;  // Writing back a dirty line before eviction
localparam S_WRITE_CLEAN_LAST  = 5'd9;
localparam S_WRITE_FILL_BURST  = 5'd10; // Pulling in a clean line before modifying
localparam S_WRITE_FILL_LAST   = 5'd11;
localparam S_WRITE_MODIFY      = 5'd12; // Updating a valid line following a fill
localparam S_WRITE_DONE        = 5'd13; // Generate AHB OKAY response and accept new src address phase

localparam S_UWRITE_APH        = 5'd14; // Uncached write downstream address phase
localparam S_UWRITE_DPH        = 5'd15; // Uncached write downstream data phase
localparam S_UWRITE_DONE       = 5'd16; // Uncached write completion (hready is registered)
localparam S_UREAD_APH         = 5'd17; // Uncached read downstream address phase
localparam S_UREAD_DPH         = 5'd18; // Uncached read downstream data phase
localparam S_UREAD_DONE        = 5'd19; // Uncached read completion (hrdata is registered)

localparam S_ERR_PH0           = 5'd20; // Upstream error response phase 0
localparam S_ERR_PH1           = 5'd21; // Upstream error response phase 1

reg [W_STATE-1:0]   cache_state;
reg [W_ADDR-1:0]    src_addr_dphase;
reg [2:0]           src_size_dphase;

wire                cache_hit;
wire                cache_dirty;

wire src_uncacheable = !(src_hprot[3] && src_hprot[2]);

wire src_aphase_read = src_hready && src_htrans[1] && !src_hwrite;
wire src_aphase_write = src_hready && src_htrans[1] && src_hwrite;
wire src_aphase = src_aphase_read || src_aphase_write;

wire [W_STATE-1:0] s_next_or_idle =
	src_aphase_read  && src_uncacheable ? S_UREAD_APH   :
	src_aphase_write && src_uncacheable ? S_UWRITE_APH  :
	src_aphase_read                     ? S_READ_CHECK  :
	src_aphase_write                    ? S_WRITE_CHECK : S_IDLE;

always @ (posedge clk or negedge rst_n) begin
	if (!rst_n) begin
		src_addr_dphase <= {W_ADDR{1'b0}};
		src_size_dphase <= 3'h0;
	end else if (src_hready && src_aphase) begin
		src_addr_dphase <= src_haddr;
		src_size_dphase <= src_hsize;
	end
end

wire last_aphase_of_burst;

always @ (posedge clk or negedge rst_n) begin
	if (!rst_n) begin
		cache_state <= S_IDLE;
	end else begin
		case (cache_state)
		S_IDLE: begin
			cache_state <= s_next_or_idle;
		end
		S_READ_CHECK: begin
			if (cache_hit)
				cache_state <= s_next_or_idle;
			else if (cache_dirty)
				cache_state <= BURST_SIZE > 1 ? S_READ_CLEAN_BURST : S_READ_CLEAN_LAST;
			else 
				cache_state <= BURST_SIZE > 1 ? S_READ_FILL_BURST : S_READ_FILL_LAST;
		end
		S_READ_CLEAN_BURST: if (dst_hready) begin
			if (last_aphase_of_burst)
				cache_state <= S_READ_CLEAN_LAST;
		end
		S_READ_CLEAN_LAST: if (dst_hready) begin
			cache_state <=  BURST_SIZE > 1 ? S_READ_FILL_BURST : S_READ_FILL_LAST;
		end
		S_READ_FILL_BURST: if (dst_hready) begin
			if (last_aphase_of_burst)
				cache_state <= S_READ_FILL_LAST;
		end
		S_READ_FILL_LAST: if (dst_hready) begin
			cache_state <= S_READ_DONE;
		end
		S_READ_DONE: begin
			// Dummy state to allow buffering of read response
			cache_state <= s_next_or_idle;
		end
		S_WRITE_CHECK: begin
			if (cache_hit) begin
				cache_state <= S_WRITE_DONE; // modify happens in this cycle
			end else if (cache_dirty) begin
				cache_state <= BURST_SIZE > 1 ? S_WRITE_CLEAN_BURST : S_WRITE_CLEAN_LAST;
			end else begin
				cache_state <= BURST_SIZE > 1 ? S_WRITE_FILL_BURST : S_WRITE_FILL_LAST;
			end
		end
		S_WRITE_CLEAN_BURST: if (dst_hready) begin
			if (last_aphase_of_burst)
				cache_state <= S_WRITE_CLEAN_LAST;
		end
		S_WRITE_CLEAN_LAST: if (dst_hready) begin
			cache_state <= BURST_SIZE > 1 ? S_WRITE_FILL_BURST : S_WRITE_FILL_LAST;
		end
		S_WRITE_FILL_BURST: if (dst_hready) begin
			if (last_aphase_of_burst)
				cache_state <= S_WRITE_FILL_LAST;
		end
		S_WRITE_FILL_LAST: if (dst_hready) begin
			cache_state <= S_WRITE_MODIFY;
		end
		S_WRITE_MODIFY: begin
			// Previous cycle committed fresh line from dst, this cycle commits pending
			// bytes from src. TODO src_hwdata and dst_hrdata are already muxed into
			// cache_wdata, we could skip this state by using those muxes to merge the
			// bytes.
			cache_state <= S_WRITE_DONE;
		end
		S_WRITE_DONE: begin
			// Dummy state required to avoid read/write address collision
			cache_state <= s_next_or_idle;
		end
		S_UWRITE_APH: begin
			// IDLE->OKAY means no stall or error
			cache_state <= S_UWRITE_DPH;
		end
		S_UWRITE_DPH: begin
			if (dst_hready) begin
				cache_state <= dst_hresp ? S_ERR_PH0 : S_UWRITE_DONE;
			end
		end
		S_UWRITE_DONE: begin
			cache_state <= s_next_or_idle;
		end
		S_UREAD_APH: begin
			// IDLE->OKAY means no stall or error
			cache_state <= S_UREAD_DPH;
		end
		S_UREAD_DPH: begin
			if (dst_hready) begin
				cache_state <= dst_hresp ? S_ERR_PH0 : S_UREAD_DONE;
			end
		end
		S_UREAD_DONE: begin
			cache_state <= s_next_or_idle;
		end
		S_ERR_PH0: begin
			cache_state <= S_ERR_PH1;
		end
		S_ERR_PH1: begin
			cache_state <= s_next_or_idle;
		end
		endcase
		// Override state transition on error (save some copy/paste). dst should
		// only generate error response when we have an active dst dphase.
		if (dst_hready && dst_hresp)
			cache_state <= S_ERR_PH0;
	end
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

wire [W_ADDR-1:0] burst_fill_addr_aphase;
wire [W_ADDR-1:0] burst_fill_addr_dphase;
wire [W_ADDR-1:0] burst_dirty_addr_aphase;
wire dst_dphase_addr_matches_src_addr;

// Output from cache:
wire [W_ADDR-1:0] cache_dirty_addr;

generate
if (BURST_SIZE == 1) begin: no_fill_ctr

	// Source address is aligned down, since transfer is size of data bus.
	assign burst_fill_addr_aphase = {src_addr_dphase[W_ADDR-1:BUS_SIZE_BYTES], {BUS_SIZE_BYTES{1'b0}}};
	assign burst_fill_addr_dphase = burst_fill_addr_aphase; // because it doesn't increment
	assign burst_dirty_addr_aphase = cache_dirty_addr;

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
		end else if (!dst_htrans[1]) begin
			// Note HTRANS is decoded from our own registered state, we could list all
			// the conditions here but it wouldn't achieve anything synthesis-wise.
			burst_addr_ctr <= {W_BURST_ADDR{1'b0}};
			burst_ctr_prev_matched_src <= 1'b0;
		end else if (dst_hready && dst_htrans[1]) begin
			burst_addr_ctr <= burst_addr_ctr + 1'b1;
			burst_ctr_prev_matched_src <= burst_addr_ctr == src_addr_dphase[BUS_SIZE_BYTES +: W_BURST_ADDR];
		end
	end

	wire [W_ADDR-W_BURST_ADDR-BUS_SIZE_BYTES-1:0] src_addr_dphase_passthrough =
		src_addr_dphase[W_ADDR-1:BUS_SIZE_BYTES+W_BURST_ADDR];


	assign burst_fill_addr_aphase = {src_addr_dphase_passthrough,  burst_addr_ctr,         {BUS_SIZE_BYTES{1'b0}}};
	assign burst_fill_addr_dphase = {src_addr_dphase_passthrough, {burst_addr_ctr - 1'b1}, {BUS_SIZE_BYTES{1'b0}}};
	assign burst_dirty_addr_aphase = cache_dirty_addr |           {burst_addr_ctr,         {BUS_SIZE_BYTES{1'b0}}};

	assign dst_dphase_addr_matches_src_addr = burst_ctr_prev_matched_src;
	assign last_aphase_of_burst = &burst_addr_ctr;

end
endgenerate


// ----------------------------------------------------------------------------
// Cache memory

wire [W_ADDR-1:0]   cache_addr;
wire [W_DATA-1:0]   cache_wdata;
wire [W_DATA-1:0]   cache_rdata;

wire                cache_ren;
wire                cache_wen_fill;
wire [W_DATA/8-1:0] cache_wen_modify;
wire                cache_invalidate;
wire                cache_clean;

cache_mem_directmapped #(
	.W_ADDR       (W_ADDR),
	.W_DATA       (W_DATA),
	.DEPTH        (DEPTH),
	.TMEM_PRELOAD (TMEM_PRELOAD),
	.DMEM_PRELOAD (DMEM_PRELOAD),
	.TRACK_DIRTY  (1)
) cache_mem (
	.clk        (clk),
	.rst_n      (rst_n),
	.addr       (cache_addr),
	.wdata      (cache_wdata),
	.rdata      (cache_rdata),
	.ren        (cache_ren),
	.wen_fill   (cache_wen_fill),
	.wen_modify (cache_wen_modify),
	.invalidate (cache_invalidate),
	.clean      (cache_clean),
	.hit        (cache_hit),
	.dirty      (cache_dirty),
	.dirty_addr (cache_dirty_addr)
);

reg dst_dphase_active;
always @ (posedge clk or negedge rst_n) begin
	if (!rst_n) begin
		dst_dphase_active <= 1'b0;
	end else if (dst_hready) begin
		dst_dphase_active <= dst_htrans[1];
	end
end

wire maybe_modify_cache = cache_state == S_WRITE_CHECK || cache_state == S_WRITE_MODIFY;

assign cache_addr =
	dst_dphase_active  ? burst_fill_addr_dphase :
	maybe_modify_cache ? src_addr_dphase        : src_haddr;

assign cache_wdata  = maybe_modify_cache ? src_hwdata : dst_hrdata;

assign cache_ren = src_aphase ||
	cache_state == S_READ_CLEAN_BURST || cache_state == S_WRITE_CLEAN_BURST;

assign cache_wen_fill = dst_hready && (
	cache_state == S_WRITE_FILL_BURST || cache_state == S_WRITE_FILL_LAST ||
	cache_state == S_READ_FILL_BURST || cache_state == S_READ_FILL_LAST
);

parameter LOG_BUS_WIDTH = $clog2(W_DATA / 8);

wire [W_DATA/8-1:0] byte_mask_dphase = ~({W_DATA/8{1'b1}} << (1 << src_size_dphase))
	<< src_addr_dphase[LOG_BUS_WIDTH-1:0];

assign cache_wen_modify = byte_mask_dphase & {W_DATA/8{
	(cache_state == S_WRITE_CHECK && cache_hit) || cache_state == S_WRITE_MODIFY}};

assign cache_invalidate = 1'b0; // for now!

assign cache_clean = 1'b0; // for now! (lines become clean when filled, but we never clean in-place.)

// ----------------------------------------------------------------------------
// Destination request

wire in_clean_aphase = 
	cache_dirty && (
		cache_state == S_WRITE_CHECK ||
		cache_state == S_READ_CHECK) ||
	cache_state == S_WRITE_CLEAN_BURST ||
	cache_state == S_READ_CLEAN_BURST;

wire in_uncached_aphase = cache_state == S_UWRITE_APH || cache_state == S_UREAD_APH;

assign dst_haddr =
	in_clean_aphase    ? burst_dirty_addr_aphase :
	in_uncached_aphase ? src_addr_dphase         : burst_fill_addr_aphase;

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

// NSEQ for first access, SEQ for following accesses.
localparam HTRANS_IDLE = 2'b00;
localparam HTRANS_NSEQ = 2'b10;
localparam HTRANS_SEQ = 2'b11;

assign dst_htrans = 
	dst_err_ph1 ? HTRANS_IDLE :	(
		cache_state == S_READ_CHECK && !cache_hit ||
		cache_state == S_READ_CLEAN_LAST ||
		cache_state == S_WRITE_CHECK && !cache_hit ||
		cache_state == S_WRITE_CLEAN_LAST ||
		cache_state == S_UWRITE_APH ||
		cache_state == S_UREAD_APH
	) ? HTRANS_NSEQ : (
		cache_state == S_READ_CLEAN_BURST ||
		cache_state == S_READ_FILL_BURST ||
		cache_state == S_WRITE_CLEAN_BURST ||
		cache_state == S_WRITE_FILL_BURST
	) ? HTRANS_SEQ : HTRANS_IDLE;

assign dst_hwrite =
	cache_state == S_READ_CHECK && !cache_hit && cache_dirty ||
	cache_state == S_READ_CLEAN_BURST ||
	cache_state == S_WRITE_CHECK && !cache_hit && cache_dirty ||
	cache_state == S_WRITE_CLEAN_BURST ||
	cache_state == S_UWRITE_APH;

reg [W_DATA-1:0] src_hwdata_reg;
always @ (posedge clk or negedge rst_n) begin
	if (!rst_n) begin
		src_hwdata_reg <= {W_DATA{1'b0}};
	end else if (cache_state == S_UWRITE_APH) begin
		src_hwdata_reg <= src_hwdata;
	end
end

assign dst_hwdata = cache_state == S_UWRITE_DPH ? src_hwdata_reg : cache_rdata;

assign dst_hsize = cache_state == S_UWRITE_APH || cache_state == S_UREAD_APH
	? src_size_dphase : BUS_SIZE_BYTES;

assign dst_hready = dst_hready_resp;

// Tie off unused or fixed controls

assign dst_hmastlock = 1'b0;
assign dst_hprot = 4'b0011;
assign dst_hburst = BURST_SIZE == 1  ? 3'b000 : // SINGLE
                    BURST_SIZE == 4  ? 3'b011 : // INCR4
                    BURST_SIZE == 8  ? 3'b101 : // INCR8
                    BURST_SIZE == 16 ? 3'b111 : // INCR16
                                       3'b001 ; // INCR

// ----------------------------------------------------------------------------
// Source response

reg [W_DATA-1:0] dst_hrdata_reg;

always @ (posedge clk or negedge rst_n) begin
	if (!rst_n) begin
		dst_hrdata_reg <= {W_DATA{1'b0}};
	end else if (dst_hready && dst_dphase_addr_matches_src_addr) begin
		dst_hrdata_reg <= dst_hrdata;
	end
end

assign src_hrdata = cache_state == S_READ_DONE || cache_state == S_UREAD_DONE
	? dst_hrdata_reg : cache_rdata;

assign src_hready_resp =
	cache_state == S_IDLE ||
	cache_state == S_READ_CHECK && cache_hit ||
	cache_state == S_READ_DONE ||
	cache_state == S_WRITE_DONE ||
	cache_state == S_UREAD_DONE ||
	cache_state == S_UWRITE_DONE ||
	cache_state == S_ERR_PH1;

assign src_hresp = cache_state == S_ERR_PH0 || cache_state == S_ERR_PH1;

endmodule
