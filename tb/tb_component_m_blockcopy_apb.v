/* TB for m_blockcopy_apb
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


   /* Requester 0:  m_blockcopy_apb */
   m_blockcopy_apb
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

	.PCLK(clk),
	.PSEL(1),
	.PENABLE(1),
	.PWRITE(apb_wr),
	.PRDATA(apb_data_out),
	.PWDATA(apb_data_in),
	.PADDR(apb_addr)
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
	   $dumpfile("tb_component_m_blockcopy_apb.vcd");
           $dumpvars(0, top);

	   clk <= 1;
	   reset <= 1;
	   glbl.GSR <= 0;

	   apb_addr <= 0;
	   apb_wr <= 0;
	   apb_data_in <= 0;

	   #(`CLK_PERIOD*2);
	   reset <= 0;


	   /* Do some APB fun things to get transactions moving: */

	   /* Write RAM */
	   for (i = 0; i < 64; i = i + 4) begin
	      apb_write(13'h1000 + i, 32'hbeefcafe ^ i ^ (i*256));
	   end

	   dump_buffer();

	   /* Setup MIC write */
	   apb_write(13'h0004, 32'h00040007);  // 8 beats from offset 4 (32) in RAM
	   apb_write(13'h0008, 32'h00001000);  // addr 0x1000 in BRAM
	   apb_write(13'h0000, 32'h00000000);  // WR
	   apb_write(13'h0000, 32'h00000001);  // WR, go
	   #`CLK_PERIOD;
	   wait_for_completion();

	   /* Set up MIC read */
	   apb_write(13'h0004, 32'h00000007);  // 8 beats to offset 0 in RAM
	   apb_write(13'h0008, 32'h00001000);  // addr 0x1000 in BRAM
	   apb_write(13'h0000, 32'h00000002);  // RD
	   apb_write(13'h0000, 32'h00000003);  // RD, go
	   #`CLK_PERIOD;
	   wait_for_completion();

	   /* Now RAM should be full of data that was generated, eritten out,
	    * and read back to different addresses.  Read it back and verify:
	    */

	   /* Check RAM:  the data from bytes 0-31 was originally at 32-63;
	    * that at 32-63 was originally at 0-31.
	    */
	   for (i = 32; i < 64; i = i + 4) begin
	      apb_read(13'h1000 - 32 + i, d);
	      if (d != (32'hbeefcafe ^ i ^ (i*256))) begin
		 $display("Read data at APB address %x was %x, should be %x",
			  13'h1000 - 32 + i, d, (32'hbeefcafe ^ i ^ (i*256)));
		 $fatal(1);
	      end
	   end
	   for (i = 0; i < 32; i = i + 4) begin
	      apb_read(13'h1000 + 32 + i, d);
	      if (d != (32'hbeefcafe ^ i ^ (i*256))) begin
		 $display("Read data at APB address %x was %x, should be %x",
			  13'h1000 + 32 + i, d, (32'hbeefcafe ^ i ^ (i*256)));
		 $fatal(1);
	      end
	   end

	   $display("PASSED");

	   $finish;
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
