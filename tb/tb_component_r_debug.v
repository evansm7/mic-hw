/* TB for r_debug
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

   wire        s0_tv;
   wire        s0_tr;
   wire [63:0] s0_td;
   wire	       s0_tl;

   wire        s0r_tv;
   wire        s0r_tr;
   wire [63:0] s0r_td;
   wire        s0r_tl;

   wire [7:0]  tx_data;
   wire        tx_has_data;
   wire        tx_data_consume;

   reg [7:0]   rx_data;
   wire        rx_has_space;
   wire        rx_data_produce;

   /* Requester 0:  r_debug */
   r_debug
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

	/* Byte stream interface, TX (output) */
	.tx_data(tx_data),
	.tx_has_data(tx_has_data),
	.tx_data_consume(tx_data_consume),

	/* RX (input) */
	.rx_data(rx_data),
	.rx_has_space(rx_has_space),
	.rx_data_produce(rx_data_produce)
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
   reg [127:0]  wd;
   reg [127:0]  rd;

   reg rx_data_ready;
   reg tx_data_ready;
   assign rx_data_produce = rx_has_space && rx_data_ready;
   assign tx_data_consume = tx_has_data && tx_data_ready;

   initial
     begin
`ifndef VERILATOR
	$dumpfile("tb_component_r_debug.vcd");
        $dumpvars(0, top);

	clk = 1;
	reset = 1;

	rx_data = 0;
	rx_data_ready = 0;
	tx_data_ready = 0;

	#(`CLK_PERIOD*2);
	reset = 0;

	#(`CLK_PERIOD*10);

	// Simple aligned big block writes:
	$display("Writing x 128");
	wd = 128'hdeadbeeffeedface12345678cafecace;
	req_write128(32'h12340, wd);
	$display("Writing y 128");
	wd = 128'h00112233445566778899aabbccddeeff;
	req_write128(32'h12350, wd);

	$display("Reading x");
	req_read128(32'h12340, rd);
	if (rd != 128'hdeadbeeffeedface12345678cafecace) begin $fatal(1, "Mismatch %x", rd); end

	$display("Reading y");
	#(`CLK_PERIOD*10);
	req_read128(32'h12350, rd);
	if (rd != 128'h00112233445566778899aabbccddeeff) begin $fatal(1, "Mismatch %x", rd); end

	// Next, unaligned blocks
	$display("Writing z 128, unaligned start/end");
	wd = 128'h000102030405060708090a0b0c0d0e0f;
	req_write128(32'h12344, wd);

	$display("Reading z");
	#(`CLK_PERIOD*16);
	req_read128(32'h12344, rd);
	if (rd != wd) begin $fatal(1, "Mismatch %x", rd); end

	// Finally, some single words, unaligned and aligned
	$display("Three word writes");
	req_write32(32'h12340, 32'hfeedface);
	req_write32(32'h12344, 32'h0);
	req_write32(32'h12348, 32'ha5a5a5a5);

	$display("Three reads/checks");
	req_read32(32'h12344, rd[31:0]);
	if (rd[31:0] != 0) begin $fatal(1, "Mismatch %x", rd[31:0]); end
	req_read32(32'h12340, rd[31:0]);
	if (rd[31:0] != 32'hfeedface) begin $fatal(1, "Mismatch %x", rd[31:0]); end
	req_read32(32'h12348, rd[31:0]);
	if (rd[31:0] != 32'ha5a5a5a5) begin $fatal(1, "Mismatch %x", rd[31:0]); end

	$display("Writing w 128 sync");
	wd = 128'haabbccddeeffabcd9192939495969798;
	req_write128_sync(32'h12360, wd);

	$display("Reading w");
	#(`CLK_PERIOD*10);
	req_read128(32'h12360, rd);
	if (rd != 128'haabbccddeeffabcd9192939495969798) begin $fatal(1, "Mismatch %x", rd); end

	$display("PASSED");

	$finish;
`endif
     end


   task bs_send;
      input [7:0] d;
      reg [31:0] loop;
      begin
	 loop = 0;
	 rx_data = d;

	 @(negedge clk);
	 while (!rx_has_space) begin
	    @(negedge clk);
	    loop++;
	    if (loop > 255)
	      $fatal(1, "Timeout waiting for BS RX space");
	 end
	 rx_data_ready = 1;
	 @(posedge clk);
	 rx_data_ready = 0;
`ifdef VERBOSE
	 $display("[BS send %x]", d);
`endif

      end
   endtask // bs_send

   task bs_receive;
      output [7:0] d;
      reg [31:0] loop;
      begin
	 loop = 0;
	 @(negedge clk);
	 while (!tx_has_data) begin
	    @(negedge clk);
	    loop++;
	    if (loop > 255)
	      $fatal(1, "Timeout waiting for BS TX data");
	 end
	 tx_data_ready = 1;
	 d = tx_data;
	 @(posedge clk);
	 tx_data_ready = 0;
`ifdef VERBOSE
	 $display("[BS receive %x]", d);
`endif

      end
   endtask // bs_send

   task req_write128;
      input [31:0]  addr;
      input [127:0] data;
      reg [7:0]     l;
      begin
	 bs_send(8'h01); // WR
	 bs_send(8'h04); // 128 bits, 4 words
	 bs_send(addr[7:0]); // Address
	 bs_send(addr[15:8]);
	 bs_send(addr[23:16]);
	 bs_send(addr[31:24]);
	 //
	 for (l = 0; l < 16; l++) begin
	    bs_send(data[7:0]);
	    data = {8'h0, data[127:8]};
	 end
      end
   endtask

   task req_write128_sync;
      input [31:0]  addr;
      input [127:0] data;
      reg [7:0]     l;
      reg [7:0]     d;
      begin
	 bs_send(8'h03); // WR_SYNC
	 bs_send(8'h04); // 128 bits, 4 words
	 bs_send(addr[7:0]); // Address
	 bs_send(addr[15:8]);
	 bs_send(addr[23:16]);
	 bs_send(addr[31:24]);
	 //
	 for (l = 0; l < 16; l++) begin
	    bs_send(data[7:0]);
	    data = {8'h0, data[127:8]};
	 end
	 bs_receive(d);
	 if (d != 8'haa) begin
	      $fatal(1, "Weird ack byte received, %x", d);
	 end
      end
   endtask

   task req_write32;
      input [31:0]  addr;
      input [31:0]  data;
      begin
	 bs_send(8'h01); // WR
	 bs_send(8'h01); // 1 word
	 bs_send(addr[7:0]); // Address
	 bs_send(addr[15:8]);
	 bs_send(addr[23:16]);
	 bs_send(addr[31:24]);
	 //
	 bs_send(data[7:0]);
	 bs_send(data[15:8]);
	 bs_send(data[23:16]);
	 bs_send(data[31:24]);
      end
   endtask

   task req_read128;
      input [31:0]   addr;
      output [127:0] data;
      reg [7:0]      l;
      reg [127:0]    d;
      begin
	 bs_send(8'h02); // RD
	 bs_send(8'h04); // 128 bits, 4 words
	 bs_send(addr[7:0]); // Address
	 bs_send(addr[15:8]);
	 bs_send(addr[23:16]);
	 bs_send(addr[31:24]);
	 //
	 for (l = 0; l < 16; l++) begin
	    d = {8'h0, d[127:8]};
	    bs_receive(d[127:120]);
	 end
	 data = d;
      end
   endtask

   task req_read32;
      input [31:0]   addr;
      output [31:0]  data;
      begin
	 bs_send(8'h02); // RD
	 bs_send(8'h01); // 1 word
	 bs_send(addr[7:0]); // Address
	 bs_send(addr[15:8]);
	 bs_send(addr[23:16]);
	 bs_send(addr[31:24]);

	 bs_receive(data[7:0]);
	 bs_receive(data[15:8]);
	 bs_receive(data[23:16]);
	 bs_receive(data[31:24]);
      end
   endtask

endmodule
