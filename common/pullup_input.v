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

module pullup_input #(
	parameter INVERT = 1
) (
	output wire in,
	inout wire pad
);

`ifdef FPGA_ICE40

wire padin;
assign in = padin ^ INVERT;

SB_IO #(
	.PIN_TYPE(6'b00_00_01),
	//           |  |  |
	//           |  |  \----- Unregistered input
	//           |  \-------- Registered output (don't care)
	//           \----------- Permanent output disable
	.PULLUP(1'b1)
) buffer (
	.PACKAGE_PIN (pad),
	.D_IN_0      (padin)
);

`else

assign (pull0, pull1) pad = 1'b1;
assign in = pad ^ INVERT;

`endif

endmodule
