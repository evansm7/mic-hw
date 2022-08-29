/* Super-hacky TB for s_mic_apb
 * ME 28/5/20
 *
 * Copyright 2020, 2022 Matt Evans
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


   reg 	       pready;
   wire [15:0] paddr;
   wire        pwrite;
   wire        psel;
   wire [2:0]  psel_bank;
   wire        penable;
   reg [31:0]  prdata; // Wire
   wire [31:0] pwdata;


   reg [31:0]  A_rdata; // Wire
   reg [31:0]  B_rdata; // Wire

   /* Fake APB thingy */
   reg [31:0]  reg_A;
   reg [31:0]  reg_B;
   reg [31:0]  reg_C;
   reg [31:0]  reg_D;

   /* Peripheral 1 + 2 reads*/
   always @(*) begin
      case (paddr)
	16'h0000:
	   A_rdata = reg_A;

	16'h0004:
	   A_rdata = reg_B;

	default:
	  A_rdata = 32'h0;
      endcase

      case (paddr)
	16'h0000:
	   B_rdata = reg_C;

	16'h0004:
	   B_rdata = reg_D;

	default:
	  B_rdata = 32'h0;
      endcase // case (paddr)

      // Addr mux
      case (psel_bank)
	3'h0:
	  prdata = A_rdata;

	3'h1:
	  prdata = B_rdata;

	default:
	  prdata = 32'hx;
      endcase // case (psel_bank)
   end // always @ (*)

   always @(posedge clk) begin
      if (psel && psel_bank == 0 && pwrite) begin
	 case (paddr)
	   16'h0000:
	     reg_A <= pwdata;
	   16'h0004:
	     reg_B <= pwdata;
	 endcase
      end

      if (psel && psel_bank == 1 && pwrite) begin
	 case (paddr)
	   16'h0000:
	     reg_C <= pwdata;
	   16'h0004:
	     reg_D <= pwdata;
	 endcase
      end
   end


   /* DUT */
   s_mic_apb MAB(.clk(clk),
		 .reset(reset),

		 .I_TDATA(s0_td),
		 .I_TVALID(s0_tv),
		 .I_TREADY(s0_tr),
		 .I_TLAST(s0_tl),

		 .O_TDATA(s0r_td),
		 .O_TVALID(s0r_tv),
		 .O_TREADY(s0r_tr),
		 .O_TLAST(s0r_tl),

		 .PADDR(paddr),
		 .PWRITE(pwrite),
		 .PSEL(psel),
		 .PSEL_BANK(psel_bank),
		 .PENABLE(penable),
		 .PWDATA(pwdata),
		 .PRDATA(prdata),
		 .PREADY(pready)
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
	   $dumpfile("tb_component_mic_apb.vcd");
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

	   pready <= 1; // Components ready so far

	   //////////////////////////////////////////////////////////////////////
	   // Write s0 reg 4
	   @(posedge clk);

	   addr = 32'h00000;
	   id = 8'hab;
	   create_write_header(5'b10100 /* Top word, +4 */, addr, id, hdr);

	   s0r_tr <= 0;
	   submit_req_2beats(hdr, 64'hdeadbeefcafebabe); // deadbeef

	   // Now make responses ready and wait for one...
	   s0r_tr <= 1;
	   wait_response_one(hdr, last);

	   #`CLK_PERIOD;

	   // check header
	   $display("-- WR response %x last %d\n", hdr, last);
	   get_hdr_id_addr(hdr, id, pkt_type, addr);
	   #1;
	   `assert(id, 8'hab);
	   `assert(addr, 32'h0);
	   `assert(pkt_type, 3);


	   //////////////////////////////////////////////////////////////////////
	   // Write s1 reg 0
	   @(posedge clk);

	   addr = 32'h10000;
	   id = 8'h69;
	   create_write_header(5'b10000 /* Bottom word, +0 */, addr, id, hdr);

	   s0r_tr <= 0;
	   submit_req_2beats(hdr, 64'hfeedfacefee7f00d); // fee7f00d

	   // Now make responses ready and wait for one...
	   s0r_tr <= 1;
	   wait_response_one(hdr, last);

	   #`CLK_PERIOD;
	   // check header
	   $display("-- WR response %x last %d\n", hdr, last);
	   get_hdr_id_addr(hdr, id, pkt_type, addr);
	   #1;
	   `assert(id, 8'h69);
	   `assert(addr, 32'h10000);
	   `assert(pkt_type, 3);


	   //////////////////////////////////////////////////////////////////////
	   // Write s1 reg 4
	   @(posedge clk);

	   addr = 32'h10000;
	   id = 8'h55;
	   create_write_header(5'b10100 /* Top word, +4 */, addr, id, hdr);

	   s0r_tr <= 0;
	   submit_req_2beats(hdr, 64'hfeedfacefee7f00d); // feedface

	   // Now make responses ready and wait for one...
	   s0r_tr <= 1;
	   wait_response_one(hdr, last);

	   #`CLK_PERIOD;
	   // check header
	   $display("-- WR response %x last %d\n", hdr, last);
	   get_hdr_id_addr(hdr, id, pkt_type, addr);
	   #1;
	   `assert(id, 8'h55);
	   `assert(addr, 32'h10000);
	   `assert(pkt_type, 3);


	   //////////////////////////////////////////////////////////////////////
	   // Write s0 reg 0
	   @(posedge clk);

	   addr = 32'h00000;
	   id = 8'h12;
	   create_write_header(5'b10000 /* Bottom word, +0 */, addr, id, hdr);

	   s0r_tr <= 0;
	   submit_req_2beats(hdr, 64'hfeedfacecafebabe); // cafebabe

	   // Now make responses ready and wait for one...
	   s0r_tr <= 1;
	   wait_response_one(hdr, last);

	   #`CLK_PERIOD;
	   // check header
	   $display("-- WR response %x last %d\n", hdr, last);
	   get_hdr_id_addr(hdr, id, pkt_type, addr);
	   #1;
	   `assert(id, 8'h12);
	   `assert(addr, 32'h00000);
	   `assert(pkt_type, 3);



	   //////////////////////////////////////////////////////////////////////
	   // Read s1 reg 0
	   @(posedge clk);

	   addr = 32'h10000;
	   id = 8'hcd;
	   create_read_header(5'b10000 /* Bottom word, +0 */, addr, id, hdr);

	   s0r_tr <= 0;
	   submit_req_1beat(hdr);

	   s0r_tr <= 1;
	   wait_response_one(hdr, last);

	   #1;
	   `assert(last, 0);
	   // check header
	   $display("-- RD response 0: %x last %d\n", hdr, last);
	   get_hdr_id_addr(hdr, id, pkt_type, addr);
	   #1;
	   `assert(id, 8'hcd);
	   `assert(addr, 32'h10000);
	   `assert(pkt_type, 2);

	   // Wait for data beat:
	   wait_response_one(hdr, last);
	   $display("-- RD response 1: %x last %d\n", hdr, last);

	   if (hdr[31:0] != 32'hfee7f00d)
	     $fatal(1, "Mismatched read data %x", hdr[31:0]);


	   //////////////////////////////////////////////////////////////////////
	   // Read s1 reg 4
	   @(posedge clk);

	   addr = 32'h10000;
	   id = 8'hef;
	   create_read_header(5'b10100 /* Top word, +4 */, addr, id, hdr);

	   s0r_tr <= 0;
	   submit_req_1beat(hdr);

	   s0r_tr <= 1;
	   wait_response_one(hdr, last);

	   #1;
	   `assert(last, 0);
	   // check header
	   $display("-- RD response 0: %x last %d\n", hdr, last);
	   get_hdr_id_addr(hdr, id, pkt_type, addr);
	   #1;
	   `assert(id, 8'hef);
	   `assert(addr, 32'h10000);
	   `assert(pkt_type, 2);

	   // Wait for data beat:
	   wait_response_one(hdr, last);
	   $display("-- RD response 1: %x last %d\n", hdr, last);

	   if (hdr[63:32] != 32'hfeedface)
	     $fatal(1, "Mismatched read data %x", hdr[31:0]);


	   //////////////////////////////////////////////////////////////////////
	   // Read s0 reg 4
	   @(posedge clk);

	   addr = 32'h00000;
	   id = 8'h98;
	   create_read_header(5'b10100 /* Top word, +4 */, addr, id, hdr);

	   s0r_tr <= 0;
	   submit_req_1beat(hdr);

	   s0r_tr <= 1;
	   wait_response_one(hdr, last);

	   #1;
	   `assert(last, 0);
	   // check header
	   $display("-- RD response 0: %x last %d\n", hdr, last);
	   get_hdr_id_addr(hdr, id, pkt_type, addr);
	   #1;
	   `assert(id, 8'h98);
	   `assert(addr, 32'h00000);
	   `assert(pkt_type, 2);

	   // Wait for data beat:
	   wait_response_one(hdr, last);
	   $display("-- RD response 1: %x last %d\n", hdr, last);

	   if (hdr[63:32] != 32'hdeadbeef)
	     $fatal(1, "Mismatched read data %x", hdr[31:0]);


	   //////////////////////////////////////////////////////////////////////
	   // Read s0 reg 0
	   @(posedge clk);

	   addr = 32'h00000;
	   id = 8'h98;
	   create_read_header(5'b10000 /* Bottom word, +0 */, addr, id, hdr);

	   s0r_tr <= 0;
	   submit_req_1beat(hdr);

	   s0r_tr <= 1;
	   wait_response_one(hdr, last);

	   #1;
	   `assert(last, 0);
	   // check header
	   $display("-- RD response 0: %x last %d\n", hdr, last);
	   get_hdr_id_addr(hdr, id, pkt_type, addr);
	   #1;
	   `assert(id, 8'h98);
	   `assert(addr, 32'h00000);
	   `assert(pkt_type, 2);

	   // Wait for data beat:
	   wait_response_one(hdr, last);
	   $display("-- RD response 1: %x last %d\n", hdr, last);

	   if (hdr[31:0] != 32'hcafebabe)
	     $fatal(1, "Mismatched read data %x", hdr[31:0]);



	   $display("PASS: Done\n");
	   $finish;
	end

   task get_hdr_id_addr;
      input [63:0] hdr;
      output [7:0] id;
      output [1:0] pt;
      output [31:0] addr;
      begin
	 id = hdr[55:48];
	 pt = hdr[33:32];
	 addr = {hdr[31:3], 3'b000};
      end
   endtask // get_hdr_id_addr

   task submit_req_1beat;
      input [63:0] header;
      begin
	 s0_td <= header;
	 s0_tv <= 1;
	 s0_tl <= 1;

	 #`CLK_PERIOD;
	 while (!s0_tr) begin
	    #`CLK_PERIOD;
	 end
	 s0_tv <= 0;
      end
   endtask

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
      reg [9:0]     timeout;
      begin
         timeout = 10'h3ff;
	 s0r_tr = 1;

         #1;

         do begin
            @(posedge clk);
            if (!s0r_tv) begin
               timeout = timeout - 1;
               if (timeout == 0) begin
                  $fatal(1, "FAIL: wait_response_one timed out");
               end
            end
         end while (!s0r_tv);

	 header = s0r_td;
	 last = s0r_tl;
      end
   endtask

   task create_read_header;
      input [4:0]  ben;
      input [31:0] address;
      input [7:0]  src_id;
      output [63:0] header;
      begin
	 header[63:0] = { ben, 3'h0, src_id[7:0], 8'h00, 6'h00, 2'b00 /* Read */,
			  address[31:3], 3'h0};
      end
   endtask // create_read_header

   task create_write_header;
      input [4:0]  ben;
      input [31:0] address;
      input [7:0]  src_id;
      output [63:0] header;
      begin
	 header[63:0] = { ben, 3'h0, src_id[7:0], 8'h00, 6'h00, 2'b01 /* Write */, address[31:3], 3'h0};
      end
   endtask // create_write_header

endmodule
