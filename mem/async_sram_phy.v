/**********************************************************************
 * DO WHAT THE FUCK YOU WANT TO AND DON'T BLAME US PUBLIC LICENSE     *
 *                    Version 3, April 2008                           *
 *                                                                    *
 * Copyright (C) 2023 Luke Wren                                       *
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

// Async SRAM PHY: make an external, asynchronous SRAM appear like an
// internal, synchronous SRAM. This also wraps all tristate signals, so that
// tristate triples (in out oe) can be preserved up to the system top level,
// allowing use of 2-state simulators like Verilator or CXXRTL.

`default_nettype none

module async_sram_phy #(
	parameter W_ADDR = 18,
	parameter W_DATA = 16
) (
	// These should be the same clock/reset used by the controller
	input wire                 clk,
	input wire                 rst_n,

	// From SRAM controller
	input  wire [W_ADDR-1:0]   ctrl_addr,
	input  wire [W_DATA-1:0]   ctrl_dq_out,
	input  wire [W_DATA-1:0]   ctrl_dq_oe,
	output wire [W_DATA-1:0]   ctrl_dq_in,
	input  wire                ctrl_ce_n,
	input  wire                ctrl_we_n,
	input  wire                ctrl_oe_n,
	input  wire [W_DATA/8-1:0] ctrl_byte_n,

	// To external SRAM
	output wire [W_ADDR-1:0]   sram_addr,
	inout  wire [W_DATA-1:0]   sram_dq,
	output wire                sram_ce_n,
	output wire                sram_we_n,
	output wire                sram_oe_n,
	output wire [W_DATA/8-1:0] sram_byte_n
);

tristate_io #(
	.SYNC_OUT (1),
	.SYNC_IN  (1)
) addr_buf [W_ADDR-1:0] (
	.clk   (clk),
	.rst_n (rst_n),
	.out   (ctrl_addr),
	.oe    ({W_ADDR{1'b1}}),
	.in    (),
	.pad   (sram_addr)
);

ddr_out we_ddr (
	.clk    (clk),
	.rst_n  (rst_n),
	.d_rise (1'b1),
	.d_fall (ctrl_we_n),
	.q      (sram_we_n)
);

tristate_io #(
	.SYNC_OUT (1),
	.SYNC_IN  (1)
) cmd_buf [1 + W_DATA / 8 -1:0] (
	.clk   (clk),
	.rst_n (rst_n),
	.out   ({ctrl_oe_n, ctrl_byte_n}),
	.oe    ({1 + W_DATA / 8{1'b1}}),
	.in    (),
	.pad   ({sram_oe_n, sram_byte_n})
);

// TODO this is grounded externally on the modified HX8k board, as a
// workaround for a clock enable packing issue on a previous version of the
// hardware. Should really be part of the cmd_buf above:
assign sram_ce_n = 1'b0;

// TODO would like this to all be synchronous:
tristate_io #(
	.SYNC_OUT (0),
	.SYNC_IN  (0)
) iobuf [W_DATA-1:0] (
	.out (ctrl_dq_out),
	.oe  (ctrl_dq_oe),
	.in  (ctrl_dq_in),
	.pad (sram_dq)
);

endmodule

`ifndef YOSYS
`default_nettype wire
`endif
