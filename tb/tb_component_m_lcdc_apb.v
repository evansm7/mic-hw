/* TB for m_lcdc_apb
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
`define PCLK_PERIOD 7

`define NUM_TRANSACTIONS 1234

module glbl();
   reg 	GSR = 0;
   reg 	GTS = 0;
endmodule // glbl


module top();
   reg 	reset;
   reg  clk;
   reg  pclk;

   ////////////////////////////////////////////////////////////////////////

`ifndef VERILATOR
   always #(`CLK_PERIOD/2) clk = !clk;
   always #(`PCLK_PERIOD/2) pclk = !pclk;
`endif

   ////////////////////////////////////////////////////////////////////////

   wire        s0_tv;
   wire        s0_tr;
   wire [63:0] s0_td;
   wire	       s0_tl;

   wire        s0r_tv;
   wire        s0r_tr;
   wire [63:0] s0r_td;
   wire        s0r_tl;

   wire [31:0] apb_data_out;
   reg [31:0]  apb_data_in;
   reg [12:0]  apb_addr;
   reg 	       apb_wr;

   wire        hs;
   wire        vs;

   /* Requester 0:  m_lcdc_apb */
   m_lcdc_apb
     REQA
       (.sys_clk(clk),
	.reset(reset),

	.O_TDATA(s0_td),
	.O_TVALID(s0_tv),
	.O_TREADY(s0_tr),
	.O_TLAST(s0_tl),

	.I_TDATA(s0r_td),
	.I_TVALID(s0r_tv),
	.I_TREADY(s0r_tr),
	.I_TLAST(s0r_tl),

	.PCLK(clk),
	.nRESET(~reset),
	.PSEL(1'b1),
	.PENABLE(1'b1),
	.PWRITE(apb_wr),
	.PRDATA(apb_data_out),
	.PWDATA(apb_data_in),
	.PADDR(apb_addr[5:0]),

	.pixel_clk(pclk),
	.rgb(),
	.hs(hs),
	.vs(vs),
	.de(),

	.IRQ_VS(),
	.IRQ_HS()
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


   /* Completer 0 */
   s_bram
     #( .NAME("RAM0"),
	.KB_SIZE(256)
	)
   RAMA
     (.clk(clk),
      .reset(reset),

      .I_TDATA(s0a_td),
      .I_TVALID(s0a_tv),
      .I_TREADY(s0a_tr),
      .I_TLAST(s0a_tl),

      .O_TDATA(s0ar_td),
      .O_TVALID(s0ar_tv),
      .O_TREADY(s0ar_tr),
      .O_TLAST(s0ar_tl)
      );


   //////////////////////////////////////////////////////////////////////////
   // Showtime
   //////////////////////////////////////////////////////////////////////////

   reg [31:0]  i;
   reg [31:0]  d;

   initial
     begin
`ifndef VERILATOR
	   $dumpfile("tb_component_m_lcdc_apb.vcd");
           $dumpvars(0, top);

	   clk = 1;
	   pclk = 1;
	   reset = 1;

	   apb_addr = 0;
	   apb_wr = 0;
	   apb_data_in = 0;

	   #(`CLK_PERIOD*2);
	   reset = 0;

	   #(`CLK_PERIOD*100000);

	   apb_write(13'h0010, 32'h00abcde0);
//	   apb_read(13'h1000 - 32 + i, d);

	   #(`CLK_PERIOD*200000);

	   $display("PASSED");

	   $finish;
`endif
     end


   task apb_write;
      input [12:0] address;
      input [31:0] data;
      begin
	 apb_addr <= address;
	 apb_data_in <= data;

	 #`CLK_PERIOD;
	 apb_wr <= 1;
	 #(`CLK_PERIOD);

	 apb_wr <= 0;
	 #(`CLK_PERIOD);
	 $display("[APB: Wrote %x to %x]", data, address);
      end
   endtask

   task apb_read;
      input [12:0]  address;
      output [31:0] data;
      begin
	 apb_addr <= address;

	 #(`CLK_PERIOD*3/2);
	 data <= apb_data_out;
	 #(`CLK_PERIOD/2);
	 $display("[APB: Read %x from %x]", data, address);
      end
   endtask // apb_read

   task wait_for_completion;
      reg [31:0] dat;
      reg [31:0] loop;
      begin
	 for (loop = 0; loop < 255; loop++) begin
	    #`CLK_PERIOD;
	    apb_read(13'h0000, dat);           // Poll status bit
	    if (dat[0] == 0) begin
	       loop = 1000; // break...
	    end
	 end
	 if (loop == 255) begin
	    $display("Timed out waiting for completion!\n");
	    $fatal();
	 end else begin
	    $display("Got completion, data = %x\n", dat);
	 end
      end
   endtask // wait_for_completion

   task dump_buffer;
      reg [31:0] dat;
      reg [31:0] loop;
      begin
	 for (loop = 0; loop < 64; loop = loop + 4) begin
	    apb_read(13'h1000 + loop, dat);
	    $display("Buffer[%x] = %x", loop, dat);
	 end
      end
   endtask

endmodule
