/* Configurable synthesised RAM for MIC
 *
 * RAM idiom should be inferred as blockrams with byte write enables.
 *
 * Because this is useful for simulation too, the size has a high upper limit (128M),
 * limited by the size of ram_addr.  Typically will be 16-64K for on-FPGA boot memory.
 *
 * Copyright 2017, 2019-2022 Matt Evans
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

module s_bram(input wire        clk,
	      input wire 	reset,

	      input wire 	I_TVALID,
	      output wire 	I_TREADY,
	      input wire [63:0] I_TDATA,
	      input wire 	I_TLAST,

	      output reg 	O_TVALID,
	      input wire 	O_TREADY,
	      output reg [63:0] O_TDATA,
	      output reg 	O_TLAST
	      );

   parameter KB_SIZE = 64;
   parameter NAME = "RAM";
   parameter INIT_FILE = "";

   /* Request type */
   reg [1:0] 	     request;
`define REQ_NONE          0
`define REQ_RD            1
`define REQ_WR            2

   reg [2:0] 	     output_state;
`define STATE_IDLE        0
`define STATE_RDATA_HDR   1
`define STATE_RDATA_DATA  2
`define STATE_WRACK_HDR   3
`define STATE_DONE        4

   reg [7:0] 	     req_srcid;
   reg [7:0] 	     req_len;
   reg [1:0] 	     req_type;
   reg [31:3] 	     req_addr;
   reg [7:0] 	     req_wr_strobes;

   reg [8:0] 	     beat_count;
   reg 		     is_header;

   /* Break out info from header: */
   wire [4:0] 	     header_byte_ens;
   wire [7:0] 	     header_src_id;
   wire [7:0] 	     header_rd_len;
   wire [1:0] 	     header_pkt_type;
   wire [31:3] 	     header_address;
   wire 	     header_address_valid;

   assign header_byte_ens = I_TDATA[63:59];
   assign header_src_id = I_TDATA[55:48];
   assign header_rd_len = I_TDATA[47:40];
   assign header_pkt_type = I_TDATA[33:32];
   assign header_address = I_TDATA[31:3];
   /* If a header for READ or WRITE is present this cycle: */
   assign header_address_valid = (request == `REQ_NONE) && I_TVALID && is_header &&
				 ((header_pkt_type == 2'b01) || (header_pkt_type == 2'b00));

   wire [7:0] 	     byte_strobes;

   /* Decode byte enables into strobes: */
   mic_ben_dec MBD(.byte_enables(header_byte_ens),
		   .byte_strobes(byte_strobes),
		   .addr_offset());

   reg [63:0] 	     RAM[(KB_SIZE*1024/8)-1:0] /*verilator public*/;

   initial begin
      if (INIT_FILE != "") begin
         $display("s_bram: Initialising RAM from %s", INIT_FILE);
         $readmemh(INIT_FILE, RAM);
      end
   end

   reg 		     do_write;

   assign I_TREADY = (request == `REQ_NONE);

   /* Handshake between input and output:
    * When request is REQ_NONE, input is accepted.
    * When input is a valid request, request becomes REQ_RD or REQ_WR.
    * When REQ_RD/REQ_WR and output_state is ST_IDLE, an output request is generated.
    * When output is complete, and request is not REQ_NONE output_state is ST_DONE.
    * When output_state is ST_DONE, request returns to REQ_NONE.
    * When REQ_NONE, and output_state is ST_DONE, it goes to ST_IDLE.
    */

   /* Input request processing */
   always @(posedge clk)
     begin
	if (request <= `REQ_NONE) begin
	   if (I_TVALID) begin
	      if (is_header) begin
`ifdef DEBUG
		 $display("%s:  Got pkt type %d, addr %x, len %d, src_id %x",
			  NAME, header_pkt_type, {header_address, 3'h0}, header_rd_len, header_src_id);
`endif

		 req_srcid <= header_src_id; /* To route response */
		 req_len <= header_rd_len;   /* To generate correct number of response beats */
		 req_type <= header_pkt_type;
		 req_addr <= header_address;

		 if (!I_TLAST) begin
		    // There's more than just the header.
		    if (header_pkt_type != 2'b01) begin // WRITE
		       $display("%s:  *** Multi-beat packet that isn't a WRITE", NAME);
		    end else begin
`ifdef DEBUG		  $display("%s:  Header complete; WRITE continues", NAME);  `endif
		       do_write <= 1;
		    end
		    is_header <= 0;
		    beat_count <= 1;
		 end else begin
		    // A read request is set up on receipt of the header (LAST=1)
		    if (/* Current header */ header_pkt_type == 2'b00) begin
`ifdef DEBUG		  $display("%s:  Header complete; READ", NAME);  `endif
		       request <= `REQ_RD;
		    end
		 end
	      end else begin // if (is_header)
		 /* This is a non-header beat.  The RAM is being
		  * written if do_write was set by the previous
		  * header parsing.
		  */

		 if (I_TLAST) begin
		    is_header <= 1;
		    do_write <= 0; /* In other words, next cycle is no longer a write */

`ifdef DEBUG		       $display("%s:  Multi-beat request was %d beats long", NAME, beat_count);  `endif
		    // Consumed all input beats; set the request type (for a response):
		    if (/* Previous header */ req_type == 2'b01) begin
		       request <= `REQ_WR;
		    end
		 end
		 beat_count <= beat_count + 1;
	      end
	   end
	end else begin // if (request <= `REQ_NONE)
	   /* Since we're not in state REQ_NONE, our TREADY is LOW
	    * (i.e. not accepting any further requests).
	    */
	   if (output_state == `STATE_DONE) begin
	      request <= `REQ_NONE;
	      do_write <= 0;
	   end
	end

        if (reset) begin
	   is_header <= 1;
	   request <= `REQ_NONE;
	   do_write <= 0;
	end
     end


   ///////////////////////////////////////////////////////////////////////////

   /* RAM control:
    *
    * do_write is enabled when a write burst is still ongoing.
    */
   reg [23:0] 	     ram_addr; /* In dwords */
   wire [23:0] 	     ram_addr_trunc;
   reg [7:0] 	     ram_wr_strobes;
   wire [7:0] 	     ram_we;
   wire 	     ram_enable_wr;
   wire 	     ram_enable;
   assign ram_enable_wr = I_TVALID && do_write;
   assign ram_we[0] = ram_enable_wr && ram_wr_strobes[0];
   assign ram_we[1] = ram_enable_wr && ram_wr_strobes[1];
   assign ram_we[2] = ram_enable_wr && ram_wr_strobes[2];
   assign ram_we[3] = ram_enable_wr && ram_wr_strobes[3];
   assign ram_we[4] = ram_enable_wr && ram_wr_strobes[4];
   assign ram_we[5] = ram_enable_wr && ram_wr_strobes[5];
   assign ram_we[6] = ram_enable_wr && ram_wr_strobes[6];
   assign ram_we[7] = ram_enable_wr && ram_wr_strobes[7];
   reg [63:0] 	     ram_do;

   wire 	     first_read;

   /* RAM reads */
   always @(posedge clk) begin
      /* I spent a full day wrestling trying to guess why ISE said it
       * was correctly inferring a BRAM, but failed to make it
       * writable. It was the fact that the READ had an enable
       * different to write.  ARGH FUCKING HELL!
       *
       * *Either* have ONE COMMON ENABLE that enables read and write
       * (secondarily qualified w/ write enable(s), OR have NO OVERALL
       * ENABLE!
       *
       * Read needs an enable as address has to progress, to make bursts
       * work.
       *
       * I would prefer this to also depend on ~|ram_we but that doesn't
       * seem to synth properly in both old and new tools.  As-is,
       * this produces read-first mode which is less desirable but
       * probably not the biggest issue right now.
       */
      if (ram_enable)
	ram_do <= RAM[ram_addr_trunc];
   end

   /* RAM writes */
   generate
      genvar i;
      for (i = 0; i < 8; i = i+1)
        begin : ramblk
           always @(posedge clk) begin
              if (ram_enable) begin
                 if (ram_we[i]) begin
                    RAM[ram_addr_trunc][(i*8)+7:i*8] <= I_TDATA[(i*8)+7:i*8];
                 end
              end
           end
        end
   endgenerate

   /* RAM address and write strobe capture */
   always @(posedge clk)
     begin
	if (header_address_valid) begin
	   /* If a read or write header is currently being presented, latch its address. */
	   ram_addr <= header_address;
	   /* Only need to do this for writes, but it's harmless for read requests: */
	   ram_wr_strobes <= byte_strobes;
	end
	else if ((ram_enable_wr) /* Writing data */ ||
                 first_read /* Idle setup before read */ ||
		 (O_TREADY && ((output_state == `STATE_RDATA_HDR) ||
			       (output_state == `STATE_RDATA_DATA)))) /* Reading */ begin
	   ram_addr <= ram_addr + 1;
	end

        if (reset) begin
	   ram_addr <= 0;
	end
     end

   assign first_read = (output_state == `STATE_IDLE && request == `REQ_RD);
   assign ram_addr_trunc = ram_addr & ((1 << ($clog2(KB_SIZE*1024)-3))-1);
   // Ram does a read, and possibly a write, if:
   assign ram_enable = ram_enable_wr || O_TREADY || first_read;

   ///////////////////////////////////////////////////////////////////////////

   wire [63:0] 	     rdata_header;
   wire [63:0] 	     wrack_header;
   assign rdata_header[63:0] = { 8'h00, req_srcid, 8'h00 /* RD len */, 6'h00, 2'b10 /* RDATA */,
				 req_addr, 3'h0};
   assign wrack_header[63:0] = { 8'h00, req_srcid, 8'h00 /* RD len */, 6'h00, 2'b11 /* WRACK */,
				 req_addr, 3'h0};

   reg [7:0] 	     output_counter;

   /* Output response processing */
   always @(posedge clk)
     begin
	case (output_state)
	  `STATE_IDLE:
	    begin
	       if (request == `REQ_RD) begin
		  O_TDATA <= rdata_header;
		  O_TVALID <= 1;
		  O_TLAST <= 0; /* Read data provides more beats */
		  output_state <= `STATE_RDATA_HDR;
`ifdef DEBUG	     $display("%s:   Sending ReadData response of %d beats to %x\n", NAME, req_len+1, req_srcid);  `endif
		  output_counter <= req_len;
	       end else if (request == `REQ_WR) begin
		  O_TDATA <= wrack_header;
		  O_TVALID <= 1;
		  O_TLAST <= 1;
		  output_state <= `STATE_WRACK_HDR;
`ifdef DEBUG	     $display("%s:   Sending WrAck to %x\n", NAME, req_srcid);  `endif
	       end
	    end

	  `STATE_WRACK_HDR:
	    begin
	       if (O_TREADY) begin
		  /* OK, other side got our request, we're done. */
		  O_TVALID <= 0;
		  O_TLAST <= 0;
		  output_state <= `STATE_DONE;
	       end
	    end

	  `STATE_RDATA_HDR:
	    begin
	       if (O_TREADY) begin
		  /* OK, other side got our header, move onto data: */
		  O_TVALID <= 1;
		  O_TDATA <= ram_do;
		  output_state <= `STATE_RDATA_DATA;
		  if (output_counter == 8'h00) begin
		     O_TLAST <= 1;
		  end
	       end
	    end

	  `STATE_RDATA_DATA:
	    begin
	       if (O_TREADY) begin
		  /* One beat consumed, either prepare another or we're done. */
		  if (output_counter == 8'h00) begin
		     O_TVALID <= 0;
		     O_TLAST <= 0;
		     output_state <= `STATE_DONE;
		  end else begin
		     if (output_counter == 8'h01) O_TLAST <= 1;

		     O_TDATA <= ram_do;
		     output_counter <= output_counter - 1;
		  end
	       end
	    end // case: `STATE_WR_DATA

	  `STATE_DONE:
	    begin
	       if (request == `REQ_NONE) begin
		  output_state <= `STATE_IDLE;
	       end
	    end
	endcase // case (state)

        if (reset) begin
	   output_state <= `STATE_IDLE;
	   O_TVALID <= 0;
	end
     end

endmodule // m_pktsink
