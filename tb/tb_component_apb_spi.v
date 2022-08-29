/* TB for apb_spi
 *
 * Copyright 2021 Matt Evans
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


module top();
   reg 	reset;
   reg  clk;

   ////////////////////////////////////////////////////////////////////////

   always #(`CLK_PERIOD/2) clk = !clk;

   ////////////////////////////////////////////////////////////////////////

   wire [31:0] apb_data_out;
   reg [31:0]  apb_data_in;
   reg [12:0]  apb_addr;
   reg 	       apb_wr;
   reg 	       apb_enb;

   wire        tdo;
   wire        cs;

   apb_spi #(
	    )
            DUT
              (
	       .clk(clk),
	       .reset(reset),

	       .spi_clk(),
	       .spi_dout(tdo),
	       .spi_din(tdo),  // Loopback
	       .spi_cs(cs),

	       .PSEL(1'b1),
	       .PENABLE(apb_enb),
	       .PWRITE(apb_wr),
	       .PRDATA(apb_data_out),
	       .PWDATA(apb_data_in),
	       .PADDR(apb_addr[4:0])
	       );


   //////////////////////////////////////////////////////////////////////////
   // Showtime
   //////////////////////////////////////////////////////////////////////////

   reg [31:0]  da;
   reg [31:0]  db;
   reg [31:0]  wa;
   reg [31:0]  wb;

   initial
	begin
	   $dumpfile("tb_component_apb_spi.vcd");
           $dumpvars(0, top);

	   clk <= 1;
	   reset <= 1;

	   apb_addr <= 0;
	   apb_wr <= 0;
	   apb_data_in <= 0;

	   #(`CLK_PERIOD*2);
	   reset <= 0;

	   #(`CLK_PERIOD*2);

	   //////////////////////////////////////////////////////////////////////
	   apb_read(13'h00, da);
	   if (da[7] || da[10]) $fatal(1, "Running out of reset??");

	   // Test CS GPIO:
	   apb_write(13'h0c, 32'h0);
	   if (cs) $fatal(1, "CS should be 0");

	   apb_write(13'h0c, 32'h1);
	   if (!cs) $fatal(1, "CS should be 1");


	   // Try an 8b transfer, mode 0:
	   wa = 8'ha5;
	   apb_write(13'h10, 32'h0); // CLK /2
	   apb_write(13'h04, wa);
	   apb_write(13'h00, 32'h00000080); // Len=0 (1), cpol=0, cpha=0, RUN_A
	   wait_done();
	   // Check RX data matches
	   apb_read(13'h08, da);
	   if (da[7:0] !== wa[7:0]) $fatal(1, "Read bad data (%x), should be %x", da, wa[7:0]);

	   // Try an 8b transfer, mode 1 (A buffer):
	   wa = 8'ha5;
	   apb_write(13'h10, 32'h0); // CLK /2
	   apb_write(13'h04, wa);
	   apb_write(13'h00, 32'h00000082); // Len=0 (1), cpol=0, cpha=1, RUN_A
	   wait_done();
	   // Check RX data matches
	   apb_read(13'h08, da);
	   if (da[7:0] !== wa[7:0]) $fatal(1, "Read bad data (%x), should be %x", da, wa[7:0]);

	   // Try an 8b transfer, mode 1 (B buffer):
	   wa = 8'h5a;
	   apb_write(13'h10, 32'h0); // CLK /2
	   apb_write(13'h14, wa);
	   apb_write(13'h00, 32'h00000402); // Len=0 (1), cpol=0, cpha=1, RUN_B
	   wait_done();
	   // Check RX data matches
	   apb_read(13'h18, da);
	   if (da[7:0] !== wa[7:0]) $fatal(1, "Read bad data (%x), should be %x", da, wa[7:0]);

	   // Try a full 32b transfer, mode 0, divided clock:
	   wa = 32'hfeedaca7;
	   apb_write(13'h10, 32'h3); // 0 = /2, 1 = /4, 2 = /6
	   apb_write(13'h04, wa);
	   apb_write(13'h00, 32'h00000380); // Len=3 (4), cpol=0, cpha=0, RUN_A
	   wait_done();
	   // Check RX data matches
	   apb_read(13'h08, da);
	   if (da !== wa) $fatal(1, "Read bad data (%x), should be %x", da, wa);

	   // 32b transfer, mode 3:
	   apb_write(13'h00, 32'h00000003); // cpol=1, cpha=1
	   wa = 32'hca7b17e5;
	   apb_write(13'h10, 32'h2); // CLK /2
	   apb_write(13'h04, wa);
	   apb_write(13'h00, 32'h00000383); // Len=3 (4), cpol=1, cpha=1, RUN_A
	   wait_done();
	   // Check RX data matches
	   apb_read(13'h08, da);
	   if (da !== wa) $fatal(1, "Read bad data (%x), should be %x", da, wa);

	   // Back-to-back 64b transfer, mode 3:
	   apb_write(13'h00, 32'h00000003); // cpol=1, cpha=1
	   wa = 32'hca7b17e5;
	   wb = 32'h0feedca7;
	   apb_write(13'h10, 32'h2); // CLK /6
	   apb_write(13'h04, wa);
	   apb_write(13'h14, wb);
	   apb_write(13'h00, 32'h00001f83); // LenA=3/LenB=3 (4), cpol=1, cpha=1, RUN_A/RUN_B
	   wait_done();
	   // Check RX data matches
	   apb_read(13'h08, da);
	   apb_read(13'h18, db);
	   if (da !== wa) $fatal(1, "Read bad data (%x), should be %x", da, wa);
	   if (db !== wb) $fatal(1, "Read bad data (%x), should be %x", db, wb);
	   // Note: that doesn't test order (i.e. that A was transferred before B)!


	   $display("PASSED");

	   $finish;
	end


   task wait_done;
      reg [31:0] d;
      reg [31:0] i;

      begin
	 d = 32'h80;
	 i = 0;
	 while (d[7] == 1 || d[10] == 1) begin
	    i = i + 1;
	    if (i > 1000) $fatal(1, "Timed out waiting for Tx completion");
	    apb_read(12'h00, d);
	    $display("Poll RUN, read %x", d);
	 end
      end
   endtask

   // Helpers for correct APB transfers:
   // These don't support wait states.
   task apb_write;
      input [12:0] address;
      input [31:0] data;
      begin
	 @(posedge clk);
	 apb_wr = 1;
	 apb_enb = 0;
	 apb_data_in = data;
	 apb_addr = address;

	 @(posedge clk);
	 #1;
	 apb_enb = 1;

	 @(posedge clk);
	 #1;
	 apb_wr = 0;
	 apb_enb = 0;
	 apb_data_in = 32'hx;
	 apb_addr = 13'hx;

	 $display("[APB: Wrote %x to %x]", data, address);
      end
   endtask

   task apb_read;
      input [12:0]  address;
      output [31:0] data;
      begin
	 @(posedge clk);
	 apb_addr = address;
	 apb_wr = 0;
	 apb_enb = 0;

	 @(posedge clk);
	 #1;
	 apb_enb = 1;
	 // DUT now starts generating output, valid at next edge

	 // Sample "just before" next edge:
	 #(`CLK_PERIOD/2);
	 data = apb_data_out;

	 @(posedge clk);
	 #1;
	 apb_enb = 0;
	 apb_addr = 13'hx;

	 $display("[APB: Read %x from %x]", data, address);
      end
   endtask // apb_read

endmodule
