// Formal property testbench for ahb_cache_writeback. This is our contract
// with the cache:
//
// - Assume that, on some cycle, a write takes place, which overlaps some byte
//
// - Assume that, on a later cycle, a read takes place, which overlaps the
//   same byte
//
// - Assume that no writes overlapping that byte took place during the
//   intervening cycles
//
// - Assert that the byte read back matches the byte written.
//
// Also assume that the upstream bus port follows some basic AHB-Lite
// compliance rules, and assert that the downstream port does the same. We
// have a memory attached to the downstream port to handle fills and spills.

module tb;

// Smol cache, hopefully enough to cover all the state of a larger one
localparam W_ADDR = 32;
localparam W_DATA = 32;
localparam W_LINE = 2 * W_DATA;
localparam CACHE_DEPTH = 4;

// Downstream SRAM, a few times bigger than the cache, nothing too extravagant.
localparam MEM_SIZE_BYTES = 4 * (W_LINE * CACHE_DEPTH / 8);

// Can cover more cache state space when write takes place later, and read is
// further from write, but the BMC gets more expensive.
localparam TEST_WRITE_CYCLE = 20;
localparam TEST_READ_CYCLE = 55;


// ----------------------------------------------------------------------------
// DUT and RAM model

reg                clk;
wire               rst_n;

reg                src_hready;
wire               src_hresp;
reg  [W_ADDR-1:0]  src_haddr;
reg                src_hwrite;
reg  [1:0]         src_htrans;
reg  [2:0]         src_hsize;
reg  [2:0]         src_hburst;
reg  [3:0]         src_hprot;
reg                src_hmastlock;
reg  [W_DATA-1:0]  src_hwdata;
wire [W_DATA-1:0]  src_hrdata;

wire               dst_hready;
wire               dst_hready_resp;
wire               dst_hresp;
wire [W_ADDR-1:0]  dst_haddr;
wire               dst_hwrite;
wire [1:0]         dst_htrans;
wire [2:0]         dst_hsize;
wire [2:0]         dst_hburst;
wire [3:0]         dst_hprot;
wire               dst_hmastlock;
wire [W_DATA-1:0]  dst_hwdata;
reg  [W_DATA-1:0]  dst_hrdata;

ahb_cache_writeback #(
	.W_ADDR(W_ADDR),
	.W_DATA(W_DATA),
	.W_LINE(W_LINE),
	.TMEM_PRELOAD("tag_zeroes.hex"),
	.DEPTH(CACHE_DEPTH)
) dut (
	.clk             (clk),
	.rst_n           (rst_n),

	.src_hready_resp (src_hready),
	.src_hready      (src_hready),
	.src_hresp       (src_hresp),
	.src_haddr       (src_haddr),
	.src_hwrite      (src_hwrite),
	.src_htrans      (src_htrans),
	.src_hsize       (src_hsize),
	.src_hburst      (src_hburst),
	.src_hprot       (src_hprot),
	.src_hmastlock   (src_hmastlock),
	.src_hwdata      (src_hwdata),
	.src_hrdata      (src_hrdata),

	.dst_hready_resp (dst_hready_resp),
	.dst_hready      (dst_hready),
	.dst_hresp       (dst_hresp),
	.dst_haddr       (dst_haddr),
	.dst_hwrite      (dst_hwrite),
	.dst_htrans      (dst_htrans),
	.dst_hsize       (dst_hsize),
	.dst_hburst      (dst_hburst),
	.dst_hprot       (dst_hprot),
	.dst_hmastlock   (dst_hmastlock),
	.dst_hwdata      (dst_hwdata),
	.dst_hrdata      (dst_hrdata)
);

ahb_sync_sram #(
	.W_DATA(W_DATA),
	.W_ADDR(W_ADDR),
	.DEPTH(MEM_SIZE_BYTES / (W_DATA - 8))
) downstream_sys_mem (
	.clk               (clk),
	.rst_n             (rst_n),

	.ahbls_hready_resp (/* unused, signal given weaker constraints */),
	.ahbls_hready      (dst_hready),
	.ahbls_hresp       (/* unused, signal given weaker constraints */),
	.ahbls_haddr       (dst_haddr),
	.ahbls_hwrite      (dst_hwrite),
	.ahbls_htrans      (dst_htrans),
	.ahbls_hsize       (dst_hsize),
	.ahbls_hburst      (dst_hburst),
	.ahbls_hprot       (dst_hprot),
	.ahbls_hmastlock   (dst_hmastlock),
	.ahbls_hwdata      (dst_hwdata),
	.ahbls_hrdata      (dst_hrdata)
);

// ----------------------------------------------------------------------------
// Global signal properties

reg first_cyc = 1;
always @ (posedge clk)
	first_cyc <= $initstate;

assign rst_n = !($initstate || first_cyc);

integer cycle_ctr;

always @ (posedge clk or negedge rst_n)
	if (!rst_n)
		cycle_ctr <= 0;
	else
		cycle_ctr <= cycle_ctr + 1;

// ----------------------------------------------------------------------------
// Assumptions/assertions for AHBL signalling

// Simple signal monitoring to make properties easier

reg              src_active_dph;
reg              src_write_dph;
reg [W_ADDR-1:0] src_addr_dph;
reg [2:0]        src_size_dph;
reg [3:0]        src_prot_dph;

always @ (posedge clk or negedge rst_n) begin
	if (!rst_n) begin
		src_active_dph <= 1'b0;
		src_write_dph <= 1'b0;
		src_addr_dph <= {W_ADDR{1'b0}};
		src_size_dph <= 3'h0;
		src_prot_dph <= 4'h0;
	end else if (src_hready) begin
		src_active_dph <= src_htrans[1];
		src_write_dph <= src_hwrite;
		src_addr_dph <= src_haddr;
		src_size_dph <= src_hsize;
		src_prot_dph <= src_hprot;
	end
end

reg              dst_active_dph;
reg              dst_write_dph;
reg [W_ADDR-1:0] dst_addr_dph;
reg [2:0]        dst_size_dph;

always @ (posedge clk or negedge rst_n) begin
	if (!rst_n) begin
		dst_active_dph <= 1'b0;
		dst_write_dph <= 1'b0;
		dst_addr_dph <= {W_ADDR{1'b0}};
		dst_size_dph <= 3'h0;
	end else if (dst_hready) begin
		dst_active_dph <= dst_htrans[1];
		dst_write_dph <= dst_hwrite;
		dst_addr_dph <= dst_haddr;
		dst_size_dph <= dst_hsize;
	end
end

// Assumptions for all upstream requests
always @ (posedge clk) begin: src_ahbl_req_properties
	// Address aligned to size
	assume(!(src_haddr & ~({W_ADDR{1'b1}} << src_hsize)));
	// Address is within memory
	assume(src_haddr < MEM_SIZE_BYTES);
	// We only support IDLE/NSEQ (we ignore bit 0, this just makes the waves nicer)
	assume(!src_htrans[0]);
	// HSIZE appropriate for bus width
	assume(8 << src_hsize <= W_DATA);
	// No deassertion or change of active request
	if ($past(src_htrans[1] && !src_hready)) begin
		assume($stable({
			src_htrans,
			src_hwrite,
			src_haddr,
			src_hsize,
			src_hburst,
			src_hprot,
			src_hmastlock
		}));
	end
	// Write data stable during write data phase
	if (src_active_dph && src_write_dph && !$past(src_hready))
		assume($stable(src_hwdata));
end

// Assertions for all upstream responses
always @ (posedge clk) if(!first_cyc) begin: src_ahbl_resp_properties
	// IDLE->OKAY
	if (!src_active_dph) begin
		assert(src_hready);
		assert(!src_hresp);
	end
	// Correct two-phase error response.
	if (src_hresp && src_hready)
		assert($past(src_hresp && !src_hready));
	if (src_hresp && !src_hready)
		assert($past(!(src_hresp && !src_hready)));
	if ($past(src_hresp && !src_hready))
		assert(src_hresp);
end

// Assertions for all downstream requests
always @ (posedge clk) if (!first_cyc) begin: dst_ahbl_req_properties
	// Address phase properties are don't-care when request is IDLE:
	if (dst_htrans[1]) begin
		// Cache must realign the address when it increases the transfer size
		assert(!(dst_haddr & ~({W_ADDR{1'b1}} << dst_hsize)));
		// If memory is a multiple of cache line size (it is), upstream accesses
		// within bounds must not result in out-of-bounds downstream accesses
		assert(dst_haddr < MEM_SIZE_BYTES);
		// HSIZE appropriate for bus width
		assert(8 << dst_hsize <= W_DATA);
		// No deassertion or change of active request
		if ($past(dst_htrans[1] && !dst_hready)) begin
			assert($stable({
				dst_htrans,
				dst_hwrite,
				dst_haddr,
				dst_hsize,
				dst_hburst,
				dst_hprot,
				dst_hmastlock
			}));
		end
		// SEQ only issued following an NSEQ or SEQ, never an IDLE
		if (dst_htrans == 2'b11)
			assert(dst_active_dph);
		// SEQ transfer addresses must be sequential with previous transfer (note
		// the cache only uses INCRx bursts right now, and this property will fail
		// if WRAP support is added)
		if (dst_htrans == 2'b11)
			assert(dst_haddr == dst_addr_dph + W_DATA / 8);
		// Write data stable during write data phase
		if (dst_active_dph && dst_write_dph && !$past(dst_hready))
			assert($stable(dst_hwdata));
	end
end

// Assumptions for all downstream responses
always @ (posedge clk) if (!first_cyc) begin: dst_ahbl_resp_properties
	// IDLE->OKAY
	if (!dst_active_dph) begin
		assume(dst_hready_resp);
		assume(!dst_hresp);
	end
	// Correct two-phase error response.
	if (dst_hresp && dst_hready)
		assume($past(dst_hresp && !dst_hready));
	if (dst_hresp && !dst_hready)
		assume($past(!(dst_hresp && !dst_hready)));
	if ($past(dst_hresp && !dst_hready))
		assume(dst_hresp);
	// We don't limit the length of stall for this test. We just assume that a
	// write and a read retire at some point in the trace, and the solver will
	// figure out it can't hold the bus stall forever.
end

// ----------------------------------------------------------------------------
// Memory contract

// The byte of interest
wire [W_ADDR-1:0] check_addr = $anyconst;
wire [7:0]        check_data = $anyconst;
always assume(test_addr < MEM_SIZE_BYTES);

always @ (posedge clk) if (!rst_n) begin
	if (cycle_ctr == TEST_WRITE_CYCLE) begin

		// Assume that, on some cycle, a write to the cache takes place, which
		// overlaps some particular byte in memory.
		assume(src_hready);
		assume(src_active_dph);
		assume(src_write_dph);
		assume(src_addr_dph <= check_addr);
		assume(src_addr_dph + (1 << src_size_dph) > check_addr);
		assume(src_hwdata[check_addr % (W_DATA / 8) * 8 +:8] == check_data);
		// Cacheable and bufferable attributes
		assume(src_hwdatac_prot_dph[3:2] == 2'b11);

	end else if (cycle_ctr > TEST_WRITE_CYCLE && cycle_ctr < TEST_READ_CYCLE) begin

		// Assume that there are no intervening cache writes to the same byte before
		// the point we observe it
		if (src_active_dph && src_write_dph) assume(
			src_addr_dph > check_addr ||
			src_addr_dph < check_addr - (1 << src_size_dph)
		);
			
	end else if (cycle_ctr == TEST_READ_CYCLE) begin
		
		// Assume that, on some later cycle, a read to the cache takes place, which
		// overlaps the same byte (though may not have the same size/alignment).
		assume(src_hready);
		assume(src_active_dph);
		assume(!src_write_dph);
		assume(src_addr_dph <= check_addr);
		assume(src_addr_dph + (1 << src_size_dph) > check_addr);
		assume(src_prot_dph[3:2] == 2'b11);

		// Assert that the data we read matches the data we wrote
		assert(src_hrdata[check_addr % (W_DATA / 8) * 8 +:8] == check_data);

	end
end

endmodule
