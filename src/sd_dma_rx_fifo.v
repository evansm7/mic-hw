/* sd_dma_rx_fifo: SD host interface RX FIFO
 *
 * Wrap up some fiddly buffering duties:  provide FIFO buffering from
 * data RX path to DMA write path.
 *
 * For MIC, the DMA path is 64b and the SD data path is 32b; this module
 * thunks the up-conversion.
 *
 * FIFO is 64b wide (matching MIC) but of configurable depth, in units of
 * the "chunk" (matching the MIC burst size, which must be committed-to).
 *
 * ME 18 Mar 2022
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

module sd_dma_rx_fifo(input wire         clk,
                      input wire         reset,

                      input wire         dp_ptr_reset,
                      input wire         dp_write_strobe,
                      input wire [31:0]  dp_wdata,
                      output wire        dp_overflow,

                      input wire         dma_ptr_reset,
                      input wire         dma_read_strobe,
                      output wire [63:0] dma_rdata,
                      /* Read can be performed this cycle: */
                      output wire        can_read_now,

                      /* In general, there is data to read
                       * (though not necessarily this cycle):
                       */
                      output wire        data_chunk_ready
                      );

   parameter DMA_CHUNK_L2 = 3;                  // 2**3=8x64b = one "chunk" of 64 bytes
   parameter NUM_CHUNKS_L2 = 2;
   parameter FIFO_SIZE_L2 = (DMA_CHUNK_L2+NUM_CHUNKS_L2);


   ////////////////////////////////////////////////////////////////////////////////
   // FIFO storage

   reg [63:0]                   buffer_mem[(1 << FIFO_SIZE_L2)-1:0];
   wire [FIFO_SIZE_L2-1:0]      ram_addr;
   wire [63:0]                  ram_wr_data;
   reg [63:0]                   ram_rd_data;
   wire                         ram_EN;
   wire                         ram_WE;

   always @ (posedge clk) begin
      if (ram_EN) begin
         if (ram_WE) begin
            buffer_mem[ram_addr][63:0] <= ram_wr_data[63:0];
         end
         ram_rd_data[63:0] <= buffer_mem[ram_addr][63:0];
      end
   end

   wire [FIFO_SIZE_L2-1:0]      dp_write_addr;
   wire                         dp_write_req;
   wire [FIFO_SIZE_L2-1:0]      dma_read_addr;
   wire                         dma_read_req;

   /* FIFO storage access arbiter:
    * DP write always wins (it cannot be throttled, whereas MIC/DMA read can
    * take pushback).
    */
   wire                         do_ram_write = dp_write_req;
   wire                         do_ram_read  = dma_read_req;
   assign ram_EN                             = do_ram_read | do_ram_write;
   assign ram_WE                             = do_ram_write;
   assign ram_addr                           = do_ram_write ? dp_write_addr :
                                               do_ram_read ? dma_read_addr :
                                               {FIFO_SIZE_L2{1'bx}};


   ////////////////////////////////////////////////////////////////////////////////
   // Datapath <-> FIFO

   // Using port A, write RX'd data into the buffer:
   reg [31:0]                   dp_dw_staging;
   reg [FIFO_SIZE_L2+1:0]       dp_idx;
   wire                         dp_wrap     = dp_idx[FIFO_SIZE_L2+1];
   wire [FIFO_SIZE_L2-1:0]      dp_fifo_ptr = dp_idx[FIFO_SIZE_L2:1];
   wire [FIFO_SIZE_L2-4:0]      dp_chunk    = dp_fifo_ptr[FIFO_SIZE_L2-1:3];
   wire                         can_write_dp;

   assign dp_overflow   = dp_write_strobe && !can_write_dp;

   always @(posedge clk)
      if (reset) begin
         dp_idx <= 0;
      end else begin
         if (dp_ptr_reset) begin
            dp_idx <= 0;
         end else if (dp_write_strobe && can_write_dp) begin
            dp_idx <= dp_idx + 1;
            // Capture 32b into 1/2 64b on even-numbered writes...
            if (!dp_idx[0])
              dp_dw_staging <= dp_wdata;
            // ...and the 64b word is written to RAM on odd-numbered writes.
         end
      end

   assign dp_write_addr = dp_fifo_ptr;
   assign dp_write_req  = dp_write_strobe && dp_idx[0];
   assign ram_wr_data   = {dp_wdata, dp_dw_staging};


   ////////////////////////////////////////////////////////////////////////////////
   // DMA <-> FIFO

   reg [FIFO_SIZE_L2:0]         dma_idx;
   wire                         dma_wrap     = dma_idx[FIFO_SIZE_L2];
   wire [FIFO_SIZE_L2-1:0]      dma_fifo_ptr = dma_idx[FIFO_SIZE_L2-1:0];
   wire [FIFO_SIZE_L2-4:0]      dma_chunk    = dma_fifo_ptr[FIFO_SIZE_L2-1:3];
   reg [63:0]                   dma_output_capture;
   reg                          dma_output_select;
   reg                          dma_read_req_last;
   wire [63:0]                  held_ram_data;

   always @(posedge clk) begin
      if (dma_ptr_reset) begin
         dma_idx <= 0;
      end else if (dma_read_req) begin
         dma_idx <= dma_idx + 1;
      end

      /* Capture RAM read data, so it can be held
       * constant for DMA to (later) capture.
       * This protects against ram_rd_data changing
       * because of a dp_write_req.
       */
      if (dma_read_req)
        dma_output_select <= 1;
      else
        dma_output_select <= 0;

      dma_read_req_last   <= dma_read_req;

      if (dma_read_req_last)
        dma_output_capture <= ram_rd_data;

      if (reset) begin
         dma_idx            <= 0;
         dma_output_select  <= 0;
         dma_output_capture <= 0;
         dma_read_req_last  <= 0;
      end
   end

   assign held_ram_data  = dma_output_select ? ram_rd_data : dma_output_capture;
   assign dma_read_addr  = dma_idx;
   assign dma_rdata      = held_ram_data;
   assign dma_read_req   = dma_read_strobe && can_read_now;
   /* Stops read if a DP write is going on (it wins) */
   assign can_read_now   = data_chunk_ready && !dp_write_req;


   ////////////////////////////////////////////////////////////////////////////////
   // FIFO status

   // Read if not empty.  (Empty if R==W and wrap bits same.)
   assign data_chunk_ready = (dp_chunk != dma_chunk) || (dma_wrap != dp_wrap);
   // Can write if not full.  (Full if R==W and wrap bits differ.)
   assign can_write_dp = (dp_chunk != dma_chunk) || (dma_wrap == dp_wrap);

endmodule // sd_dma_fifo
