/* sd_data_tx: SD host interface TX datapath
 *
 * Similar to sd_data_rx, implements transmit datapath.
 *
 * Consumes data from an external FIFO, formatting into a transmit
 * block (with CRC).  Waits for and deals with card response.
 *
 * Supports multi-block transfers.
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

module sd_data_tx(input wire        clk,
                  input wire        reset,

                  // SD stuff
                  input wire [3:0]  sd_din,
                  output reg [3:0]  sd_data_out,
                  output reg        sd_data_out_en,
                  input wire        sd_clk_rising,
                  input wire        sd_clk_falling,

                  input wire        wide_bus,

                  // Data channel for received data:
                  input wire [31:0] tx_data_in,
                  // Goes active cycle before new value on tx_data_in is required:
                  output wire       tx_data_strobe,
                  output wire       tx_block_starting,
                  output wire       tx_block_is_first,
                  input wire [15:0] tx_blocks_len_m1, /* Minus 1 */
                  output reg [15:0] tx_block_count,

                  /* Indicates when first chunk becomes readable (with the assumption that
                   * a whole 512B block is then readable thereafter):
                   */
                  input wire        tx_data_ready,

                  input wire        ms_pulse,

                  // TX control/completion:
                  input wire        tx_pending,
                  output reg [1:0]  tx_status,
                  output reg        tx_ack,

                  output wire       tx_crc_enable,
                  output wire       tx_crc_clear,
                  output wire [3:0] tx_crc_data,
                  input wire [15:0] crc0,
                  input wire [15:0] crc1,
                  input wire [15:0] crc2,
                  input wire [15:0] crc3
                  );

   parameter TX_TIMEOUT = 200; // ms

   reg [8:0]       tx_timeout;
   reg [(8*6)-1:0] tx_state_name;
   reg [3:0]       tx_state;
   reg [13:0]      tx_count;
   reg [3:0]       tx_nybble; // Wire
   reg [3:0]       tx_crc_nybble; // Wire
   reg             tx_bit; // Wire
   reg [2:0]       tx_status_resp;

`define SD_DTX_IDLE             0
`define SD_DTX_DATA_OUT         1
`define SD_DTX_CRC_OUT          2
`define SD_DTX_STOP             3
`define SD_DTX_CHANGEOVER       4       // NCRC, ZZ between WR & status
`define SD_DTX_WAIT_STATUS_S    5       // Start bit: UHS might be up to 8c
`define SD_DTX_STATUS           6       // Status data & end bit
`define SD_DTX_WAIT_NBUSY       7
`define SD_DTX_WAIT_NWR         8
`define SD_DTX_WAIT_DATA_READY  9
`define SD_DTX_CHECK_MORE       10

   assign tx_block_is_first = (tx_block_count == 0);

   // FIXME: trigger TX from WR command successful completion (e.g. status having R1_READY_FOR_DATA)

   always @(posedge clk) begin
      case (tx_state)
        `SD_DTX_IDLE:
          if (tx_pending && sd_clk_falling) begin
             tx_state_name    <= "WDAT";
             tx_state         <= `SD_DTX_WAIT_DATA_READY;
             tx_status_resp   <= 0;
             tx_count         <= 0;
             sd_data_out_en   <= 0;
             tx_block_count   <= 0;
          end

        `SD_DTX_WAIT_DATA_READY:
          /* This state is multi-purpose & hacky.  In cycle 0, it strobes tx_block_starting.
           * That requests that the DMA engine starts to buffer data.
           * After that, it waits for tx_data_ready which indicates "enough" data is
           * ready to start streaming out a block.
           */
          if (sd_clk_falling) begin /* Not really necessary for external logic, but "consistent" */
             if (tx_count == 0) begin
                /* tx_block_starting is asserted here */
                tx_count         <= tx_count + 1;
             end if (tx_count == 1 && tx_data_ready) begin
                tx_state_name <= "WNWR";
                tx_state      <= `SD_DTX_WAIT_NWR;
                tx_count      <= 0;
             end
          end

        `SD_DTX_WAIT_NWR:
          /* Wait the busy-to-data time NWR (2c).  Note first cycle is
           * high-Z, thereafter is actively driven to 1!
           */
          // NOTE: CRC is cleared here
          if (sd_clk_falling) begin
             tx_count              <= tx_count + 1;
             if (tx_count == 0) begin
                // Begin to drive 1s:
                sd_data_out_en     <= 1;
                sd_data_out        <= 4'hf;
             end else if (tx_count == 2 /* a bit longer */) begin
                /* Start transmission: */
                tx_state_name      <= "DATAO";
                tx_state           <= `SD_DTX_DATA_OUT;
                tx_count           <= 0;
                // NOTE: tx_data_strobe active in this cycle (fetch first word)
                sd_data_out        <= 4'h0;   // Start bit
                sd_data_out_en     <= 1; // Stays 1
             end
          end

        `SD_DTX_DATA_OUT:
          if (sd_clk_falling) begin
             sd_data_out     <= wide_bus ? tx_nybble : {3'h0, tx_bit};
             tx_count        <= tx_count + 1;

             /* (For wide mode,) Every 8 transmissions grab a new word:
              * See tx_data_strobe, which activates here when tx_count[2:0] == 111.
              * Note: The strobe inhibited on the very last word of the block
              * (so as not to burn the first word of the next block!).
              */

             if (tx_count == (wide_bus ? ((2*512)-1) : ((8*512)-1))) begin
                tx_state_name <= "CRCO";
                tx_state      <= `SD_DTX_CRC_OUT;
                tx_count      <= 0;
             end
          end

        `SD_DTX_CRC_OUT:
          if (sd_clk_falling) begin
             /* Note, the first cycle of this state is outputting the
              * last nybble of data, so we stay in this state 17 cycles
              * to include that, plus 16 CRC bits per line.
              */
             if (tx_count == 16) begin
                tx_state_name <= "STOP";
                tx_state      <= `SD_DTX_STOP;
                sd_data_out   <= 4'hf;
             end else begin
                sd_data_out   <= tx_crc_nybble;
                tx_count      <= tx_count + 1;
             end
          end

        `SD_DTX_STOP:
          // Pop into here for 1 cycle, D=1111
          if (sd_clk_falling) begin
             sd_data_out_en   <= 0;
             tx_state_name    <= "CHOVER";
             tx_state         <= `SD_DTX_CHANGEOVER;
             tx_count         <= 0;
          end

        `SD_DTX_CHANGEOVER:
          // Ncrc (2) cycles for CMD to go hi-Z before card drives it:
          if (sd_clk_falling) begin
             if (tx_count == 1) begin
                tx_state_name <= "WAITSS";
                tx_state      <= `SD_DTX_WAIT_STATUS_S;
                tx_timeout    <= TX_TIMEOUT;
             end else begin
                tx_count      <= tx_count + 1;
             end
          end

        `SD_DTX_WAIT_STATUS_S: begin
           // Wait for status start bit (0)
           if (sd_clk_rising) begin
              if (sd_din[0] == 0) begin
                 tx_state_name <= "STATUS";
                 tx_state      <= `SD_DTX_STATUS;
                 tx_count      <= 0;
              end else begin
                 if (tx_timeout == 0) begin
                    // On timeout, go straight to idle:
                    tx_status      <= 2'b01;

                    tx_state_name  <= "IDLE";
                    tx_state       <= `SD_DTX_IDLE;
                    sd_data_out_en <= 0;
                    tx_ack         <= ~tx_ack;
                 end
              end
           end
           if (ms_pulse && tx_timeout != 0)
             tx_timeout       <= tx_timeout - 1;
        end

        `SD_DTX_STATUS:
          // Collect 3-bit status plus end bit
          if (sd_clk_rising) begin
             tx_count         <= tx_count + 1;
             tx_status_resp   <= {tx_status_resp[1:0], sd_din[0]};
             if (tx_count == 3) begin
                // Great success or great fail?
                if (sd_din[0] == 0) begin
                   tx_status          <= 2'b10;       // End bit fail
                end else if (tx_status_resp[2:0] != 3'b010) begin
                   // Not a "CRC good" status!
                   tx_status          <= 2'b11;       // CRC fail
                end else begin
                   // Good CRC received by card
                   tx_status          <= 2'b00;       // Great success!
                end
                /* Card might be in programming state (or otherwise busy,
                 * observed real card do this after a CRC error.
                 * Wait for it to be not-busy:
                 */
                tx_state_name         <= "WNBUSY";
                tx_state              <= `SD_DTX_WAIT_NBUSY;
                tx_timeout            <= TX_TIMEOUT;

                sd_data_out_en        <= 0; // Stays 0/off!
             end
          end

        /* Observation/note...
         *
         * The sdModel.v I'm testing against doesn't like receiving another write command
         * while it's still in programming state.  For a single block write, it should be
         * OK to issue more things.  It only goes into receive state if write buffer is
         * free.  So, wait for NBUSY before flagging the command is done via tx_ack. :(
         *
         * FIXME: Do real SD cards behave this way?  If not, we can hide the prog time
         * perhaps by permitting other commands before !busy.
         */

        `SD_DTX_WAIT_NBUSY: begin
           /* A previous write might still be consuming buffer space;
            * wait for card to indicate buffer is free (by not pulling
            * D0 low)
            */
           if (sd_clk_rising) begin
              if (sd_din[0] == 1'b1 || tx_timeout == 0) begin
                 tx_state_name        <= "CHKMRE";
                 tx_state             <= `SD_DTX_CHECK_MORE;
                 sd_data_out_en       <= 0; // Stays 0/off!

                 if (tx_timeout == 0)
                   tx_status <= 2'b01;
              end
           end
           if (ms_pulse && tx_timeout != 0)
             tx_timeout  <= tx_timeout - 1;
        end // case: `SD_DTX_WAIT_NBUSY

        `SD_DTX_CHECK_MORE: begin
           tx_block_count <= tx_block_count + 1;
           /* If there are more blocks in the transfer and previous blocks
            * ALL completed successfully, go start another transfer.
            * Otherwise, go idle.
            */
           if ((tx_block_count < tx_blocks_len_m1) &&
               (tx_status == 0)) begin
              /* Status is important; a CRC failure terminates the transfer
               * and software can abort the write (CMD12).
               */
              tx_state_name  <= "WDAT";
              tx_state       <= `SD_DTX_WAIT_DATA_READY;
              tx_status_resp <= 0;
              tx_count       <= 0;
           end else begin
              /* Transfer totally complete. */
              tx_state_name   <= "IDLE";
              tx_state        <= `SD_DTX_IDLE;
              tx_ack          <= ~tx_ack;
           end
        end

      endcase

      if (reset) begin
         tx_state_name  <= "IDLE";
         tx_state       <= `SD_DTX_IDLE;
         tx_ack         <= 0;
         tx_status      <= 0;
         tx_status_resp <= 0;
         sd_data_out_en <= 0;    /* NTS: be explicit about when this changes/stays */
      end
   end

   assign tx_block_starting  = (tx_state == `SD_DTX_WAIT_DATA_READY) && sd_clk_falling && (tx_count == 0);
   assign tx_data_strobe = ((tx_state == `SD_DTX_WAIT_NWR) && sd_clk_falling && (tx_count == 2)) ||
                           ((tx_state == `SD_DTX_DATA_OUT) && sd_clk_falling &&
                            ( wide_bus ? ((tx_count[2:0] == 3'b111) && (tx_count != (2*512)-1)) :
                              ((tx_count[4:0] == 5'b11111) && (tx_count != (8*512)-1)) ));

   always @(*) begin
      /* tx_nybble is used for wide bus mode */
      tx_nybble = 0;
      case (tx_count[2:0])
        3'b000: tx_nybble = tx_data_in[7:4];
        3'b001: tx_nybble = tx_data_in[3:0];
        3'b010: tx_nybble = tx_data_in[15:12];
        3'b011: tx_nybble = tx_data_in[11:8];
        3'b100: tx_nybble = tx_data_in[23:20];
        3'b101: tx_nybble = tx_data_in[19:16];
        3'b110: tx_nybble = tx_data_in[31:28];
        3'b111: tx_nybble = tx_data_in[27:24];
      endcase

      /* tx_bit is used for narrow bus mode */
      tx_bit        = 0;
      case (tx_count[4:0])
        5'b00000:       tx_bit = tx_data_in[7];
        5'b00001:       tx_bit = tx_data_in[6];
        5'b00010:       tx_bit = tx_data_in[5];
        5'b00011:       tx_bit = tx_data_in[4];
        5'b00100:       tx_bit = tx_data_in[3];
        5'b00101:       tx_bit = tx_data_in[2];
        5'b00110:       tx_bit = tx_data_in[1];
        5'b00111:       tx_bit = tx_data_in[0];
        5'b01000:       tx_bit = tx_data_in[8+7];
        5'b01001:       tx_bit = tx_data_in[8+6];
        5'b01010:       tx_bit = tx_data_in[8+5];
        5'b01011:       tx_bit = tx_data_in[8+4];
        5'b01100:       tx_bit = tx_data_in[8+3];
        5'b01101:       tx_bit = tx_data_in[8+2];
        5'b01110:       tx_bit = tx_data_in[8+1];
        5'b01111:       tx_bit = tx_data_in[8+0];
        5'b10000:       tx_bit = tx_data_in[16+7];
        5'b10001:       tx_bit = tx_data_in[16+6];
        5'b10010:       tx_bit = tx_data_in[16+5];
        5'b10011:       tx_bit = tx_data_in[16+4];
        5'b10100:       tx_bit = tx_data_in[16+3];
        5'b10101:       tx_bit = tx_data_in[16+2];
        5'b10110:       tx_bit = tx_data_in[16+1];
        5'b10111:       tx_bit = tx_data_in[16+0];
        5'b11000:       tx_bit = tx_data_in[24+7];
        5'b11001:       tx_bit = tx_data_in[24+6];
        5'b11010:       tx_bit = tx_data_in[24+5];
        5'b11011:       tx_bit = tx_data_in[24+4];
        5'b11100:       tx_bit = tx_data_in[24+3];
        5'b11101:       tx_bit = tx_data_in[24+2];
        5'b11110:       tx_bit = tx_data_in[24+1];
        5'b11111:       tx_bit = tx_data_in[24+0];
      endcase

      tx_crc_nybble = 0;
      case (tx_count[3:0])
        4'b0000:        tx_crc_nybble = {crc3[15], crc2[15], crc1[15], crc0[15]};
        4'b0001:        tx_crc_nybble = {crc3[14], crc2[14], crc1[14], crc0[14]};
        4'b0010:        tx_crc_nybble = {crc3[13], crc2[13], crc1[13], crc0[13]};
        4'b0011:        tx_crc_nybble = {crc3[12], crc2[12], crc1[12], crc0[12]};
        4'b0100:        tx_crc_nybble = {crc3[11], crc2[11], crc1[11], crc0[11]};
        4'b0101:        tx_crc_nybble = {crc3[10], crc2[10], crc1[10], crc0[10]};
        4'b0110:        tx_crc_nybble = {crc3[9], crc2[9], crc1[9], crc0[9]};
        4'b0111:        tx_crc_nybble = {crc3[8], crc2[8], crc1[8], crc0[8]};
        4'b1000:        tx_crc_nybble = {crc3[7], crc2[7], crc1[7], crc0[7]};
        4'b1001:        tx_crc_nybble = {crc3[6], crc2[6], crc1[6], crc0[6]};
        4'b1010:        tx_crc_nybble = {crc3[5], crc2[5], crc1[5], crc0[5]};
        4'b1011:        tx_crc_nybble = {crc3[4], crc2[4], crc1[4], crc0[4]};
        4'b1100:        tx_crc_nybble = {crc3[3], crc2[3], crc1[3], crc0[3]};
        4'b1101:        tx_crc_nybble = {crc3[2], crc2[2], crc1[2], crc0[2]};
        4'b1110:        tx_crc_nybble = {crc3[1], crc2[1], crc1[1], crc0[1]};
        4'b1111:        tx_crc_nybble = {crc3[0], crc2[0], crc1[0], crc0[0]};
      endcase
   end

   assign tx_crc_enable = sd_clk_falling &&
                          (tx_state == `SD_DTX_DATA_OUT);
   assign tx_crc_clear = (tx_state == `SD_DTX_WAIT_NWR);
   assign tx_crc_data = wide_bus ? tx_nybble : {3'h0, tx_bit};

endmodule
