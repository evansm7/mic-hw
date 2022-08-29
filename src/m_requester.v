/* Combined requester
 * - Generate reads and writes
 * - Random gap between packets
 * - Random address for packet
 * - Random packet size
 *
 * This is paired with a m_pktsink that simply accepts responses.
 * A TODO improvement is to combine into a single module that cross-checks responses against requests, i.e.:
 * - A write gives a WRACK
 * - A read of N gives a data packet of N
 *
 * Copyright 2017, 2019-2021 Matt Evans
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

module m_requester(input wire        clk,
		   input wire 	     reset,

		   /* Request port out */
		   output reg 	     O_TVALID,
		   input wire 	     O_TREADY,
		   output reg [63:0] O_TDATA,
		   output reg 	     O_TLAST,

		   /* Response port in */
		   input wire 	     I_TVALID,
		   output wire 	     I_TREADY,
		   input wire [63:0] I_TDATA,
		   input wire 	     I_TLAST
		);

   parameter NAME = "Requester";
   parameter THROTTLE = 0;
   parameter RNG_INIT = 16'hface;
   parameter SRC_ID = 8'h00;
   parameter ADDR_MASK = 29'h1fffffff;
   parameter ADDR_OFFS = 29'h00000000;
   parameter HALT = 0; /* For easy debug */

   reg 		     write_en;
   wire		     start_request;
   wire		     do_write;
   reg [7:0] 	     write_count;

   wire [15:0] 	     rng;

   rng		#(.S(RNG_INIT)
		  )
                RNG
		  (.clk(clk),
		   .reset(reset),
		   .rng_o(rng));
   assign start_request = !HALT && (!THROTTLE || rng[14]);
   assign do_write = (rng[13] ^ rng[12]);

`define STATE_IDLE       0
`define STATE_RD_HDR     1
`define STATE_WR_HDR     2
`define STATE_WR_DATA    3
`define STATE_WAIT_RESP  4

   reg [2:0] 	     state;

   reg 		     response_handshake_a;
   reg 		     response_handshake_b;

   wire [31:3] 	     out_address;
   assign out_address = ADDR_OFFS | (ADDR_MASK & {rng[15:0], ~rng[15:3]});

   wire [7:0] 	     rd_len;
   assign rd_len = {4'h0, rng[3:0]}; /* Intentionally small */

   wire [63:0] 	     rd_header;
   wire [63:0] 	     wr_header;
   wire [63:0] 	     wr_data;
   assign rd_header[63:0] = { 5'h1f /* ByteEnables */, 3'h0, SRC_ID, rd_len[7:0], 6'h00, 2'b00 /* Read */,
			      out_address, 3'h0};
   assign wr_header[63:0] = { 5'h1f /* ByteEnables */, 3'h0, SRC_ID,       8'h00, 6'h00, 2'b01 /* Write */,
			      out_address, 3'h0};
   assign wr_data[63:0] = {rng, rng, rng, rng};


   /* Request/output channel */
   always @(posedge clk)
     begin
	if (reset) begin
	   state <= `STATE_IDLE;

	   O_TDATA <= 0;
	   O_TLAST <= 0;
	   O_TVALID <= 0;
	   write_count <= 0;
	   response_handshake_a <= 0;
	end else begin
	   case (state)
	     `STATE_IDLE:
	       begin
		  if (start_request) begin
		     if (do_write) begin
			O_TDATA <= wr_header;
			O_TVALID <= 1;
			state <= `STATE_WR_HDR;
			write_count <= rng[3:0]; /* Intentionally small */
			$display("%s:  Write of %d beats to %x\n", NAME, rng[3:0] + 1, {out_address, 3'h0});
		     end else begin
			O_TDATA <= rd_header;
			O_TVALID <= 1;
			O_TLAST <= 1; /* A read is only one beat */
			state <= `STATE_RD_HDR;
			$display("%s:  Read of %d beats from %x\n", NAME, rd_len+1, {out_address, 3'h0});
		     end
		  end
	       end

	     `STATE_RD_HDR:
	       begin
		  if (O_TREADY) begin
		     /* OK, other side got our request, we're done. */
		     O_TVALID <= 0;
		     state <= `STATE_WAIT_RESP;
		     response_handshake_a <= ~response_handshake_a;
		     O_TLAST <= 0;
		  end
	       end

	     `STATE_WR_HDR:
	       begin
		  if (O_TREADY) begin
		     /* OK, other side got our header, move onto first beat of data: */
		     O_TVALID <= 1;
		     O_TDATA <= wr_data;
		     state <= `STATE_WR_DATA;
		     if (write_count == 8'h00) begin
			O_TLAST <= 1;
		     end
		  end
	       end

	     `STATE_WR_DATA:
	       begin
		  if (O_TREADY) begin
		     /* One beat consumed, either prepare another or we're done. */
		     if (write_count == 8'h00) begin
			O_TVALID <= 0;
			state <= `STATE_WAIT_RESP;
			response_handshake_a <= ~response_handshake_a;
			O_TLAST <= 0;
		     end else begin
			if (write_count == 8'h01)
			  O_TLAST <= 1;
			O_TDATA <= wr_data;
			write_count <= write_count - 1;
		     end
		  end
	       end // case: `STATE_WR_DATA

	     `STATE_WAIT_RESP:
	       begin
		  /* Do nothing until the response for our request comes in. */
		  if (response_handshake_a == response_handshake_b)
		    state <= `STATE_IDLE;
	       end
	   endcase // case (state)
	end
     end


   /* Response/input channel */
   wire [1:0] 	     pkt_type;
   wire [31:3] 	     in_address;
   reg [1:0] 	     pkt_type_r;
   reg [31:3] 	     in_address_r;
   reg 		     is_header;
   reg [9:0] 	     count;

   /* Don't care about these yet: {wr_strobes, src_id, rd_len} = I_TDATA[63:40] */
   assign pkt_type = I_TDATA[33:32];
   assign in_address = I_TDATA[31:3];

   assign I_TREADY = 1; /* No wait states on input */

   always @(posedge clk)
     begin
	if (reset) begin
	   is_header <= 1;
	   count <= 0;
	   pkt_type_r <= 0;
	   in_address_r <= 0;
	   response_handshake_b <= 0;
	end else begin
	   if (I_TVALID && I_TREADY) begin
	      if (is_header) begin
		 /* Actually only type, src_id and possibly len are valid. */
		 $display("%s:   Got pkt type %d, addr %x", NAME, pkt_type, {in_address, 3'h0});
		 pkt_type_r <= pkt_type;
		 in_address_r <= in_address;

		 if (!I_TLAST) begin
		    // There's more than just the header.
		    if (pkt_type != 2'b10) begin // RDATA
		       $display("%s:  *** Multi-beat packet that isn't an RDATA", NAME);
		    end
		    is_header <= 0;
		    count <= 1;
		 end else begin
		    if (pkt_type == 2'b11) begin // WRACK
		       $display("%s:   Got WRACK for addr %x\n", NAME, {in_address, 3'h0});
		    end else begin
		       $display("%s:  *** Got mystery 1-beat packet type %d\n", NAME, pkt_type);
		    end

		    /* Tell the other side it can continue. */
		    response_handshake_b <= ~response_handshake_b;
		 end
	      end else begin // if (is_header)
		 // Count non-header beats
		 count <= count + 1;
		 // Do something with I_TDATA[], which is read data.
		 // Also, can increment in_address_r to track real read address.

		 if (I_TLAST) begin
		    // OK, done; next beat is the next packet's header.
		    is_header <= 1;
		    /* Tell the other side it can continue. */
		    response_handshake_b <= ~response_handshake_b;

		    if (pkt_type_r == 2'b10) begin
		       $display("%s:   ReadData %d beats from address %x\n", NAME, count, {in_address_r, 3'h0});
		    end else begin
		       $display("%s:  *** Mystery multi-beat packet was %d beats long\n", NAME, count);
		    end
		 end
	      end // else: !if(is_header)
	   end
	end
     end
endmodule
