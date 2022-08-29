/* TB for MIC interconnect, memtest, bram
 *
 * Copyright 2017, 2019, 2022 Matt Evans
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

`timescale 1ns/1ns

`define CLK_PERIOD 10

`define NUM_TRANSACTIONS 1234

module glbl();
   reg 	GSR = 0;
   reg 	GTS = 0;
endmodule // glbl


module top();
   reg 	reset;
   reg  clk;

   ////////////////////////////////////////////////////////////////////////

   always #(`CLK_PERIOD/2) clk = !clk;

   ////////////////////////////////////////////////////////////////////////

   wire [31:0] mt1_ntrx;

   wire        r0_tv;
   wire        r0_tr;
   wire [63:0] r0_td;
   wire        r0_tl;
   wire        r0r_tv;
   wire        r0r_tr;
   wire [63:0] r0r_td;
   wire        r0r_tl;

   wire        r1_tv;
   wire        r1_tr;
   wire [63:0] r1_td;
   wire        r1_tl;
   wire        r1r_tv;
   wire        r1r_tr;
   wire [63:0] r1r_td;
   wire        r1r_tl;

   wire        r2_tv;
   wire        r2_tr;
   wire [63:0] r2_td;
   wire        r2_tl;
   wire        r2r_tv;
   wire        r2r_tr;
   wire [63:0] r2r_td;
   wire        r2r_tl;

   wire        c0_tv;
   wire        c0_tr;
   wire [63:0] c0_td;
   wire        c0_tl;

   wire        c0r_tv;
   wire        c0r_tr;
   wire [63:0] c0r_td;
   wire        c0r_tl;

   wire        c1_tv;
   wire        c1_tr;
   wire [63:0] c1_td;
   wire        c1_tl;

   wire        c1r_tv;
   wire        c1r_tr;
   wire [63:0] c1r_td;
   wire        c1r_tl;


   /* Requester 0:  Memtest requester */
   m_memtest
     #( .THROTTLE(1),
	.ADDR_MASK(29'h00003fff), /* 128K in bottom 2G (to RAM only) */
	.NAME("Memtest0")
	)
   REQA
     (.clk(clk),
      .reset(reset),

      .O_TDATA(r0_td),
      .O_TVALID(r0_tv),
      .O_TREADY(r0_tr),
      .O_TLAST(r0_tl),

      .I_TDATA(r0r_td),
      .I_TVALID(r0r_tv),
      .I_TREADY(r0r_tr),
      .I_TLAST(r0r_tl)
      );

   /* Requester 1:  Memtest requester */
   m_memtest
     #( .THROTTLE(0),
	.NUM_TRANSACTIONS(`NUM_TRANSACTIONS),
	.ADDR_MASK(29'h00003fff), /* 128K in bottom 2G (to RAM only) */
	.ADDR_OFFS(29'h00004000), /* Top 128K of RAM, i.e. don't overlap above! */
	.NAME("Memtest1")
	)
   REQB
     (.clk(clk),
      .reset(reset),

      .O_TDATA(r1_td),
      .O_TVALID(r1_tv),
      .O_TREADY(r1_tr),
      .O_TLAST(r1_tl),

      .I_TDATA(r1r_td),
      .I_TVALID(r1r_tv),
      .I_TREADY(r1r_tr),
      .I_TLAST(r1r_tl),

      .trx_count(mt1_ntrx)
      );

   /* Requester 2:  Combined requester */
   m_requester
     #( .THROTTLE(1),
	.HALT(0),
	.ADDR_MASK(29'h10003fff), /* 128K in top 2G */
	.ADDR_OFFS(29'h10000000), /* Always in top 2G  */
	.NAME("Requester2")
	)
   REQC
     (.clk(clk),
      .reset(reset),

      .O_TDATA(r2_td),
      .O_TVALID(r2_tv),
      .O_TREADY(r2_tr),
      .O_TLAST(r2_tl),

      .I_TDATA(r2r_td),
      .I_TVALID(r2r_tv),
      .I_TREADY(r2r_tr),
      .I_TLAST(r2r_tl)
      );


   /* Completer 0 */
   s_bram
     #( .NAME("RAM0"),
	.KB_SIZE(256)
	)
     RAMA
     (.clk(clk),
      .reset(reset),

      .I_TDATA(c0_td),
      .I_TVALID(c0_tv),
      .I_TREADY(c0_tr),
      .I_TLAST(c0_tl),

      .O_TDATA(c0r_td),
      .O_TVALID(c0r_tv),
      .O_TREADY(c0r_tr),
      .O_TLAST(c0r_tl)
      );

   /* Completer 1 */
   s_responder
     #( .NAME("Completer1") )
     RESPONDERA
     (.clk(clk),
      .reset(reset),

      .I_TDATA(c1_td),
      .I_TVALID(c1_tv),
      .I_TREADY(c1_tr),
      .I_TLAST(c1_tl),

      .O_TDATA(c1r_td),
      .O_TVALID(c1r_tv),
      .O_TREADY(c1r_tr),
      .O_TLAST(c1r_tl)
      );


   /* The main interconnect */
   mic_4r2c
     MIC
       (.clk(clk),
	.reset(reset),

	/* Requester port 0 request input */
	.R0I_TVALID(r0_tv),
	.R0I_TREADY(r0_tr),
	.R0I_TDATA(r0_td),
	.R0I_TLAST(r0_tl),
	/* Requester port 0 response output */
	.R0O_TVALID(r0r_tv),
	.R0O_TREADY(r0r_tr),
	.R0O_TDATA(r0r_td),
	.R0O_TLAST(r0r_tl),

	/* Requester port 1 request input */
	.R1I_TVALID(r1_tv),
	.R1I_TREADY(r1_tr),
	.R1I_TDATA(r1_td),
	.R1I_TLAST(r1_tl),
	/* Requester port 1 response output */
	.R1O_TVALID(r1r_tv),
	.R1O_TREADY(r1r_tr),
	.R1O_TDATA(r1r_td),
	.R1O_TLAST(r1r_tl),

	/* Requester port 2 request input */
	.R2I_TVALID(r2_tv),
	.R2I_TREADY(r2_tr),
	.R2I_TDATA(r2_td),
	.R2I_TLAST(r2_tl),
	/* Requester port 2 response output */
	.R2O_TVALID(r2r_tv),
	.R2O_TREADY(r2r_tr),
	.R2O_TDATA(r2r_td),
	.R2O_TLAST(r2r_tl),

	/* Requester port 3 request input */
	.R3I_TVALID(1'b0),
	.R3I_TREADY(),
	.R3I_TDATA(64'h0000000000000000),
	.R3I_TLAST(1'b0),
	/* Requester port 3 response output */
	.R3O_TVALID(),
	.R3O_TREADY(1'b1),
	.R3O_TDATA(),
	.R3O_TLAST(),

	/* Completer port 0 request output */
	.C0O_TVALID(c0_tv),
	.C0O_TREADY(c0_tr),
	.C0O_TDATA(c0_td),
	.C0O_TLAST(c0_tl),
	/* Completer port 0 response input */
	.C0I_TVALID(c0r_tv),
	.C0I_TREADY(c0r_tr),
	.C0I_TDATA(c0r_td),
	.C0I_TLAST(c0r_tl),

	/* Completer port 1 request output */
	.C1O_TVALID(c1_tv),
	.C1O_TREADY(c1_tr),
	.C1O_TDATA(c1_td),
	.C1O_TLAST(c1_tl),
	/* Requester port 1 response input */
	.C1I_TVALID(c1r_tv),
	.C1I_TREADY(c1r_tr),
	.C1I_TDATA(c1r_td),
	.C1I_TLAST(c1r_tl)
	);

   //////////////////////////////////////////////////////////////////////////
   // Showtime
   //////////////////////////////////////////////////////////////////////////

   initial
	begin
	   $dumpfile("tb_top_mic.vcd");
           $dumpvars(0, top);

	   clk <= 0;
	   reset <= 1;
	   glbl.GSR <= 0;

	   #(`CLK_PERIOD*2);
	   reset <= 0;

	   /* The memtest blocks are self-checking; wait for them to perform a
	    * number of transactions, with a timeout:
	    */
	   repeat (100000) begin
	      #`CLK_PERIOD;
	      if (mt1_ntrx == 0) begin
		 $display("Completed %d transactions\n", `NUM_TRANSACTIONS);
		 $finish;
	      end
	   end
	   $display("Timed out waiting for transaction completion...\n");
	   $fatal(1);
	end
endmodule
