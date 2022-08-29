/* Interconnect steer 4:1 component
 *
 * One incoming port, four outgoing ports.  Steers an entire packet
 * (from header to last, wholly) down an output port given by the bits
 * of address selected by the parameter, HDR_BIT.
 *
 * See note in i_steer; CONSUME_ROUTE eats two bits from the route and
 * used when this component routes completions.  When this component is
 * used to route requests, HDR_BIT indicates the LSB of the 2-bit address
 * field that steers.
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

module i_steer4(input wire 	  clk,
		input wire 	   reset,

		/* Input */
		input wire 	   I_TVALID,
		output wire 	   I_TREADY,
		input wire [63:0]  I_TDATA,
		input wire 	   I_TLAST,

		/* Out 0 */
		output wire 	   O0_TVALID,
		input wire 	   O0_TREADY,
		output wire [63:0] O0_TDATA,
		output wire 	   O0_TLAST,

		/* Out 1 */
		output wire 	   O1_TVALID,
		input wire 	   O1_TREADY,
		output wire [63:0] O1_TDATA,
		output wire 	   O1_TLAST,

		/* Out 2 */
		output wire 	   O2_TVALID,
		input wire 	   O2_TREADY,
		output wire [63:0] O2_TDATA,
		output wire 	   O2_TLAST,

		/* Out 3 */
		output wire 	   O3_TVALID,
		input wire 	   O3_TREADY,
		output wire [63:0] O3_TDATA,
		output wire 	   O3_TLAST
	    );

   parameter CONSUME_ROUTE = 0;		// 1 if on completion/return path
   parameter HDR_BIT = 30;		// If on request path, LSB of address to steer from

   wire [66:0] 			  storage_data_in;
   wire 			  s_valid;
   wire 			  s_ready;
   wire [66:0] 			  storage_data_out;
   wire 			  m_valid;
   wire 			  m_ready;
   wire [1:0]                     hdr_direction;
   wire [63:0]                    hdr_transformed;

   reg 				  is_header;
   reg [1:0] 			  routing_direction;

   /* Storage element is effectively a 1- or 2-entry FIFO; use bits [67:64] to
    * track the routing direction for a given packet beat; use bit [68] to flag
    * last beat.
    */
   double_latch #(.WIDTH(67))
     ST(.clk(clk), .reset(reset),
	.s_valid(s_valid), .s_ready(s_ready), .s_data(storage_data_in),
	.m_valid(m_valid), .m_ready(m_ready), .m_data(storage_data_out));

   wire [1:0] 			  out_direction = storage_data_out[65:64];

   assign s_valid       = I_TVALID;
   assign I_TREADY 	= s_ready;

   assign O0_TDATA	= storage_data_out[63:0];
   assign O1_TDATA	= storage_data_out[63:0];
   assign O2_TDATA	= storage_data_out[63:0];
   assign O3_TDATA	= storage_data_out[63:0];

   assign O0_TLAST      = storage_data_out[66];
   assign O1_TLAST      = storage_data_out[66];
   assign O2_TLAST      = storage_data_out[66];
   assign O3_TLAST      = storage_data_out[66];

   assign O0_TVALID     = out_direction == 2'b00 ? m_valid : 2'h0;
   assign O1_TVALID     = out_direction == 2'b01 ? m_valid : 2'h0;
   assign O2_TVALID     = out_direction == 2'b10 ? m_valid : 2'h0;
   assign O3_TVALID     = out_direction == 2'b11 ? m_valid : 2'h0;

   assign m_ready       = m_valid & (out_direction == 2'b00 ? O0_TREADY :
				     out_direction == 2'b01 ? O1_TREADY :
				     out_direction == 2'b10 ? O2_TREADY :
				     out_direction == 2'b11 ? O3_TREADY :
				     1'bz);

   /* The routing direction is sticky; it's determined on first beat and is
    * attached to all subsequent beats of the packet:
    */

   assign hdr_direction = CONSUME_ROUTE ? I_TDATA[49:48] : // 2 LSBs of route
                          I_TDATA[HDR_BIT+1:HDR_BIT]; // Else, address bits from parameter

   assign hdr_transformed = { I_TDATA[63:56],
                              ( CONSUME_ROUTE ? {2'b00, I_TDATA[55:50]} : I_TDATA[55:48]),
                              I_TDATA[47:0] };

   assign storage_data_in[66:0] = {I_TLAST,
				   is_header ? hdr_direction : routing_direction,
				   is_header ? hdr_transformed : I_TDATA[63:0]};


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
	end // if (s_ready && s_valid)

        if (reset) begin
	   is_header <= 1;
	   routing_direction <= 0;
	end
     end
endmodule
