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

`default_nettype none

// - Tracks bank state
// - Generates AutoRefresh commands at regular intervals
// - Generates SDRAM commands to satisfy read/write burst requests coming in
//   from the system bus
// - Generates enable signals for DQ launch and capture

module sdram_scheduler #(
	parameter N_REQ          = 4,
	parameter W_REFRESH_CTR  = 12,
	parameter W_RADDR        = 13,
	parameter W_BANKSEL      = 2,
	parameter W_CADDR        = 10,
	parameter BURST_LEN      = 8,  // We ONLY support fixed size bursts. Not runtime configurable
	                               // because it is a function of busfabric.
	parameter W_TIME_CTR     = 3   // Counter size for SDRAM timing restrictions
) (
	input  wire                       clk,
	input  wire                       rst_n,

	input  wire                       cfg_refresh_en,
	input  wire [W_REFRESH_CTR-1:0]   cfg_refresh_interval,

	input  wire [W_TIME_CTR-1:0]      time_rc,  // tRC: Row cycle time, RowActivate to RowActivate, same bank.
	input  wire [W_TIME_CTR-1:0]      time_rcd, // tRCD: RAS to CAS delay.
	input  wire [W_TIME_CTR-1:0]      time_rp,  // tRP: Precharge to RowActivate delay (same bank)
	input  wire [W_TIME_CTR-1:0]      time_rrd, // tRRD: RowActivate to RowActivate, different banks
	input  wire [W_TIME_CTR-1:0]      time_ras, // tRAS: RowActivate to Precharge, same bank
	input  wire [W_TIME_CTR-1:0]      time_wr,  // tWR: Write to Precharge, same bank
	input  wire [1:0]                 time_cas, // tCAS: CAS-to-data latency

	input  wire [N_REQ-1:0]           req_vld,
	output wire [N_REQ-1:0]           req_rdy,
	input  wire [N_REQ*W_RADDR-1:0]   req_raddr,
	input  wire [N_REQ*W_BANKSEL-1:0] req_banksel,
	input  wire [N_REQ*W_CADDR-1:0]   req_caddr,
	input  wire [N_REQ-1:0]           req_write,

	output wire                       cmd_vld,
	output wire                       cmd_ras_n,
	output wire                       cmd_cas_n,
	output wire                       cmd_we_n,
	output wire [W_RADDR-1:0]         cmd_addr,
	output wire [W_BANKSEL-1:0]       cmd_banksel,

	output wire [N_REQ-1:0]           dq_write,
	output wire [N_REQ-1:0]           dq_read
);

localparam N_BANKS = 1 << W_BANKSEL;

// ras_n, cas_n, we_n
localparam CMD_REFRESH   = 3'b001;
localparam CMD_PRECHARGE = 3'b010;
localparam CMD_ACTIVATE  = 3'b011;
localparam CMD_WRITE     = 3'b100;
localparam CMD_READ      = 3'b101;

// ----------------------------------------------------------------------------
// Timing constraint scoreboard

reg [W_TIME_CTR-1:0] ctr_ras_to_ras_same [0:N_BANKS-1]; // tRC
reg [W_TIME_CTR-1:0] ctr_ras_to_cas      [0:N_BANKS-1]; // tRCD
reg [W_TIME_CTR-1:0] ctr_pre_to_ras      [0:N_BANKS-1]; // tRP
reg [W_TIME_CTR-1:0] ctr_ras_to_ras_any;                // tRRD, global across all banks
reg [W_TIME_CTR-1:0] ctr_ras_to_pre      [0:N_BANKS-1]; // tRAS
reg [3:0]            ctr_cas_to_pre      [0:N_BANKS-1]; // tWR, and blocking precharge during read bursts

localparam PRECHARGE_ALL_ADDR_BIT = 10;
wire precharge_is_all = cmd_addr[PRECHARGE_ALL_ADDR_BIT];

wire [2:0] cmd = {cmd_ras_n, cmd_cas_n, cmd_we_n};

always @ (posedge clk or negedge rst_n) begin: timing_scoreboard_update
	integer i;
	if (!rst_n) begin
		for (i = 0; i < N_BANKS; i = i + 1) begin
			ctr_ras_to_ras_same[i] <= {W_TIME_CTR{1'b0}};
			ctr_ras_to_cas     [i] <= {W_TIME_CTR{1'b0}};
			ctr_pre_to_ras     [i] <= {W_TIME_CTR{1'b0}};
			ctr_ras_to_pre     [i] <= {W_TIME_CTR{1'b0}};
			ctr_cas_to_pre     [i] <= {W_TIME_CTR{1'b0}};
		end
		ctr_ras_to_ras_any <= {W_TIME_CTR{1'b0}};
	end else begin
		// By default, saturating down count
		for (i = 0; i < N_BANKS; i = i + 1) begin
			ctr_ras_to_ras_same[i] <= ctr_ras_to_ras_same[i] - |ctr_ras_to_ras_same[i];
			ctr_ras_to_cas[i] <= ctr_ras_to_cas[i] - |ctr_ras_to_cas[i];
			ctr_pre_to_ras[i] <= ctr_pre_to_ras[i] - |ctr_pre_to_ras[i];
			ctr_ras_to_pre[i] <= ctr_ras_to_pre[i] - |ctr_ras_to_pre[i];
			ctr_cas_to_pre[i] <= ctr_cas_to_pre[i] - |ctr_cas_to_pre[i];
		end
		ctr_ras_to_ras_any <= ctr_ras_to_ras_any - |ctr_ras_to_ras_any;

		// Reload each counter with user-supplied value if a relevant command is
		// issued (note that the given values are expressed as cycles - 1)
		if (cmd_vld) begin
			for (i = 0; i < N_BANKS; i = i + 1) begin
				if (cmd == CMD_ACTIVATE && cmd_banksel == i || cmd == CMD_REFRESH) begin
					ctr_ras_to_ras_same[i] <= time_rc;
					ctr_ras_to_cas[i] <= time_rcd;
					ctr_ras_to_pre[i] <= time_ras;
				end
				if (cmd == CMD_PRECHARGE && (precharge_is_all || cmd_banksel == i)) begin
					ctr_pre_to_ras[i] <= time_rp;
				end
				if (cmd == CMD_WRITE && cmd_banksel == i) begin
					ctr_cas_to_pre[i] <= BURST_LEN - 1 + (time_wr + 1);
				end else if (cmd == CMD_READ && cmd_banksel == i) begin
					ctr_cas_to_pre[i] <= BURST_LEN - 1 + (time_cas + 1);
				end
			end
			if (cmd == CMD_ACTIVATE) begin
				ctr_ras_to_ras_any <= time_rrd;
			end
		end
	end
end

// Refresh request at regular intervals. There can be some delay in the
// refresh being issued (e.g. if there is an ongoing data burst at the point
// where the refresh is requested, or if a recent ACT stops us from PREing a
// bank) so we continue counting whilst the request is outstanding, to make
// sure we get a consistent steady-state refresh rate.

reg [W_REFRESH_CTR-1:0] refresh_ctr;
reg                     refresh_req;

wire refresh_issued = cmd_vld && cmd == CMD_REFRESH;

always @ (posedge clk or negedge rst_n) begin
	if (!rst_n) begin
		refresh_ctr <= {W_REFRESH_CTR{1'b0}};
		refresh_req <= 1'b0;
	end else if (!cfg_refresh_en) begin
		// Refresh is disabled at startup, enabled once software has done mode
		// register programming etc.
		refresh_ctr <= {W_REFRESH_CTR{1'b0}};
		refresh_req <= 1'b0;
	end else begin
		refresh_ctr <= refresh_ctr + 1'b1 - (refresh_issued ? cfg_refresh_interval : {W_REFRESH_CTR{1'b0}});
		refresh_req <= (refresh_req && !refresh_issued) || refresh_ctr == cfg_refresh_interval;
	end
end

// ----------------------------------------------------------------------------
// Bank state scoreboard

reg [N_BANKS-1:0] bank_active;
reg [W_RADDR-1:0] bank_active_row [0:N_BANKS-1];

always @ (posedge clk or negedge rst_n) begin: bank_scoreboard_update
	integer i;
	if (!rst_n) begin
		for (i = 0; i < N_BANKS; i = i + 1) begin
			bank_active_row[i] <= {W_RADDR{1'b0}};
			bank_active[i] <= 1'b0;
		end
	end else if (cmd_vld) begin
		for (i = 0; i < N_BANKS; i = i + 1) begin
			if (cmd == CMD_PRECHARGE && (precharge_is_all || cmd_banksel == i)) begin
				bank_active[i] <= 1'b0;
			end else if (cmd == CMD_ACTIVATE && cmd_banksel == i) begin
				bank_active[i] <= 1'b1;
				bank_active_row[i] <= cmd_addr;
			end
		end
	end
end

// ----------------------------------------------------------------------------
// DQ scoreboard

// We maintain a shift register of what operation the DQs are performing for n
// cycles into the future (read for some master, write for some master, or
// no operation) and also 1 cycle into the past so we can check turnarounds.
//
// We schedule the DQs in time with our issue of addresses and commands. The
// actual read timing may need to be adjusted later to match the delay of the
// launch and capture registers, but this is someone else's problem.

wire [N_REQ-1:0] current_req;

// burst len + max CAS + 1 extra for previous cycle
localparam DQ_SCHEDULE_LEN = BURST_LEN + 4 + 1;
// Record is: valid, read_nwrite, master ID
parameter W_REQSEL = $clog2(N_REQ);
localparam W_DQ_RECORD = 2 + W_REQSEL;

wire [W_DQ_RECORD-1:0] write_record;
wire [W_DQ_RECORD-1:0] read_record;

// Avoid 0-width signal when encoding master ID
generate
if (N_REQ == 1) begin: small_record
	assign write_record = 2'b10;
	assign read_record = 2'b11;
end else begin: big_record
	wire [W_REQSEL-1:0] reqsel;
	onehot_encoder #(
		.W_INPUT (N_REQ)
	) req_encode (
		.in  (current_req),
		.out (reqsel)
	);
	assign write_record = {2'b10, reqsel};
	assign read_record = {2'b11, reqsel};
end
endgenerate


wire [DQ_SCHEDULE_LEN-1:0] write_cycle_mask = {{DQ_SCHEDULE_LEN-BURST_LEN{1'b0}}, {BURST_LEN{1'b1}}};
wire [DQ_SCHEDULE_LEN-1:0] read_cycle_mask =  {{DQ_SCHEDULE_LEN-BURST_LEN-1{1'b0}}, {BURST_LEN{1'b1}}, 1'b0} << time_cas;

reg [W_DQ_RECORD-1:0] dq_schedule [0:DQ_SCHEDULE_LEN-1];

wire write_cmd_issued = cmd_vld && cmd == CMD_WRITE;
wire read_cmd_issued = cmd_vld && cmd == CMD_READ;

always @ (posedge clk or negedge rst_n) begin: dq_schedule_update
	integer i;
	if (!rst_n) begin
		for (i = 0; i < DQ_SCHEDULE_LEN; i = i + 1) begin
			dq_schedule[i] <= {W_DQ_RECORD{1'b0}};
		end
	end else begin
		for (i = 0; i < DQ_SCHEDULE_LEN; i = i + 1) begin
			dq_schedule[i] <= (i < DQ_SCHEDULE_LEN - 1 ? dq_schedule[i + 1] : {W_DQ_RECORD{1'b0}})
				| write_record & {W_DQ_RECORD{write_cmd_issued && write_cycle_mask[i]}}
				| read_record & {W_DQ_RECORD{read_cmd_issued && read_cycle_mask[i]}};
		end
	end
end

// Can issue write if DQs are free for the next BURST_LEN cycles (including
// this cycle), and there was no read on the previous cycle.
reg dq_write_contention_ok;
always @ (*) begin: check_dq_write_contention_ok
	integer i;
	dq_write_contention_ok = 1'b1;
	for (i = 1; i < BURST_LEN + 1; i = i + 1) begin
		dq_write_contention_ok = dq_write_contention_ok && !dq_schedule[i][W_DQ_RECORD-1];
	end
	dq_write_contention_ok = dq_write_contention_ok && dq_schedule[0][W_DQ_RECORD-1:W_DQ_RECORD-2] != 2'b11;
end

// Can issue read if DQs are free from tCAS to tCAS + BURST_LEN - 1, and there
// was no write on tCAS - 1. (turnaround/contention)
//
// Additionally make sure that there is no *write* cycle specifically on the
// current cycle, as issuing a Read at any point during a Write burst seems to
// terminate the Write (not clear from documentation but this is how the
// MT48LC32M16 vendor model behaves)
reg dq_read_contention_ok;
always @ (*) begin: check_dq_read_contention_ok
	integer i;
	dq_read_contention_ok = 1'b1;
	for (i = 0; i < DQ_SCHEDULE_LEN; i = i + 1) begin
		dq_read_contention_ok = dq_read_contention_ok && !(read_cycle_mask[i] && dq_schedule[i][W_DQ_RECORD-1]);
	end
	dq_read_contention_ok = dq_read_contention_ok && dq_schedule[time_cas][W_DQ_RECORD-1:W_DQ_RECORD-2] != 2'b10;
	dq_read_contention_ok = dq_read_contention_ok && dq_schedule[1][W_DQ_RECORD-1:W_DQ_RECORD-2] != 2'b10;
end

// ----------------------------------------------------------------------------
// Arbitration/queueing

// We process one request at a time, with simple priority selection. This gets
// reasonable bank concurrency when there is no bank thrashing, because we can
// start preparing the bank for the next request whilst the previous request's
// data burst is ongoing.

wire [N_REQ-1:0] current_req_comb;
reg  [N_REQ-1:0] current_req_hold;
assign current_req = |current_req_hold ? current_req_hold : current_req_comb;

onehot_priority #(
	.W_INPUT (N_REQ)
) req_priority_sel (
	.in  (req_vld),
	.out (current_req_comb)
);

always @ (posedge clk or negedge rst_n) begin
	if (!rst_n) begin
		current_req_hold <= {N_REQ{1'b0}};
	end else begin
		current_req_hold <= |req_rdy ? {N_REQ{1'b0}} : current_req;
	end
end

// ... and mux in the attributes of that request:
wire [W_RADDR-1:0]   current_req_raddr;
wire [W_BANKSEL-1:0] current_req_banksel;
wire [W_CADDR-1:0]   current_req_caddr;
wire                 current_req_write;

onehot_mux #(
	.N_INPUTS (N_REQ),
	.W_INPUT  (W_RADDR)
) raddr_mux (
	.in  (req_raddr),
	.sel (current_req),
	.out (current_req_raddr)
);

onehot_mux #(
	.N_INPUTS (N_REQ),
	.W_INPUT  (W_BANKSEL)
) banksel_mux (
	.in  (req_banksel),
	.sel (current_req),
	.out (current_req_banksel)
);

onehot_mux #(
	.N_INPUTS (N_REQ),
	.W_INPUT  (W_CADDR)
) caddr_mux (
	.in  (req_caddr),
	.sel (current_req),
	.out (current_req_caddr)
);

onehot_mux #(
	.N_INPUTS (N_REQ),
	.W_INPUT  (1)
) write_mux (
	.in  (req_write),
	.sel (current_req),
	.out (current_req_write)
);

// ----------------------------------------------------------------------------
// Command generation

assign {cmd_ras_n, cmd_cas_n, cmd_we_n} =
	refresh_req && |bank_active                               ? CMD_PRECHARGE :
	refresh_req && ~|bank_active                              ? CMD_REFRESH   :
	!bank_active[current_req_banksel]                         ? CMD_ACTIVATE  :
	bank_active_row[current_req_banksel] != current_req_raddr ? CMD_PRECHARGE :
	current_req_write                                         ? CMD_WRITE     : CMD_READ;

wire refresh_miss = cmd == CMD_PRECHARGE && refresh_req;
wire refresh_hit  = cmd == CMD_REFRESH;
wire page_miss    = cmd == CMD_PRECHARGE && !refresh_req;
wire page_empty   = cmd == CMD_ACTIVATE;
wire page_hit     = cmd == CMD_WRITE || cmd == CMD_READ;

assign cmd_addr =
	refresh_miss ? {{W_RADDR-1{1'b0}}, 1'b1} << PRECHARGE_ALL_ADDR_BIT :
	page_hit     ? {{W_RADDR-W_CADDR{1'b0}}, current_req_caddr}        :
	page_empty   ? current_req_raddr                                   : {W_RADDR{1'b0}};

assign cmd_banksel = current_req_banksel;

// Precharge must respect tRAS, tWR, and must not precharge during a read
// burst on same bank (uses same counter as tWR)
wire precharge_is_possible = ~|{
	ctr_ras_to_pre[current_req_banksel],
	ctr_cas_to_pre[current_req_banksel]
};

// PrechargeAll is the same, but for all banks.
reg precharge_all_is_possible;
always @ (*) begin: check_precharge_all_is_possible
	integer b;
	precharge_all_is_possible = 1'b1;
	for (b = 0; b < N_BANKS; b = b + 1) begin
		precharge_all_is_possible = precharge_all_is_possible && ~|{
			ctr_ras_to_pre[b],
			ctr_cas_to_pre[b]
		};
	end
end

// Activate must respect tRC, tRP, tRRD
wire activate_is_possible = ~|{
	ctr_ras_to_ras_any,
	ctr_ras_to_ras_same[current_req_banksel],
	ctr_pre_to_ras[current_req_banksel]
};

// Refresh is the same, but for all banks.
reg refresh_is_possible;
always @ (*) begin: check_refresh_is_possible
	integer b;
	refresh_is_possible = ~|ctr_ras_to_ras_any;
	for (b = 0; b < N_BANKS; b = b + 1) begin
		refresh_is_possible = refresh_is_possible && ~|{
			ctr_ras_to_ras_same[b],
			ctr_pre_to_ras[b]
		};
	end
end

// Bursts must respect tRCD, plus turnaround/contention rules.
wire burst_is_possible = ~|ctr_ras_to_cas[current_req_banksel] &&
	(current_req_write ? dq_write_contention_ok : dq_read_contention_ok);

assign cmd_vld =
	refresh_req && (
		refresh_miss && precharge_all_is_possible ||
		refresh_hit  && refresh_is_possible
	) || |current_req && (
		page_miss    && precharge_is_possible     ||
		page_empty   && activate_is_possible      ||
		page_hit     && burst_is_possible
	);

// ----------------------------------------------------------------------------
// Handshaking

assign req_rdy = current_req & {N_REQ{page_hit && cmd_vld}};

// Onehot0 read/write data strobes to control bus interface
wire [N_REQ-1:0] dq_master_sel;

generate
if (N_REQ == 1) begin: one_master_sel
	assign dq_master_sel = 1'b1;
end else begin: n_master_sel
	assign dq_master_sel = {{N_REQ-1{1'b0}}, 1'b1} << dq_schedule[1][W_REQSEL-1:0];
end
endgenerate

wire [1:0] scheduled_dq_op = dq_schedule[1][W_DQ_RECORD-1:W_DQ_RECORD-2];

assign dq_write = cmd_vld && cmd == CMD_WRITE ? current_req :
	dq_master_sel & {N_REQ{scheduled_dq_op == 2'b10}};

assign dq_read = dq_master_sel & {N_REQ{scheduled_dq_op == 2'b11}};

endmodule

`ifndef YOSYS
`default_nettype wire
`endif
