// Adapt AHB bus to an async SRAM with half width.
// Feels like there is a loss of generality/parameterisation here,
// but for RISCBoy there is some scope to do e.g. double-pumped reads
// to improve performance, so makes sense to have a special-case
// half-width-only controller to inject these.

// Size of memory is DEPTH * W_SRAM_DATA

`default_nettype none

module ahb_async_sram_halfwidth #(
	parameter W_DATA = 32,
	parameter W_ADDR = 32,
	parameter DEPTH = 1 << 11,
	parameter W_SRAM_ADDR = $clog2(DEPTH), // Let this default
	parameter W_SRAM_DATA = W_DATA / 2     // Let this default
) (
	// Globals
	input wire                      clk,
	input wire                      rst_n,

	// AHB lite slave interface
	output wire                     ahbls_hready_resp,
	input  wire                     ahbls_hready,
	output wire                     ahbls_hresp,
	input  wire [W_ADDR-1:0]        ahbls_haddr,
	input  wire                     ahbls_hwrite,
	input  wire [1:0]               ahbls_htrans,
	input  wire [2:0]               ahbls_hsize,
	input  wire [2:0]               ahbls_hburst,
	input  wire [3:0]               ahbls_hprot,
	input  wire                     ahbls_hmastlock,
	input  wire [W_DATA-1:0]        ahbls_hwdata,
	output wire [W_DATA-1:0]        ahbls_hrdata,

	output wire [W_SRAM_ADDR-1:0]   sram_addr,
	output wire [W_SRAM_DATA-1:0]   sram_dq_out,
	output wire [W_SRAM_DATA-1:0]   sram_dq_oe,
	input  wire [W_SRAM_DATA-1:0]   sram_dq_in,
	output wire                     sram_ce_n,
	output wire                     sram_we_n, // DDR output
	output wire                     sram_oe_n,
	output wire [W_SRAM_DATA/8-1:0] sram_byte_n
);

parameter W_BYTEADDR = $clog2(W_SRAM_DATA / 8);

assign ahbls_hresp = 1'b0;

reg hready_r;
reg long_dphase;
reg write_dph;
reg read_dph;
reg addr_lsb;

// AHBL decode and muxing

wire [W_SRAM_DATA/8-1:0] bytemask_noshift = ~({W_SRAM_DATA/8{1'b1}} << (8'h1 << ahbls_hsize));
wire [W_SRAM_DATA/8-1:0] bytemask_aph = bytemask_noshift << ahbls_haddr[W_BYTEADDR-1:0];
wire aphase_full_width = (8'h1 << ahbls_hsize) == W_DATA / 8; // indicates next dphase will be long

wire [W_SRAM_DATA-1:0] sram_rdata;
wire [W_SRAM_DATA-1:0] sram_wdata = ahbls_hwdata[(addr_lsb ? W_SRAM_DATA : 0) +: W_SRAM_DATA];
reg  [W_SRAM_DATA-1:0] rdata_buf;
assign ahbls_hrdata = {sram_rdata, long_dphase ? rdata_buf : sram_rdata};

assign ahbls_hready_resp = hready_r;

// AHBL state machine

always @ (posedge clk or negedge rst_n) begin
	if (!rst_n) begin
		hready_r <= 1'b1;
		long_dphase <= 1'b0;
		write_dph <= 1'b0;
		read_dph <= 1'b0;
		addr_lsb <= 1'b0;
	end else if (ahbls_hready) begin
		if (ahbls_htrans[1]) begin
			long_dphase <= aphase_full_width;
			hready_r <= !aphase_full_width;
			write_dph <= ahbls_hwrite;
			read_dph <= !ahbls_hwrite;
			addr_lsb <= ahbls_haddr[W_BYTEADDR];
		end	else begin
			write_dph <= 1'b0;
			long_dphase <= 1'b0;
			read_dph <= 1'b0;
			hready_r <= 1'b1;
		end
	end else if (long_dphase && !hready_r) begin
		rdata_buf <= sram_rdata;
		hready_r <= 1'b1;
		addr_lsb <= 1'b1;
	end
end

// SRAM PHY hookup

wire ce_aph = ahbls_htrans[1] && ahbls_hready;
wire ce_dph = long_dphase && !hready_r;

reg [W_SRAM_ADDR-1:0] addr_dph;
always @ (posedge clk or negedge rst_n) begin
	if (!rst_n) begin
		addr_dph <= {W_SRAM_ADDR{1'b0}};
	end else if (ahbls_hready) begin
		addr_dph <= ahbls_haddr[W_BYTEADDR +: W_SRAM_ADDR] | {{W_SRAM_ADDR-1{1'b0}}, 1'b1};
	end
end

assign sram_ce_n   = !( ce_aph                   ||  ce_dph               );
assign sram_we_n   = !((ce_aph &&  ahbls_hwrite) || (ce_dph &&  write_dph));
assign sram_oe_n   = !((ce_aph && !ahbls_hwrite) || (ce_dph && !write_dph));

assign sram_addr   = ce_dph ? addr_dph : ahbls_haddr[W_BYTEADDR +: W_SRAM_ADDR];
assign sram_byte_n = ~(bytemask_aph | {W_SRAM_DATA/8{ce_dph}});

assign sram_rdata  = sram_dq_in;
assign sram_dq_out = sram_wdata;
`ifdef FPGA_ICE40
// Output registers are built into pad (relies on the negedge trick for DQ wdata)
assign sram_dq_oe  = {W_SRAM_DATA{!sram_we_n}};
`else
// No output registers on DQ
assign sram_dq_oe  = {W_SRAM_DATA{write_dph}};
`endif
endmodule

`ifndef YOSYS
`default_nettype wire
`endif
