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

// Monostable, generates a pulse of at least WIDTH cycles every time the input
// signal is seen to change.

module activity_led #(
	parameter WIDTH = 1 << 16,
	parameter ACTIVE_LEVEL = 1'b1,
	parameter W_CTR = $clog2(WIDTH) // do not modify
) (
	input  wire clk,
	input  wire rst_n,
	input  wire i,
	output reg  o
);

wire i_sync;

// Signal may be asynchronous to clk, e.g. a TCK signal from a debug probe
sync_1bit inst_sync_1bit (
	.clk   (clk),
	.rst_n (rst_n),
	.i     (i),
	.o     (i_sync)
);

reg             i_prev;
reg [W_CTR-1:0] ctr;

always @ (posedge clk or negedge rst_n) begin
	if (!rst_n) begin
		i_prev <= 1'b0;
		ctr <= {W_CTR{1'b0}};
		o <= !ACTIVE_LEVEL;
	end else begin
		i_prev <= i_sync;
		if (i_prev != i_sync) begin
			o <= ACTIVE_LEVEL;
			ctr <= WIDTH - 1;
		end else if (|ctr) begin
			ctr <= ctr - 1'b1;
		end else begin
			o <= !ACTIVE_LEVEL;
		end
	end
end

endmodule
