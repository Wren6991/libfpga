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

module tristate_io (
	input wire out,
	input wire oe,
	output wire in,
	inout wire pad
);

`ifdef FPGA_ICE40

SB_IO #(
    .PIN_TYPE (6'b1010_01),
    .PULLUP   (1'b0)
) buffer (
    .PACKAGE_PIN   (pad),
    .OUTPUT_ENABLE (oe),
    .D_OUT_0       (out),
    .D_IN_0        (in)
);

`else

assign pad = oe ? out : 1'bz;
assign in = pad;

`endif

endmodule
