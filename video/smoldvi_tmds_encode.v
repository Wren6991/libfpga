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

// Encoder from the SmolDVI project: https://github.com/wren6991/smoldvi

// This encoder is based on a property of the TMDS algorithm specified in DVI
// spec: If the running balance is currently zero, and you encode data x
// followed by x ^ 1, this produces a pair of TMDS symbols with net balance
// zero, hence the running balance will *remain* at zero. Provided the input
// follows this pattern (doubled pixels with alternating LSB), there is no
// need to actually track the balance, which makes the encoder effectively
// stateless.
//
// This leads to:
// - Halving of horizontal resolution
// - Loss of LSB (bit 0) of colour precision
// - Toggling of colour LSBs (bit 0) across screen
//
// But this last effect is not noticeable in practice, and the first two are
// acceptable for any pixel source that would fit onto a iCE40 UP5k or HX1k.
//
// Our TMDS algorithm:
//
// - Mask off d[0]
// - If population count of d[7:0] less than 4:
//     - q[9:8] = 2'b01 for both output symbols
//     - First symbol q[n] = ^d[n:0] for n = 0...7
//     - Second symbol inverse of first q[7:0] (thanks to input LSB toggling)
// - Else:
//     - q[9:8] = 2'b10 for both output symbols
//     - First symbol same as less than case but XOR'd with 'h55 (this
//       accounts for both XNOR-ness and q[9] complementing)
//     - Second symbol inverse of first q[7:0] (thanks to input LSB toggling)
//
// These rules *exactly* reproduce Figure 3-5 on page 29 of DVI v1.0 spec, if
// the pixels input to that algorithm are manipulated properly. You can check
// this by enumerating all possible input values, running them through the
// original algorithm with initial balance = 0 (recalling that balance is
// defined to be 0 at the start of each scanline), and noting that the balance
// returns to 0 after each output pixel pair, forming the sketch of an
// induction proof.
//
// To check that the output of our algorithm is DC-balanced, observe that bits
// q[9:8] always have one bit set, and bits q[7:0] are complemented over
// consecutive pixels, so have an average population count of 4 out of 8.
// Therefore for every 20 bits we output (2 TMDS symbols), there are 10 1 bits
// and 10 0 bits.
//
// Note that the instantiator is responsible for holding d[7:0] constant over
// two cycles (it's not registered here)

module smoldvi_tmds_encode (
	input  wire       clk,
	input  wire       rst_n,

	input  wire [1:0] c,
	input  wire [7:0] d,
	input  wire       den,

	output reg  [9:0] q
);

reg [2:0] popcount;
wire low_balance = !popcount[2];

always @ (*) begin: count_d_pop
	integer i;
	popcount = 3'd0;
	// Ignore d[0] as it's implicitly masked
	for (i = 1; i < 8; i = i + 1)
		popcount = popcount + {2'h0, d[i]};
end

reg [7:0] d_reduced;
reg symbol_is_second;

always @ (*) begin: reduce_d
	integer i;
	d_reduced = 8'h0;
	for (i = 1; i < 8; i = i + 1)
		d_reduced[i] = d_reduced[i - 1] ^ d[i];
end

wire [9:0] pixel_q = {
	!low_balance,
	low_balance,
	d_reduced ^ (8'h55 & {8{!low_balance}}) ^ {8{symbol_is_second}}
};

always @ (posedge clk or negedge rst_n) begin
	if (!rst_n) begin
		symbol_is_second <= 1'b0;
		q <= 10'd0;
	end else begin
		if (den) begin
			symbol_is_second <= !symbol_is_second;
			q <= pixel_q;
		end else begin
			symbol_is_second <= 1'b0;
			case (c)
				2'b00: q <= 10'b1101010100;
				2'b01: q <= 10'b0010101011;
				2'b10: q <= 10'b0101010100;
				2'b11: q <= 10'b1010101011;
			endcase
		end
	end
end

endmodule
