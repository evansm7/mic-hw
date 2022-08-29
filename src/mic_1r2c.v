/* MIC 1 requester, 2 responders
 *
 * Simplest ever address map is as follows:
 * 0x00000000-0x3fffffff / 0x80000000-0xbfffffff: Responder 0
 * 0x40000000-0x7fffffff / 0xc0000000-0xffffffff: Requester 1
 *
 * Copyright 2020-2021 Matt Evans
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

module mic_1r2c(input wire 	   clk,
		input wire 	   reset,

		/* Requester port 0 request input */
		input wire 	   R0I_TVALID,
		output wire 	   R0I_TREADY,
		input wire [63:0]  R0I_TDATA,
		input wire 	   R0I_TLAST,
		/* Requester port 0 response output */
		output wire 	   R0O_TVALID,
		input wire 	   R0O_TREADY,
		output wire [63:0] R0O_TDATA,
		output wire 	   R0O_TLAST,

		/* Completer port 0 request output */
		output wire 	   C0O_TVALID,
		input wire 	   C0O_TREADY,
		output wire [63:0] C0O_TDATA,
		output wire 	   C0O_TLAST,
		/* Completer port 0 response input */
		input wire 	   C0I_TVALID,
		output wire 	   C0I_TREADY,
		input wire [63:0]  C0I_TDATA,
		input wire 	   C0I_TLAST,

		/* Completer port 1 request output */
		output wire 	   C1O_TVALID,
		input wire 	   C1O_TREADY,
		output wire [63:0] C1O_TDATA,
		output wire 	   C1O_TLAST,
		/* Completer port 1 response input */
		input wire 	   C1I_TVALID,
		output wire 	   C1I_TREADY,
		input wire [63:0]  C1I_TDATA,
		input wire 	   C1I_TLAST
		);

   ////////////////////////////////////////////////////////////////////////////
   // Requests                                                               //
   ////////////////////////////////////////////////////////////////////////////

   i_steer
     #( .CONSUME_ROUTE(0), .HDR_BIT(30) /* Addr[30] */ )
   STEER_R0REQ
     (.clk(clk),
      .reset(reset),

      .I_TDATA(R0I_TDATA),
      .I_TVALID(R0I_TVALID),
      .I_TREADY(R0I_TREADY),
      .I_TLAST(R0I_TLAST),

      .O0_TDATA(C0O_TDATA),
      .O0_TVALID(C0O_TVALID),
      .O0_TREADY(C0O_TREADY),
      .O0_TLAST(C0O_TLAST),

      .O1_TDATA(C1O_TDATA),
      .O1_TVALID(C1O_TVALID),
      .O1_TREADY(C1O_TREADY),
      .O1_TLAST(C1O_TLAST)
      );

   ////////////////////////////////////////////////////////////////////////////
   // Responses                                                              //
   ////////////////////////////////////////////////////////////////////////////

   /* i_merge from 2x completers back the request port: */

   i_merge
     #( .PROD_ROUTE(0) )
     MERGE_R0RESP
       (.clk(clk),
	.reset(reset),

	.I0_TVALID(C0I_TVALID),
	.I0_TREADY(C0I_TREADY),
	.I0_TDATA(C0I_TDATA),
	.I0_TLAST(C0I_TLAST),

	.I1_TVALID(C1I_TVALID),
	.I1_TREADY(C1I_TREADY),
	.I1_TDATA(C1I_TDATA),
	.I1_TLAST(C1I_TLAST),

	.O_TVALID(R0O_TVALID),
	.O_TREADY(R0O_TREADY),
	.O_TDATA(R0O_TDATA),
	.O_TLAST(R0O_TLAST)
	);

endmodule
