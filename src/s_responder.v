/* Receives requests from an m_pktgen and returns responses
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

module s_responder(input wire        clk,
		   input wire 	     reset,

		   input wire 	     I_TVALID,
		   output wire 	     I_TREADY,
		   input wire [63:0] I_TDATA,
		   input wire 	     I_TLAST,

		   output reg 	     O_TVALID,
		   input wire 	     O_TREADY,
		   output reg [63:0] O_TDATA,
		   output reg 	     O_TLAST
		   );

   parameter NAME = "Responder";

   /* Request type */
   reg [1:0] 	     request;
`define REQ_NONE          0
`define REQ_RD            1
`define REQ_WR            2

   reg [3:0] 	     output_state;
`define STATE_IDLE        0
`define STATE_RDATA_HDR   1
`define STATE_RDATA_DATA  2
`define STATE_WRACK_HDR   3
`define STATE_DONE        4

   reg [7:0] 	     req_srcid;
   reg [7:0] 	     req_len;
   reg [1:0] 	     req_type;
   reg [31:3] 	     req_addr;

   reg [8:0] 	     beat_count;
   reg 		     is_header;

   wire [7:0] 	     wr_strobes;
   wire [7:0] 	     src_id;
   wire [7:0] 	     rd_len;
   wire [1:0] 	     pkt_type;
   wire [31:3] 	     address;

   assign {wr_strobes, src_id, rd_len} = I_TDATA[63:40];
   assign pkt_type = I_TDATA[33:32];
   assign address = I_TDATA[31:3];

   assign I_TREADY = (request == `REQ_NONE);

   /* Handshake between input and output:
    * When request is REQ_NONE, input is accepted.
    * When input is a valid request, request becomes REQ_RD or REQ_WR.
    * When REQ_RD/REQ_WR and output_state is ST_IDLE, an output request is generated.
    * When output is complete, and request is not REQ_NONE output_state is ST_DONE.
    * When output_state is ST_DONE, request returns to REQ_NONE.
    * When REQ_NONE, and output_state is ST_DONE, it goes to ST_IDLE.
    */

   /* Input request processing */
   always @(posedge clk)
     begin
	if (reset) begin
	   is_header <= 1;
	   beat_count <= 0;

	   req_type <= 0;
	   req_len <= 0;
	   req_srcid <= 0;
	   req_addr <= 0;
	   request <= `REQ_NONE;
	end else begin
	   if (request <= `REQ_NONE) begin
	      if (I_TVALID && I_TREADY) begin
		 if (is_header) begin
		    $display("%s:  Got pkt type %d, addr %x, len %d, src_id %x",
			     NAME, pkt_type, {address, 3'h0}, rd_len, src_id);

		    req_srcid <= src_id; /* To route response */
		    req_len <= rd_len;   /* To generate correct number of response beats */
		    req_type <= pkt_type;
		    req_addr <= address;

		    if (!I_TLAST) begin
		       // There's more than just the header.
		       if (pkt_type != 2'b01) begin // WRITE
			  $display("%s:  *** Multi-beat packet that isn't a WRITE", NAME);
		       end else begin
			  $display("%s:  Header complete; WRITE continues", NAME);
		       end
		       is_header <= 0;
		       beat_count <= 1;
		    end else begin
		       // A read request is set up on receipt of the header (LAST=1)
		       if (/* Current header */ pkt_type == 2'b00) begin
			  $display("%s:  Header complete; READ", NAME);
			 request <= `REQ_RD;
		       end
		    end
		 end else begin // if (is_header)
		    if (I_TLAST) begin
		       is_header <= 1;
		       $display("%s:  Multi-beat request was %d beats long", NAME, beat_count);

		       // Consumed all input beats; set the request type (for a response):
		       if (/* Previous header */ req_type == 2'b01) begin
			 request <= `REQ_WR;
		       end
		    end
		    beat_count <= beat_count + 1;
		 end
	      end // if (I_TVALID && I_TREADY)
	   end else begin // if (request <= `REQ_NONE)
	      if (output_state == `STATE_DONE) begin
		 request <= `REQ_NONE;
	      end
	   end
	end
     end

   wire [63:0] 	     rdata_header;
   wire [63:0] 	     wrack_header;
   assign rdata_header[63:0] = { 8'h00, req_srcid, 8'h00 /* RD len */, 6'h00, 2'b10 /* RDATA */,
				 req_addr, 3'h0};
   assign wrack_header[63:0] = { 8'h00, req_srcid, 8'h00 /* RD len */, 6'h00, 2'b11 /* WRACK */,
				 req_addr, 3'h0};

   reg [7:0] 	     output_counter;

   /* Output response processing */
   always @(posedge clk)
     begin
	if (reset) begin
	   output_state <= `STATE_IDLE;

	   O_TDATA <= 0;
	   O_TLAST <= 0;
	   O_TVALID <= 0;

	   output_counter <= 0;
	end else begin
	   case (output_state)
	     `STATE_IDLE:
	       begin
		  if (request == `REQ_RD) begin
		     O_TDATA <= rdata_header;
		     O_TVALID <= 1;
		     O_TLAST <= 0; /* Read data provides more beats */
		     output_state <= `STATE_RDATA_HDR;
		     $display("%s:   Sending ReadData response of %d beats to %x\n", NAME, req_len+1, req_srcid);
		     output_counter <= req_len;
		  end else if (request == `REQ_WR) begin
		     O_TDATA <= wrack_header;
		     O_TVALID <= 1;
		     O_TLAST <= 1;
		     output_state <= `STATE_WRACK_HDR;
		     $display("%s:   Sending WrAck to %x\n", NAME, req_srcid);
		  end
	       end

	     `STATE_WRACK_HDR:
	       begin
		  if (O_TREADY) begin
		     /* OK, other side got our request, we're done. */
		     O_TVALID <= 0;
		     O_TLAST <= 0;
		     output_state <= `STATE_DONE;
		  end
	       end

	     `STATE_RDATA_HDR:
	       begin
		  if (O_TREADY) begin
		     /* OK, other side got our header, move onto data: */
		     O_TVALID <= 1;
		     O_TDATA <= 64'hfeedfacebeef0000 | output_counter[7:0];
		     output_state <= `STATE_RDATA_DATA;
		     if (output_counter == 8'h00) begin
			O_TLAST <= 1;
		     end
		  end
	       end

	     `STATE_RDATA_DATA:
	       begin
		  if (O_TREADY) begin
		     /* One beat consumed, either prepare another or we're done. */
		     if (output_counter == 8'h00) begin
			O_TVALID <= 0;
			O_TLAST <= 0;
			output_state <= `STATE_DONE;
		     end else begin
			if (output_counter == 8'h01) O_TLAST <= 1;
			O_TDATA <= 64'hfeedfacebeef0000 | output_counter[7:0];
			output_counter <= output_counter - 1;
		     end
		  end
	       end // case: `STATE_WR_DATA

	     `STATE_DONE:
	       begin
		  if (request == `REQ_NONE) begin
		     output_state <= `STATE_IDLE;
		  end
	       end
	   endcase // case (state)

	end
     end

endmodule // m_pktsink
