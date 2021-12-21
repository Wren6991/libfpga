// Fully-registered tristate IO, for driving DQs on SDR SDRAM. Uses internal
// registers of IO cell, where applicable.

module sdram_dq_buf (
	input  wire clk,
	input  wire rst_n,

	input  wire o,  // output from core to pad
	input  wire oe, // active-high output enable
	output wire i,  // input to core from pad
	inout  wire dq  // pad connection
);

`ifdef FPGA_ECP5

wire o_pad;
wire oe_pad;
wire i_pad;

// The syn_useioff attribute tells nextpnr to pack these flops into the IO
// cell (or die trying). The IO cell must be the flop's only load.
// Flops driven with identical signals (e.g. the direction of a
// parallel data bus) may be merged during synthesis, which breaks the
// single-load requirement for IO packing.
//
// Putting a keep attribute on a `reg` doesn't prevent flop merging. Yosys
// does check for this attribute in opt_merge, but it sees its own $dff cell
// created during proc, and the keep attribute doesn't seem to be propagated.
// Dodgy workaround is to instantiate TRELLIS_FF directly.

(*syn_useioff*) (*keep*) TRELLIS_FF #(
	.GSR("DISABLED"),
	.CEMUX("1"),
	.CLKMUX("CLK"),
	.LSRMUX("LSR"),
	.REGSET("RESET")
) o_reg (
	.CLK (clk),
	.LSR (1'b0),
	.DI  (o),
	.Q   (o_pad)
);

(*syn_useioff*) (*keep*) TRELLIS_FF #(
	.GSR("DISABLED"),
	.CEMUX("1"),
	.CLKMUX("CLK"),
	.LSRMUX("LSR"),
	.REGSET("RESET")
) oe_reg (
	.CLK (clk),
	.LSR (1'b0),
	.DI  (!oe),  // pad signal is active-low
	.Q   (oe_pad)
);

// Capture is aligned with outgoing SDCLK posedge (which is on clk negedge, so
// that SDCLK is centre-aligned with our outputs)
IDDRX1F iddr (
	.D    (i_pad),
	.SCLK (clk),
	.RST  (1'b0),
	.Q0   (/* unused */),
	.Q1   (i)
);

TRELLIS_IO #(
	.DIR("BIDIR")
) iobuf (
	.B (dq),
	.I (o_pad), // Lattice use I for core->pad for some fuckawful reason
	.O (i_pad),
	.T (oe_pad)
);

`else

reg i_negedge;

always @ (negedge clk or negedge rst_n) begin
	if (!rst_n) begin
		i_negedge <= 1'b0;
	end else begin
		i_negedge <= dq;
	end
end

reg o_reg;
reg oe_reg;
reg i_reg;

always @ (posedge clk or negedge rst_n) begin
	if (!rst_n) begin
		o_reg <= 1'b0;
		oe_reg <= 1'b0;
		i_reg <= 1'b0;
	end else begin
		o_reg <= o;
		oe_reg <= oe;
		i_reg <= i_negedge;
	end
end

assign dq = oe_reg ? o_reg : 1'bz;
assign i = i_reg;

`endif

endmodule
