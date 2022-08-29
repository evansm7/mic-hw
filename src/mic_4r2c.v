/* MIC 4 Requesters, 2 Completers
 *
 * Simplest ever address map is as follows:
 * 0x00000000-0x7fffffff: Completer 0
 * 0x80000000-0xffffffff: Completer 1
 *
 * Copyright 2017, 2021 Matt Evans
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

module mic_4r2c(input wire 	   clk,
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

   wire        r0c0_tv;
   wire        r0c0_tr;
   wire [63:0] r0c0_td;
   wire        r0c0_tl;

   wire        r0c1_tv;
   wire        r0c1_tr;
   wire [63:0] r0c1_td;
   wire        r0c1_tl;

   wire        r1c0_tv;
   wire        r1c0_tr;
   wire [63:0] r1c0_td;
   wire        r1c0_tl;

   wire        r1c1_tv;
   wire        r1c1_tr;
   wire [63:0] r1c1_td;
   wire        r1c1_tl;

   wire        r2c0_tv;
   wire        r2c0_tr;
   wire [63:0] r2c0_td;
   wire        r2c0_tl;

   wire        r2c1_tv;
   wire        r2c1_tr;
   wire [63:0] r2c1_td;
   wire        r2c1_tl;

   wire        r3c0_tv;
   wire        r3c0_tr;
   wire [63:0] r3c0_td;
   wire        r3c0_tl;

   wire        r3c1_tv;
   wire        r3c1_tr;
   wire [63:0] r3c1_td;
   wire        r3c1_tl;

   i_steer
     #( .CONSUME_ROUTE(0), .HDR_BIT(31) /* Addr[31] */ )
   STEER_R0REQ
     (.clk(clk),
      .reset(reset),

      .I_TDATA(R0I_TDATA),
      .I_TVALID(R0I_TVALID),
      .I_TREADY(R0I_TREADY),
      .I_TLAST(R0I_TLAST),

      .O0_TDATA(r0c0_td),
      .O0_TVALID(r0c0_tv),
      .O0_TREADY(r0c0_tr),
      .O0_TLAST(r0c0_tl),

      .O1_TDATA(r0c1_td),
      .O1_TVALID(r0c1_tv),
      .O1_TREADY(r0c1_tr),
      .O1_TLAST(r0c1_tl)
      );

   i_steer
     #( .CONSUME_ROUTE(0), .HDR_BIT(31) /* Addr[31] */ )
   STEER_R1REQ
     (.clk(clk),
      .reset(reset),

      .I_TDATA(R1I_TDATA),
      .I_TVALID(R1I_TVALID),
      .I_TREADY(R1I_TREADY),
      .I_TLAST(R1I_TLAST),

      .O0_TDATA(r1c0_td),
      .O0_TVALID(r1c0_tv),
      .O0_TREADY(r1c0_tr),
      .O0_TLAST(r1c0_tl),

      .O1_TDATA(r1c1_td),
      .O1_TVALID(r1c1_tv),
      .O1_TREADY(r1c1_tr),
      .O1_TLAST(r1c1_tl)
      );

   i_steer
     #( .CONSUME_ROUTE(0), .HDR_BIT(31) /* Addr[31] */ )
   STEER_R2REQ
     (.clk(clk),
      .reset(reset),

      .I_TDATA(R2I_TDATA),
      .I_TVALID(R2I_TVALID),
      .I_TREADY(R2I_TREADY),
      .I_TLAST(R2I_TLAST),

      .O0_TDATA(r2c0_td),
      .O0_TVALID(r2c0_tv),
      .O0_TREADY(r2c0_tr),
      .O0_TLAST(r2c0_tl),

      .O1_TDATA(r2c1_td),
      .O1_TVALID(r2c1_tv),
      .O1_TREADY(r2c1_tr),
      .O1_TLAST(r2c1_tl)
      );

   i_steer
     #( .CONSUME_ROUTE(0), .HDR_BIT(31) /* Addr[31] */ )
   STEER_R3REQ
     (.clk(clk),
      .reset(reset),

      .I_TDATA(R3I_TDATA),
      .I_TVALID(R3I_TVALID),
      .I_TREADY(R3I_TREADY),
      .I_TLAST(R3I_TLAST),

      .O0_TDATA(r3c0_td),
      .O0_TVALID(r3c0_tv),
      .O0_TREADY(r3c0_tr),
      .O0_TLAST(r3c0_tl),

      .O1_TDATA(r3c1_td),
      .O1_TVALID(r3c1_tv),
      .O1_TREADY(r3c1_tr),
      .O1_TLAST(r3c1_tl)
      );

   ////////////////////////////////////////////////////////////////////////////

   i_merge4
     #( .PROD_ROUTE(1) )
     C0MERGEREQ
       (.clk(clk),
	.reset(reset),

	.I0_TVALID(r0c0_tv),
	.I0_TREADY(r0c0_tr),
	.I0_TDATA(r0c0_td),
	.I0_TLAST(r0c0_tl),

	.I1_TVALID(r1c0_tv),
	.I1_TREADY(r1c0_tr),
	.I1_TDATA(r1c0_td),
	.I1_TLAST(r1c0_tl),

	.I2_TVALID(r2c0_tv),
	.I2_TREADY(r2c0_tr),
	.I2_TDATA(r2c0_td),
	.I2_TLAST(r2c0_tl),

	.I3_TVALID(r3c0_tv),
	.I3_TREADY(r3c0_tr),
	.I3_TDATA(r3c0_td),
	.I3_TLAST(r3c0_tl),

	.O_TVALID(C0O_TVALID),
	.O_TREADY(C0O_TREADY),
	.O_TDATA(C0O_TDATA),
	.O_TLAST(C0O_TLAST)
      );

   i_merge4
     #( .PROD_ROUTE(1) )
     C1MERGEREQ
       (.clk(clk),
	.reset(reset),

	.I0_TVALID(r0c1_tv),
	.I0_TREADY(r0c1_tr),
	.I0_TDATA(r0c1_td),
	.I0_TLAST(r0c1_tl),

	.I1_TVALID(r1c1_tv),
	.I1_TREADY(r1c1_tr),
	.I1_TDATA(r1c1_td),
	.I1_TLAST(r1c1_tl),

	.I2_TVALID(r2c1_tv),
	.I2_TREADY(r2c1_tr),
	.I2_TDATA(r2c1_td),
	.I2_TLAST(r2c1_tl),

	.I3_TVALID(r3c1_tv),
	.I3_TREADY(r3c1_tr),
	.I3_TDATA(r3c1_td),
	.I3_TLAST(r3c1_tl),

	.O_TVALID(C1O_TVALID),
	.O_TREADY(C1O_TREADY),
	.O_TDATA(C1O_TDATA),
	.O_TLAST(C1O_TLAST)
      );

   ////////////////////////////////////////////////////////////////////////////
   // Responses                                                              //
   ////////////////////////////////////////////////////////////////////////////

   wire        c0r0_tv;
   wire        c0r0_tr;
   wire [63:0] c0r0_td;
   wire        c0r0_tl;

   wire        c0r1_tv;
   wire        c0r1_tr;
   wire [63:0] c0r1_td;
   wire        c0r1_tl;

   wire        c0r2_tv;
   wire        c0r2_tr;
   wire [63:0] c0r2_td;
   wire        c0r2_tl;

   wire        c0r3_tv;
   wire        c0r3_tr;
   wire [63:0] c0r3_td;
   wire        c0r3_tl;

   wire        c1r0_tv;
   wire        c1r0_tr;
   wire [63:0] c1r0_td;
   wire        c1r0_tl;

   wire        c1r1_tv;
   wire        c1r1_tr;
   wire [63:0] c1r1_td;
   wire        c1r1_tl;

   wire        c1r2_tv;
   wire        c1r2_tr;
   wire [63:0] c1r2_td;
   wire        c1r2_tl;

   wire        c1r3_tv;
   wire        c1r3_tr;
   wire [63:0] c1r3_td;
   wire        c1r3_tl;

   /* i_steer4 from completer input C0I/C1I ports to 4 requesters */

   i_steer4
     #( .CONSUME_ROUTE(1) )
     STEER_C0RESP
       (.clk(clk),
	.reset(reset),

	.I_TVALID(C0I_TVALID),
	.I_TREADY(C0I_TREADY),
	.I_TDATA(C0I_TDATA),
	.I_TLAST(C0I_TLAST),

	.O0_TVALID(c0r0_tv),
	.O0_TREADY(c0r0_tr),
	.O0_TDATA(c0r0_td),
	.O0_TLAST(c0r0_tl),

	.O1_TVALID(c0r1_tv),
	.O1_TREADY(c0r1_tr),
	.O1_TDATA(c0r1_td),
	.O1_TLAST(c0r1_tl),

	.O2_TVALID(c0r2_tv),
	.O2_TREADY(c0r2_tr),
	.O2_TDATA(c0r2_td),
	.O2_TLAST(c0r2_tl),

	.O3_TVALID(c0r3_tv),
	.O3_TREADY(c0r3_tr),
	.O3_TDATA(c0r3_td),
	.O3_TLAST(c0r3_tl)
	);

   i_steer4
     #( .CONSUME_ROUTE(1) )
     STEER_C1RESP
       (.clk(clk),
	.reset(reset),

	.I_TVALID(C1I_TVALID),
	.I_TREADY(C1I_TREADY),
	.I_TDATA(C1I_TDATA),
	.I_TLAST(C1I_TLAST),

	.O0_TVALID(c1r0_tv),
	.O0_TREADY(c1r0_tr),
	.O0_TDATA(c1r0_td),
	.O0_TLAST(c1r0_tl),

	.O1_TVALID(c1r1_tv),
	.O1_TREADY(c1r1_tr),
	.O1_TDATA(c1r1_td),
	.O1_TLAST(c1r1_tl),

	.O2_TVALID(c1r2_tv),
	.O2_TREADY(c1r2_tr),
	.O2_TDATA(c1r2_td),
	.O2_TLAST(c1r2_tl),

	.O3_TVALID(c1r3_tv),
	.O3_TREADY(c1r3_tr),
	.O3_TDATA(c1r3_td),
	.O3_TLAST(c1r3_tl)
	);

   /* ...and i_merge from 2x completers back to each of 4 requesters: */

   i_merge
     #( .PROD_ROUTE(0) )
     MERGE_R0RESP
       (.clk(clk),
	.reset(reset),

	.I0_TVALID(c0r0_tv),
	.I0_TREADY(c0r0_tr),
	.I0_TDATA(c0r0_td),
	.I0_TLAST(c0r0_tl),

	.I1_TVALID(c1r0_tv),
	.I1_TREADY(c1r0_tr),
	.I1_TDATA(c1r0_td),
	.I1_TLAST(c1r0_tl),

	.O_TVALID(R0O_TVALID),
	.O_TREADY(R0O_TREADY),
	.O_TDATA(R0O_TDATA),
	.O_TLAST(R0O_TLAST)
	);

   i_merge
     #( .PROD_ROUTE(0) )
     MERGE_R1RESP
       (.clk(clk),
	.reset(reset),

	.I0_TVALID(c0r1_tv),
	.I0_TREADY(c0r1_tr),
	.I0_TDATA(c0r1_td),
	.I0_TLAST(c0r1_tl),

	.I1_TVALID(c1r1_tv),
	.I1_TREADY(c1r1_tr),
	.I1_TDATA(c1r1_td),
	.I1_TLAST(c1r1_tl),

	.O_TVALID(R1O_TVALID),
	.O_TREADY(R1O_TREADY),
	.O_TDATA(R1O_TDATA),
	.O_TLAST(R1O_TLAST)
	);

   i_merge
     #( .PROD_ROUTE(0) )
     MERGE_R2RESP
       (.clk(clk),
	.reset(reset),

	.I0_TVALID(c0r2_tv),
	.I0_TREADY(c0r2_tr),
	.I0_TDATA(c0r2_td),
	.I0_TLAST(c0r2_tl),

	.I1_TVALID(c1r2_tv),
	.I1_TREADY(c1r2_tr),
	.I1_TDATA(c1r2_td),
	.I1_TLAST(c1r2_tl),

	.O_TVALID(R2O_TVALID),
	.O_TREADY(R2O_TREADY),
	.O_TDATA(R2O_TDATA),
	.O_TLAST(R2O_TLAST)
	);

   i_merge
     #( .PROD_ROUTE(0) )
     MERGE_R3RESP
       (.clk(clk),
	.reset(reset),

	.I0_TVALID(c0r3_tv),
	.I0_TREADY(c0r3_tr),
	.I0_TDATA(c0r3_td),
	.I0_TLAST(c0r3_tl),

	.I1_TVALID(c1r3_tv),
	.I1_TREADY(c1r3_tr),
	.I1_TDATA(c1r3_td),
	.I1_TLAST(c1r3_tl),

	.O_TVALID(R3O_TVALID),
	.O_TREADY(R3O_TREADY),
	.O_TDATA(R3O_TDATA),
	.O_TLAST(R3O_TLAST)
	);

endmodule
