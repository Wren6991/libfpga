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

module delay_ff #(
	parameter W = 1,
	parameter N = 1
) (
	input wire clk,
	input wire rst_n,

	input wire [W-1:0] d,
	output wire [W-1:0] q
);

generate
if (N == 0) begin: nodelay

	assign q = d;

end else begin: delay

	reg [W-1:0] delay_regs [0:N-1];
	integer i;
	always @ (posedge clk or negedge rst_n) begin
		if (!rst_n) begin
			for (i = 0; i < N; i = i + 1) begin
				delay_regs[i] <= {W{1'b0}};
			end
		end else begin
			delay_regs[0] <= d;
			for (i = 0; i < N - 1; i = i + 1) begin
				delay_regs[i + 1] <= delay_regs[i];
			end
		end
	end

	assign q = delay_regs[N - 1];

end
endgenerate

endmodule
