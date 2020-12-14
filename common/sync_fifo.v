/**********************************************************************
 * DO WHAT THE FUCK YOU WANT TO AND DON'T BLAME US PUBLIC LICENSE     *
 *                    Version 3, April 2008                           *
 *                                                                    *
 * Copyright (C) 2018-2020 Luke Wren                                  *
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

// Synchronous FIFO
// DEPTH can be any integer >= 1.

module sync_fifo #(
	parameter DEPTH = 2,
	parameter WIDTH = 32,
	parameter W_LEVEL = $clog2(DEPTH + 1)
) (
	input  wire clk,
	input  wire rst_n,

	input  wire [WIDTH-1:0]   w_data,
	input  wire               w_en,
	output wire [WIDTH-1:0]   r_data,
	input  wire               r_en,

	output wire               full,
	output wire               empty,
	output reg  [W_LEVEL-1:0] level
);

reg [WIDTH-1:0] mem [0:DEPTH];
reg [DEPTH-1:0] valid;

// ----------------------------------------------------------------------------
// Control and datapath

wire push = w_en && !full;
wire pop = r_en && !empty;

always @ (posedge clk or negedge rst_n) begin
	if (!rst_n) begin
		valid <= {DEPTH{1'b0}};
	end else if (w_en || r_en) begin
		// 2 LUTs 1 FF per flag, all FFs have same clke
		valid <= (valid << push | {{DEPTH-1{1'b0}}, push}) >> pop;
	end
end

// No reset on datapath
always @ (posedge clk) begin: shift_data
	integer i;
	for (i = 0; i < DEPTH; i = i + 1) begin: data_stage
		if (r_en || (w_en && !valid[i] && (i == DEPTH - 1 || !valid[i + 1]))) begin
			mem[i] <= valid[i + 1] ? mem[i + 1] : w_data;
		end
	end
end

always @ (*) mem[DEPTH] = w_data;
assign r_data = mem[0];

// ----------------------------------------------------------------------------
// Flags

assign full = valid[DEPTH-1];
assign empty = !valid[0];

always @ (posedge clk or negedge rst_n) begin
	if (!rst_n) begin
		level <= {W_LEVEL{1'b0}};
	end else begin
		level <= level + push - pop;
	end
end

// ----------------------------------------------------------------------------
// Testbench junk vvv

//synthesis translate_off
always @ (posedge clk)
	if (w_en && full)
		$display($time, ": WARNING %m: push on full");
always @ (posedge clk)
	if (r_en && empty)
		$display($time, ": WARNING %m: pop on empty");
//synthesis translate_on


`ifdef FORMAL_CHECK_FIFO
initial assume(!rst_n);
always @ (posedge clk) begin
	assume(!(w_en && full && !r_en));
	assume(!(r_en && empty));
	assume(rst_n);

	assert((full) ~^ (level == DEPTH));
	assert((empty) ~^ (level == 0));
	assert(level <= DEPTH);
	assert((w_ptr == r_ptr) ~^ (full || empty));

	assert($past(r_en) || (r_data == $past(r_data) || $past(empty)));
	assert($past(r_en) || level >= $past(level));
	assert($past(w_en) || level <= $past(level));
	assert(!($past(empty) && $past(w_en) && r_data != $past(w_data)));
	assert(!($past(r_en) && r_ptr == $past(r_ptr)));
	assert(!($past(w_en) && w_ptr == $past(w_ptr)));
end
`endif

endmodule
