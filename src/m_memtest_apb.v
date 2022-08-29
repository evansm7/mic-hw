/* Requester generating random write data, reading back, checking.
 * - Random gap between packets
 * - Random address for packet
 * - Random packet size
 *
 * May also be useful as a template for a "real" requester in terms of two
 * FSMs to make a request, deal with responses, and hand-off between them.
 *
 * Register interface:
 *
 * 0:   [0]       fatal_stop
 *      [7:4]     error_type
 * 4:   [31:0]    trx_count
 * 8:   [31:0]    last_addr
 * 10:  [31:0]    error_data_L
 * 14:  [31:0]    error_data_H
 * 18:  [31:0]    expected_data_L
 * 1c:  [31:0]    expected_data_H
 *
 * m_memtest is useful in sim, whereas this variant is designed to be driven by
 * an embedded CPU subsystem in order to exercise real hardware at speed.
 *
 *
 * Copyright 2017, 2019-2021 Matt Evans
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

module m_memtest_apb(input wire         clk,
		     input wire         reset,

		     /* Request port out */
		     output reg         O_TVALID,
		     input wire         O_TREADY,
		     output reg [63:0]  O_TDATA,
		     output reg         O_TLAST,

		     /* Response port in */
		     input wire         I_TVALID,
		     output wire        I_TREADY,
		     input wire [63:0]  I_TDATA,
		     input wire         I_TLAST,

		     output reg [31:0]  trx_count,
                     output reg         fatal_stop,

		     /* APB interface */
		     input wire         PCLK,
		     input wire         PSEL,
		     input wire [31:0]  PWDATA,
		     output wire [31:0] PRDATA,
		     input wire         PENABLE,
		     input wire [4:0]   PADDR,
		     input wire         PWRITE
		     );

   parameter NAME = "Memtest";
   parameter THROTTLE = 0;
   parameter THROTTLE_RESPONSES = 0;
   parameter RNG_INIT = 16'hface;
   parameter SRC_ID = 8'h00;
   parameter ADDR_MASK = 29'h1fffffff;
   parameter ADDR_OFFS = 29'h00000000;
   parameter NUM_TRANSACTIONS  = 32'hffffffff;
   parameter DATA_PATTERN = 0;	/* Or !0 for alternate pattern */

   /* Error capture */
   /* fatal_stop is a reg output; when set, requests stop. */
   reg [3:0] error_type;
   reg [63:0] error_data;
   reg [63:0] error_data_correct;
`define ERR_RD_MISMATCH    1
`define ERR_MULTI_BEAT     2
`define ERR_MYSTERY_SHORT  3
`define ERR_MYSTERY_LEN    4
`define ERR_RD_LEN         5

   reg 		     write_en;
   wire		     start_request;
   reg [7:0] 	     write_limit;
   reg [7:0] 	     write_counter;
   reg [31:3] 	     write_address;

   reg               throttle_tx; // Config reg version
   reg               throttle_rx;
   reg [1:0]         throttle_tx_r; // synchronised version
   reg [1:0]         throttle_rx_r;

   wire [15:0] 	     rng;
   reg [63:0] 	     sent_data[255:0];

   rng		#(.S(RNG_INIT)
		  )
                RNG
		  (.clk(clk),
		   .reset(reset),
		   .rng_o(rng));
   assign start_request = (trx_count != 0) && (!throttle_tx_r[1] || rng[14]) && !fatal_stop;
   wire 	     lumpy_request;
   // Also, randomly pause beats of write requests!
   assign lumpy_request = !throttle_tx_r[1] || rng[3];

`define STATE_IDLE       0
`define STATE_RD         1
`define STATE_WR         2
`define STATE_WAIT_RESP  3

   reg [2:0] 	     state;
   reg 		     do_write; // Or check

   reg 		     response_handshake_a;
   reg 		     response_handshake_b;

   wire [31:3] 	     out_address;
   assign out_address = ADDR_OFFS | (ADDR_MASK & {rng[15:0], ~rng[15:3]});

   wire [7:0] 	     rd_len;
   assign rd_len = write_limit;

   wire [63:0] 	     rd_header;
   wire [63:0] 	     wr_header;
   wire [63:0] 	     wr_data;
   assign rd_header[63:0] = { 5'h1f /* ByteEnables */, 3'h0, SRC_ID, rd_len[7:0], 6'h00, 2'b00 /* Read */,
			      write_address, 3'h0};
   assign wr_header[63:0] = { 5'h1f /* ByteEnables */, 3'h0, SRC_ID,       8'h00, 6'h00, 2'b01 /* Write */,
			      out_address, 3'h0};
   wire              toggle_bit = trx_count[0] ^ write_counter[0];
   assign wr_data[63:0] = (DATA_PATTERN != 0) ? {32{toggle_bit, ~toggle_bit}} : {rng, rng, rng, rng};

   /* Request/output channel */
   always @(posedge clk)
     begin
	if (reset) begin
	   state                <= `STATE_IDLE;

	   O_TDATA              <= 0;
	   O_TLAST              <= 0;
	   O_TVALID             <= 0;
	   write_counter        <= 0;
	   write_limit          <= 0;
	   write_address        <= 0;
	   response_handshake_a <= 0;
	   do_write             <= 1;
	   trx_count            <= NUM_TRANSACTIONS;

           throttle_tx_r        <= 0;
           throttle_rx_r        <= 0;
	end else begin
	   case (state)
	     `STATE_IDLE:
	       begin
		  if (start_request) begin
		     if (do_write) begin
			O_TDATA <= wr_header;
			O_TVALID <= 1;
			O_TLAST <= 0; /* A write is always >1 beat */
			state <= `STATE_WR;
			do_write <= 0; /* Next request's a read */

			write_address <= out_address;
			write_limit <= rng[4:0]; /* Intentionally small */
			write_counter <= 0;
			$display("%s:  Write of %d beats to %x\n", NAME, rng[4:0] + 1, {out_address, 3'h0});
		     end else begin
			O_TDATA <= rd_header;
			O_TVALID <= 1;
			O_TLAST <= 1; /* A read is only one beat */
			state <= `STATE_RD;
			do_write <= 1; /* Next request's a write */
			$display("%s:  Read of %d beats from %x\n", NAME, rd_len+1, {write_address, 3'h0});
		     end // else: !if(do_write)
		     trx_count <= trx_count - 1;
		  end
	       end

	     `STATE_RD:
	       begin
		  if (O_TREADY) begin
		     /* OK, other side got our request, we're done. */
		     O_TVALID <= 0;
		     state <= `STATE_WAIT_RESP;
		     response_handshake_a <= ~response_handshake_a;
		     O_TLAST <= 0;
		  end
	       end

	     `STATE_WR:
	       begin
		  if (O_TREADY) begin
		     /* One beat consumed, either prepare another or we're done. */
		     if (write_counter > write_limit) begin
			O_TVALID <= 0;
			state <= `STATE_WAIT_RESP;
			response_handshake_a <= ~response_handshake_a;
			O_TLAST <= 0;
			$display("%s:  Write burst complete, %d beats total\n", NAME, write_counter);
		     end else begin
			if (lumpy_request) begin
			   O_TVALID <= 1;
			   if (write_counter == write_limit) begin
			      O_TLAST <= 1;
			   end
			   O_TDATA <= wr_data;
			   sent_data[write_counter] <= wr_data;
			   write_counter <= write_counter + 1;
			   $display("%s:  Write beat %d: data %x", NAME, write_counter, wr_data);
			end else begin
			   O_TVALID <= 0;
			end // else: !if(lumpy_request)
		     end
		  end
	       end // case: `STATE_WR_DATA

	     `STATE_WAIT_RESP:
	       begin
		  /* Do nothing until the response for our request comes in. */
		  if (response_handshake_a == response_handshake_b)
		    state <= `STATE_IDLE;
	       end
	   endcase // case (state)

           throttle_rx_r[0] <= throttle_rx;
           throttle_rx_r[1] <= throttle_rx_r[0];
           throttle_tx_r[0] <= throttle_tx;
           throttle_tx_r[1] <= throttle_tx_r[0];
	end
     end


   /* Response/input channel */
   wire [1:0] 	     pkt_type;
   wire [31:3] 	     in_address;
   reg [1:0] 	     pkt_type_r;
   reg [31:3] 	     in_address_r;
   reg 		     is_header;
   reg [9:0] 	     count;

   /* Don't care about these yet: {wr_strobes, src_id, rd_len} = I_TDATA[63:40] */
   assign pkt_type = I_TDATA[33:32];
   assign in_address = I_TDATA[31:3];

   assign I_TREADY = !throttle_rx_r[1] || rng[7] || rng[2]; /* Wait states on input if configured */

   always @(posedge clk)
     begin
	if (reset) begin
	   is_header <= 1;
	   count <= 0;
	   pkt_type_r <= 0;
	   in_address_r <= 0;
	   response_handshake_b <= 0;
	   fatal_stop <= 0;
	   error_type <= 0;
	   error_data <= 0;
	   error_data_correct <= 0;
	end else begin
	   if (I_TVALID && I_TREADY) begin
	      if (is_header) begin
		 /* Actually only type, src_id and possibly len are valid. */
		 $display("%s:   Got pkt type %d, addr %x", NAME, pkt_type, {in_address, 3'h0});
		 pkt_type_r <= pkt_type;
		 in_address_r <= in_address;

		 if (!I_TLAST) begin
		    // There's more than just the header.
		    if (pkt_type != 2'b10) begin // RDATA
`ifdef SIM
		       $fatal(1, "%s:  *** Multi-beat packet that isn't an RDATA", NAME);
`endif
		       fatal_stop <= 1;
		       error_type <= `ERR_MULTI_BEAT;
		    end
		    is_header <= 0;
		    count <= 0;
		 end else begin
		    if (pkt_type == 2'b11) begin // WRACK
`ifdef SIM
		       $display("%s:   Got WRACK for addr %x\n", NAME, {in_address, 3'h0});
`endif
		    end else begin
`ifdef SIM
		       $fatal(1, "%s:  *** Got mystery 1-beat packet type %d\n", NAME, pkt_type);
`endif
		       fatal_stop <= 1;
		       error_type <= `ERR_MYSTERY_SHORT;
		       error_data <= I_TDATA;
		    end

		    /* Tell the other side it can continue. */
		    response_handshake_b <= ~response_handshake_b;
		 end
	      end else begin // if (is_header)
		 // Count non-header beats
		 count                <= count + 1;
		 // Do something with I_TDATA[], which is read data.
		 // Also, can increment in_address_r to track real read address.
		 // Note ===/!== to give a z/x-exact compare
		 if (sent_data[count] !== I_TDATA) begin
`ifdef SIM
		    $fatal(1, "%s:   *** Read data mismatch, got %x, expecting %x, count %d ***", NAME,
			   I_TDATA, sent_data[count], count);
`endif
		    fatal_stop <= 1;
		    error_type <= `ERR_RD_MISMATCH;
		    error_data <= I_TDATA;
		    error_data_correct <= sent_data[count];
		 end else begin
`ifdef SIM
		    $display("%s:   Beat %d: Read data %x CORRECT", NAME,
			     count, sent_data[count]);
`endif
		 end

		 if (I_TLAST) begin
		    // OK, done; next beat is the next packet's header.
		    is_header            <= 1;
		    /* Tell the other side it can continue. */
		    response_handshake_b <= ~response_handshake_b;

		    if (pkt_type_r == 2'b10) begin
`ifdef SIM
		       $display("%s:   ReadData total %d beats read from address %x\n", NAME, count+1, {in_address_r, 3'h0});
`endif
		       if (write_counter != count+1) begin
`ifdef SIM
			  $fatal(1, "%s:  *** Read count %d instead of %d\n", NAME, count+1, write_counter);
`endif
			  fatal_stop <= 1;
			  error_type <= `ERR_RD_LEN;
			  error_data <= {count, write_counter};
		       end
		    end else begin // if (pkt_type_r == 2'b10)
`ifdef SIM
		       $fatal(1, "%s:  *** Mystery multi-beat packet was %d beats long\n", NAME, count);
`endif
		       fatal_stop <= 1;
		       error_type <= `ERR_MYSTERY_LEN;
		       error_data <= {count, write_counter};
		    end
		 end
	      end // else: !if(is_header)
	   end
	end
     end

   reg [31:0] reg0_r;
   reg [31:0] reg0_rr;
   reg [31:0] reg1_r;
   reg [31:0] reg1_rr;
   reg [31:0] reg2_r;
   reg [31:0] reg2_rr;
   reg [31:0] reg3_r;
   reg [31:0] reg3_rr;
   reg [31:0] reg4_r;
   reg [31:0] reg4_rr;
   reg [31:0] reg5_r;
   reg [31:0] reg5_rr;
   reg [31:0] reg6_r;
   reg [31:0] reg6_rr;

   /* APB interface */
   /* Regs run asynchronously to the MIC interface */
   always @(posedge PCLK)
     if (reset) begin
	reg0_r      <= 0;
	reg0_rr     <= 0;
	reg1_r      <= 0;
	reg1_rr     <= 0;
	reg2_r      <= 0;
	reg2_rr     <= 0;
	reg3_r      <= 0;
	reg3_rr     <= 0;
	reg4_r      <= 0;
	reg4_rr     <= 0;
	reg5_r      <= 0;
	reg5_rr     <= 0;
	reg6_r      <= 0;
	reg6_rr     <= 0;

        throttle_rx <= THROTTLE_RESPONSES;
        throttle_tx <= THROTTLE;
     end else begin
	if (PSEL & PENABLE & PWRITE) begin
	   // Reg write, PADDR[4:0]
	   // capture PWDATA
           if (PADDR[4:0] == 5'h1c) begin
              throttle_rx <= PWDATA[1];
              throttle_tx <= PWDATA[0];
           end
	end

	// Synchronisers:
	reg0_rr <= {error_type, 3'b000, fatal_stop};
	reg0_r <= reg0_rr;

	reg1_rr <= trx_count;
	reg1_r <= reg1_rr;

	reg2_rr <= in_address_r;
	reg2_r <= reg2_rr;

	reg3_rr <= error_data[31:0];
	reg3_r <= reg3_rr;

	reg4_rr <= error_data[63:32];
	reg4_r <= reg4_rr;

	reg5_rr <= error_data_correct[31:0];
	reg5_r <= reg5_rr;

	reg6_rr <= error_data_correct[63:32];
	reg6_r <= reg6_rr;

     end

   assign PRDATA = (PADDR[4:0] == 5'h00) ? reg0_r :
		   (PADDR[4:0] == 5'h04) ? reg1_r :
		   (PADDR[4:0] == 5'h08) ? reg2_r :
		   (PADDR[4:0] == 5'h0c) ? reg3_r :
		   (PADDR[4:0] == 5'h10) ? reg4_r :
		   (PADDR[4:0] == 5'h14) ? reg5_r :
		   (PADDR[4:0] == 5'h18) ? reg6_r :
                   (PADDR[4:0] == 5'h1c) ? {30'h00000000, throttle_rx, throttle_tx} :
		   32'hcafebabe;
endmodule
