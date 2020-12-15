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
	// You should set this by hand, it may be hugely pessimistic *or* optimistic:
	parameter STORAGE_SIZE = W_IN * W_OUT
) (
	input  wire             clk_in,
	input  wire             rst_n_in,
	input  wire [W_IN-1:0]  din,

	input  wire             clk_out,
	input  wire             rst_n_out,
	output reg  [W_OUT-1:0] dout
);

localparam N_IN = STORAGE_SIZE / W_IN;
localparam N_OUT = STORAGE_SIZE / W_OUT;

(* keep = 1'b1 *) reg [STORAGE_SIZE-1:0] launch_reg;
(* keep = 1'b1 *) reg [STORAGE_SIZE-1:0] capture_reg;

// ----------------------------------------------------------------------------
// Apply transitions to sections of launch register, in a circular manner,
// across successive clk_in cycles

reg [N_IN-1:0] wmask;

always @ (posedge clk_in or negedge rst_n_in) begin
	if (!rst_n_in) begin
		wmask <= {{N_IN-1{1'b0}}, 1'b1};
	end else begin
		wmask <= {wmask[N_IN-2:0], wmask[N_IN-1]};
	end
end

always @ (posedge clk_in) begin: wport
	integer i;
	for (i = 0; i < N_IN; i = i + 1) begin
		if (wmask[i])
			launch_reg[i * W_IN +: W_IN] <= din;
	end
end

// ----------------------------------------------------------------------------
// Apply enables to sections of capture register, in a circular manner, across
// successive clk_out cycles (hopefully staying distant from the transitions!)

reg [N_OUT-1:0] rmask;

always @ (posedge clk_out or negedge rst_n_out) begin
	if (!rst_n_out) begin
		// Reads start as far as possible from writes
		rmask <= {{N_OUT-1{1'b0}}, 1'b1} << (N_OUT / 2);
	end else begin
		rmask <= {rmask[N_OUT-2:0], rmask[N_OUT-1]};
	end
end

always @ (posedge clk_out) begin: capture_proc
	integer i;
	for (i = 0; i < N_OUT; i = i + 1) begin
		if (rmask[i])
			capture_reg[i * W_OUT +: W_OUT] <= launch_reg[i * W_OUT +: W_OUT];
	end
end

// ----------------------------------------------------------------------------
// CDC done, now on to the muxing

wire [N_OUT-1:0] rmask_delayed = {rmask[0], rmask[N_OUT-1:1]};
reg [STORAGE_SIZE-1:0] captured_masked;

always @ (posedge clk_out) begin: output_mask
	integer i;
	for (i = 0; i < STORAGE_SIZE; i = i + 1) begin
		captured_masked[i] <= capture_reg[i] && rmask_delayed[i / W_OUT];
	end
end

// Do the OR reduction in one cycle. For 20 storage flops this is a 10:1
// reduction, which costs 2 LUT delays. Easiest way to reduce further is to add
// an empty pipe stage afterward and tell the tools to retime :) OR reductions
// are very retimable.

reg [W_OUT-1:0] muxed;

always @ (*) begin: output_mux
	integer i, j;
	for (i = 0; i < W_OUT; i = i + 1) begin
		muxed[i] = 1'b0;
		for (j = 0; j < N_OUT; j = j + 1) begin
			muxed[i] = muxed[i] || captured_masked[j * W_OUT + i];
		end
	end
end

always @ (posedge clk_out) begin
	dout <= muxed;
end

endmodule
