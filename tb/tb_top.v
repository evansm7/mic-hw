/* TB for MIC source/sink components
 *
 * Copyright 2017 Matt Evans
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

   m_pktgen
     #( .THROTTLE(1)
	)
   MGEN
     (.clk(clk),
      .reset(reset),

      .TDATA(m1_td),
      .TVALID(m1_tv),
      .TREADY(m1_tr),
      .TLAST(m1_tl)
      );

   wire        m1r_tv;
   wire        m1r_tr;
   wire [63:0] m1r_td;
   wire        m1r_tl;

   s_responder
     RESPONDER
     (.clk(clk),
      .reset(reset),

      .I_TDATA(m1_td),
      .I_TVALID(m1_tv),
      .I_TREADY(m1_tr),
      .I_TLAST(m1_tl),

      .O_TDATA(m1r_td),
      .O_TVALID(m1r_tv),
      .O_TREADY(m1r_tr),
      .O_TLAST(m1r_tl)
      );

   m_pktsink
     #( .THROTTLE(1)
	)
   MSINK
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
	   $dumpfile("tb_top.vcd");
           $dumpvars(0, top);

	   clk <= 0;
	   reset <= 1;
	   glbl.GSR <= 0;

	   #(`CLK_PERIOD*2);
	   reset <= 0;

	   #(`CLK_PERIOD * 500);
	   $finish;
	end

endmodule
