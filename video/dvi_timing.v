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

module dvi_timing #(
	// Defaults are for 640x480p 60 Hz (from CEA 861D).
	// All horizontal timings are in pixels.
	// All vertical timings are in scanlines.
	parameter H_SYNC_POLARITY   = 1'b0, // 0 for active-low pulse
	parameter H_FRONT_PORCH     = 16,
	parameter H_SYNC_WIDTH      = 96,
	parameter H_BACK_PORCH      = 48,
	parameter H_ACTIVE_PIXELS   = 640,

	parameter V_SYNC_POLARITY   = 1'b0, // 0 for active-low pulse
	parameter V_FRONT_PORCH     = 10,
	parameter V_SYNC_WIDTH      = 2,
	parameter V_BACK_PORCH      = 33,
	parameter V_ACTIVE_LINES    = 480
) (
	input wire clk,
	input wire rst_n,

	input wire en,

	output reg vsync,
	output reg hsync,
	output reg den
);

parameter W_H_CTR = $clog2(H_ACTIVE_PIXELS);
parameter W_V_CTR = $clog2(V_ACTIVE_LINES);

// ----------------------------------------------------------------------------
// Horizontal timing state machine

localparam W_STATE = 2;
localparam S_FRONT_PORCH = 2'h0;
localparam S_SYNC        = 2'h1;
localparam S_BACK_PORCH  = 2'h2;
localparam S_ACTIVE      = 2'h3;

reg [W_H_CTR-1:0] h_ctr;
reg [W_STATE-1:0] h_state;
reg in_active_vertical_period;
reg v_advance;

always @ (posedge clk or negedge rst_n) begin
	if (!rst_n) begin
		h_state <= S_FRONT_PORCH;
		h_ctr <= {W_H_CTR{1'b0}};
		hsync <= !H_SYNC_POLARITY;
		den <= 1'b0;
		v_advance <= 1'b0;
	end else if (!en) begin
		hsync <= !H_SYNC_POLARITY;
		den <= 1'b0;
		h_ctr <= {W_H_CTR{1'b0}};
		h_state <= S_FRONT_PORCH;
		v_advance <= 1'b0;
	end else begin
		h_ctr <= h_ctr - 1'b1;
		v_advance <= h_state == S_ACTIVE && h_ctr == 1;
		case (h_state)
		S_FRONT_PORCH: if (h_ctr == 0) begin
			h_ctr <= H_SYNC_WIDTH - 1;
			h_state <= S_SYNC;
			hsync <= H_SYNC_POLARITY;
		end
		S_SYNC: if (h_ctr == 0) begin
			h_ctr <= H_BACK_PORCH - 1;
			h_state <= S_BACK_PORCH;
			hsync <= !H_SYNC_POLARITY;
		end
		S_BACK_PORCH: if (h_ctr == 0) begin
			h_ctr <= H_ACTIVE_PIXELS - 1;
			h_state <= S_ACTIVE;
			den <= in_active_vertical_period;
		end
		S_ACTIVE: if (h_ctr == 0) begin
			h_ctr <= H_FRONT_PORCH - 1;
			h_state <= S_FRONT_PORCH;
			den <= 1'b0;
		end
		endcase
	end
end

// ----------------------------------------------------------------------------
// Vertical timing state machine

reg [W_V_CTR-1:0] v_ctr;
reg [W_STATE-1:0] v_state;

always @ (posedge clk or negedge rst_n) begin
	if (!rst_n) begin
		v_state <= S_FRONT_PORCH;
		v_ctr <= {W_V_CTR{1'b0}};
		vsync <= !V_SYNC_POLARITY;
		in_active_vertical_period <= 1'b0;
	end else if (!en) begin
		vsync <= !V_SYNC_POLARITY;
		in_active_vertical_period <= 1'b0;
		v_ctr <= {W_V_CTR{1'b0}};
		v_state <= S_FRONT_PORCH;
	end else if (v_advance) begin
		v_ctr <= v_ctr - 1'b1;
		case (v_state)
		S_FRONT_PORCH: if (v_ctr == 0) begin
			v_ctr <= V_SYNC_WIDTH - 1;
			v_state <= S_SYNC;
			vsync <= V_SYNC_POLARITY;
		end
		S_SYNC: if (v_ctr == 0) begin
			v_ctr <= V_BACK_PORCH - 1;
			v_state <= S_BACK_PORCH;
			vsync <= !V_SYNC_POLARITY;
		end
		S_BACK_PORCH: if (v_ctr == 0) begin
			v_ctr <= V_ACTIVE_LINES - 1;
			v_state <= S_ACTIVE;
			in_active_vertical_period <= 1'b1;
		end
		S_ACTIVE: if (v_ctr == 0) begin
			v_ctr <= V_FRONT_PORCH - 1;
			v_state <= S_FRONT_PORCH;
			in_active_vertical_period <= 1'b0;
		end
		endcase
	end
end

endmodule
