/* TB for multiple MIC requesters, steer/merge
 *
 * Copyright 2017, 2022 Matt Evans
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
   // Instances & system wiring:
   parameter PIPELINE_DEPTH = 5;
`define PL_TYPE 	p_dbl

   wire        m1_tv;
   wire        m1_tr;
   wire [63:0] m1_td;
   wire        m1_tl;

   wire        m2_tv;
   wire        m2_tr;
   wire [63:0] m2_td;
   wire        m2_tl;

   wire        m1r_tv;
   wire        m1r_tr;
   wire [63:0] m1r_td;
   wire        m1r_tl;

   wire        m2r_tv;
   wire        m2r_tr;
   wire [63:0] m2r_td;
   wire        m2r_tl;

   wire        m_tv;
   wire        m_tr;
   wire [63:0] m_td;
   wire        m_tl;

   m_pktgen
     #( .THROTTLE(1),
	.RNG_INIT(16'hbeef),
	.NAME("Requester0"),
	.SRC_ID(0)
	)
   MGENA
     (.clk(clk),
      .reset(reset),

      .TDATA(m1_td),
      .TVALID(m1_tv),
      .TREADY(m1_tr),
      .TLAST(m1_tl)
      );


   m_requester
     #( .THROTTLE(1),
	.NAME("Requester1"),
	.SRC_ID(1)
	)
   REQB
     (.clk(clk),
      .reset(reset),

      .O_TDATA(m2_td),
      .O_TVALID(m2_tv),
      .O_TREADY(m2_tr),
      .O_TLAST(m2_tl),

      .I_TDATA(m2r_td),
      .I_TVALID(m2r_tv),
      .I_TREADY(m2r_tr),
      .I_TLAST(m2r_tl)
      );


   i_merge
     MERGE
       (.clk(clk),
	.reset(reset),

	.I0_TVALID(m1_tv),
	.I0_TREADY(m1_tr),
	.I0_TDATA(m1_td),
	.I0_TLAST(m1_tl),

	.I1_TVALID(m2_tv),
	.I1_TREADY(m2_tr),
	.I1_TDATA(m2_td),
	.I1_TLAST(m2_tl),

	.O_TVALID(m_tv),
	.O_TREADY(m_tr),
	.O_TDATA(m_td),
	.O_TLAST(m_tl)
	);

   wire        mr_tv;
   wire        mr_tr;
   wire [63:0] mr_td;
   wire        mr_tl;

   s_responder
     RESPONDER
     (.clk(clk),
      .reset(reset),

      .I_TDATA(m_td),
      .I_TVALID(m_tv),
      .I_TREADY(m_tr),
      .I_TLAST(m_tl),

      .O_TDATA(mr_td),
      .O_TVALID(mr_tv),
      .O_TREADY(mr_tr),
      .O_TLAST(mr_tl)
      );


   i_steer
     #(
       .HDR_BIT(48) // SRC_ID[0]
       )
   STEER
     (.clk(clk),
      .reset(reset),

      .I_TDATA(mr_td),
      .I_TVALID(mr_tv),
      .I_TREADY(mr_tr),
      .I_TLAST(mr_tl),

      .O0_TDATA(m1r_td),
      .O0_TVALID(m1r_tv),
      .O0_TREADY(m1r_tr),
      .O0_TLAST(m1r_tl),

      .O1_TDATA(m2r_td),
      .O1_TVALID(m2r_tv),
      .O1_TREADY(m2r_tr),
      .O1_TLAST(m2r_tl)
      );

   m_pktsink
     #( .THROTTLE(0),
	.NAME("RequesterSink0")
	)
   MSINKA
     (.clk(clk),
      .reset(reset),

      .TDATA(m1r_td),
      .TVALID(m1r_tv),
      .TREADY(m1r_tr),
      .TLAST(m1r_tl)
      );


   //////////////////////////////////////////////////////////////////////////
   // Showtime
   //////////////////////////////////////////////////////////////////////////

   initial
	begin
	   $dumpfile("tb_top_multi.vcd");
           $dumpvars(0, top);

	   clk <= 0;
	   reset <= 1;
	   glbl.GSR <= 0;

	   #(`CLK_PERIOD*2);
	   reset <= 0;

	   #(`CLK_PERIOD * 5000);
	   $finish;
	end

endmodule
