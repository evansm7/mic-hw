/* Interconnect merge component
 *
 * Two incoming port, one outgoing port.  Steers an entire packet
 * (from header to last, wholly) from a selected input to output,
 * giving priority to port0.
 *
 * When used on a request path, this component adds routing info.
 * This is indicated by PROD_ROUTE.  1 bit of route is pushed onto
 * SRC_ID[0], shifting up the existing route to [7:1].
 *
 * Copyright 2017, 2019-2022 Matt Evans
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

module i_merge(input wire 	  clk,
	       input wire 	  reset,

	       /* Input 0 */
	       input wire 	  I0_TVALID,
	       output wire 	  I0_TREADY,
	       input wire [63:0]  I0_TDATA,
	       input wire 	  I0_TLAST,

	       /* Input 1 */
	       input wire 	  I1_TVALID,
	       output wire 	  I1_TREADY,
	       input wire [63:0]  I1_TDATA,
	       input wire 	  I1_TLAST,

	       /* Out */
	       output wire 	  O_TVALID,
	       input wire 	  O_TREADY,
	       output wire [63:0] O_TDATA,
	       output wire 	  O_TLAST
	    );

   parameter PROD_ROUTE = 1;	/* 1 if used on request path, 0 on completion path */

   localparam ID0 = 1'b0;
   localparam ID1 = 1'b1;

   reg 				  is_header;
   reg 				  routing_direction;
   wire 			  input_select;

   wire [64:0] 			  storage_data_in;
   wire [64:0] 			  storage_data_out;
   wire 			  s_valid;
   wire 			  s_ready;
   wire 			  m_valid;
   wire 			  m_ready;

   /* Storage element is effectively a 1- or 2-entry FIFO; use bit [64] to track
    * the routing direction for a given packet beat; use bit [65] to flag last
    * beat.
    */
   double_latch #(.WIDTH(65))
     ST(.clk(clk), .reset(reset),
	.s_valid(s_valid), .s_ready(s_ready), .s_data(storage_data_in),
	.m_valid(m_valid), .m_ready(m_ready), .m_data(storage_data_out));

   /* Looks weird, but if is_header then effectively we're waiting for a new
    * packet and we don't want to tell *both* ports they're _TREADY at the same
    * time.  So in this case, TREADY depends on the input being TVALID.
    */
   assign I0_TREADY 	= s_ready &&
			  ((is_header && I0_TVALID) ||
			   (!is_header && (routing_direction == 0)));
   assign I1_TREADY 	= s_ready &&
			  ((is_header && !I0_TVALID && I1_TVALID) ||
			   (!is_header && (routing_direction == 1)));

   assign O_TVALID      = m_valid;
   assign O_TDATA	= storage_data_out[63:0];
   assign O_TLAST       = storage_data_out[64];
   assign m_ready       = O_TREADY;

   assign input_select = is_header ? (I0_TVALID ? 0 :
				      (I1_TVALID ? 1 : 0)) :
			 routing_direction;

   wire [63:0]                    i0_hdr_transformed;
   wire [63:0] 			  i1_hdr_transformed;

   wire [63:0] 			  i0_din;
   wire [63:0] 			  i1_din;

   /* If producing routing info then shift up routing info, adding on 1 bit for this hop: */
   assign i0_hdr_transformed = { I0_TDATA[63:56],
                                 (PROD_ROUTE ? { I0_TDATA[54:48], ID0 } : I0_TDATA[55:48]),
                                 I0_TDATA[47:0] };
   assign i1_hdr_transformed = { I1_TDATA[63:56],
                                 (PROD_ROUTE ? { I1_TDATA[54:48], ID1 } : I1_TDATA[55:48]),
                                 I1_TDATA[47:0] };

   assign i0_din = is_header ? i0_hdr_transformed : I0_TDATA[63:0];
   assign i1_din = is_header ? i1_hdr_transformed : I1_TDATA[63:0];

   assign storage_data_in[64:0] = input_select ?
                                  {I1_TLAST, i1_din} :
                                  {I0_TLAST, i0_din};

   assign s_valid = input_select ? I1_TVALID : I0_TVALID;


   always @(posedge clk)
     begin
	if (s_ready) begin
	   if (is_header) begin
	      /* Pick a favourite */
	      if (I0_TVALID) begin
		 routing_direction <= 0;
		 if (!I0_TLAST) is_header <= 0;
	      end else if (I1_TVALID) begin
		 routing_direction <= 1;
		 if (!I1_TLAST) is_header <= 0;
	      end
	   end else begin /* Not header, subsequent beat */
	      if (routing_direction == 0 && I0_TVALID) begin
		 if (I0_TLAST) is_header <= 1;
	      end else if (routing_direction == 1 && I1_TVALID) begin
		 if (I1_TLAST) is_header <= 1;
	      end
	   end // else: !if(is_header)
	end // if (s_ready)

        if (reset) begin
           /* Last assignment wins */
	   is_header <= 1;
	   routing_direction <= 0;
	end
     end

endmodule // p_st
