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

// Input a stream of RGB pixels. The clk input is the pixel clock. Source
// *must* keep r, g, b valid at all times, as there is no forward handshake. 
// rgb_rdy is high on cycles where the dvi_tx consumes a pixel, and a fresh
// pixel must be presented on r, g, b on the next cycle.
//
// Output 3 streams of 10 bit TMDS symbols. Each of these must go through a
// 10:1 serialiser.

module dvi_tx_parallel #(
	// Defaults are for 640x480p 60 Hz (from CEA 861D).
	// All horizontal timings are in pixels.
	// All vertical timings are in scanlines.
	parameter H_SYNC_POLARITY   = 1'b0, // 0 for active-low pulse
	parameter H_FRONT_PORCH     = 16,
	parameter H_SYNC_WIDTH      = 96,
	parameter H_BACK_PORCH      = 48,
	parameter H_ACTIVE_PIXELS   = 640,

	parameter V_SYNC_POLARITY   = 1'b0, // 0 for active-low pulse
	parameter V_FRONT_PORCH     = 10,
	parameter V_SYNC_WIDTH      = 2,
	parameter V_BACK_PORCH      = 33,
	parameter V_ACTIVE_LINES    = 480
) (
	input wire clk,
	input wire rst_n,
	input wire en, // synchronous reset if low

	input  wire [7:0] r,
	input  wire [7:0] g,
	input  wire [7:0] b,
	output wire       rgb_rdy,

	output wire [9:0]  tmds2,
	output wire [9:0]  tmds1,
	output wire [9:0]  tmds0
);

wire hsync;
wire vsync;
wire den;

dvi_timing #(
	.H_SYNC_POLARITY (H_SYNC_POLARITY),
	.H_FRONT_PORCH   (H_FRONT_PORCH),
	.H_SYNC_WIDTH    (H_SYNC_WIDTH),
	.H_BACK_PORCH    (H_BACK_PORCH),
	.H_ACTIVE_PIXELS (H_ACTIVE_PIXELS),

	.V_SYNC_POLARITY (V_SYNC_POLARITY),
	.V_FRONT_PORCH   (V_FRONT_PORCH),
	.V_SYNC_WIDTH    (V_SYNC_WIDTH),
	.V_BACK_PORCH    (V_BACK_PORCH),
	.V_ACTIVE_LINES  (V_ACTIVE_LINES)
) inst_dvi_timing (
	.clk   (clk),
	.rst_n (rst_n),
	.en    (en),

	.vsync (vsync),
	.hsync (hsync),
	.den   (den)
);

tmds_encode tmds2_encoder (
	.clk   (clk),
	.rst_n (rst_n),
	.c     (2'b00),
	.d     (r),
	.den   (den),
	.q     (tmds2)
);

tmds_encode tmds1_encoder (
	.clk   (clk),
	.rst_n (rst_n),
	.c     (2'b00),
	.d     (g),
	.den   (den),
	.q     (tmds1)
);

tmds_encode tmds0_encoder (
	.clk   (clk),
	.rst_n (rst_n),
	.c     ({vsync, hsync}),
	.d     (b),
	.den   (den),
	.q     (tmds0)
);

assign rgb_rdy = den;

endmodule
