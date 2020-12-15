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

// We can drive a clock by passing 10'b11111_00000 into a 10:1 serialiser, but this
// is wasteful, because the tools won't trim the CDC hardware. It's worth it
// (area-wise) to specialise this.
//
// This module takes a half-rate bit clock (5x pixel clock) and drives a
// pseudodifferential pixel clock using DDR outputs.

module dvi_clock_driver (
	input  wire       clk_x5,
	input  wire       rst_n_x5,

	output wire       qp,
	output wire       qn
);

reg [9:0] ring_ctr;

always @ (posedge clk_x5 or negedge rst_n_x5) begin
	if (!rst_n_x5) begin
		ring_ctr <= 10'b11111_00000;
	end else begin
		ring_ctr <= {ring_ctr[1:0], ring_ctr[9:2]};
	end
end


ddr_out ddrp (
	.clk    (clk_x5),
	.rst_n  (rst_n_x5),

	.d_rise (ring_ctr[0]),
	.d_fall (ring_ctr[1]),
	.e      (1),
	.q      (qp)
);

ddr_out ddrn (
	.clk    (clk_x5),
	.rst_n  (rst_n_x5),

	.d_rise (ring_ctr[5]),
	.d_fall (ring_ctr[6]),
	.e      (1),
	.q      (qn)
);

endmodule
