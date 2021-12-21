module sdram_clk_buf (
	input  wire clk,
	input  wire rst_n,
	input  wire e,
	output wire clkout
);

// Inverted clock output to get centre-aligned SDR
ddr_out ckbuf (
	.clk (clk),
	.rst_n (rst_n),

	.d_rise (1'b0),
	.d_fall (e),
	.e      (1'b1),
	.q      (clkout)
);

endmodule
