/* Interconnect steer component
 *
 * One incoming port, two outgoing ports.  Steers an entire packet
 * (from header to last, wholly) down an output port given by the bit
 * of address (or SRC_ID...) selected by the parameter, HDR_BIT.
 *
 * Behaviour differs when this component is used on a request or
 * response path.  A request is simply steered given HDR_BIT, usually
 * indicating an address bit.  A response is steered given a routing
 * bit and additionally *consumes* (modifies) the routing information.
 * CONSUME_ROUTE is used to indicate this.
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

module i_steer(input wire 	  clk,
	       input wire 	  reset,

	       /* Input */
	       input wire 	  I_TVALID,
	       output wire 	  I_TREADY,
	       input wire [63:0]  I_TDATA,
	       input wire 	  I_TLAST,

	       /* Out 0 */
	       output wire 	  O0_TVALID,
	       input wire 	  O0_TREADY,
	       output wire [63:0] O0_TDATA,
	       output wire 	  O0_TLAST,

	       /* Out 1 */
	       output wire 	  O1_TVALID,
	       input wire 	  O1_TREADY,
	       output wire [63:0] O1_TDATA,
	       output wire 	  O1_TLAST
	    );

   parameter CONSUME_ROUTE = 0;		// 1 if on completion/return path
   parameter HDR_BIT = 31;		// If on request path, bit of address to steer from

   wire [65:0] 			  storage_data_in;
   wire [65:0] 			  storage_data_out;
   wire 			  s_valid;
   wire 			  s_ready;
   wire 			  m_valid;
   wire 			  m_ready;
   wire                           hdr_direction;
   wire [63:0]                    hdr_transformed;

   reg 				  is_header;
   reg 				  routing_direction;

   /* Storage element is effectively a 1- or 2-entry FIFO; use bit [64] to track
    * the routing direction for a given packet beat; use bit [65] to flag last
    * beat.
    */
   double_latch #(.WIDTH(66))
     ST(.clk(clk), .reset(reset),
	.s_valid(s_valid), .s_ready(s_ready), .s_data(storage_data_in),
	.m_valid(m_valid), .m_ready(m_ready), .m_data(storage_data_out));

   wire 			  out_direction = storage_data_out[64];

   assign s_valid       = I_TVALID;
   assign I_TREADY 	= s_ready;

   assign O0_TDATA	= storage_data_out[63:0];
   assign O1_TDATA	= storage_data_out[63:0];

   assign O0_TLAST      = storage_data_out[65];
   assign O1_TLAST      = storage_data_out[65];

   assign O0_TVALID     = out_direction ? 1'b0 : m_valid;
   assign O1_TVALID     = out_direction ? m_valid : 1'b0;

   assign m_ready       = m_valid & (out_direction ? O1_TREADY : O0_TREADY);

   /* The routing direction is sticky; it's determined on first beat and is
    * attached to all subsequent beats of the packet:
    */
   assign hdr_direction = CONSUME_ROUTE ? I_TDATA[48] : // LSB of route
                          I_TDATA[HDR_BIT]; // Else, address bit from parameter

   assign hdr_transformed = { I_TDATA[63:56],
                              ( CONSUME_ROUTE ? {1'b0, I_TDATA[55:49]} : I_TDATA[55:48]),
                              I_TDATA[47:0] };

   assign storage_data_in[65:0] = { I_TLAST,
				    is_header ? hdr_direction : routing_direction,
				    is_header ? hdr_transformed : I_TDATA[63:0] };


   always @(posedge clk)
     begin
	if (s_ready && s_valid) begin
	   /* If the storage is going to accept a beat...*/
	   if (is_header) begin
	      /* If it's the first beat of a packet, store the route so it
	       * can be attached to subsequent beats.
	       */
	      routing_direction <= hdr_direction;
	      if (!I_TLAST) is_header <= 0;
	   end else begin
	      if (I_TLAST) is_header <= 1;
	   end
	end

        if (reset) begin
           /* Last assignment wins */
           is_header <= 1;
           routing_direction <= 0;
        end
     end

endmodule
