/* sd_dma_ctrl_mic: SD host interface DMA unit (for MIC)
 *
 * DMA control logic (specialised for MIC interface) for SD RX/TX streams
 *
 * Refactored out of top level 8 Apr 2022 ME
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

module sd_dma_ctrl_mic(input wire         clk,
                       input wire         reset,

                       /* MIC request port out */
                       output wire        O_TVALID,
                       input wire         O_TREADY,
                       output wire [63:0] O_TDATA,
                       output wire        O_TLAST,

                       /* MIC response port in */
                       input wire         I_TVALID,
                       output wire        I_TREADY,
                       input wire [63:0]  I_TDATA,
                       input wire         I_TLAST,

                       input wire         tx_pending,
                       output wire [31:0] tx_data_out,
                       input wire         tx_data_strobe,
                       input wire         tx_block_starting,
                       input wire         tx_block_is_first,
                       output wire        tx_data_ready,

                       input wire         rx_pending,
                       input wire [31:0]  rx_data_in,
                       input wire         rx_data_strobe,
                       input wire         rx_block_starting,
                       input wire         rx_block_is_first,
                       output wire        rx_dma_done,

                       input wire [31:0]  dma_addr,
                       output reg [1:0]   dma_status,
                       output wire        dma_busy
                       );

   parameter DMA_CHUNK_L2                                = 3;   // Beats in a chunk: 2**3 = 8 beats = 64B
   localparam DMA_CHUNK                                  = (1 << DMA_CHUNK_L2);
   /* FIXME: Parameters for TX/RX FIFO sizes */

   wire                                   tx_buffer_init = tx_block_starting && tx_block_is_first;
   wire                                   rx_buffer_init = rx_block_starting && rx_block_is_first;

   wire                                   tx_dma_unf;
   wire                                   rx_dma_ovf;

   wire                                   req_ready;
   wire                                   req_start;
   wire                                   req_RnW;
   wire [31:0]                            req_address;
   wire [4:0]                             req_byte_enables = 5'b11000; // 64b

   wire [63:0]                            read_data;
   wire [63:0]                            write_data;
   wire                                   read_data_valid;
   wire                                   read_data_ready;
   wire                                   write_data_ready;
   reg                                    write_data_valid;
   wire [7:0]                             req_beats = (DMA_CHUNK-1);


   /* MIC interface */

   mic_m_if #(.NAME("MIC_SD"))
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
                 .req_beats(req_beats),
                 .req_address(req_address[31:3]),
                 .req_byte_enables(req_byte_enables),

                 .read_data(read_data),
                 .read_data_valid(read_data_valid),
                 .read_data_ready(read_data_ready),

                 .write_data(write_data),
                 .write_data_valid(write_data_valid),
                 .write_data_ready(write_data_ready)
                 );


   /* RX and TX FIFOs interfacing to the datapath components:
    * They buffer between the firehose of SD and the flow-controlled
    * interconnect, but also up/downsize 32-to-64.
    */
   wire                                  dma_read_strobe;
   wire                                  dma_chunk_ready_to_read;
   wire                                  dma_can_read_fifo_now;

   sd_dma_rx_fifo #(.DMA_CHUNK_L2(DMA_CHUNK_L2),
                    .NUM_CHUNKS_L2(2)           /* 4 chunks in size (256B) */
                    )
                  DMARXFIFO(.clk(clk),
                            .reset(reset),
                            // Two ports, "DMA side" (64b) and "DP side" (32b)
                            .dp_ptr_reset(rx_buffer_init),
                            .dp_write_strobe(rx_data_strobe),
                            .dp_wdata(rx_data_in),
                            .dp_overflow(rx_dma_ovf),

                            .dma_ptr_reset(rx_buffer_init),
                            .dma_read_strobe(dma_read_strobe),
                            .dma_rdata(write_data),
                            .can_read_now(dma_can_read_fifo_now),
                            .data_chunk_ready(dma_chunk_ready_to_read)
                            );


   wire                                  tx_fifo_read_ready;
   sd_dma_tx_fifo #(.DMA_CHUNK_L2(DMA_CHUNK_L2),
                    .NUM_CHUNKS_L2(2)           /* 4 chunks in size (256B) */
                    )
                  DMATXFIFO(.clk(clk),
                            .reset(reset),

                            .dp_ptr_reset(tx_buffer_init),
                            .dp_read_strobe(tx_data_strobe), /* Only valid if dp_can_read! */
                            .dp_rdata(tx_data_out),
                            .dp_can_read(tx_data_ready),
                            .dp_underflow(tx_dma_unf),

                            .dma_ptr_reset(tx_buffer_init),
                            .dma_data_valid(read_data_valid),
                            .dma_data_ready(tx_fifo_read_ready),
                            .dma_wdata(read_data)
                            );


   /* Main FSM/DMA control for read and write */

   reg [2:0]                            dma_state;
   reg [(8*8)-1:0]                      dma_state_name;
   /* FIXME: Max DMA size is 16b of block size times 64 beats per block is
    * 22 bits. This is excessive!  Really don't need 32MB block reads and this
    * can be broken down, e.g. to 1MB (17 bits) max.
    */
   reg [21:0]                           dma_counter;
   wire [21:0]                          dma_chunks_done = dma_counter[21:3];
   wire [2:0]                           dma_idx = dma_counter[2:0];
   reg                                  dma_rd_start;
   reg                                  dma_wr_start;
   wire                                 dma_last_beat = (dma_idx == DMA_CHUNK-1); // FIXME size

`define SD_DS_IDLE      0
`define SD_DS_WR_WAIT   1
`define SD_DS_WR_PREP   2
`define SD_DS_WR_DO     3
`define SD_DS_WAITRDY   4
`define SD_DS_RD_WAIT   5
`define SD_DS_RD_DI     6

   always @(posedge clk) begin
      case (dma_state)
        `SD_DS_IDLE: begin
           if (rx_block_starting) begin // RX starting (could use rx_pending :P )
              if (rx_block_is_first) begin
                 dma_counter <= 0;
              end
              dma_state      <= `SD_DS_WR_WAIT;
              dma_state_name <= "WRWAIT";
           end else if (tx_block_starting) begin
              if (tx_block_is_first) begin
                 dma_counter <= 0;
              end
              dma_state      <= `SD_DS_RD_WAIT;
              dma_state_name <= "RDWAIT";
           end
        end

        `SD_DS_WR_WAIT: begin
           if (!rx_pending) begin
              /* RX is complete.  (Possibly because an RX timed out or
               * there was a CRC error.)  In any case, return to IDLE:
               */
              dma_state            <= `SD_DS_IDLE;
              dma_state_name       <= "IDLE";
           end else begin
              /* RX is still ongoing, so wait for a new chunk to transfer: */
              if (req_ready && dma_chunk_ready_to_read) begin
                 dma_wr_start         <= 1;
                 dma_state            <= `SD_DS_WR_PREP;
                 dma_state_name       <= "WRPREP";
              end
           end
        end

        `SD_DS_WR_PREP: begin        // NOTE: First FIFO DWORD read is enabled here
           dma_wr_start <= 0;
           if (dma_can_read_fifo_now) begin
              dma_state        <= `SD_DS_WR_DO;
              dma_state_name   <= "WRDO";
              write_data_valid <= 1'b1;
           end
        end

        `SD_DS_WR_DO: begin
           /* We're juggling two things here, a source that might not be
            * readable in any given cycle (!dma_can_read_fifo_now) and a sink
            * that might not be writable (!write_data_ready).
            *
            *  Possibilities here:
            * - write_data_ready (WDR)=0, meaning MIC is busy and holding us off.
            *   Don't get new data, don't increment counter -- hold current
            *   values.
            * - WDR=1, and can read fifo: MIC captures current data and we fetch
            *   new data for next cycle (inc counter tracking fetches)
            * - WDR=1 but can't read fifo: MIC captures current data, must
            *   wait to fetch new data.  Must mark write_data_valid=0 as next
            *   cycle's data isn't valid (won't have read FIFO).
            *   Note the last beat tends to hit this case anyway, so we
            *   still inc counter & change state if necessary!
            *
            * Decouple the two:
            * If we've previously read valid data (write_data_valid) and WDR,
            * then either consume the data (WDR=0) or consume the data and
            * fetch new data (WDR stays 1).
            *
            * If we've got valid data, we have to wait if !dma_can_read_fifo_now,
            * or if consumer isn't consuming (!write_data_ready).
            */

           /* Deal with MIC writes and buffer validity */
           if (write_data_ready) begin
              if (dma_can_read_fifo_now && !dma_last_beat) begin
                 /* Data is being read, see dma_read_strobe */
                 write_data_valid    <= 1'b1;
              end else begin
                 /* Current data consumed, but can't read new data yet. */
                 write_data_valid    <= 1'b0;
              end

              /* Deal with state */

              /* If it just consumed the last beat, we're done - move on.
               * Make sure the counter's updated though, because this
               * cycle might not have dma_can_read_fifo_now etc. to do
               * this below.
               */
              if (dma_last_beat) begin
                 write_data_valid  <= 1'b0;
                 dma_state         <= `SD_DS_WR_WAIT;
                 dma_state_name    <= "WRWAIT";
                 dma_counter       <= dma_counter + 1;
              end
           end

           /* Deal with FIFO reads */
           if (dma_can_read_fifo_now &&
               (write_data_ready || /* Consume-and-update in same cycle */
                !write_data_valid)  /* Or, no valid data so update OK anyway */
               ) begin

              if (!dma_last_beat) begin
                 dma_counter <= dma_counter + 1;

                 // dma_read_strobe is asserted here!
                 write_data_valid     <= 1'b1;
                 /* Fiddly, but note that assignment is mutually
                  * exclusive to those in the if(WDR) above!
                  */
              end
           end // if (dma_can_read_fifo_now &&...
        end

        `SD_DS_RD_WAIT: begin
           /* Wait for there to be FIFO space - not super necessary
            * because individual beats are throttled if FIFO is full, but
            * spaces requests out a bit.
            *
            * But first, bomb back to IDLE if tx request has gone away.
            */
           if (!tx_pending) begin
              dma_state      <= `SD_DS_IDLE;
              dma_state_name <= "IDLE";
           end else if (read_data_ready) begin
              dma_rd_start   <= 1;
              dma_state      <= `SD_DS_RD_DI;
              dma_state_name <= "RDDI";
           end
        end

        `SD_DS_RD_DI: begin
           /* In this state, we've committed to MIC to read all of one block.
            * If the request goes away early (tx_pending = 0) then we must
            * sink data (even if the FIFO is full, which can happen when the TX
            * datapath dies/times out on something).  read_data_ready is forced
            * active (regardless of FIFO readiness) if !tx_pending anymore.
            */
           dma_rd_start      <= 0;
           if (read_data_valid && read_data_ready) begin
              dma_counter    <= dma_counter + 1;
              if (dma_last_beat) begin
                 dma_state         <= `SD_DS_RD_WAIT;
                 dma_state_name    <= "RDWAIT";
              end
           end
        end

      endcase // case (dma_state)

      if (reset) begin
         dma_state        <= `SD_DS_IDLE;
         dma_state_name   <= "IDLE";
         dma_rd_start     <= 0;
         dma_wr_start     <= 0;
         write_data_valid <= 0;
      end
   end


   /* Capture overflow/underflow into DMA status: */
   always @(posedge clk) begin
      if (dma_state == `SD_DS_IDLE && ((rx_block_starting && rx_block_is_first) ||
                                       (tx_block_starting && tx_block_is_first) )) begin
         dma_status <= 2'b00;
      end else if (rx_dma_ovf) begin
         dma_status  <= 2'b01;
      end else if (tx_dma_unf) begin
         dma_status  <= 2'b10;
      end

      if (reset) begin
         dma_status     <= 2'b00;
      end
   end


   /* The RX control FSM will wait for rx_dma_done to ensure previous data's
    * in memory before flagging RX being complete.
    */
   assign rx_dma_done       = ((dma_state == `SD_DS_IDLE) ||
                               (dma_state == `SD_DS_WR_WAIT)) &&
                              !dma_chunk_ready_to_read /* And no more data backed up */ &&
                              req_ready;
   /* See the comment in SD_DS_RD_DI: if the request goes away we must be
    * able to sink data until the end of the burst, even if the FIFO's full.
    */
   assign read_data_ready   = tx_fifo_read_ready || !tx_pending;

   assign dma_busy          = (dma_state != `SD_DS_IDLE); // For SW
   /* Confusing name - DMA /FIFO/ read, i.e. data for DMA write! */
   assign dma_read_strobe   = dma_can_read_fifo_now && ((dma_state == `SD_DS_WR_PREP) ||
                                                        (dma_state == `SD_DS_WR_DO &&
                                                         !dma_last_beat &&
                                                         (write_data_ready ||
                                                          !write_data_valid)));
   assign req_start         = dma_wr_start || dma_rd_start;
   assign req_address       = dma_addr + {dma_chunks_done, 6'h0};
   assign req_RnW           = dma_rd_start; /* 0 whenever dma_wr_start asserted! */

endmodule // sd_dma_ctrl_mic
