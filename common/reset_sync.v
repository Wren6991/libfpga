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

// The output is asserted asynchronously when the input is asserted,
// but deasserted synchronously when clocked with the input deasserted.
// Input and output are both active-low.

module reset_sync #(
	parameter N_CYCLES = 2 // must be >= 2
) (
	input  wire clk,
	input  wire rst_n_in,
	output wire rst_n_out
);

(* keep = 1'b1 *) reg [N_CYCLES-1:0] delay;

always @ (posedge clk or negedge rst_n_in)
	if (!rst_n_in)
		delay <= {N_CYCLES{1'b0}};
	else
		delay <= {delay[N_CYCLES-2:0], 1'b1};

assign rst_n_out = delay[N_CYCLES-1];

endmodule
