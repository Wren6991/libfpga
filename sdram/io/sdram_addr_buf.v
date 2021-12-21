module sdram_addr_buf (
	input  wire clk,
	input  wire rst_n,
	input  wire d,
	output wire q
);

`ifdef FPGA_ECP5

(*syn_useioff*) (*keep*) TRELLIS_FF #(
	.GSR("DISABLED"),
	.CEMUX("1"),
	.CLKMUX("CLK"),
	.LSRMUX("LSR"),
	.REGSET("RESET")
) o_reg (
	.CLK (clk),
	.LSR (1'b0),
	.DI  (d),
	.Q   (q)
);

`else

reg q_r;

always @ (posedge clk or negedge rst_n) begin
	if (!rst_n) begin
		q_r <= 1'b0;
	end else begin
		q_r <= d;
	end
end

assign q = q_r;

`endif

endmodule
