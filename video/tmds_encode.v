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

module tmds_encode (
	input  wire       clk,   // Must be == pixel clock.
	input  wire       rst_n,

	input  wire [1:0] c,
	input  wire [7:0] d,
	input  wire       den,

	output reg  [9:0] q
);

// This is a direct implementation of Figure 3-5 on page 29 of DVI v1.0 spec.

// ----------------------------------------------------------------------------
// 1. Transition minimisation

reg [8:0] q_m;
wire [3:0] d_count;

popcount #(
	.W_IN (8)
) popcount_d (
	.din  (d),
	.dout (d_count)
);

always @ (posedge clk or negedge rst_n) begin
	if (!rst_n) begin
		q_m <= 9'h0;
	end else if (d_count > 4'd4 || (d_count == 4'd4 && !d[0])) begin
		q_m <= {1'b0, ~^d[7:0],  ^d[6:0], ~^d[5:0],  ^d[4:0], ~^d[3:0],  ^d[2:0], ~^d[1:0], d[0]};
	end else begin
		q_m <= {1'b1,  ^d[7:0],  ^d[6:0],  ^d[5:0],  ^d[4:0],  ^d[3:0],  ^d[2:0],  ^d[1:0], d[0]};
	end
end

// ----------------------------------------------------------------------------
// 2. Running DC balance correction

// The count is guaranteed to be between +/- 10 inclusive, as this is the
// maximum symbol weight, and we always aim towards (and potentially past)
// zero if current count is nonzero.

localparam W_IMBALANCE = 5;
reg [W_IMBALANCE-1:0] imbalance;
wire [3:0] q_m_count;

popcount #(
	.W_IN (8)
) popcount_q_m (
	.din  (q_m[7:0]),
	.dout (q_m_count)
);

reg [1:0] den_delayed;

always @ (posedge clk or negedge rst_n) begin
	if (!rst_n) begin
		den_delayed <= 2'h0;
	end else begin
		den_delayed <= {den_delayed[0], den};
	end
end

reg [9:0] q_m_inv;

always @ (posedge clk or negedge rst_n) begin
	if (!rst_n) begin
		imbalance <= {W_IMBALANCE{1'b0}};
		q_m_inv <= 10'h0;
	end else begin
		if (~|imbalance || q_m_count == 4'd4) begin
			q_m_inv <= {!q_m[8], q_m[8], q_m[8] ? q_m[7:0] : ~q_m[7:0]};
			if (!q_m[8])
				imbalance <= imbalance + 5'd4 - q_m_count;
			else
				imbalance <= imbalance + q_m_count - 5'd4;
		end else if ($signed(imbalance) > 5'sh0 && q_m_count > 4'd4
		          || $signed(imbalance) < 5'sh0 && q_m_count < 4'd4) begin
			q_m_inv <= {1'b1, q_m[8], ~q_m[7:0]};
			imbalance <= imbalance + {4'h0, q_m[8]} - q_m_count + 5'd4;
		end else begin
			q_m_inv <= {1'b0, q_m[8],  q_m[7:0]};
			imbalance <= imbalance - {4'h0, !q_m[8]} + q_m_count - 5'd4;
		end 
		// Override counter update during control period (but don't add extra muxing
		// to datapath in this pipestage)
		if (!den_delayed[0])
			imbalance <= 5'd0;
	end
end

// ----------------------------------------------------------------------------
// 3. Control symbol insertion

reg [1:0] c_delayed [0:1];


always @ (posedge clk or negedge rst_n) begin
	if (!rst_n) begin
		q <= 10'd0;
		c_delayed[0] <= 2'b00;
		c_delayed[1] <= 2'b00;
	end else begin
		{c_delayed[1], c_delayed[0]} <= {c_delayed[0], c};
		if (den_delayed[1]) begin
			q <= q_m_inv;
		end else begin
			case (c_delayed[1])
				2'b00: q <= 10'b1101010100;
				2'b01: q <= 10'b0010101011;
				2'b10: q <= 10'b0101010100;
				2'b11: q <= 10'b1010101011;
			endcase
		end
	end
end

endmodule
