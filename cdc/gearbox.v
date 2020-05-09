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

// Clock-crossing gearbox. Pack/unpack a parallel bus n bits wide at f MHz
// into a bus n / k bits wide at f * k MHz. The two clocks must derive from a
// common root oscillator.
//
// Ideally rst_n_in and rst_n_out should be derived from the same asynchronous
// reset, but each with their deassertion synchronised to the respective clock
// domain.
//
// Some pseudocode for selecting a reasonable storage size:
//
// size = lowest_common_multiple(W_IN, W_OUT)
// while size < W_IN * 4 or size < W_OUT * 4:
//     size = size * 2

 module gearbox #(
	parameter W_IN = 10,
	parameter W_OUT = 2,
	parameter STORAGE_SIZE = W_IN * W_OUT // This is not really the right expression, but it's difficult to calculate. Better to set this one by hand.
) (
	input  wire            clk_in,
	input  wire            rst_n_in,
	input  wire [W_IN-1:0] din,

	input  wire            clk_out,
	input  wire            rst_n_out,
(* keep = 1'b1 *) output reg [W_OUT-1:0] dout
);

localparam N_IN = STORAGE_SIZE / W_IN;
localparam N_OUT = STORAGE_SIZE / W_OUT;

parameter W_IN_PTR = $clog2(N_IN);
parameter W_OUT_PTR = $clog2(N_OUT);

(* keep = 1'b1 *) reg [STORAGE_SIZE-1:0] storage;

(* keep = 1'b1 *) reg [W_IN_PTR-1:0] in_ptr;

always @ (posedge clk_in or negedge rst_n_in) begin
	if (!rst_n_in) begin
		in_ptr <= N_IN / 2;
	end else begin
		if (in_ptr == N_IN - 1)
			in_ptr <= {W_IN_PTR{1'b0}};
		else
			in_ptr <= in_ptr + 1'b1;
		storage[in_ptr * W_IN +: W_IN] <= din;
	end
end

(* keep = 1'b1 *) reg [W_OUT_PTR-1:0] out_ptr;

always @ (posedge clk_out or negedge rst_n_out) begin
	if (!rst_n_out) begin
		out_ptr <= {W_OUT_PTR{1'b0}};
		dout <= {W_OUT{1'b1}};
	end else begin
		if (out_ptr == N_OUT - 1)
			out_ptr <= {W_OUT_PTR{1'b0}};
		else
			out_ptr <= out_ptr + 1'b1;
		dout <= storage[out_ptr * W_OUT +: W_OUT];
	end
end

endmodule
