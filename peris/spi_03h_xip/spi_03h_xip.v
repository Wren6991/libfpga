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

// Minimal execute-in-place for SPI NOR flash. Translates each AHB-Lite access
// into a 32-bit 03h serial read command, with 24-bit address, CPHA = 0, CPOL
// = 0. SCK is at half the frequency of clk.
//
// This is pretty slow, but if you slap a cache on top of it
// (ahb_cache_readonly in this repo) you can get acceptable performance.

`default_nettype none

module spi_03h_xip #(
	parameter W_ADDR = 32, // do not modify
	parameter W_DATA = 32  // do not modify
) (
	// Globals
	input wire                   clk,
	input wire                   rst_n,

	// APB slave for direct SPI access (e.g. flash erase/programming)
	input  wire                  apbs_psel,
	input  wire                  apbs_penable,
	input  wire                  apbs_pwrite,
	input  wire [15:0]           apbs_paddr,
	input  wire [31:0]           apbs_pwdata,
	output wire [31:0]           apbs_prdata,
	output wire                  apbs_pready,
	output wire                  apbs_pslverr,

	// AHB-Lite slave for XIP access
	output wire                  ahbls_hready_resp,
	input  wire                  ahbls_hready,
	output wire                  ahbls_hresp,
	input  wire [W_ADDR-1:0]     ahbls_haddr,
	input  wire                  ahbls_hwrite,
	input  wire [1:0]            ahbls_htrans,
	input  wire [2:0]            ahbls_hsize,
	input  wire [2:0]            ahbls_hburst,
	input  wire [3:0]            ahbls_hprot,
	input  wire                  ahbls_hmastlock,
	input  wire [W_DATA-1:0]     ahbls_hwdata,
	output wire [W_DATA-1:0]     ahbls_hrdata,

	// SPI interface
	output reg                   spi_cs_n,
	output reg                   spi_sck,
	output wire                  spi_mosi,
	input  wire                  spi_miso
);

localparam W_STATE     = 2;
localparam S_IDLE      = 2'd0;
localparam S_ADDR      = 2'd1;
localparam S_DATA      = 2'd2;
localparam S_BACKPORCH = 2'd3;

localparam W_CTR = 5;

reg  [W_CTR-1:0]   shift_ctr;
reg  [W_DATA-1:0]  shift_reg;
reg  [W_STATE-1:0] shift_state;

wire               direct_mode;
reg                direct_mode_busy;
wire [7:0]         txdata_o;
wire               txdata_wen;
wire [7:0]         rxdata_i = shift_reg[7:0];

assign spi_mosi = shift_reg[W_DATA-1];

xip_regs regs (
	.clk          (clk),
	.rst_n        (rst_n),

	.apbs_psel    (apbs_psel),
	.apbs_penable (apbs_penable),
	.apbs_pwrite  (apbs_pwrite),
	.apbs_paddr   (apbs_paddr),
	.apbs_pwdata  (apbs_pwdata),
	.apbs_prdata  (apbs_prdata),
	.apbs_pready  (apbs_pready),
	.apbs_pslverr (apbs_pslverr),

	.csr_direct_o (direct_mode),
	.csr_busy_i   (direct_mode_busy),
	.txdata_o     (txdata_o),
	.txdata_wen   (txdata_wen),
	.rxdata_i     (rxdata_i),
	.rxdata_ren   (/* unused */)
);


always @ (posedge clk or negedge rst_n) begin
	if (!rst_n) begin
		shift_reg <= {W_DATA{1'b0}};
		shift_ctr <= {W_CTR{1'b0}};
		shift_state <= S_IDLE;
		spi_cs_n <= 1'b1;
		spi_sck <= 1'b0;
		direct_mode_busy <= 1'b0;
	end else if (direct_mode) begin
		shift_state <= S_IDLE;
		spi_cs_n <= 1'b0;
		if (txdata_wen) begin
			direct_mode_busy <= 1'b1;
			shift_reg[W_DATA - 1 -: 8] <= txdata_o;
			shift_ctr <= 5'd7;
		end else if (direct_mode_busy) begin
			if (spi_sck) begin
				spi_sck <= 1'b0;
				shift_ctr <= shift_ctr - 1'b1;
				shift_reg[W_DATA-1:1] <= shift_reg[W_DATA-2:0];
				if (~|shift_ctr) begin
					direct_mode_busy <= 1'b0;
				end
			end else begin
				spi_sck <= 1'b1;
				shift_reg[0] <= spi_miso;
			end
		end
	end else if (shift_state == S_IDLE) begin
		spi_cs_n <= 1'b1;
		if (ahbls_hready && ahbls_htrans[1]) begin
			shift_reg <= {8'h03, ahbls_haddr[23:2], 2'b00};
			spi_cs_n <= 1'b0;
			shift_ctr <= W_DATA - 1;
			shift_state <= S_ADDR;
		end
	end else if (shift_state == S_ADDR) begin
		if (spi_sck) begin
			spi_sck <= 1'b0;
			shift_ctr <= shift_ctr - 1'b1;
			shift_reg <= (shift_reg << 1);
			if (~|shift_ctr)
				shift_state <= S_DATA;
		end else begin
			spi_sck <= 1'b1;
		end
	end else if (shift_state == S_DATA) begin
		if (spi_sck) begin
			spi_sck <= 1'b0;
			shift_ctr <= shift_ctr - 1'b1;
			if (~|shift_ctr)
				shift_state <= S_BACKPORCH;
		end else begin
			spi_sck <= 1'b1;
			shift_reg <= (shift_reg << 1) | spi_miso;
		end
	end else if (shift_state == S_BACKPORCH) begin
		spi_cs_n <= 1'b1;
		shift_state <= S_IDLE;
	end
end

assign ahbls_hready_resp = shift_state == S_IDLE;
assign ahbls_hresp = 1'b0;
assign ahbls_hrdata = shift_reg;

endmodule
