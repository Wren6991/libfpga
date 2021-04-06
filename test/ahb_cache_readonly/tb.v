// Assume that the upstream bus port follows some basic AHB-Lite compliance
// rules, and assert that the downstream port does the same.
// Attach a small memory to the downstream port, and assert that the data read
// upstream always matches the memory contents.

`default_nettype none

module tb;

// Smol cache, hopefully enough to cover all the state of a larger one
localparam W_ADDR = 32;
localparam W_DATA = 32;
localparam W_LINE = 2 * W_DATA;
localparam CACHE_DEPTH = 4;

// Downstream SRAM, a few times bigger than the cache, nothing too extravagant.
localparam MEM_SIZE_BYTES = 4 * (W_LINE * CACHE_DEPTH / 8);
localparam MEM_DEPTH = MEM_SIZE_BYTES / (W_DATA / 8);

// ----------------------------------------------------------------------------
// DUT

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
wire [W_DATA-1:0]  dst_hrdata;

ahb_cache_readonly #(
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

// ----------------------------------------------------------------------------
// Global signals and RAM model

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


reg [W_DATA-1:0] test_mem [0:MEM_DEPTH-1];

always @ (*) begin: constrain_mem_const
	integer i;
	for (i = 0; i < MEM_DEPTH; i = i + 1)
		assume(test_mem[i] == $anyconst);	
end

assign dst_hrdata = test_mem[dst_addr_dph / (W_DATA / 8)];

// ----------------------------------------------------------------------------
// Assumptions/assertions for AHBL signalling

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
	// Read only!
	assume(!src_hwrite);
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

// FIXME we don't care about error-related stuff right now
always assume (!dst_hresp);

// ----------------------------------------------------------------------------
// Memory validity check (the most important property)

wire [W_DATA-1:0] src_hrdata_expect = src_active_dph && src_hready ? test_mem[src_addr_dph / (W_DATA / 8)] : {W_DATA{1'b0}};

always @ (posedge clk) if (!first_cyc) begin
	if (src_active_dph && src_hready && !src_hresp)
		assert(src_hrdata == src_hrdata_expect);
end

endmodule
