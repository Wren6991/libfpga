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

// ----------------------------------------------------------------------------
// Cache control state machine

localparam W_STATE = 4;
localparam S_IDLE         = 4'd0;  // No data phase in progress
localparam S_READ_CHECK   = 4'd1;  // Cache status and read data are valid
localparam S_READ_CLEAN   = 4'd2;  // Writing back a dirty line before eviction
localparam S_READ_FILL    = 4'd3;  // Pulling in a clean line for reading
localparam S_READ_DONE    = 4'd4;  // Buffered read data response (cut external hrdata path)
localparam S_WRITE_CHECK  = 4'd5;  // Cache status is valid
localparam S_WRITE_CLEAN  = 4'd6;  // Writing back a dirty line before eviction
localparam S_WRITE_FILL   = 4'd7;  // Pulling in a clean line before modifying
localparam S_WRITE_MODIFY = 4'd8;  // Updating a valid line following a fill
localparam S_WRITE_DONE   = 4'd9;  // Generate AHB OKAY response and accept new address phase
localparam S_ERR_PH0      = 4'd10; // AHBL error phase 0
localparam S_ERR_PH1      = 4'd11; // AHBL error phase 1

reg [W_STATE-1:0]   cache_state;
reg [W_ADDR-1:0]    addr_dphase;
reg [2:0]           size_dphase;

wire                cache_hit;
wire                cache_dirty;

wire src_aphase_read = src_hready && src_htrans[1] && !src_hwrite;
wire src_aphase_write = src_hready && src_htrans[1] && src_hwrite;
wire src_aphase = src_aphase_read || src_aphase_write;

wire [W_STATE-1:0] s_check_or_idle =
	src_aphase_read  ? S_READ_CHECK :
	src_aphase_write ? S_WRITE_CHECK : S_IDLE;

always @ (posedge clk or negedge rst_n) begin
	if (!rst_n) begin
		addr_dphase <= {W_ADDR{1'b0}};
		size_dphase <= 3'h0;
	end else if (src_hready && src_aphase) begin
		addr_dphase <= src_haddr;
		size_dphase <= src_hsize;
	end
end

always @ (posedge clk or negedge rst_n) begin
	if (!rst_n) begin
		cache_state <= S_IDLE;
	end else case (cache_state)
		S_IDLE: begin
			if (src_aphase) begin
				cache_state <= s_check_or_idle;
			end
		end
		S_READ_CHECK: begin
			if (cache_hit) begin
				cache_state <= s_check_or_idle;
			end else if (cache_dirty) begin
				cache_state <= S_READ_CLEAN;
			end else begin
				cache_state <= S_READ_FILL;
			end
		end
		S_READ_CLEAN: begin
			if (dst_hready) begin
				cache_state <= dst_hresp ? S_ERR_PH0 : S_READ_FILL;
			end
		end
		S_READ_FILL: begin
			if (dst_hready) begin
				cache_state <= dst_hresp ? S_ERR_PH0 : S_READ_DONE;
			end
		end
		S_READ_DONE: begin
			cache_state <= s_check_or_idle;
		end
		S_WRITE_CHECK: begin
			if (cache_hit) begin
				cache_state <= S_WRITE_DONE; // modify happens in this cycle
			end else if (cache_dirty) begin
				cache_state <= S_WRITE_CLEAN;
			end else begin
				cache_state <= S_WRITE_FILL;
			end
		end
		S_WRITE_CLEAN: begin
			if (dst_hready) begin
				cache_state <= dst_hresp ? S_ERR_PH0 : S_WRITE_FILL;
			end
		end
		S_WRITE_FILL: begin
			if (dst_hready) begin
				cache_state <= dst_hresp ? S_ERR_PH0 : S_WRITE_MODIFY;
			end
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
			cache_state <= s_check_or_idle;
		end
		S_ERR_PH0: begin
			cache_state <= S_ERR_PH1;
		end
		S_ERR_PH1: begin
			cache_state <= s_check_or_idle;
		end
	endcase
end

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

wire [W_ADDR-1:0]   cache_dirty_addr;

cache_mem_directmapped #(
	.W_ADDR(W_ADDR),
	.W_DATA(W_DATA),
	.DEPTH(DEPTH),
	.TRACK_DIRTY(1)
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

assign cache_addr = (
	cache_state == S_READ_FILL   ||
	cache_state == S_WRITE_CHECK ||
	cache_state == S_WRITE_FILL  ||
	cache_state == S_WRITE_MODIFY) ? addr_dphase : src_haddr;

assign cache_wdata  = (
	cache_state == S_WRITE_CHECK ||
	cache_state == S_WRITE_MODIFY) ? src_hwdata : dst_hrdata;

assign cache_ren = src_aphase;

assign cache_wen_fill = (cache_state == S_WRITE_FILL || cache_state == S_READ_FILL) && dst_hready;

parameter LOG_BUS_WIDTH = $clog2(W_DATA / 8);

wire [W_DATA/8-1:0] byte_mask_dphase = ~({W_DATA/8{1'b1}} << (1 << size_dphase))
	<< addr_dphase[LOG_BUS_WIDTH-1:0];

assign cache_wen_modify = byte_mask_dphase & {W_DATA/8{
	(cache_state == S_WRITE_CHECK && cache_hit) || cache_state == S_WRITE_MODIFY}};

assign cache_invalidate = 1'b0; // for now!

assign cache_clean = 1'b0; // for now! (lines become clean when filled, but we never clean in-place.)

// ----------------------------------------------------------------------------
// Bus wrangling

// Destination request

assign dst_haddr = (cache_state == S_WRITE_CHECK || cache_state == S_READ_CHECK)
	&& cache_dirty ? cache_dirty_addr : addr_dphase;

assign dst_htrans = (
	cache_state == S_READ_CHECK && !cache_hit ||
	cache_state == S_READ_CLEAN ||
	cache_state == S_WRITE_CHECK && !cache_hit ||
	cache_state == S_WRITE_CLEAN
	) ? 2'b10 : 2'b00;

assign dst_hwrite =
	cache_state == S_READ_CHECK && !cache_hit && cache_dirty ||
	cache_state == S_WRITE_CHECK && !cache_hit && cache_dirty;

assign dst_hwdata = cache_rdata;

// Source response

reg [W_DATA-1:0] dst_hrdata_reg;
always @ (posedge clk or negedge rst_n) begin
	if (!rst_n) begin
		dst_hrdata_reg <= {W_DATA{1'b0}};
	end else begin
		dst_hrdata_reg <= dst_hrdata;
	end
end
assign src_hrdata = cache_state == S_READ_DONE ? dst_hrdata_reg : cache_rdata;

assign src_hready_resp =
	cache_state == S_IDLE ||
	cache_state == S_READ_CHECK && cache_hit ||
	cache_state == S_READ_DONE ||
	cache_state == S_WRITE_DONE ||
	cache_state == S_ERR_PH1;

assign src_hresp = cache_state == S_ERR_PH0 || cache_state == S_ERR_PH1;


// Tie off unused controls
assign dst_hmastlock = 1'b0;
assign dst_hprot = 4'b0011;
assign dst_hburst = 3'b000;
parameter [2:0] BUS_SIZE_BYTES = $clog2(W_DATA / 8);
assign dst_hsize = BUS_SIZE_BYTES;

endmodule
