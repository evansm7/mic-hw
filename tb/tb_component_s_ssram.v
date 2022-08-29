/* TB for s_ssram
 *
 * Depends on external cy1471 model!
 *
 * Copyright 2019, 2022 Matt Evans
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

`include "tb_includes.vh"

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

   wire        s0_tv;
   wire        s0_tr;
   wire [63:0] s0_td;
   wire	       s0_tl;

   wire        s0r_tv;
   wire        s0r_tr;
   wire [63:0] s0r_td;
   wire        s0r_tl;

   /* Requester 0:  Memtest requester */
   m_memtest
     #( .THROTTLE(1),
	.THROTTLE_RESPONSES(1),
	.RNG_INIT(16'h1234),
	.ADDR_MASK(29'h00003fff), /* 128K in bottom 2G (to RAM only) */
	.NAME("Memtest0"),
	.NUM_TRANSACTIONS(`NUM_TRANSACTIONS)
	)
   REQA
     (.clk(clk),
      .reset(reset),

      .O_TDATA(s0_td),
      .O_TVALID(s0_tv),
      .O_TREADY(s0_tr),
      .O_TLAST(s0_tl),

      .I_TDATA(s0r_td),
      .I_TVALID(s0r_tv),
      .I_TREADY(s0r_tr),
      .I_TLAST(s0r_tl),

      .trx_count(mt1_ntrx)
      );


   wire        s0a_tv;
   wire        s0a_tr;
   wire [63:0] s0a_td;
   wire	       s0a_tl;

   wire        s0ar_tv;
   wire        s0ar_tr;
   wire [63:0] s0ar_td;
   wire        s0ar_tl;

   mic_sim MICSIM(.clk(clk),
		  .reset(reset),

		  .M0I_TDATA(s0_td),
		  .M0I_TVALID(s0_tv),
		  .M0I_TREADY(s0_tr),
		  .M0I_TLAST(s0_tl),

		  .M0O_TDATA(s0r_td),
		  .M0O_TVALID(s0r_tv),
		  .M0O_TREADY(s0r_tr),
		  .M0O_TLAST(s0r_tl),

		  .S0O_TDATA(s0a_td),
		  .S0O_TVALID(s0a_tv),
		  .S0O_TREADY(s0a_tr),
		  .S0O_TLAST(s0a_tl),

		  .S0I_TDATA(s0ar_td),
		  .S0I_TVALID(s0ar_tv),
		  .S0I_TREADY(s0ar_tr),
		  .S0I_TLAST(s0ar_tl)
		  );

   wire [28:0] r_addr;
   wire        r_ncen;
   wire        r_nce;
   wire        r_advld;
   wire        r_nwe;
   wire [7:0]  r_nbw;
   wire [63:0] r_dq;
   wire        r_clk;

   /* Completer 0 */
   s_ssram
     #( .NAME("SSRAM0"), .ADDR_WIDTH(29)
	)
     SSRAMCTRL
     (.clk(clk),
      .reset(reset),

      .I_TDATA(s0a_td),
      .I_TVALID(s0a_tv),
      .I_TREADY(s0a_tr),
      .I_TLAST(s0a_tl),

      .O_TDATA(s0ar_td),
      .O_TVALID(s0ar_tv),
      .O_TREADY(s0ar_tr),
      .O_TLAST(s0ar_tl),

      .sram_clk(r_clk),
      .sram_ncen(r_ncen),
      .sram_nce0(r_nce),
      .sram_nce1(),
      .sram_advld(r_advld),
      .sram_nwe(r_nwe),
      .sram_nbw(r_nbw),
      .sram_addr(r_addr),
      .sram_dq(r_dq)
      );

   /* RAM models: */
   cy1471 SSRAMA (.d(r_dq[31:0]), .clk(r_clk), .a(r_addr[20:0]), .bws(r_nbw[3:0]), .we_b(r_nwe),
		  .adv_lb(1'b0), .ce1b(r_nce), .ce2(1'b1), .ce3b(1'b0),
		  .oeb(1'b0), .cenb(1'b0), .mode(1'b0));
   cy1471 SSRAMB (.d(r_dq[63:32]), .clk(r_clk), .a(r_addr[20:0]), .bws(r_nbw[7:4]), .we_b(r_nwe),
		  .adv_lb(1'b0), .ce1b(r_nce), .ce2(1'b1), .ce3b(1'b0),
		  .oeb(1'b0), .cenb(1'b0), .mode(1'b0));

   reg [63:0]  hdr;
   reg 	       last;
   reg [7:0]   id;
   reg [31:3]  addr;
   reg [1:0]   pkt_type;

   //////////////////////////////////////////////////////////////////////////
   // Showtime
   //////////////////////////////////////////////////////////////////////////

   initial
	begin
	   $dumpfile("tb_component_s_ssram.vcd");
           $dumpvars(0, top);

	   clk <= 1;
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
