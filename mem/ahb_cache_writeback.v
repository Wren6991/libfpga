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

localparam W_STATE = 5;
localparam S_IDLE         = 5'd0;  // No data phase in progress
localparam S_READ_CHECK   = 5'd1;  // Cache status and read data are valid
localparam S_READ_CLEAN   = 5'd2;  // Writing back a dirty line before eviction
localparam S_READ_FILL    = 5'd3;  // Pulling in a clean line for reading
localparam S_READ_DONE    = 5'd4;  // Buffered read data response (cut external hrdata path)
localparam S_WRITE_CHECK  = 5'd5;  // Cache status is valid
localparam S_WRITE_CLEAN  = 5'd6;  // Writing back a dirty line before eviction
localparam S_WRITE_FILL   = 5'd7;  // Pulling in a clean line before modifying
localparam S_WRITE_MODIFY = 5'd8;  // Updating a valid line following a fill
localparam S_WRITE_DONE   = 5'd9;  // Generate AHB OKAY response and accept new address phase

localparam S_UWRITE_APH   = 5'd10; // Uncached write downstream address phase
localparam S_UWRITE_DPH   = 5'd11; // Uncached write downstream data phase
localparam S_UWRITE_DONE  = 5'd12; // Uncache write completion (hready is registered)
localparam S_UREAD_APH    = 5'd13; // Uncached read downstream address phase
localparam S_UREAD_DPH    = 5'd14; // Uncached read downstream data phase
localparam S_UREAD_DONE   = 5'd15; // Uncached read completion (hrdata is registered)

localparam S_ERR_PH0      = 5'd16; // Upstream error response phase 0
localparam S_ERR_PH1      = 5'd17; // Upstream error response phase 1

reg [W_STATE-1:0]   cache_state;
reg [W_ADDR-1:0]    addr_dphase;
reg [2:0]           size_dphase;

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
			cache_state <= s_next_or_idle;
		end
		S_READ_CHECK: begin
			if (cache_hit) begin
				cache_state <= s_next_or_idle;
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
			cache_state <= s_next_or_idle;
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
// Destination request

wire [W_ADDR-1:0] addr_mask = {{W_ADDR-LOG_BUS_WIDTH{1'b1}}, {LOG_BUS_WIDTH{
	cache_state == S_UWRITE_APH || cache_state == S_UWRITE_DPH}}};

assign dst_haddr = (cache_state == S_WRITE_CHECK || cache_state == S_READ_CHECK)
	&& cache_dirty ? cache_dirty_addr : addr_dphase & addr_mask;

assign dst_htrans = (
	cache_state == S_READ_CHECK && !cache_hit ||
	cache_state == S_READ_CLEAN ||
	cache_state == S_WRITE_CHECK && !cache_hit ||
	cache_state == S_WRITE_CLEAN ||
	cache_state == S_UWRITE_APH ||
	cache_state == S_UREAD_APH
	) ? 2'b10 : 2'b00;

assign dst_hwrite =
	cache_state == S_READ_CHECK && !cache_hit && cache_dirty ||
	cache_state == S_WRITE_CHECK && !cache_hit && cache_dirty ||
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

parameter [2:0] BUS_SIZE_BYTES = $clog2(W_DATA / 8);
assign dst_hsize = cache_state == S_UWRITE_APH || cache_state == S_UREAD_APH
	? size_dphase : BUS_SIZE_BYTES;

assign dst_hready = dst_hready_resp;

// Tie off unused controls
assign dst_hmastlock = 1'b0;
assign dst_hprot = 4'b0011;
assign dst_hburst = 3'b000;

// ----------------------------------------------------------------------------
// Source response

reg [W_DATA-1:0] dst_hrdata_reg;

always @ (posedge clk or negedge rst_n) begin
	if (!rst_n) begin
		dst_hrdata_reg <= {W_DATA{1'b0}};
	end else if (dst_hready) begin
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
