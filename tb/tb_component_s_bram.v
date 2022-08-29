/* TB for s_bram
 *
 * Copyright 2019-2020, 2022 Matt Evans
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

   reg 	       s0_tv;
   wire        s0_tr;
   reg [63:0]  s0_td;
   reg 	       s0_tl;

   wire        s0r_tv;
   reg         s0r_tr;
   wire [63:0] s0r_td;
   wire        s0r_tl;


   /* Completer 0 */
   s_bram
     #( .NAME("RAM0"),
	.KB_SIZE(256)
	)
     RAMA
     (.clk(clk),
      .reset(reset),

      .I_TDATA(s0_td),
      .I_TVALID(s0_tv),
      .I_TREADY(s0_tr),
      .I_TLAST(s0_tl),

      .O_TDATA(s0r_td),
      .O_TVALID(s0r_tv),
      .O_TREADY(s0r_tr),
      .O_TLAST(s0r_tl)
      );

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
	   $dumpfile("tb_component_s_bram.vcd");
           $dumpvars(0, top);

	   clk <= 1;
	   reset <= 1;
	   glbl.GSR <= 0;

	   s0_tv <= 0;
	   s0_td <= 0;
	   s0_tl <= 0;
	   s0r_tr <= 0;

	   #(`CLK_PERIOD*2);
	   reset <= 0;

	   addr = 1234;
	   id = 8'hab;
	   create_write_header(5'h1f, addr, id, hdr);

	   s0r_tr <= 0;
	   submit_req_2beats(hdr, 64'hdeadbeefcafebabe);

	   // Now make responses ready and wait for one...
	   s0r_tr <= 1;
	   wait_response_one(hdr, last);

	   #`CLK_PERIOD;

	   // check header
	   $display("-- WR response %x last %d\n", hdr, last);

	   get_hdr_id_addr(hdr, id, pkt_type, addr);
	   #1;
	   `assert(id, 8'hab);
	   `assert(addr, 1234);
	   `assert(pkt_type, 3);

	   $display("Done\n");
	   $finish;
	end

   task get_hdr_id_addr;
      input [63:0] hdr;
      output [7:0] id;
      output [1:0] pt;
      output [31:3] addr;
      begin
	 id = hdr[55:48];
	 pt = hdr[33:32];
	 addr = hdr[31:3];
      end
   endtask // get_hdr_id_addr

   task submit_req_2beats;
      input [63:0] header;
      input [63:0] b0_data;
      begin
	 s0_td <= header;
	 s0_tv <= 1;
	 s0_tl <= 0;

	 #`CLK_PERIOD;
	 while (!s0_tr) begin
	    #`CLK_PERIOD;
	 end

	 s0_td <= b0_data;
	 s0_tv <= 1;
	 s0_tl <= 1;
	 #`CLK_PERIOD;
	 while (!s0_tr) begin
	    #`CLK_PERIOD;
	 end
	 s0_tv <= 0;
      end
   endtask

   task wait_response_one;
      output [63:0] header;
      output 	    last;
      begin
	 s0r_tr <= 1;

	 while (!s0r_tv) begin
	    #`CLK_PERIOD;
	 end
	 header = s0r_td;
	 last = s0r_tl;
      end
   endtask

   task create_read_header;
      input [7:0]  beats;
      input [31:3] address;
      input [7:0]  src_id;
      output [63:0] header;
      begin
	 header[63:0] = { 5'h1f, 3'h0, src_id[7:0], beats[7:0], 6'h00, 2'b00 /* Read */,
			  address[31:3], 3'h0};
      end
   endtask // create_read_header

   task create_write_header;
      input [4:0]  strobes;
      input [31:3] address;
      input [7:0]  src_id;
      output [63:0] header;
      begin
	 header[63:0] = { strobes, 3'h0, src_id[7:0], 8'h00, 6'h00, 2'b01 /* Write */, address[31:3], 3'h0};
      end
   endtask // create_write_header

endmodule
