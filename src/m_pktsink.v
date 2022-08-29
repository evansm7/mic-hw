/* Receive responses to requests issued by an m_pktgen
 *
 * Implements a random delay/backpressure, if THROTTLE parameter is set to 1.
 *
 * Copyright 2017, 2020 Matt Evans
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

module m_pktsink(input wire        clk,
		 input wire 	   reset,
		 input wire 	   TVALID,
		 output wire 	   TREADY,
		 input wire [63:0] TDATA,
		 input wire 	   TLAST
		);

   parameter NAME = "PktSink";
   parameter THROTTLE = 0;

   reg 		     is_header;

   wire [15:0] 	     rng;

   rng		#(.S(16'h1234)
		  )
                RNG
		  (.clk(clk),
		   .reset(reset),
		   .rng_o(rng));

   assign TREADY = !THROTTLE || (rng[14] || rng[13]);

   reg [8:0] 	     count;

   wire [7:0] 	     wr_strobes;
   wire [7:0] 	     src_id;
   wire [7:0] 	     rd_len;
   wire [1:0] 	     pkt_type;
   wire [31:3] 	     address;
   reg [1:0] 	     pkt_type_r;
   reg [31:3] 	     address_r;

   assign {wr_strobes, src_id, rd_len} = TDATA[63:40];
   assign pkt_type = TDATA[33:32];
   assign address = TDATA[31:3];

   always @(posedge clk)
     begin
	if (reset) begin
	   is_header <= 1;
	   count <= 0;
	   pkt_type_r <= 0;
	   address_r <= 0;
	end else begin
	   if (TVALID && TREADY) begin
	      if (is_header) begin
		 /* Actually only type, src_id and possibly len are valid. */
		 $display("%s:  Got pkt type %d, addr %x, len %d, src_id %x", NAME, pkt_type, {address, 3'h0}, rd_len, src_id);
		 pkt_type_r <= pkt_type;
		 address_r <= address;

		 if (!TLAST) begin
		    // There's more than just the header.
		    if (pkt_type != 2'b10) begin // RDATA
		       $display("%s:  *** Multi-beat packet that isn't an RDATA", NAME);
		    end
		    is_header <= 0;
		    count <= 1;
		 end else begin
		    if (pkt_type == 2'b11) begin // WRACK
		       $display("%s:   Got WRACK for addr %x\n", NAME, {address, 3'h0});
		    end
		 end
	      end else begin // if (is_header)
		 // Count non-header beats
		 if (TLAST) begin
		    // OK, done; next beat is the next packet's header.
		    is_header <= 1;
		    if (pkt_type_r == 2'b10) begin
		       $display("%s:   ReadData %d beats from address %x\n", NAME, count, {address_r, 3'h0});
		    end else begin
		       $display("%s:  *** Mystery multi-beat packet was %d beats long\n", NAME, count);
		    end
		 end
		 count <= count + 1;
	      end // else: !if(is_header)
	   end
	end
     end
endmodule
