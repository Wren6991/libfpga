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

// IO instantiations for ahbl_sdram. These are separated out so that they can
// be instantiated in the top-level FPGA wrapper, which allows full-system
// simulation using 2-state simulators like CXXRTL.

`default_nettype none

module sdram_phy #(
	parameter W_SDRAM_BANKSEL    = 2,
	parameter W_SDRAM_ADDR       = 13,
	parameter W_SDRAM_DATA       = 16
) (
	input wire                          clk,
	input wire                          rst_n,

	// Interface to SDRAM controller
	input  wire                         ctrl_clk_enable,
	input  wire [W_SDRAM_BANKSEL-1:0]   ctrl_ba_next,
	input  wire [W_SDRAM_ADDR-1:0]      ctrl_a_next,
	input  wire [W_SDRAM_DATA/8-1:0]    ctrl_dqm_next,

	input  wire [W_SDRAM_DATA-1:0]      ctrl_dq_o_next,
	input  wire                         ctrl_dq_oe_next,
	output wire [W_SDRAM_DATA-1:0]      ctrl_dq_i,

	input  wire                         ctrl_clke_next,
	input  wire                         ctrl_cs_n_next,
	input  wire                         ctrl_ras_n_next,
	input  wire                         ctrl_cas_n_next,
	input  wire                         ctrl_we_n_next,

	// Connection to external SDRAM device
	output wire                         sdram_clk,
	output wire [W_SDRAM_ADDR-1:0]      sdram_a,
	inout  wire [W_SDRAM_DATA-1:0]      sdram_dq,
	output wire [W_SDRAM_BANKSEL-1:0]   sdram_ba,
	output wire [W_SDRAM_DATA/8-1:0]    sdram_dqm,
	output wire                         sdram_clke,
	output wire                         sdram_cs_n,
	output wire                         sdram_ras_n,
	output wire                         sdram_cas_n,
	output wire                         sdram_we_n
);

sdram_dq_buf dq_buf [W_SDRAM_DATA-1:0] (
	.clk    (clk),
	.rst_n  (rst_n),
	.o      (ctrl_dq_o_next),
	.oe     (ctrl_dq_oe_next),
	.i      (ctrl_dq_i),
	.dq     (sdram_dq)
);

sdram_clk_buf clk_buf (
	.clk    (clk),
	.rst_n  (rst_n),
	.e      (ctrl_clk_enable),
	.clkout (sdram_clk)
);

sdram_addr_buf addr_buf [W_SDRAM_ADDR-1:0] (
	.clk   (clk),
	.rst_n (rst_n),
	.d     (ctrl_a_next),
	.q     (sdram_a)
);

sdram_addr_buf ctrl_buf [W_SDRAM_BANKSEL + W_SDRAM_DATA / 8 + 5 - 1 : 0] (
	.clk   (clk),
	.rst_n (rst_n),
	.d     ({ ctrl_ba_next,  ctrl_dqm_next,  ctrl_clke_next,  ctrl_cs_n_next,  ctrl_ras_n_next,  ctrl_cas_n_next,  ctrl_we_n_next}),
	.q     ({sdram_ba,      sdram_dqm,      sdram_clke,      sdram_cs_n,      sdram_ras_n,      sdram_cas_n,      sdram_we_n     })
);

endmodule

`ifndef YOSYS
`default_nettype wire
`endif
