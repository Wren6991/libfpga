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

// A pad, with optional input and output registers. Where possible, this uses
// the registers built directly into the IO cell.

// Note: rst_n may not be functional on FPGA.

module tristate_io #(
    parameter SYNC_OUT = 0,
    parameter SYNC_IN  = 0,
    parameter PULLUP   = 0
) (
    input  wire clk,
    input  wire rst_n,

	input  wire out,
	input  wire oe,
	output wire in,
	inout  wire pad
);

// ----------------------------------------------------------------------------

`ifdef FPGA_ICE40

// Based on the SB_IO library description, PIN_TYPE breaks down as follows:
//
// - bits 5:4: OUTPUT_ENABLE muxing (note OUTPUT_ENABLE is active-*high*)
//
//   - 00 Always disabled
//   - 01 Always enabled
//   - 10: Unregistered OUTPUT_ENABLE
//   - 11: Posedge-registered OUTPUT_ENABLE
//
// - bits 3:2: D_OUT_x muxing
//
//   - 00: DDR, posedge-registered D_OUT_0 for half cycle following posedge,
//     then negedge-registered D_OUT_1 for next half cycle
//   - 01: Posedge-registered D_OUT_0
//   - 10: Unregistered D_OUT_0
//   - 11: Registered, inverted D_OUT_0
//
// - bits 1:0: D_IN_0 muxing (note D_IN_1 is always negedge-registered input)
//
//   - 00: Posedge-registered input
//   - 01: Unregistered input
//   - 10: Posedge-registered input with latch (latch is transparent when
//     LATCH_INPUT_VALUE is low)
//   - 11: Unregistered input with latch (latch is transparent when
//     LATCH_INPUT_VALUE is low)

localparam [5:0] PIN_TYPE = {
    SYNC_OUT ? 2'b11 : 2'b10,
    SYNC_OUT ? 2'b01 : 2'b10,
    SYNC_IN  ? 2'b00 : 2'b01
};

generate
if (SYNC_OUT == 0 && SYNC_IN == 0) begin: no_clk
    // Do not connect the clock nets if not required, because it causes
    // packing issues with other IOs

    SB_IO #(
        .PIN_TYPE (PIN_TYPE),
        .PULLUP   (|PULLUP)
    ) buffer (
        .PACKAGE_PIN   (pad),
        .OUTPUT_ENABLE (oe),
        .D_OUT_0       (out),
        .D_IN_0        (in)
    );

end else begin: have_clk

    SB_IO #(
        .PIN_TYPE (PIN_TYPE),
        .PULLUP   (|PULLUP)
    ) buffer (
        .OUTPUT_CLK    (clk),
        .INPUT_CLK     (clk),
        .PACKAGE_PIN   (pad),
        .OUTPUT_ENABLE (oe),
        .D_OUT_0       (out),
        .D_IN_0        (in)
    );

end
endgenerate

// ----------------------------------------------------------------------------

`else

// Synthesisable behavioural code

reg out_pad;
reg oe_pad;
wire in_pad;

generate
if (SYNC_OUT == 0) begin: no_out_ff
    always @ (*) begin
        out_pad = out;
        oe_pad = oe;
    end
end else begin: have_out_ff
    always @ (posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            out_pad <= 1'b0;
            oe_pad <= 1'b0;
        end else begin
            out_pad <= out;
            oe_pad <= oe;
        end
    end
end
endgenerate

generate
if (SYNC_IN == 0) begin: no_in_ff
    assign in = in_pad;
end else begin: have_in_ff
    reg in_r;
    always @ (posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            in_r <= 1'b0;
        end else begin
            in_r <= in_pad;
        end
    end
    assign in = in_r;
end
endgenerate

assign pad = oe_pad ? out_pad : 1'bz;
assign in_pad = pad;

`endif

endmodule
