/* TB for apb_uart
 *
 * Copyright 2020 Matt Evans
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

   wire [31:0] apb_data_out;
   reg [31:0]  apb_data_in;
   reg [12:0]  apb_addr;
   reg 	       apb_wr;
   reg 	       apb_enb;

   wire        tdo;

   apb_uart #(.CLK_DIVISOR(3), // Shorter sim...
	      .RX_FIFO_LOG2(3), // 8 entries
	      .TX_FIFO_LOG2(3)
	      )
            DUT
              (
	       .clk(clk),
	       .reset(reset),

	       .txd(tdo), // Loopback
	       .rxd(tdo),

	       .PSEL(1'b1),
	       .PENABLE(apb_enb),
	       .PWRITE(apb_wr),
	       .PRDATA(apb_data_out),
	       .PWDATA(apb_data_in),
	       .PADDR(apb_addr[3:0])
	       );


   //////////////////////////////////////////////////////////////////////////
   // Showtime
   //////////////////////////////////////////////////////////////////////////

   reg [31:0]  i;
   reg [31:0]  d;

   initial
	begin
	   $dumpfile("tb_component_apb_uart.vcd");
           $dumpvars(0, top);

	   clk <= 1;
	   reset <= 1;
	   glbl.GSR <= 0;

	   apb_addr <= 0;
	   apb_wr <= 0;
	   apb_data_in <= 0;

	   #(`CLK_PERIOD*2);
	   reset <= 0;

	   #(`CLK_PERIOD*2);

	   /* Do some APB fun things to get transactions moving: */

	   uart_tx(8'hab);
	   uart_tx(8'hcd);
	   uart_tx(8'hef);

	   uart_rx_check(8'hab);

	   uart_tx(8'h69);
	   uart_tx(8'h68);
	   uart_tx(8'h67);
	   uart_tx(8'h11);
	   uart_tx(8'h12);  // TX full
	   uart_tx(8'h13);  // Waits

	   // Now the race is on, read out before RX overruns :)

	   uart_rx_check(8'hcd);
	   uart_rx_check(8'hef);
	   uart_rx_check(8'h69);
	   uart_rx_check(8'h68);
	   uart_rx_check(8'h67);
	   uart_rx_check(8'h11);
	   uart_rx_check(8'h12);
	   uart_rx_check(8'h13);

	   $display("PASSED");

	   $finish;
	end


   task uart_rx_check;
      input [7:0] value;
      reg [7:0]   d;

      begin
	 uart_rx(d);
	 if (d != value) begin
	    #10;
	    $fatal(1, "Mismatched data %x not %x", d, value);
	 end
      end
   endtask // uart_rx_check

   task uart_tx;
      input [7:0] txd;

      reg [31:0] d;
      reg [31:0] loop;

      begin
	 loop = 0;

	 d = 0;

	 while (d[1] == 0) begin
	    apb_read(12'h4, d);
	    loop += 1;
	    if (loop > 1000) begin
	       $fatal(1, "Timed out waiting for TXnF");
	    end
	 end

	 apb_write(12'h0, txd);
      end
   endtask

   task uart_rx;
      output [7:0] rxd;

      reg [31:0] d;
      reg [31:0] loop;

      begin
	 loop = 0;

	 d = 0;

	 while (d[0] == 0) begin
	    apb_read(12'h4, d);
	    loop += 1;
	    if (loop > 1000) begin
	       $fatal(1, "Timed out waiting for RXnE");
	    end
	 end

	 apb_read(12'h0, rxd);
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


/* -----\/----- EXCLUDED -----\/-----
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
 -----/\----- EXCLUDED -----/\----- */

endmodule
