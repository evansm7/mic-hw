/* Trivial simulation of a complex interconnect:
 * Basically, pass things through a pipeline with the occasional stall to test
 * backpressure -- make sure a requester copes with MIC not being able to accept
 * a request, accept write data, or MIC not providing read data back-to-back.
 *
 * Todo: Control delays as packet begins versus delays whilst packet is sent.
 *
 * Copyright 2019, 2021 Matt Evans
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

module mic_sim(input wire         clk,
	       input wire 	  reset,

	       /* Request port input (forward from requester) */
	       input wire 	  M0I_TVALID,
	       output wire 	  M0I_TREADY,
	       input wire [63:0]  M0I_TDATA,
	       input wire 	  M0I_TLAST,
	       /* Response port output (back to requester) */
	       output wire 	  M0O_TVALID,
	       input wire 	  M0O_TREADY,
	       output wire [63:0] M0O_TDATA,
	       output wire 	  M0O_TLAST,

	       /* Request port output (forward to completer) */
	       output wire 	  S0O_TVALID,
	       input wire 	  S0O_TREADY,
	       output wire [63:0] S0O_TDATA,
	       output wire 	  S0O_TLAST,

	       /* Response port input (back from completer) */
	       input wire 	  S0I_TVALID,
	       output wire 	  S0I_TREADY,
	       input wire [63:0]  S0I_TDATA,
	       input wire 	  S0I_TLAST
	       );

   parameter RNG_INIT = 16'hbeef;

   wire [15:0] 	     rng;

   rng		#(.S(RNG_INIT))
                RNG(.clk(clk), .reset(reset), .rng_o(rng));

   /* Add a pipeline slice in each direction.
    * Based on RNG, inhibit READY in the backward direction (and cause VALID to be 0 in these cycles)
    */

   /* Storage element is effectively a 1- or 2-entry FIFO; use bit [64] to flag
    * last beat.
    */
   wire [64:0] 			  f_storage_data_out;
   wire 			  f_s_ready;
   wire 			  f_m_valid;
   wire 			  f_stall;

   assign f_stall = rng[3];

   double_latch #(.WIDTH(65))
     FWD(.clk(clk), .reset(reset),
	 .s_valid(M0I_TVALID && !f_stall), .s_ready(f_s_ready), .s_data({M0I_TLAST, M0I_TDATA}),
	 .m_valid(f_m_valid), .m_ready(S0O_TREADY), .m_data(f_storage_data_out));

   assign M0I_TREADY = f_s_ready && !f_stall;
   assign S0O_TVALID = f_m_valid;
   assign S0O_TDATA = f_storage_data_out[63:0];
   assign S0O_TLAST = f_storage_data_out[64];


   wire [64:0] 			  b_storage_data_out;
   wire 			  b_s_ready;
   wire 			  b_m_valid;
   wire 			  b_stall;

   assign b_stall = rng[0];

   double_latch #(.WIDTH(65))
     BK(.clk(clk), .reset(reset),
	.s_valid(S0I_TVALID && !b_stall), .s_ready(b_s_ready), .s_data({S0I_TLAST, S0I_TDATA}),
	.m_valid(b_m_valid), .m_ready(M0O_TREADY), .m_data(b_storage_data_out));

   assign S0I_TREADY = b_s_ready && !b_stall;
   assign M0O_TVALID = b_m_valid;
   assign M0O_TDATA = b_storage_data_out[63:0];
   assign M0O_TLAST = b_storage_data_out[64];


endmodule // mic_sim
