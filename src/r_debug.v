/*
 * r_debug
 *
 * Debug requester for MIC, turning a bytestream of commands/requests
 * into MIC R/W transactions.  Useful to connect via a UART to a host, for
 * downloading memory images, etc.
 *
 * ME 14/9/2020
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

module r_debug(input wire         clk,
               input wire 	  reset,

               /* MIC request port out */
               output wire 	  O_TVALID,
               input wire 	  O_TREADY,
               output wire [63:0] O_TDATA,
               output wire 	  O_TLAST,

               /* MIC response port in */
               input wire 	  I_TVALID,
               output wire 	  I_TREADY,
               input wire [63:0]  I_TDATA,
               input wire 	  I_TLAST,

               /* Byte stream for TX */
               output wire [7:0]  tx_data,
               output wire 	  tx_has_data,
               input wire 	  tx_data_consume,

               /* Byte stream for RX */
               input wire [7:0]   rx_data,
               output wire 	  rx_has_space,
               input wire 	  rx_data_produce
               );

   parameter TX_FIFO_LOG2       = 3; // Likely not really needed...
   parameter RX_FIFO_LOG2       = 3;

   ////////////////////////////////////////////////////////////////////////////
   // Data FIFOs:

   wire [7:0] 				 next_rx_byte;
   reg [7:0] 				 next_tx_byte; // Wire
   wire 				 rx_has_data;
   reg 					 rx_fifo_cons_strobe; // Wire

   wire 				 tx_has_space;
   reg 					 tx_fifo_prod_strobe; // Wire

   simple_fifo #(.DWIDTH(8),
		 .LOG2_SZ(RX_FIFO_LOG2))
               RXFIFO(.clk(clk),
		      .reset(reset),

		      .data_in(rx_data),
		      .data_in_ready(rx_has_space),
		      .data_in_strobe(rx_data_produce),

		      .data_out(next_rx_byte),
		      .data_out_valid(rx_has_data),
		      .data_out_consume_strobe(rx_fifo_cons_strobe)
		      );

   simple_fifo #(.DWIDTH(8),
		 .LOG2_SZ(RX_FIFO_LOG2))
               TXFIFO(.clk(clk),
		      .reset(reset),

		      .data_in(next_tx_byte),
		      .data_in_ready(tx_has_space),
		      .data_in_strobe(tx_fifo_prod_strobe),

		      .data_out(tx_data),
		      .data_out_valid(tx_has_data),
		      .data_out_consume_strobe(tx_data_consume)
		      );

   wire 				 tx_is_full = !tx_has_space;
   wire 				 rx_is_empty = !rx_has_data;

   reg [63:0]                            buffer;

   /* MIC interface */
   wire                                  req_ready;
   wire                                  req_start;
   wire                                  req_RnW;
   reg [31:0]                            req_address;
   reg [4:0] 				 req_byte_enables;

   wire [63:0]                           read_data;
   wire                                  read_data_valid;
   wire                                  read_data_ready;
   wire                                  write_data_ready;

   mic_m_if #(.NAME("MIC_R_DEBUG"))
            MIF (.clk(clk),
                 .reset(reset),

                 /* MIC signals */
                 .O_TVALID(O_TVALID), .O_TREADY(O_TREADY),
                 .O_TDATA(O_TDATA), .O_TLAST(O_TLAST),
                 .I_TVALID(I_TVALID), .I_TREADY(I_TREADY),
                 .I_TDATA(I_TDATA), .I_TLAST(I_TLAST),

                 /* Control/data signals */
                 .req_ready(req_ready),
                 .req_start(req_start),
                 .req_RnW(req_RnW),
                 .req_beats(8'h00 /* One beat */),
                 .req_address(req_address[31:3]),
                 .req_byte_enables(req_byte_enables),

                 .read_data(read_data),
                 .read_data_valid(read_data_valid),
                 .read_data_ready(1'b1),

                 .write_data(buffer),
                 .write_data_valid(1'b1),
                 .write_data_ready(write_data_ready)
                 );


   /* Protocol: match the litex 'Stream2Wishbone' protocol (trivial,
    * about the same as my previous hacked-up debug requesters):
    *
    * Byte:	Meaning
    * 0		Command (1=WR, 2=RD)
    * 1		Length in 32b words
    * 2,3,4,5	32b address (LE)
    * (maybe data)
    *
    * E.g. for read:
    * Sends:	0x02, <L>, <addr32>
    * Receives:	<L*4 bytes of data>
    *
    * For write:
    * Sends:	0x01, <L>, <addr32>, <L*4 bytes of data, LE>
    * Receives: (nothing)
    *
    * Extensions to that protocol:
    *
    * For write with ack:
    * Sends:	0x03, <L>, <addr32>, <L*4 bytes of data, LE>
    * Receives: 0xaa
    *
    * (If the last request of your host debug action is a write, it can be hard
    * to know that the write has completed with the original LiteX protocol;
    * the ack version gives a barrier semantic.)
    */
`define ST_IDLE				0
`define ST_LEN				1
`define ST_ADDR				2
`define ST_RX_DATA			3
`define ST_WR_RX_DATA_REQ		4
`define ST_WR_RX_DATA_WAIT		5
`define ST_RD_TX_DATA_REQ		6
`define ST_RD_TX_DATA_WAIT		7
`define ST_TX_DATA			8
`define ST_TX_ONE			9

`define CMD_WR				1
`define CMD_RD 				2
`define CMD_WR_ACK			3

   reg [3:0]                            state;
   reg [1:0] 				cmd_is;
   reg [3:0]                            counter;
   reg [7:0]                            n_words;
   reg [31:0]                           addr;
   reg 					wr_one_word;
   reg 					initial_word;
   reg 					send_ack;

   always @(posedge clk) begin
      case (state)
        `ST_IDLE: begin
           if (rx_has_data) begin
              if (next_rx_byte == `CMD_RD) begin
                 state       <= `ST_LEN;
                 cmd_is 	<= `CMD_RD;
              end else if (next_rx_byte == `CMD_WR ||
			   next_rx_byte == `CMD_WR_ACK) begin
                 state       <= `ST_LEN;
                 cmd_is 	<= `CMD_WR;
		 send_ack    <= (next_rx_byte == `CMD_WR_ACK) ? 1 : 0;
              end
              // Else silently consumed
           end
        end

        `ST_LEN: begin
           if (rx_has_data) begin
              n_words 	<= next_rx_byte;
              state   	<= `ST_ADDR;
              counter 	<= 4;
           end
        end

        `ST_ADDR: begin
           if (rx_has_data) begin
	      // Ensure addr[1:0] are zero
              req_address[31:2] 	<= {next_rx_byte, req_address[31:8+2]};
              if (counter > 1) begin
                 counter 	<= counter - 1;
              end else begin
                 if (cmd_is == `CMD_WR) begin
                    state    <= `ST_RX_DATA;
		    counter  <= 0;
                 end else if (cmd_is == `CMD_RD) begin
                    /* Set up request byte enables for the first beat, given
                     * the address offset.  This is only used for one-beat
                     * transfers, and is mostly of use where a 64-32 downsizer
                     * is present -- as happens with the APB bridge, which
                     * looks for word bytestrobes for the word offset.
                     */
                    if (n_words == 1) begin
                       if (req_address[2+8]) begin
		          req_byte_enables <= 5'b10100; // Top word
		       end else begin
		          req_byte_enables <= 5'b10000;
		       end
                    end else begin
                       req_byte_enables <= 5'b11000;
                    end

                    state    <= `ST_RD_TX_DATA_REQ;
                 end else begin
                    state 	<= `ST_IDLE;
                 end
              end
           end
        end // case: `ST_ADDR

	/* Writes */
        `ST_RX_DATA: begin
           if (rx_has_data) begin
              /* Try to align data given initial address.
	       * Possible transfers look like this:
	       *
	       * 63------------32 31-------------0
	       * -
	       *                      Word 0             // One-word transfer to a 64b boundary
	       * -
	       *     Word 0                              // One-word transfer not 64b-aligned
	       * -
	       * 	Word 1           Word 0             // 3-word transfer starting aligned
	       *                      Word 2
	       * -
	       * 	Word 0                              // 4-word transfer starting unaligned
	       *     Word 2           Word 1
	       *                      Word 3
	       * -
               *
	       * If the current address has addr[2]=1 then read serial bytes
	       * into the high part of the buffer, else start at the low
	       * part (low byte first).  This corresponds to the byte address.
               */

	      case ({req_address[2], counter[2:0]})
		/* Starting at first word */
		4'b0000:
		  buffer[7:0] <= next_rx_byte;
		4'b0001:
		  buffer[15:8] <= next_rx_byte;
		4'b0010:
		  buffer[23:16] <= next_rx_byte;
		4'b0011:
		  buffer[31:24] <= next_rx_byte;
		4'b0100:
		  buffer[39:32] <= next_rx_byte;
		4'b0101:
		  buffer[47:40] <= next_rx_byte;
		4'b0110:
		  buffer[55:48] <= next_rx_byte;
		4'b0111:
		  buffer[63:56] <= next_rx_byte;

		/* Starting at the second word */
		4'b1000:
		  buffer[39:32] <= next_rx_byte;
		4'b1001:
		  buffer[47:40] <= next_rx_byte;
		4'b1010:
		  buffer[55:48] <= next_rx_byte;
		4'b1011:
		  buffer[63:56] <= next_rx_byte;
		// Note: counter limit is 3 when addr[2]=1, see below
	      endcase

	      if ( ((n_words == 1 || req_address[2]) && counter == 3) ) begin
		 // 32-bit chunk
		 if (req_address[2]) begin
		    req_byte_enables <= 5'b10100; // Top word
		 end else begin
		    req_byte_enables <= 5'b10000;
		 end
                 state <= `ST_WR_RX_DATA_REQ;
		 counter <= 0;
		 wr_one_word <= 1;
		 n_words <= n_words - 1;

	      end else if ( ((n_words != 1 && !req_address[2]) && counter == 7) ) begin
		 // 64-bit chunk
                 req_byte_enables <= 5'b11000;
                 state <= `ST_WR_RX_DATA_REQ;
		 counter <= 0;
		 wr_one_word <= 0;
		 n_words <= n_words - 2;

	      end else begin
		 counter <= counter + 1;
	      end
           end
        end

	`ST_WR_RX_DATA_REQ: begin
	   /* Asserts req_start - req_address, req_byte_enables and buffer set up. */
	   if (req_ready) begin
	      state <= `ST_WR_RX_DATA_WAIT;
	   end
	end

        `ST_WR_RX_DATA_WAIT: begin
	   /* Since we're only doing one beat we don't need to do the proper handshake
	    * around write_data_ready.  Just wait for the request to be 'ready' again:
	    */
	   if (req_ready) begin
	      /* Done.  Are there any more words to do? */
	      if (n_words != 0) begin
		 req_address <= req_address + (wr_one_word ? 4 : 8);
		 state <= `ST_RX_DATA;
	      end else begin
		 if (send_ack) begin
		    state            <= `ST_TX_ONE;
		    req_address      <= 0;
		    buffer[7:0]      <= 8'haa;
		 end else begin
		    state             <= `ST_IDLE;
		 end
	      end
	   end
        end

	/* Reads */
        `ST_RD_TX_DATA_REQ: begin
	   /* Asserts req_start - req_address/RnW set up */
           if (req_ready) begin
	      state <= `ST_RD_TX_DATA_WAIT;
	   end
	   initial_word <= req_address[2];
        end

        `ST_RD_TX_DATA_WAIT: begin
	   /* Should get one strobe of a one-beat read... */
	   if (read_data_valid) begin
	      buffer <= read_data;
	   end
	   /* ...and then the MIC I/F going ready again means we're done: */
           if (req_ready) begin
	      state <= `ST_TX_DATA;
	      counter <= 0;
	   end
        end

        `ST_TX_DATA: begin
	   /* Similar to a write, the initial address might be unaligned so
	    * start reading from the appropriate point:
	    */
	   if (tx_has_space) begin
	      /* comb below selects next_tx_byte, and asserts tx_fifo_prod_strobe */

	      /* Just decide what to do next:
	       * Iterate through bytes of word - req_address[2:0] is used to count,
	       * and increments the word counter if another request is needed.
	       * If n_words!=0 there's more to read, so return to ST_RD_TX_DATA_REQ.
	       *
	       * Examples of requests:
	       * - 1 word, dword-aligned
	       * - 1 word, unaligned
	       * - 2 words, dword-aligned
	       * - 2 words, unaligned (two requests on MIC)
	       * - 3 words, aligned (two requests)
	       */
	      if (n_words == 1 && req_address[1:0] == 2'b11) begin
		 /* If we've sent byte 3 or byte 7, and were asked for one word,
		  * we're done
		  */
		 state <= `ST_IDLE;
	      end else if (n_words != 1 && req_address[2:0] == 7) begin
		 /* If we've sent byte 7 we're done with this dword, but there might
		  * be more.
		  */
		 if (n_words == 2 && initial_word == 0) begin
		    /* We just sent 2 words, both from the 64b DWORD: we're done. */
		    state <= `ST_IDLE;
		 end else begin
		    /* Otherwise, there's at least one word left in a new
		     * request/dword.  Fetch it.
		     */
		    n_words <= n_words - (initial_word ? 1 : 2);
		    state <= `ST_RD_TX_DATA_REQ;
		 end
	      end
	      /* Increment address for two reasons:
	       * - selects the byte to transmit
	       * - Increments address if there's another request to do
	       */
	      req_address <= req_address + 1;
	   end // if (tx_has_space)
        end // case: `ST_TX_DATA

	`ST_TX_ONE: begin
	   /* Send one byte given in buffer[req_address[2:0]; typically byte 0. */
	   if (tx_has_space) begin
	      // Byte submitted this cycle.
	      state <= `ST_IDLE;
	   end
	end

        default: begin
        end
      endcase // case (state)

      if (reset) begin
         state 		<= `ST_IDLE;
	 wr_one_word    <= 0;
	 req_address    <= 0;
	 send_ack       <= 0;
      end // else: !if(reset)
   end // always @ (posedge clk)


   always @(*) begin
      rx_fifo_cons_strobe = rx_has_data &&
			    (state == `ST_IDLE ||
			     state == `ST_LEN ||
			     state == `ST_ADDR ||
			     state == `ST_RX_DATA
			     );

      tx_fifo_prod_strobe = ((state == `ST_TX_DATA) ||
			     (state == `ST_TX_ONE)) &&
			    tx_has_space;

      next_tx_byte = 0;
      case (req_address[2:0])
	3'b000:
	  next_tx_byte = buffer[7:0];
	3'b001:
	  next_tx_byte = buffer[15:8];
	3'b010:
	  next_tx_byte = buffer[23:16];
	3'b011:
	  next_tx_byte = buffer[31:24];
	3'b100:
	  next_tx_byte = buffer[39:32];
	3'b101:
	  next_tx_byte = buffer[47:40];
	3'b110:
	  next_tx_byte = buffer[55:48];
	3'b111:
	  next_tx_byte = buffer[63:56];
      endcase
   end

   assign req_start = (state == `ST_WR_RX_DATA_REQ) || (state == `ST_RD_TX_DATA_REQ);
   assign req_RnW = (state == `ST_RD_TX_DATA_REQ);

endmodule // r_debug
