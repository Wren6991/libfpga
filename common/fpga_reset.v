/**********************************************************************
 * DO WHAT THE FUCK YOU WANT TO AND DON'T BLAME US PUBLIC LICENSE     *
 *                    Version 3, April 2008                           *
 *                                                                    *
 * Copyright (C) 2018 Luke Wren                                       *
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

// Two-stage reset generator.
// First stage consists of a shift register, which is more reliable
// immediately after power-on when PLLs and external resets can be glitchy.
// Second stage is a counter, which is more efficient for long reset delays
// (e.g. on iCE40 where the BRAMs are invalid for ~3 us after reset)

module fpga_reset #(
	parameter SHIFT = 5,
	parameter COUNT = 0,
	parameter W_CTR = $clog2(COUNT + 1) // let this default
) (
	input wire clk,
	input wire force_rst_n, // tie to e.g. PLL locks, (synchronised) external button
	output wire rst_n
);

(* keep = 1'b1 *) wire stage1_out;

generate
if (SHIFT != 0) begin: has_shifter
	(* keep = 1'b1 *) reg [SHIFT-1:0] shift = {SHIFT{1'b0}};
	always @ (posedge clk or negedge force_rst_n) begin
		if (!force_rst_n) begin
			shift <= {SHIFT{1'b0}};
		end else begin
			shift <= (shift << 1) | 1'b1;
		end
	end
	assign stage1_out = shift[SHIFT-1];
end else begin: no_shifter
	assign stage1_out = force_rst_n;
end
endgenerate

generate
if (COUNT != 0) begin: has_counter
	(* keep = 1'b1 *) reg [W_CTR-1:0] ctr = COUNT;
	(* keep = 1'b1 *) reg ctr_zero = 1'b0;
	always @ (posedge clk or negedge stage1_out) begin
		if (!stage1_out) begin
			ctr <= COUNT;
			ctr_zero <= 1'b0;
		end else begin
			ctr <= ctr - |ctr;
			ctr_zero <= ~|ctr;
		end
	end
	assign rst_n = ctr_zero;
end else begin: no_counter
	assign rst_n = stage1_out;
end
endgenerate

endmodule
