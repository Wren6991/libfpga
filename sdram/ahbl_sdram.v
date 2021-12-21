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

// This controller is written to support the AS4C32M16SB SDRAM on my ULX3S
// board. It should be possible to adapt to other SDR SDRAMS.
//
// The SDRAM CLK is the same frequency as the system clock input.
//
// There is an APB slave port for configuration and initialisation, and an
// AHB-lite port for SDRAM access.
//
// The AHBL port *only* supports wrapped bursts of a fixed size, and the SDRAM
// mode register must be programmed to the same total size. Bulk transfers
// such as video out should be happy to do large naturally-aligned bursts, and
// caches can use wrapped bursts for critical-word-first fills. The AHBL burst
// size of this controller should therefore be the same as the cache line size
// for best results.
//
// AHBL BUSY transfers are *not supported*. HTRANS may only be IDLE, NSEQ or
// SEQ. If you ask for data you will damn well take it. If you ignore this
// advice, the behaviour is undefined -- it *may* cause your FPGA to turn
// inside out.
//
// The IO primitives are instantiated in a separate module, `io/sdram_phy.v`. This
// is separated out so that it can, if desired, be instantiated at the FPGA
// top-level wrapper, making it easier to support full-system simulation with
// 2-state simulators like CXXRTL. 2-state simulation is incompatible with
// bidirectional buses like SDRAM DQ.

`default_nettype none

module ahbl_sdram #(
	parameter COLUMN_BITS        = 10,
	parameter ROW_BITS           = 13, // Fixed row:bank:column, for now
	parameter W_SDRAM_BANKSEL    = 2,
	parameter W_SDRAM_ADDR       = 13,
	parameter W_SDRAM_DATA       = 16,
	parameter N_MASTERS          = 4,
	parameter LEN_AHBL_BURST     = 4,

	parameter FIXED_TIMINGS      = 0,
	// Following are for AS4C32M16SB-7 at 80 MHz
	parameter FIXED_TIME_RC       = 3'd4, // 63 ns 5 clk
	parameter FIXED_TIME_RCD      = 3'd1, // 21 ns 2 clk
	parameter FIXED_TIME_RP       = 3'd1, // 21 ns 2 clk
	parameter FIXED_TIME_RRD      = 3'd1, // 14 ns 2 clk
	parameter FIXED_TIME_RAS      = 3'd3, // 42 ns 4 clk
	parameter FIXED_TIME_WR       = 3'd1, // 14 ns 2 clk
	parameter FIXED_TIME_CAS      = 3'd1, // 2 clk
	parameter FIXED_TIME_REFRESH  = 12'd623, // 7.8 us 624 clk

	parameter W_HADDR            = 32,
	parameter W_HDATA            = 32  // Do not modify
) (
	// Clock and reset
	input  wire                         clk,
	input  wire                         rst_n,

	// SDRAM PHY connections
	output wire                         phy_clk_enable,
	output wire [W_SDRAM_BANKSEL-1:0]   phy_ba_next,
	output wire [W_SDRAM_ADDR-1:0]      phy_a_next,
	output wire [W_SDRAM_DATA/8-1:0]    phy_dqm_next,

	output wire [W_SDRAM_DATA-1:0]      phy_dq_o_next,
	output wire                         phy_dq_oe_next,
	input  wire [W_SDRAM_DATA-1:0]      phy_dq_i,

	output wire                         phy_clke_next,
	output wire                         phy_cs_n_next,
	output wire                         phy_ras_n_next,
	output wire                         phy_cas_n_next,
	output wire                         phy_we_n_next,

	// APB configuration slave
	input  wire                         apbs_psel,
	input  wire                         apbs_penable,
	input  wire                         apbs_pwrite,
	input  wire [15:0]                  apbs_paddr,
	input  wire [31:0]                  apbs_pwdata,
	output wire [31:0]                  apbs_prdata,
	output wire                         apbs_pready,
	output wire                         apbs_pslverr,

	// AHBL bus interfaces, 1 per master, wrapped burst only
	input  wire [N_MASTERS-1:0]         ahbls_hready,
	output wire [N_MASTERS-1:0]         ahbls_hready_resp,
	output wire [N_MASTERS-1:0]         ahbls_hresp,
	input  wire [N_MASTERS*W_HADDR-1:0] ahbls_haddr,
	input  wire [N_MASTERS-1:0]         ahbls_hwrite,
	input  wire [N_MASTERS*2-1:0]       ahbls_htrans,
	input  wire [N_MASTERS*3-1:0]       ahbls_hsize,
	input  wire [N_MASTERS*3-1:0]       ahbls_hburst,
	input  wire [N_MASTERS*4-1:0]       ahbls_hprot,
	input  wire [N_MASTERS-1:0]         ahbls_hmastlock,
	input  wire [N_MASTERS*W_HDATA-1:0] ahbls_hwdata,
	output wire [N_MASTERS*W_HDATA-1:0] ahbls_hrdata
);

// ----------------------------------------------------------------------------
// Control registers

wire        csr_en;
wire        csr_pu;

wire [2:0]  time_rc;
wire [2:0]  time_rcd;
wire [2:0]  time_rp;
wire [2:0]  time_rrd;
wire [2:0]  time_ras;
wire [2:0]  time_wr;
wire [1:0]  time_cas;

wire [11:0] cfg_refresh_interval;

wire        cmd_direct_we_n_next;
wire        cmd_direct_cas_n_next;
wire        cmd_direct_ras_n_next;
wire [12:0] cmd_direct_addr_next;
wire [1:0]  cmd_direct_ba_next;

wire        cmd_direct_we_n_push;
wire        cmd_direct_cas_n_push;
wire        cmd_direct_ras_n_push;
wire        cmd_direct_addr_push;
wire        cmd_direct_ba_push;

sdram_regs regblock (
	.clk                  (clk),
	.rst_n                (rst_n),

	.apbs_psel            (apbs_psel),
	.apbs_penable         (apbs_penable),
	.apbs_pwrite          (apbs_pwrite),
	.apbs_paddr           (apbs_paddr),
	.apbs_pwdata          (apbs_pwdata),
	.apbs_prdata          (apbs_prdata),
	.apbs_pready          (apbs_pready),
	.apbs_pslverr         (apbs_pslverr),

	.csr_en_o             (csr_en),
	.csr_pu_o             (csr_pu),

	.time_rc_o            (time_rc),
	.time_rcd_o           (time_rcd),
	.time_rp_o            (time_rp),
	.time_rrd_o           (time_rrd),
	.time_ras_o           (time_ras),
	.time_wr_o            (time_wr),
	.time_cas_o           (time_cas),

	.refresh_o            (cfg_refresh_interval),

	.cmd_direct_we_n_o    (cmd_direct_we_n_next),
	.cmd_direct_we_n_wen  (cmd_direct_we_n_push),
	.cmd_direct_cas_n_o   (cmd_direct_cas_n_next),
	.cmd_direct_cas_n_wen (cmd_direct_cas_n_push),
	.cmd_direct_ras_n_o   (cmd_direct_ras_n_next),
	.cmd_direct_ras_n_wen (cmd_direct_ras_n_push),
	.cmd_direct_addr_o    (cmd_direct_addr_next),
	.cmd_direct_addr_wen  (cmd_direct_addr_push),
	.cmd_direct_ba_o      (cmd_direct_ba_next),
	.cmd_direct_ba_wen    (cmd_direct_ba_push)
);

// ----------------------------------------------------------------------------
// AHBL slave interfaces

wire [N_MASTERS-1:0]                 scheduler_req_vld;
wire [N_MASTERS-1:0]                 scheduler_req_rdy;
wire [N_MASTERS*ROW_BITS-1:0]        scheduler_req_raddr;
wire [N_MASTERS*W_SDRAM_BANKSEL-1:0] scheduler_req_banksel;
wire [N_MASTERS*COLUMN_BITS-1:0]     scheduler_req_caddr;
wire [N_MASTERS-1:0]                 scheduler_req_write;

wire [N_MASTERS-1:0]                 sdram_write_rdy;
wire [N_MASTERS-1:0]                 sdram_read_vld;

ahbl_sdram_bus_interface #(
	.W_CADDR      (COLUMN_BITS),
	.W_RADDR      (ROW_BITS),
	.W_BANKSEL    (W_SDRAM_BANKSEL),
	.W_SDRAM_DATA (W_SDRAM_DATA),
	.N_MASTERS    (N_MASTERS),
	.W_HADDR      (W_HADDR),
	.W_HDATA      (W_HDATA)
) bus_interface (
	.clk               (clk),
	.rst_n             (rst_n),

	.ahbls_hready      (ahbls_hready),
	.ahbls_hready_resp (ahbls_hready_resp),
	.ahbls_hresp       (ahbls_hresp),
	.ahbls_haddr       (ahbls_haddr),
	.ahbls_hwrite      (ahbls_hwrite),
	.ahbls_htrans      (ahbls_htrans),
	.ahbls_hsize       (ahbls_hsize),
	.ahbls_hburst      (ahbls_hburst),
	.ahbls_hprot       (ahbls_hprot),
	.ahbls_hmastlock   (ahbls_hmastlock),
	.ahbls_hwdata      (ahbls_hwdata),
	.ahbls_hrdata      (ahbls_hrdata),

	.req_vld           (scheduler_req_vld),
	.req_rdy           (scheduler_req_rdy),
	.req_raddr         (scheduler_req_raddr),
	.req_banksel       (scheduler_req_banksel),
	.req_caddr         (scheduler_req_caddr),
	.req_write         (scheduler_req_write),

	.sdram_write_rdy   (sdram_write_rdy),
	.sdram_write_data  (phy_dq_o_next),

	.sdram_read_vld    (sdram_read_vld),
	.sdram_read_data   (phy_dq_i)
);

// ----------------------------------------------------------------------------
// SDRAM scheduler

wire [W_SDRAM_ADDR-1:0]    scheduler_cmd_a_next;
wire [W_SDRAM_BANKSEL-1:0] scheduler_cmd_ba_next;
wire                       scheduler_cmd_vld_next;
wire                       scheduler_cmd_ras_n_next;
wire                       scheduler_cmd_cas_n_next;
wire                       scheduler_cmd_we_n_next;

wire [N_MASTERS-1:0]       scheduler_dq_write_rdy_next;
wire [N_MASTERS-1:0]       scheduler_dq_read_vld_next;

sdram_scheduler #(
	.N_REQ          (N_MASTERS),
	.W_REFRESH_CTR  (12),
	.W_TIME_CTR     (3),
	.W_RADDR        (ROW_BITS),
	.W_BANKSEL      (W_SDRAM_BANKSEL),
	.W_CADDR        (COLUMN_BITS),
	.BURST_LEN      (LEN_AHBL_BURST * W_HDATA / W_SDRAM_DATA)
) inst_sdram_scheduler (
	.clk                  (clk),
	.rst_n                (rst_n),

	.cfg_refresh_en       (csr_en),
	.cfg_refresh_interval (FIXED_TIMINGS ? FIXED_TIME_REFRESH : cfg_refresh_interval),

	.time_rc              (FIXED_TIMINGS ? FIXED_TIME_RC  : time_rc),
	.time_rcd             (FIXED_TIMINGS ? FIXED_TIME_RCD : time_rcd),
	.time_rp              (FIXED_TIMINGS ? FIXED_TIME_RP  : time_rp),
	.time_rrd             (FIXED_TIMINGS ? FIXED_TIME_RRD : time_rrd),
	.time_ras             (FIXED_TIMINGS ? FIXED_TIME_RAS : time_ras),
	.time_wr              (FIXED_TIMINGS ? FIXED_TIME_WR  : time_wr),
	.time_cas             (FIXED_TIMINGS ? FIXED_TIME_CAS : time_cas),

	.req_vld              (scheduler_req_vld),
	.req_rdy              (scheduler_req_rdy),
	.req_raddr            (scheduler_req_raddr),
	.req_banksel          (scheduler_req_banksel),
	.req_caddr            (scheduler_req_caddr),
	.req_write            (scheduler_req_write),

	.cmd_vld              (scheduler_cmd_vld_next),
	.cmd_ras_n            (scheduler_cmd_ras_n_next),
	.cmd_cas_n            (scheduler_cmd_cas_n_next),
	.cmd_we_n             (scheduler_cmd_we_n_next),
	.cmd_addr             (scheduler_cmd_a_next),
	.cmd_banksel          (scheduler_cmd_ba_next),

	.dq_write             (scheduler_dq_write_rdy_next),
	.dq_read              (scheduler_dq_read_vld_next)
);

// Scheduler pipe stage is useful because dq_write is generated simultaneously
// with command decode (so uses bank state scoreboard etc), and is then used
// to mux hwdata and generate hready_resp.

reg [W_SDRAM_ADDR-1:0]    scheduler_cmd_a;
reg [W_SDRAM_BANKSEL-1:0] scheduler_cmd_ba;
reg                       scheduler_cmd_vld;
reg                       scheduler_cmd_ras_n;
reg                       scheduler_cmd_cas_n;
reg                       scheduler_cmd_we_n;

reg [N_MASTERS-1:0]       scheduler_dq_write_rdy;
reg [N_MASTERS-1:0]       scheduler_dq_read_vld;

always @ (posedge clk or negedge rst_n) begin
	if (!rst_n) begin
		scheduler_cmd_a        <= {W_SDRAM_ADDR{1'b0}};
		scheduler_cmd_ba       <= {W_SDRAM_BANKSEL{1'b0}};
		scheduler_cmd_vld      <= 1'b0;
		scheduler_cmd_ras_n    <= 1'b0;
		scheduler_cmd_cas_n    <= 1'b0;
		scheduler_cmd_we_n     <= 1'b0;
		scheduler_dq_write_rdy <= {N_MASTERS{1'b0}};
		scheduler_dq_read_vld  <= {N_MASTERS{1'b0}};
	end else begin
		scheduler_cmd_a        <= scheduler_cmd_a_next;
		scheduler_cmd_ba       <= scheduler_cmd_ba_next;
		scheduler_cmd_vld      <= scheduler_cmd_vld_next;
		scheduler_cmd_ras_n    <= scheduler_cmd_ras_n_next;
		scheduler_cmd_cas_n    <= scheduler_cmd_cas_n_next;
		scheduler_cmd_we_n     <= scheduler_cmd_we_n_next;
		scheduler_dq_write_rdy <= scheduler_dq_write_rdy_next;
		scheduler_dq_read_vld  <= scheduler_dq_read_vld_next;
	end
end

// ----------------------------------------------------------------------------
// IO interface

reg                        cmd_direct_we_n;
reg                        cmd_direct_cas_n;
reg                        cmd_direct_ras_n;
reg [W_SDRAM_ADDR-1:0]     cmd_direct_addr;
reg [W_SDRAM_BANKSEL-1:0]  cmd_direct_ba;
reg                        cmd_direct_push;

always @ (posedge clk or negedge rst_n) begin
	if (!rst_n) begin
		cmd_direct_we_n <= 1'b0;
		cmd_direct_cas_n <= 1'b0;
		cmd_direct_ras_n <= 1'b0;
		cmd_direct_addr <= {W_SDRAM_ADDR{1'b0}};
		cmd_direct_ba <= {W_SDRAM_BANKSEL{1'b0}};
		cmd_direct_push <= 1'b0;
	end else begin
		cmd_direct_we_n <= cmd_direct_we_n_next;
		cmd_direct_cas_n <= cmd_direct_cas_n_next;
		cmd_direct_ras_n <= cmd_direct_ras_n_next;
		cmd_direct_addr <= cmd_direct_addr_next;
		cmd_direct_ba <= cmd_direct_ba_next;
		cmd_direct_push <=
			cmd_direct_we_n_push ||
			cmd_direct_cas_n_push ||
			cmd_direct_ras_n_push ||
			cmd_direct_addr_push ||
			cmd_direct_ba_push;
	end
end


assign phy_clk_enable = csr_pu; // This enables the toggling of sdram_clk, NOT the same as sdram_clke

assign phy_a_next     = scheduler_cmd_vld ? scheduler_cmd_a : cmd_direct_push ? cmd_direct_addr : {W_SDRAM_ADDR{1'b0}};
assign phy_ba_next    = scheduler_cmd_vld ? scheduler_cmd_ba : cmd_direct_push ? cmd_direct_ba : {W_SDRAM_BANKSEL{1'b0}};
assign phy_clke_next  = csr_pu;
assign phy_cs_n_next  = !(cmd_direct_push || scheduler_cmd_vld);
assign phy_dqm_next   = {W_SDRAM_DATA/8{1'b0}}; // Always asserted!
assign phy_ras_n_next = scheduler_cmd_vld ? scheduler_cmd_ras_n : cmd_direct_push ? cmd_direct_ras_n : 1'b1;
assign phy_cas_n_next = scheduler_cmd_vld ? scheduler_cmd_cas_n : cmd_direct_push ? cmd_direct_cas_n : 1'b1;
assign phy_we_n_next  = scheduler_cmd_vld ? scheduler_cmd_we_n  : cmd_direct_push ? cmd_direct_we_n  : 1'b1;

// Delay line for read strobes
localparam IO_ROUNDTRIP = 2;
reg [N_MASTERS-1:0] dq_read_delay [0:IO_ROUNDTRIP-1];

always @ (posedge clk or negedge rst_n) begin: io_delay_match
	integer i;
	if (!rst_n) begin
		for (i = 0; i < IO_ROUNDTRIP; i = i + 1)
			dq_read_delay[i] <= {N_MASTERS{1'b0}};
	end else begin
		dq_read_delay[0] <= scheduler_dq_read_vld;
		for (i = 1; i < IO_ROUNDTRIP; i = i + 1)
			dq_read_delay[i] <= dq_read_delay[i - 1];
	end
end

assign sdram_write_rdy = scheduler_dq_write_rdy;
assign sdram_read_vld = dq_read_delay[IO_ROUNDTRIP - 1];

assign phy_dq_oe_next = |scheduler_dq_write_rdy;

endmodule

`ifndef YOSYS
`default_nettype wire
`endif
