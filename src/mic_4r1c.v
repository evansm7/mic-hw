/* MIC 4 Requesters, 1 Completers
 *
 * This is mostly useful as a funnel into the top of something else, e.g.
 * a requester port on mic_4r4c, to extend the number of requesters.
 *
 * Copyright 2022 Matt Evans
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

module mic_4r1c(input wire 	   clk,
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

		/* Requester port 1 request input */
		input wire 	   R1I_TVALID,
		output wire 	   R1I_TREADY,
		input wire [63:0]  R1I_TDATA,
		input wire 	   R1I_TLAST,
		/* Requester port 1 response output */
		output wire 	   R1O_TVALID,
		input wire 	   R1O_TREADY,
		output wire [63:0] R1O_TDATA,
		output wire 	   R1O_TLAST,

		/* Requester port 2 request input */
		input wire 	   R2I_TVALID,
		output wire 	   R2I_TREADY,
		input wire [63:0]  R2I_TDATA,
		input wire 	   R2I_TLAST,
		/* Requester port 2 response output */
		output wire 	   R2O_TVALID,
		input wire 	   R2O_TREADY,
		output wire [63:0] R2O_TDATA,
		output wire 	   R2O_TLAST,

		/* Requester port 3 request input */
		input wire 	   R3I_TVALID,
		output wire 	   R3I_TREADY,
		input wire [63:0]  R3I_TDATA,
		input wire 	   R3I_TLAST,
		/* Requester port 3 response output */
		output wire 	   R3O_TVALID,
		input wire 	   R3O_TREADY,
		output wire [63:0] R3O_TDATA,
		output wire 	   R3O_TLAST,

		/* Completer port 0 request output */
		output wire 	   C0O_TVALID,
		input wire 	   C0O_TREADY,
		output wire [63:0] C0O_TDATA,
		output wire 	   C0O_TLAST,
		/* Completer port 0 response input */
		input wire 	   C0I_TVALID,
		output wire 	   C0I_TREADY,
		input wire [63:0]  C0I_TDATA,
		input wire 	   C0I_TLAST
		);

   ////////////////////////////////////////////////////////////////////////////
   // Requests                                                               //
   ////////////////////////////////////////////////////////////////////////////

   /* No address routing is performed; just merge all requests towards the output. */

   i_merge4
     #( .PROD_ROUTE(1) )
     C0MERGEREQ
       (.clk(clk),
	.reset(reset),

	.I0_TVALID(R0I_TVALID),
	.I0_TREADY(R0I_TREADY),
	.I0_TDATA(R0I_TDATA),
	.I0_TLAST(R0I_TLAST),

	.I1_TVALID(R1I_TVALID),
	.I1_TREADY(R1I_TREADY),
	.I1_TDATA(R1I_TDATA),
	.I1_TLAST(R1I_TLAST),

	.I2_TVALID(R2I_TVALID),
	.I2_TREADY(R2I_TREADY),
	.I2_TDATA(R2I_TDATA),
	.I2_TLAST(R2I_TLAST),

	.I3_TVALID(R3I_TVALID),
	.I3_TREADY(R3I_TREADY),
	.I3_TDATA(R3I_TDATA),
	.I3_TLAST(R3I_TLAST),

	.O_TVALID(C0O_TVALID),
	.O_TREADY(C0O_TREADY),
	.O_TDATA(C0O_TDATA),
	.O_TLAST(C0O_TLAST)
      );

   ////////////////////////////////////////////////////////////////////////////
   // Responses                                                              //
   ////////////////////////////////////////////////////////////////////////////

   /* Responses are return-routed based on the route produced by the i_merge4
    * above.
    */

   /* i_steer4 from completer input C0I port to 4 requesters */

   i_steer4
     #( .CONSUME_ROUTE(1) )
     STEER_C0RESP
       (.clk(clk),
	.reset(reset),

	.I_TVALID(C0I_TVALID),
	.I_TREADY(C0I_TREADY),
	.I_TDATA(C0I_TDATA),
	.I_TLAST(C0I_TLAST),

	.O0_TVALID(R0O_TVALID),
	.O0_TREADY(R0O_TREADY),
	.O0_TDATA(R0O_TDATA),
	.O0_TLAST(R0O_TLAST),

	.O1_TVALID(R1O_TVALID),
	.O1_TREADY(R1O_TREADY),
	.O1_TDATA(R1O_TDATA),
	.O1_TLAST(R1O_TLAST),

	.O2_TVALID(R2O_TVALID),
	.O2_TREADY(R2O_TREADY),
	.O2_TDATA(R2O_TDATA),
	.O2_TLAST(R2O_TLAST),

	.O3_TVALID(R3O_TVALID),
	.O3_TREADY(R3O_TREADY),
	.O3_TDATA(R3O_TDATA),
	.O3_TLAST(R3O_TLAST)
	);

endmodule
