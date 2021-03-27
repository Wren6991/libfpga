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

localparam W_STATE     = 3;
localparam S_IDLE      = 3'd0;
localparam S_CHECK     = 3'd1;
localparam S_MISS_WAIT = 3'd2;
localparam S_MISS_DONE = 3'd3;
localparam S_ERR_PH0   = 3'd4;
localparam S_ERR_PH1   = 3'd5;

reg [W_STATE-1:0] cache_state;
reg [W_ADDR-1:0]  addr_dphase;

wire [W_ADDR-1:0] cache_addr;
wire [W_DATA-1:0] cache_wdata;
wire [W_DATA-1:0] cache_rdata;
wire              cache_ren;
wire              cache_fill;
wire              cache_hit;

wire src_aphase_active = src_hready && src_htrans[1] && !src_hwrite;
wire dst_data_capture;

always @ (posedge clk or negedge rst_n) begin
	if (!rst_n) begin
		cache_state <= S_IDLE;
		addr_dphase <= {W_ADDR{1'b0}};
	end else case (cache_state)
		S_IDLE: begin
			if (src_aphase_active) begin
				cache_state <= S_CHECK;
				addr_dphase <= src_haddr;
			end
		end
		S_CHECK: begin
			if (!cache_hit)
				cache_state <= S_MISS_WAIT;
			else if (!src_aphase_active)
				cache_state <= S_IDLE;
			if (src_aphase_active)
				addr_dphase <= src_haddr;
		end
		S_MISS_WAIT: if (dst_hready) begin
			if (dst_hready && dst_hresp)
				cache_state <= S_ERR_PH0;
			else if (dst_data_capture)
				cache_state <= S_MISS_DONE;
		end
		S_MISS_DONE: begin
			// Purpose of this state is really to allow us to register the downstream
			// hrdata before passing to upstream hrdata
			if (src_aphase_active) begin
				cache_state <= S_CHECK;
				addr_dphase <= src_haddr;
			end else begin
				cache_state <= S_IDLE;
			end
		end
		S_ERR_PH0: begin
			cache_state <= S_ERR_PH1;
		end
		S_ERR_PH1: begin
			// src is permitted but *not required* to deassert its next transfer during S_ERR_PH0.
			if (src_aphase_active) begin
				cache_state <= S_CHECK;
				addr_dphase <= src_haddr;
			end else begin
				cache_state <= S_IDLE;
			end
		end
	endcase
end

// ----------------------------------------------------------------------------
// Cache interfacing

assign cache_ren = src_aphase_active;
assign cache_addr = cache_state == S_MISS_WAIT ? addr_dphase : src_haddr;

assign cache_wdata = dst_hrdata;
assign cache_fill = dst_data_capture;

cache_mem_directmapped #(
	.W_ADDR      (W_ADDR),
	.W_DATA      (W_DATA),
	.DEPTH       (DEPTH),
	.TRACK_DIRTY (0)
) cache_mem (
	.clk        (clk),
	.rst_n      (rst_n),
	.addr       (cache_addr),
	.wdata      (cache_wdata),
	.rdata      (cache_rdata),
	.ren        (cache_ren),
	.wen_fill   (cache_fill),
	.wen_modify ({W_DATA/8{1'b0}}),
	.invalidate (1'b0),
	.clean      (1'b0),
	.hit        (cache_hit),
	.dirty      (/* unused */)
);

// ----------------------------------------------------------------------------
// Downstream bus handling

// Generate downstream request
assign dst_haddr = addr_dphase;
// Note relying on IDLE-to-OKAY requirement here:
assign dst_htrans = {cache_state == S_CHECK && !cache_hit, 1'b0};
assign dst_hready = dst_hready_resp;

// Capture and route downstream response
assign dst_data_capture = cache_state == S_MISS_WAIT && dst_hready_resp && !dst_hresp;

reg [W_DATA-1:0] dst_hrdata_reg;
always @ (posedge clk or negedge rst_n) begin
	if (!rst_n) begin
		dst_hrdata_reg <= {W_DATA{1'b0}};
	end else if (dst_data_capture) begin
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

// Tie off unused controls
assign dst_hwrite = 1'b0;
assign dst_hmastlock = 1'b0;
assign dst_hprot = 4'b0011;
assign dst_hburst = 3'b000;
parameter [2:0] BUS_SIZE_BYTES = $clog2(W_DATA / 8);
assign dst_hsize = BUS_SIZE_BYTES;
assign dst_hwdata = {W_DATA{1'b0}};

endmodule
