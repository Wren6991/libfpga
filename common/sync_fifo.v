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

`default_nettype none

module sync_fifo #(
	parameter DEPTH = 2,
	parameter WIDTH = 32,
	parameter W_LEVEL = $clog2(DEPTH + 1)
) (
	input  wire clk,
	input  wire rst_n,

	input  wire [WIDTH-1:0]   wdata,
	input  wire               wen,
	output wire [WIDTH-1:0]   rdata,
	input  wire               ren,

	input  wire               flush,

	output wire               full,
	output wire               empty,
	output reg  [W_LEVEL-1:0] level
);

// valid has an extra bit which should remain constant 0, and mem has an extra
// entry which is wired through to wdata. This is just to handle the loop
// boundary condition without tools complaining.
reg [WIDTH-1:0] mem [0:DEPTH];
reg [DEPTH:0]   valid;

// ----------------------------------------------------------------------------
// Control and datapath

wire push = wen && (ren || !full);
wire pop = ren && !empty;

always @ (posedge clk or negedge rst_n) begin
	if (!rst_n) begin
		valid <= {DEPTH+1{1'b0}};
	end else if (flush) begin
		valid <= {DEPTH+1{1'b0}};
	end else if (wen || ren) begin
		// 2 LUTs 1 FF per flag, all FFs have same clke
		valid <= (valid << push | {{DEPTH{1'b0}}, push}) >> pop;
	end
end

// No reset on datapath
always @ (posedge clk) begin: shift_data
	integer i;
	for (i = 0; i < DEPTH; i = i + 1) begin: data_stage
		if (ren || (wen && !valid[i] && (i == DEPTH - 1 || !valid[i + 1]))) begin
			mem[i] <= valid[i + 1] ? mem[i + 1] : wdata;
		end
	end
end

always @ (*) mem[DEPTH] = wdata;
assign rdata = mem[0];

// ----------------------------------------------------------------------------
// Flags

assign full = valid[DEPTH-1];
assign empty = !valid[0];

always @ (posedge clk or negedge rst_n) begin
	if (!rst_n) begin
		level <= {W_LEVEL{1'b0}};
	end else if (flush) begin
		level <= {W_LEVEL{1'b0}};
	end else begin
		level <= (level + {{W_LEVEL-1{1'b0}}, push}) - {{W_LEVEL-1{1'b0}}, pop};
	end
end

// ----------------------------------------------------------------------------
// Testbench junk vvv

//synthesis translate_off
always @ (posedge clk)
	if (wen && full)
		$display($time, ": WARNING %m: push on full");
always @ (posedge clk)
	if (ren && empty)
		$display($time, ": WARNING %m: pop on empty");
//synthesis translate_on


`ifdef FORMAL_CHECK_FIFO
initial assume(!rst_n);
always @ (posedge clk) begin
	assume(!(wen && full && !ren));
	assume(!(ren && empty));
	assume(!flush);
	assume(rst_n);

	assert((full) ~^ (level == DEPTH));
	assert((empty) ~^ (level == 0));
	assert(level <= DEPTH);
	assert((w_ptr == r_ptr) ~^ (full || empty));

	assert($past(ren) || (rdata == $past(rdata) || $past(empty)));
	assert($past(ren) || level >= $past(level));
	assert($past(wen) || level <= $past(level));
	assert(!($past(empty) && $past(wen) && rdata != $past(wdata)));
	assert(!($past(ren) && r_ptr == $past(r_ptr)));
	assert(!($past(wen) && w_ptr == $past(w_ptr)));
end
`elsif FORMAL
always @ (posedge clk) if (rst_n) begin
	assert(!(wen && full && !ren));
	assert(!(ren && empty));
end
`endif

endmodule

`ifndef YOSYS
`default_nettype wire
`endif
