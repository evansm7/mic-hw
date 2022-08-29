/* TB for SD host interface
 *
 * Depends on external sdModel model!
 *
 * Copyright 2022 Matt Evans
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
`include "sd_regs.vh"

`timescale 1ns/1ns

`define CLK_PERIOD 10

//`define APB_DEBUG

/* Notes:
 xxd -e -g 4 -c 32 sd_img.bin | less -S

 */

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

   wire        sd_clk;
   wire        sd_cmd;
   wire        sd_cmd_out;
   wire        sd_cmd_out_en;
   wire [3:0]  sd_data;
   wire [3:0]  sd_data_out;
   wire        sd_data_out_en;

   wire        s0_tv;
   wire        s0_tr;
   wire [63:0] s0_td;
   wire        s0_tl;

   wire        s0r_tv;
   wire        s0r_tr;
   wire [63:0] s0r_td;
   wire        s0r_tl;

   assign sd_data = sd_data_out_en ? sd_data_out : 4'bzzzz;
   assign sd_cmd = sd_cmd_out_en ? sd_cmd_out : 1'bz;

   sd #(.CLK_RATE(10000) // shorten timeouts
	    )
            DUT
              (
	       .clk(clk),
	       .reset(reset),

               .sd_clk(sd_clk),
               .sd_cmd_out(sd_cmd_out),
               .sd_cmd_out_en(sd_cmd_out_en),
               .sd_cmd_in(sd_cmd),
               .sd_data_in(sd_data),
               .sd_data_out(sd_data_out),
               .sd_data_out_en(sd_data_out_en),

               .O_TDATA(s0_td),
               .O_TVALID(s0_tv),
               .O_TREADY(s0_tr),
               .O_TLAST(s0_tl),

               .I_TDATA(s0r_td),
               .I_TVALID(s0r_tv),
               .I_TREADY(s0r_tr),
               .I_TLAST(s0r_tl),

	       .PSEL(1'b1),
	       .PENABLE(apb_enb),
	       .PWRITE(apb_wr),
	       .PRDATA(apb_data_out),
	       .PWDATA(apb_data_in),
	       .PADDR(apb_addr[7:0])
	       );


   // SD model
   sdModel	#(.ramdisk("sd_img.hex"),
                  .log_file("sd_log.txt")
                  ) SD_MODEL (.sdClk(sd_clk),
                              .cmd(sd_cmd),
                              .dat(sd_data)
                              );

   // Ew
   pullup	PUC (sd_cmd);
   pullup	PUC (sd_data[0]);

   wire        s0a_tv;
   wire        s0a_tr;
   wire [63:0] s0a_td;
   wire        s0a_tl;

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

   reg [31:0]  da;
   reg [31:0]  db;
   reg [127:0] resp;
   reg [15:0]  rca;

   initial
	begin
	   $dumpfile("tb_component_sd.vcd");
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
	   apb_read(`SD_REG_STATUS, da);
	   if (da[1]) $fatal(1, "Running out of reset??");

           /* sdModel seems to always use 4-bit mode :( force it here. */
           apb_write(`SD_REG_CTRL, 32'h00800000);	// Set bus width=4

           write_cmd(48'h00_00000000_94, 2'b00);	// CMD0 + CRC, no resp
           wait_cmd_done();

           #(`CLK_PERIOD*20);	// Ncc = 8 -- FIXME, enforce this

           write_cmd(48'h08_000001aa_87, 2'b10);	// CMD8 + CRC, 48b resp
           wait_cmd_done();
           get_response(resp);
           dump_response(resp);

           // ACMD41
           write_cmd(48'h37_00000000_65, 2'b10);	// CMD55 + CRC, 48b resp
           wait_cmd_done();
           get_response(resp);
           dump_response(resp);
           write_cmd(48'h29_50300000_cb, 2'b10);	// ACMD41 + CRC, 48b resp
           wait_cmd_done();
           get_response(resp);
           dump_response(resp);				// Should check if (resp[31+8])==1 for ready

           // CMD2 to get CID, which is a "long" response:
           write_cmd(48'h02_00000000_4d, 2'b11);	// CMD2 + CRC, 136b resp
           wait_cmd_done();
           get_response(resp);
           dump_response(resp);				//

           // Now we can do CMD3 to get the RCA...
           write_cmd(48'h03_00000000_21, 2'b10);	// CMD3 + CRC, 48b resp
           wait_cmd_done();
           get_response(resp);
           dump_response(resp);				//

           rca = resp[39:24];
           $display("New RCA=%x", rca);

           // Now it's in standby state; use the RCA to select card with CMD7:
           // NOTE NOTE: Model chooses RCA 0x2000, pre-calc'd CRC on this:
           write_cmd(48'h07_20000000_43, 2'b10);	// CMD7 + CRC, 48b resp
           wait_cmd_done();
           get_response(resp);
           dump_response(resp);				//

           // ACMD6 SET_BUS_WIDTH to change to 4b mode:
           // This doesn't do anything real w/ sdModel except print a message.
           write_cmd(48'h37_20000000_a5, 2'b10);	// CMD55 + CRC, RCA 0x2000, 48b resp
           wait_cmd_done();
           get_response(resp);
           dump_response(resp);
           write_cmd(48'h06_00000002_cb, 2'b10);	// ACMD6 + CRC, 4bit, 48b resp
           wait_cmd_done();
           get_response(resp);
           dump_response(resp);				// Should check if (resp[31+8])==1 for ready

           $display("- Read sector 0x200");
           // Now....... do a read!
           apb_write(`SD_REG_DATACFG, 512/4);		// Set up expected data length
           apb_write(`SD_REG_DMAADDR, 32'h3000);

           start_data_rx();
           // Command:
           write_cmd(48'h11_00000200_79, 2'b10);	// CMD17 + CRC, 48b resp
           wait_cmd_done();
           get_response(resp);
           dump_response(resp);				//
           // Data's streaming ... finish RX:
           wait_data_rx_done();
           dump_ram(32'h3000, 128);

           $display("- Read sector 0x400");
           // Read 2
           start_data_rx();
           // Command:
           write_cmd(48'h11_00000400_0d, 2'b10);	// CMD17 + CRC, 48b resp
           wait_cmd_done();
           get_response(resp);
           dump_response(resp);				//
           // Data's streaming ... finish RX:
           wait_data_rx_done();
           dump_ram(32'h3000, 128);


           // Now try writing!
           apb_write(`SD_REG_DMAADDR, 32'h2000);
           fill_tx_buffer(32'h2000, 32'h01020304);
           $display("- Write sector 0x400");
           write_cmd(48'h18_00000400_36, 2'b10);	// CMD24 + CRC, 48b resp
           wait_cmd_done();
           get_response(resp);
           dump_response(resp);				//
           start_data_tx();
           wait_data_tx_done();

           // Do 2 back to back, to test the not-BUSY mechanism:
           apb_write(`SD_REG_DMAADDR, 32'h1000);
           fill_tx_buffer(32'h1000, 32'hdeadbeef);
           $display("- Write sector 0x800");
           write_cmd(48'h18_00000800_de, 2'b10);	// CMD24 + CRC, 48b resp
           wait_cmd_done();
           get_response(resp);
           dump_response(resp);				//
           start_data_tx();
           wait_data_tx_done();


           // Read back those sectors:
           $display("- Read sector 0x400");
           apb_write(`SD_REG_DMAADDR, 32'h3000);
           start_data_rx();
           // Command:
           write_cmd(48'h11_00000400_0d, 2'b10);	// CMD17 + CRC, 48b resp
           wait_cmd_done();
           get_response(resp);
           dump_response(resp);				//
           wait_data_rx_done();
           dump_ram(32'h3000, 128);

           $display("- Read sector 0x800");
           start_data_rx();
           // Command:
           write_cmd(48'h11_00000800_e4, 2'b10);	// CMD17 + CRC, 48b resp
           wait_cmd_done();
           get_response(resp);
           dump_response(resp);				//
           wait_data_rx_done();
           dump_ram(32'h3000, 128);


           #(`CLK_PERIOD*1000);

           /* Test multi-block read DMA.  A little hacky, as the model doesn't
            * support CMD23 multi-read stuff -- so, issue read commands back
            * to back after initialising multi-block DMA.
            */
           da[7:0] = (512/4);
           da[31:16] = 4-1;				// Multi-read 4 blocks
           apb_write(`SD_REG_DATACFG, da);

           $display("- Multi-read sector 0x200+");
           start_data_rx();
           // Command:
           write_cmd(48'h11_00000200_78, 2'b10);	// CMD17 + CRC, 48b resp
           wait_cmd_done();
           get_response(resp);
           dump_response(resp);				//
           /* Hack: wait for first command's data to finish transfer, which
            * can be seen via DMABusy going low again, then issue new command:
            */
           wait_rx_block_done();
           write_cmd(48'h11_00000400_0c, 2'b10);	// CMD17 + CRC, 48b resp
           wait_cmd_done();
           get_response(resp);
           dump_response(resp);				//

           wait_rx_block_done();
           write_cmd(48'h11_00000600_20, 2'b10);	// CMD17 + CRC, 48b resp
           wait_cmd_done();
           get_response(resp);
           dump_response(resp);				//

           wait_rx_block_done();
           write_cmd(48'h11_00000800_e4, 2'b10);	// CMD17 + CRC, 48b resp
           wait_cmd_done();
           get_response(resp);
           dump_response(resp);				//

           // Data's streaming from those reads!  Wait for RX completion:
           wait_data_rx_done();
           dump_ram(32'h3000, 128*4);

           apb_read(`SD_REG_STATUS, da);
           $write("*** DMA transfer done, status %x\n", da);

           /* Can't think of a nice way to test multi-block write with this model :(
            * Can at least demonstrate timeout.
            */
           da[7:0] = (512/4);
           da[31:16] = 4-1;				// Multi-write 4 blocks
           apb_write(`SD_REG_DMAADDR, 32'h3000);
           fill_tx_buffer(32'h2000, 32'ha7b6c5d4);
           $display("- Write sector 0x400");
           write_cmd(48'h18_00000400_36, 2'b10);	// CMD24 + CRC, 48b resp
           wait_cmd_done();
           get_response(resp);
           dump_response(resp);				//
           start_data_tx();
           wait_data_tx_done();


           #(`CLK_PERIOD*2000);
	   $display("PASSED");
	   $finish;
	end


   task write_cmd;
      input [47:0] cmd;
      input [1:0]  response_type;	// 00 None, 10 48b, 11 136b
      reg [31:0]   v;
      reg [31:0]   ctrl;
      begin
         // Assert not busy!
         apb_read(`SD_REG_STATUS, v);
         if (v[1])	$fatal(1, "write_cmd:  Attempt to write command when command pending (%x)", v);

         v = cmd[31:0];
         apb_write(`SD_REG_CB0, v);
         v = {16'h0, cmd[47:32]};
         apb_write(`SD_REG_CB1, v);

         apb_read(`SD_REG_CTRL, ctrl);	// Get existing control reg
         apb_read(`SD_REG_STATUS, v);		// Get ack val
         v = {ctrl[31:4], response_type, 1'b0, ~v[0]};
         apb_write(`SD_REG_CTRL, v);		// Go!
         $display("Sent command %x (resp %d)", cmd, response_type);
      end
   endtask // write_cmd

   task wait_cmd_done;
      reg [31:0] d;
      reg [31:0] i;

      begin
	 apb_read(`SD_REG_STATUS, d);
	 i = 0;
	 while (d[1] == 1) begin
	    i = i + 1;
	    if (i > 1000) $fatal(1, "Timed out waiting for cmd completion");
	    apb_read(`SD_REG_STATUS, d);
	 end
      end
   endtask

   task get_response;
      reg [31:0] d[3:0];
      output [127:0] resp;

      begin
	 apb_read(`SD_REG_RB0, d[0]);
	 apb_read(`SD_REG_RB1, d[1]);
	 apb_read(`SD_REG_RB2, d[2]);
	 apb_read(`SD_REG_RB3, d[3]);
         resp = {d[3], d[2], d[1], d[0]};
      end
   endtask // dump_response

   task dump_response;
      input [127:0] d;
      reg [31:0] s;

      begin
         apb_read(`SD_REG_STATUS, s);
         $display("  Resp = %08x_%08x_%08x_%08x status %x", d[127:96], d[95:64], d[63:32], d[31:0], s);
      end
   endtask // dump_response

   task dump_ram;
      input [31:0] address;
      input [31:0] nwords;
      reg [63:0]   s;
      reg [31:0]   w;
      reg [31:0]   a;
      int          i;

      begin
         for (i = 0; i < nwords/2; i = i + 1) begin
            a = {address[31:3], 3'b000} + (i*8);
            if ((i & 3) == 0)
              $write("  +%2x:  ", a);
            s = RAMA.RAM[a/8];
            $write("%08x %08x ", s[31:0], s[63:32]);
            if ((i & 3) == 3)
              $write("\n");
         end
      end
   endtask

   task start_data_rx;
      reg [31:0]	da;
      reg [31:0]	db;

      begin
         apb_read(`SD_REG_CTRL, da);
         apb_read(`SD_REG_STATUS, db);
         da[4] = ~db[4];
         // Enable RX:
         apb_write(`SD_REG_CTRL, da);
      end
   endtask // apb_read

   task wait_data_rx_done;
      reg [31:0] d;
      reg [31:0] i;

      begin
	 apb_read(`SD_REG_STATUS, d);
	 i = 0;
	 while (d[5] == 1 || d[12] == 1) begin
	    i = i + 1;
	    if (i > 20000) $fatal(1, "Timed out waiting for RX completion");
	    apb_read(`SD_REG_STATUS, d);
	 end
         if (d[7:6] != 2'b00)
           $write("RX: Status bad, %d\n", d[7:6]);
      end
   endtask

   // Hacky AF, wait for RX block count to change
   task wait_rx_block_done;
      reg [31:0] d;
      reg [31:0] i;

      begin
         i = 0;
         d = DUT.SD_DATA_RX.rx_block_count;
	 while (d == DUT.SD_DATA_RX.rx_block_count) begin
	    i = i + 1;
            @(posedge clk);
	    if (i > 20000) $fatal(1, "Timed out waiting for RX block++");
	 end
      end
   endtask

   task fill_tx_buffer;
      input [31:0] 	address;
      input [31:0] 	pattern;
      int        	i;
      int        	j;
      reg [63:0]        d;

      begin
         for (i = 0; i < 512/4; i = i + 2) begin
            j = i + 1;
            d   = {pattern + {i[7:0], i[7:0], i[7:0], i[7:0]}, pattern + {j[7:0], j[7:0], j[7:0], j[7:0]}};
            RAMA.RAM[address/8 + i/2] = d;
         end
      end
   endtask

   task start_data_tx;
      reg [31:0]	da;
      reg [31:0]	db;

      begin
         apb_read(`SD_REG_CTRL, da);
         apb_read(`SD_REG_STATUS, db);
         da[8] = ~db[8]; // TX_Ack
         // Enable TX (writes updated TX_Req)
         apb_write(`SD_REG_CTRL, da);
      end
   endtask

   task wait_data_tx_done;
      reg [31:0] d;
      reg [31:0] i;

      begin
	 apb_read(`SD_REG_STATUS, d);
	 i = 0;
	 while (d[9] == 1 || d[12] == 1) begin // TXInProgress or DMA busy
	    i = i + 1;
	    if (i > 20000) $fatal(1, "Timed out waiting for TX completion");
	    apb_read(`SD_REG_STATUS, d);
	 end
         $display("TX complete, status %d", d[11:10]);
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

`ifdef APB_DEBUG
	 $display("[APB: Wrote %x to %x]", data, address);
`endif
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

`ifdef APB_DEBUG
	 $display("[APB: Read %x from %x]", data, address);
`endif
      end
   endtask // apb_read

endmodule
