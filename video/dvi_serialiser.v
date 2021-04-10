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

module dvi_serialiser #(
	// Commoning up the ring counters on iCE40 gives much better PLB packing due
	// to larger CE groups (best to leave alone if not at the ragged edge):
	parameter EXTERNAL_RING_COUNTERS = 0
) (
	input  wire       clk_pix,
	input  wire       rst_n_pix,
	input  wire [1:0] external_ctr_pix,
	input  wire       clk_x5,
	input  wire       rst_n_x5,
	input  wire [9:0] external_ctr_x5,

	input  wire [9:0] d,
	output wire       qp,
	output wire       qn
);

reg [9:0] d_delay;
wire [1:0] data_x5;

always @ (posedge clk_pix) begin
	d_delay <= d;
end

gearbox #(
	.W_IN                  (10),
	.W_OUT                 (2),
`ifdef FPGA_ICE40
	.CE_GROUPING_FACTOR    (5),
`endif
	.USE_EXTERNAL_COUNTERS (EXTERNAL_RING_COUNTERS),
	.STORAGE_SIZE          (20)
) gearbox_u (
	.clk_in           (clk_pix),
	.rst_n_in         (rst_n_pix),
	.din              (d_delay),

	.clk_out          (clk_x5),
	.rst_n_out        (rst_n_x5),
	.dout             (data_x5),

	.external_ctr_in  (external_ctr_pix),
	.external_ctr_out (external_ctr_x5)
);

reg [1:0] data_x5_delay;
reg [1:0] data_x5_ndelay;

always @ (posedge clk_x5) begin
	data_x5_delay <= data_x5;
	data_x5_ndelay <= ~data_x5;
end

ddr_out ddrp (
	.clk    (clk_x5),
	.rst_n  (rst_n_x5),

	.d_rise (data_x5_delay[0]),
	.d_fall (data_x5_delay[1]),
	.e      (1'b1),
	.q      (qp)
);

ddr_out ddrn (
	.clk    (clk_x5),
	.rst_n  (rst_n_x5),

	.d_rise (data_x5_ndelay[0]),
	.d_fall (data_x5_ndelay[1]),
	.e      (1'b1),
	.q      (qn)
);

endmodule
