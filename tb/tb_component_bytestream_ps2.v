/* TB for bytestream_ps2
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

//`define VERBOSE

`timescale 1ns/1ns

`define CLK_PERIOD 10


module top();
   reg 	reset;
   reg  clk;

   ////////////////////////////////////////////////////////////////////////

`ifndef VERILATOR
   always #(`CLK_PERIOD/2) clk = !clk;
`endif

   ////////////////////////////////////////////////////////////////////////

   // PS2:
   wire ps2_clk_val;
   wire ps2_clk_pd_a;
   wire ps2_clk_pd_b;
   wire ps2_dat_val;
   wire ps2_dat_pd_a;
   wire ps2_dat_pd_b;

   assign ps2_clk_val = !(ps2_clk_pd_a || ps2_clk_pd_b);
   assign ps2_dat_val = !(ps2_dat_pd_a || ps2_dat_pd_b);

   reg [7:0] tx_data;
   reg       tx_has_data;
   wire      tx_data_consume;

   wire [7:0] rx_data;
   wire       rx_data_ready;

   bytestream_ps2 #(.CLK_RATE(1000000))
                  DUT(.clk(clk),
                      .reset(reset),

                      .ps2_clk_in(ps2_clk_val),
		      .ps2_clk_pd(ps2_clk_pd_a), // 1=Pull-down
                      .ps2_dat_in(ps2_dat_val),
		      .ps2_dat_pd(ps2_dat_pd_a), // 1=Pull-down

		      /* Bytestream interface: */
		      .bs_data_in(tx_data),
		      .bs_data_in_valid(tx_has_data),
		      .bs_data_in_consume(tx_data_consume),

		      .bs_data_out(rx_data),
		      .bs_data_out_produce(rx_data_ready)
		      );

   // Shitty PS2 device emulator:

   ps2dev DE(.clk(clk),
             .reset(reset),

             .ps2_clk_in(ps2_clk_val),
	     .ps2_clk_pd(ps2_clk_pd_b), // 1=Pull-down
             .ps2_dat_in(ps2_dat_val),
	     .ps2_dat_pd(ps2_dat_pd_b)
             );


   //////////////////////////////////////////////////////////////////////////
   // Showtime
   //////////////////////////////////////////////////////////////////////////

   reg [31:0]  i;
   reg [7:0]  wd;
   reg [7:0]  rd;

   always @(posedge clk) begin
      if (rx_data_ready) begin
         $display("RX data: %x", rx_data);
      end
   end

   initial
     begin
`ifndef VERILATOR
	$dumpfile("tb_component_bytestream_ps2.vcd");
        $dumpvars(0, top);

	clk         = 1;
	reset       = 1;

	tx_data     = 0;
        tx_has_data = 0;


	#(`CLK_PERIOD*2);
	reset = 0;

	#(`CLK_PERIOD*10);

        // Write a byte?  See it echoed?

        wd = 8'h69;

        bs_send(wd);
        bs_receive(rd);

        if (rd != wd) begin $fatal(1, "Mismatch %x not %x", rd, wd); end

        #(`CLK_PERIOD*10);

	$display("PASSED");

	$finish;
`endif
     end


   task bs_send;
      input [7:0] d;
      reg [31:0] loop;
      begin
	 loop = 0;
	 tx_data = d;
	 @(negedge clk);
         tx_has_data = 1;
         @(posedge clk);
	 while (tx_data_consume != 1) begin
	    @(negedge clk);
	    loop++;
	    if (loop > 25500)
	      $fatal(1, "Timeout waiting for BS TX");
	 end
         tx_has_data = 0;
	 @(posedge clk);
`ifdef VERBOSE
	 $display("[BS send %x]", d);
`endif

      end
   endtask

   task bs_receive;
      output [7:0] d;
      reg [31:0] loop;
      begin
	 loop = 0;
	 @(negedge clk);
	 while (rx_data_ready != 1) begin
	    @(negedge clk);
	    loop++;
	    if (loop > 25500)
	      $fatal(1, "Timeout waiting for BS RX data");
	 end
	 d = rx_data;
	 @(posedge clk);
`ifdef VERBOSE
	 $display("[BS receive %x]", d);
`endif

      end
   endtask

endmodule

////////////////////////////////////////////////////////////////////////////////

// Fake PS2 device:

`define BITLEN (`CLK_PERIOD*50)

module ps2dev(input wire clk,
	      input wire reset,
	      /* PS2 interface: */
              input wire ps2_clk_in,
	      output reg ps2_clk_pd, // 1=Pull-down
              input wire ps2_dat_in,
	      output reg ps2_dat_pd  // 1=Pull-down
              );

   reg [31:0]             i;
   reg [15:0]             d;

   reg [127:0]            where;

   initial begin
      while (1) begin

         ps2_clk_pd = 0;
         ps2_dat_pd = 0;

         where = "WAIT_RL";
         // wait for a RX.
         @(negedge ps2_clk_in);

         where = "WAIT_RH";
         // Host as pulled clock low
         @(posedge ps2_clk_in);
         // Host has released CLK.  Now it's my turn.

         where = "BITS";
         for (i = 0; i < 10; i = i + 1) begin
            #`BITLEN;
            ps2_clk_pd = 1; // CLK=0

            #`BITLEN;
            ps2_clk_pd = 0; // CLK=1

            #1;
            d = {ps2_dat_in, d[9:1]};
         end

         where = "ACK";
         // Send ACK
         #`BITLEN;
         ps2_dat_pd = 1; // DAT=0

         #`BITLEN;
         ps2_clk_pd = 1; // CLK=0
         #`BITLEN;
         ps2_clk_pd = 0; // CLK=1
         ps2_dat_pd = 0; // DAT=1

         // Delay a bit.

         #(`BITLEN * 123);

         // Send that byte back.

         if (ps2_clk_in) begin // host isn't trying to send!
            ps2_dat_pd = 1; // DAT=0
            #15;
            for (i = 0; i < 11; i = i + 1) begin
               ps2_clk_pd = 1; // CLK=0
               #`BITLEN;
               ps2_clk_pd = 0; // CLK=1
               #16;

               // Set data bit:
               ps2_dat_pd = ~d[0];
               d = {1'b1, d[9:1]};
               #`BITLEN;
               #15;
            end
         end // if (ps2_clk_in)
      end
   end
endmodule // ps2dev
