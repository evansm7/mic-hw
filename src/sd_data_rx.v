/* sd_data_rx: SD host interface receive datapath
 *
 * Once activated, watches SD data lines for start bit, and decodes data
 * into a 32b word on rx_data_out (plus strobe, rx_data_strobe) for external
 * FIFO/DMA/storage.  Deals with CRC/timeouts etc. and RX status/completion.
 * Activated by rx_pending, and rx_trigger (from completion of a command initiating
 * the read from the card).  rx_trigger decouples SW activation of an RX and SW's
 * issuance of the READ command, i.e. you don't time out if SW is slow because
 * this module waits for a command completion before getting impatient for data.
 *
 * Data count:
 * A block size is given in (32b) words, up to 128 (== 512 bytes).  Blocks <512B
 * are only intended to be used for things like status (64B) or SCR (8B) reads.
 *
 * An overall transfer can (with CMD23) be multi-block, in which case rx_blocks_len_m1
 * indicates the number of blocks in the transfer minus one.  E.g. for 4KB, "7" indicates
 * 8 blocks total.  The block size must be 512B when multi-block transfers are used.
 *
 * DMA handshakes:
 *
 * The rx_data_out channel, and associated signals, spews data into an external DMA
 * unit.  Signals indicate to the DMA unit what data is "first" (thus written at the
 * start of the DMA buffer) and what data is just a continuance.  To avoid the DMA
 * unit having to duplicate counting rx_blocks_len, there is a difference between the
 * start of a transfer and the start of a block within the transfer: rx_block_starting
 * strobes at the start of a block; if rx_block_first is ALSO asserted then the DMA
 * unit should initialise its write pointer to the buffer start; otherwise, the DMA
 * unit prepares to write a block carrying on from the previous.
 *
 * 11 March 2022, ME
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

module sd_data_rx(input wire         clk,
                  input wire         reset,

                  // SD stuff
                  input wire [3:0]   sd_din,
                  input wire         sd_clk_rising,

                  input wire         wide_bus,

                  // Data channel for received data:
                  output wire [31:0] rx_data_out,
                  output wire        rx_data_strobe,
                  output wire        rx_block_starting,
                  output wire        rx_block_is_first,

                  input wire         rx_dma_done,

                  input wire         ms_pulse,

                  // RX control/completion:
                  input wire         rx_pending,
                  input wire         rx_trigger,
                  input wire [7:0]   rx_words_len, /* Exact */
                  input wire [15:0]  rx_blocks_len_m1, /* Minus 1 */

                  output reg [1:0]   rx_status,
                  output reg         rx_ack,
                  output wire        rx_is_idle,

                  output wire        rx_crc_enable,
                  output wire        rx_crc_clear,
                  input wire [15:0]  crc0,
                  input wire [15:0]  crc1,
                  input wire [15:0]  crc2,
                  input wire [15:0]  crc3,

                  /* Debugging/visibility of stuff: */
                  output wire [15:0] rx_crc0,
                  output wire [15:0] rx_crc1,
                  output wire [15:0] rx_crc2,
                  output wire [15:0] rx_crc3
                  );

   parameter RX_TIMEOUT = 200;  // ms

   reg [8:0]       rx_timeout;
   reg [(8*6)-1:0] rx_state_name;
   reg [2:0]       rx_state;
   reg [12:0]      rx_count;
   reg [15:0]      rx_block_count;
   reg [31:0]      rx_data_partial;

   reg [15:0]      rx_rd_crc0;
   reg [15:0]      rx_rd_crc1;
   reg [15:0]      rx_rd_crc2;
   reg [15:0]      rx_rd_crc3;
   wire            rx_data_crc_correct;

   wire            rx_got_start_bit = (sd_din[0] == 0);
   reg             rx_dma_saw_overflow;

   assign rx_crc0 = rx_rd_crc0;
   assign rx_crc1 = rx_rd_crc1;
   assign rx_crc2 = rx_rd_crc2;
   assign rx_crc3 = rx_rd_crc3;

`define SD_DRX_IDLE             0
`define SD_DRX_WAITSTART        1
`define SD_DRX_DIN              2
`define SD_DRX_WAITEND          3
`define SD_DRX_WAITDMADONE      4
`define SD_DRX_PAD_DATA         5

   always @(posedge clk) begin
      case (rx_state)
        `SD_DRX_IDLE:
          if (rx_pending && rx_trigger) begin
             rx_state_name    <= "WAITS";
             rx_state         <= `SD_DRX_WAITSTART;
             rx_timeout       <= RX_TIMEOUT;
             rx_block_count   <= 0;
             rx_status        <= 0;
          end

        `SD_DRX_WAITSTART: begin
           // NOTE: CRC is reset in this state!
           if (sd_clk_rising) begin
              // Look for all D, or just D[0]??
              if (rx_got_start_bit) begin
                 // NOTE: RX buffer is initialised on this transition
                 rx_state_name    <= "DATAI";
                 rx_state         <= `SD_DRX_DIN;
                 rx_count         <= 0;
              end else begin
                 if (rx_timeout == 0) begin
                    rx_status     <= 2'b01;
                    rx_state_name <= "WAITD";
                    rx_state      <= `SD_DRX_WAITDMADONE;
                 end
              end
           end
           if (ms_pulse && rx_timeout != 0)
             rx_timeout <= rx_timeout - 1;
        end

        `SD_DRX_DIN:
          if (sd_clk_rising) begin
             if (wide_bus) begin
                // Capture nybbles MSB-first
                rx_data_partial[31:0] <= {sd_din, rx_data_partial[31:4]};

                /* Every 8 beats, write captured data to the RAM -- except on
                 * beat zero, and limited to the first rx_words_len beats.
                 *
                 * See rx_data_strobe, below.
                 */

                // Capture the CRC data on each of the 4 data bits, separately:
                if (rx_count >= (rx_words_len*4*2)) begin
                   rx_rd_crc0[15:0] <= {rx_rd_crc0[14:0], sd_din[0]};
                   rx_rd_crc1[15:0] <= {rx_rd_crc1[14:0], sd_din[1]};
                   rx_rd_crc2[15:0] <= {rx_rd_crc2[14:0], sd_din[2]};
                   rx_rd_crc3[15:0] <= {rx_rd_crc3[14:0], sd_din[3]};
                end

                // Ew, maths, FIXME:
                if (rx_count == (rx_words_len*4*2) + 16 - 1 /* 16b CRC */) begin
                   rx_state_name      <= "WAITE";
                   rx_state           <= `SD_DRX_WAITEND;
                end else begin
                   rx_count   <= rx_count + 1;
                end

             end else begin // if (wide_bus)
                /* Same, but for 1-bit mode.  Capture MSB (first) into highest bit.
                 * Later, we'll reverse the bytes so the first byte is written to
                 * memory lowest!
                 */
                rx_data_partial[31:0] <= {rx_data_partial[30:0], sd_din[0]};

                if (rx_count >= (rx_words_len*4*8)) begin
                   rx_rd_crc0[15:0]   <= {rx_rd_crc0[14:0], sd_din[0]};
                end

                if (rx_count == (rx_words_len*4*8) + 16 - 1 /* 16b CRC */) begin
                   rx_state_name      <= "WAITE";
                   rx_state           <= `SD_DRX_WAITEND;
                end else begin
                   rx_count   <= rx_count + 1;
                end
             end
          end // if (sd_clk_rising)

        `SD_DRX_WAITEND:
          if (sd_clk_rising) begin
             /* Set the status (unless a previous block in the same transfer
              * had an unsuccessful status result, which is "sticky"):
              */
             if (rx_status == 2'b00) begin
                if ((wide_bus && sd_din != 4'b1111) || (sd_din[0] != 1))
                  rx_status   <= 2'b10;
                else if (!rx_data_crc_correct)
                  rx_status   <= 2'b11;
             end

             rx_block_count   <= rx_block_count + 1;
             /* Are there more (multi-block) transfers to receive? */
             if (rx_block_count != rx_blocks_len_m1) begin
                rx_state_name <= "WAITS";
                rx_state      <= `SD_DRX_WAITSTART;
                rx_timeout    <= RX_TIMEOUT;
                /* Note: We still do this even if a previous block's CRC
                 * failed, as the card doesn't know this and will continue
                 * to spew data!  We have to wait it out and retry later.
                 * (OK, we could IRQ and flag this, and get SW to issue
                 * CMD12, but for smallish transfers unlikely to be a big win
                 * in an error case.)
                 */
             end else begin
                /* The SD card transfer is done, but two more outcomes here:
                 * 1. The DMA transfer will complete with exactly a chunk of data
                 *    (common case for read/write, or 512b status read).
                 * 2. The data volume is smaller than a DMA chunk (64B) and
                 *    the output stream needs to be padded to this size
                 *    (niche case for things like 64b SCR read).
                 */
                if (rx_words_len[3:0] != 4'h0) begin
                   rx_state_name      <= "PADZ";
                   rx_state           <= `SD_DRX_PAD_DATA;
                   rx_data_partial    <= 32'h0;
                   rx_count           <= 0;
                end else begin
                   // The transfer is a multiple of 64B in size; drain DMA & we're done.
                   rx_state_name      <= "WAITD";
                   rx_state           <= `SD_DRX_WAITDMADONE; // FIXME: drain/high-Z state
                end
             end
          end

        `SD_DRX_PAD_DATA:
          /* Output some dummy strobes to pad the output data to
           * meet the minimum requirements of a DMA chunk (so that DMA
           * doesn't have to support arbitrarily-small writes)
           */
          if (sd_clk_rising /* Consistent but not necessary!*/) begin
             if (rx_count == 15-rx_words_len[3:0]) begin
                rx_state_name <= "WAITD";
                rx_state      <= `SD_DRX_WAITDMADONE;
             end else begin
                rx_count      <= rx_count + 1;
             end
          end

        `SD_DRX_WAITDMADONE:
          /* Don't flag RX completion until the DMA has drained */
          if (rx_dma_done) begin
             rx_ack        <= ~rx_ack;
             rx_state_name <= "IDLE";
             rx_state      <= `SD_DRX_IDLE;
          end
      endcase // case (rx_state)

      if (reset) begin
        rx_state_name  <= "IDLE";
        rx_state       <= `SD_DRX_IDLE;
        rx_ack         <= 0;
        rx_status      <= 0;
      end
   end

   assign rx_is_idle = (rx_state == `SD_DRX_IDLE);

   assign rx_block_starting = (rx_state == `SD_DRX_WAITSTART) &&
                              sd_clk_rising && rx_got_start_bit;
   assign rx_block_is_first = (rx_block_count == 0);

   /* Note, last RAM write occurs on the first CRC transfer beat: */
   assign rx_data_strobe = ((rx_state == `SD_DRX_DIN) && sd_clk_rising && (rx_count != 13'h0) &&
                            (wide_bus ?
                             ((rx_count[2:0] == 3'b000) && (rx_count <= (rx_words_len*4*2))) :
                             ((rx_count[4:0] == 5'b00000) && (rx_count <= (rx_words_len*4*8))))) ||
                           ((rx_state == `SD_DRX_PAD_DATA) && sd_clk_rising);

   /* Re-order nybbles on RAM write: */
   assign rx_data_out = wide_bus ?
                        {rx_data_partial[27:24],
                         rx_data_partial[31:28],
                         rx_data_partial[19:16],
                         rx_data_partial[23:20],
                         rx_data_partial[11:8],
                         rx_data_partial[15:12],
                         rx_data_partial[3:0],
                         rx_data_partial[7:4]} :
                        {rx_data_partial[7:0],
                         rx_data_partial[15:8],
                         rx_data_partial[23:16],
                         rx_data_partial[31:24]};

   assign rx_data_crc_correct = wide_bus ?
                                ((crc0 == rx_rd_crc0) &&
                                 (crc1 == rx_rd_crc1) &&
                                 (crc2 == rx_rd_crc2) &&
                                 (crc3 == rx_rd_crc3)) : (crc0 == rx_rd_crc0);

   assign rx_crc_enable = sd_clk_rising &&
                          (rx_state == `SD_DRX_DIN) &&
                          (rx_count < (wide_bus ? (rx_words_len*4*2) : (rx_words_len*4*8)));

   assign rx_crc_clear = (rx_state == `SD_DRX_WAITSTART);

endmodule // sd_data_rx

