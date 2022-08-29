/* Generate packets:
 * - Random gap between packets
 * - Random address for packet
 * - Random type (read/write), where write includes data of a random number 1-N beats.
 *
 * This is paired with a m_pktsink that simply accepts responses.
 * A TODO improvement is to combine into a single module that cross-checks responses against requests, i.e.:
 * - A write gives a WRACK
 * - A read of N gives a data packet of N
 *
 * Copyright 2017, 2020-2021 Matt Evans
 * SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
 *
 * Licensed under the Solderpad Hardware License v 2.1 (the “License”); you may
 * not use this file except in compliance with the License, or, at your option,
 * the Apache License version 2.0. You may obtain a copy of the License at
 *
 *  https://solderpad.org/licenses/SHL-2.1/
 *
 * Unless required by applicable law or agreed to in writing, any work
 * distributed under the License is distributed on an “AS IS” BASIS, WITHOUT
 * WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. See the
 * License for the specific language governing permissions and limitations
 * under the License.
 */

module m_pktgen(input wire        clk,
		input wire 	  reset,
		output reg 	  TVALID,
		input wire 	  TREADY,
		output reg [63:0] TDATA,
		output reg 	  TLAST
		);

   parameter NAME = "PktGen";
   parameter THROTTLE = 0;
   parameter RNG_INIT = 16'h1234;
   parameter SRC_ID = 8'h00;

   reg 		     write_en;
   wire		     start;
   wire		     do_write;
   reg [7:0] 	     write_count;

   wire [15:0] 	     rng;

   rng		#(.S(RNG_INIT)
		  )
                RNG
		  (.clk(clk),
		   .reset(reset),
		   .rng_o(rng));
   assign start = !THROTTLE || (rng[14] && rng[13]);
   assign do_write = (rng[13] ^ rng[12]);

`define STATE_IDLE     0
`define STATE_RD_HDR   1
`define STATE_WR_HDR   2
`define STATE_WR_DATA  3

   reg [2:0] 	     state;

   wire [31:3] 	     address;
   assign address = {rng[15:0], ~rng[15:3]};

   wire [7:0] 	     rd_len;
   assign rd_len = {4'h0, rng[3:0]}; /* Intentionally small */

   wire [63:0] 	     rd_header;
   wire [63:0] 	     wr_header;
   wire [63:0] 	     wr_data;
   assign rd_header[63:0] = { 5'h1f /* ByteEnables */, 3'h0, SRC_ID, rd_len[7:0], 6'h00, 2'b00 /* Read */,
			      address, 3'h0};
   assign wr_header[63:0] = { 5'h1f /* ByteEnables */, 3'h0, SRC_ID, 8'h00 /* RD len */, 6'h00, 2'b01 /* Write */,
			      address, 3'h0};
   assign wr_data[63:0] = {rng, rng, rng, rng};

   always @(posedge clk)
     begin
	if (reset) begin
	   state <= `STATE_IDLE;

	   TDATA <= 0;
	   TLAST <= 0;
	   TVALID <= 0;
	   write_count <= 0;
	end else begin
	   case (state)
	     `STATE_IDLE:
	       begin
		  if (start) begin
		     if (do_write) begin
			TDATA <= wr_header;
			TVALID <= 1;
			state <= `STATE_WR_HDR;
			write_count <= rng[3:0]; /* Intentionally small */
			$display("%s:  Write of %d beats to %x\n", NAME, rng[3:0] + 1, {address, 3'h0});
		     end else begin
			TDATA <= rd_header;
			TVALID <= 1;
			TLAST <= 1; /* A read is only one beat */
			state <= `STATE_RD_HDR;
			$display("%s:  Read of %d beats from %x\n", NAME, rd_len+1, {address, 3'h0});
		     end
		  end
	       end

	     `STATE_RD_HDR:
	       begin
		  if (TREADY) begin
		     /* OK, other side got our request, we're done. */
		     TVALID <= 0;
		     state <= `STATE_IDLE;
		     TLAST <= 0;
		  end
	       end

	     `STATE_WR_HDR:
	       begin
		  if (TREADY) begin
		     /* OK, other side got our header, move onto data: */
		     TVALID <= 1;
		     TDATA <= wr_data;
		     state <= `STATE_WR_DATA;
		     if (write_count == 8'h00) begin
			TLAST <= 1;
		     end
		  end
	       end

	     `STATE_WR_DATA:
	       begin
		  if (TREADY) begin
		     /* One beat consumed, either prepare another or we're done. */
		     if (write_count == 8'h00) begin
			TVALID <= 0;
			state <= `STATE_IDLE;
			TLAST <= 0;
		     end else begin
			if (write_count == 8'h01) TLAST <= 1;
			TDATA <= wr_data;
			write_count <= write_count - 1;
		     end
		  end
	       end
	   endcase // case (state)
	end
     end
endmodule
