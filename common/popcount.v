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

module popcount #(
	parameter W_IN = 8,
	parameter W_OUT = $clog2(W_IN + 1) // Do not modify
) (
	input  wire [W_IN-1:0]  din,
	output wire [W_OUT-1:0] dout
);

// If it's stupid but it works, it's not stupid
// (this actually gives reasonable synthesis results, though FPGAs can do much
// better in some cases using e.g. compressor trees)

reg [W_OUT-1:0] accum;
integer i;

always @ (*) begin
	accum = {W_OUT{1'b0}};
	for (i = 0; i < W_IN; i = i + 1)
		accum = accum + din[i];
end

assign dout = accum;

endmodule
