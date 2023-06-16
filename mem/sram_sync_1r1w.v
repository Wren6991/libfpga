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

// Inference/injection wrapper for one-write one-read synchronous memory

`default_nettype none

module sram_sync_1r1w #(
	parameter WIDTH = 16,
	parameter DEPTH = 1 << 8,
	parameter WRITE_GRANULE = WIDTH,
	parameter R2W_FORWARDING = 0,
	parameter PRELOAD_FILE = "",
	parameter W_ADDR = $clog2(DEPTH) // let this default
) (
	input  wire                           clk,

	input  wire [W_ADDR-1:0]              waddr,
	input  wire [WIDTH-1:0]               wdata,
	input  wire [WIDTH/WRITE_GRANULE-1:0] wen,

	input  wire [W_ADDR-1:0]              raddr,
	output wire [WIDTH-1:0]               rdata,
	input  wire                           ren
);

`ifdef YOSYS
(* no_rw_check *)
`endif
reg [WIDTH-1:0] mem [0:DEPTH-1];

initial if (PRELOAD_FILE != "" ) begin: preload
	$readmemh(PRELOAD_FILE, mem);
end

reg [WIDTH-1:0] rdata_raw;
always @ (posedge clk) begin: read_port
	if (ren) begin
		rdata_raw <= mem[raddr];
	end
end

always @ (posedge clk) begin: write_port
	integer i;
	for (i = 0; i < WIDTH / WRITE_GRANULE; i = i + 1) begin
		if (wen[i]) begin
			mem[waddr][i * WRITE_GRANULE +: WRITE_GRANULE] <= wdata[i * WRITE_GRANULE +: WRITE_GRANULE];
		end
	end
end

// Optional forwarding of write to read data when a read and write of the same
// address are coincident (without this logic you can get garbage)

generate
if (R2W_FORWARDING == 0) begin: no_r2w_forwarding
	assign rdata = rdata_raw;
end else begin: r2w_forwarding
	genvar g;

	reg [W_ADDR-1:0]              raddr_prev;
	reg [W_ADDR-1:0]              waddr_prev;
	reg [WIDTH-1:0]               wdata_prev;
	reg [WIDTH/WRITE_GRANULE-1:0] wen_prev;

	always @ (posedge clk) begin
		raddr_prev <= raddr;
		waddr_prev <= waddr;
		wdata_prev <= wdata;
		wen_prev <= wen;
	end

	for (g = 0; g < WIDTH / WRITE_GRANULE; g = g + 1) begin
		assign rdata[g * WRITE_GRANULE +: WRITE_GRANULE] = raddr_prev == waddr_prev && wen_prev[g] ?
			wdata_prev[g * WRITE_GRANULE +: WRITE_GRANULE] : rdata_raw[g * WRITE_GRANULE +: WRITE_GRANULE];
	end

end
endgenerate

endmodule

`ifndef YOSYS
`default_nettype wire
`endif

