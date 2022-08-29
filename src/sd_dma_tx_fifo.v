/* sd_dma_tx_fifo: SD host interface TX FIFO
 *
 * Wrap up some fiddly buffering duties:  provide FIFO buffering from
 * 64-bit (MIC) DMA read path to 32-bit data TX path.
 *
 * Have decided to do this separately to the RX path/FIFO, with small
 * memory/FIFO sizes (instead of trying to share a BRAM).  A huge amount
 * of buffering is not required (likely 128-256B is sufficient) and KISS.
 *
 * The TX DP can't be halted once it starts (once it's told dp_can_read),
 * so any cycle asserting dp_read_strobe gets the memory port/address.
 * In such a cycle, if DMA is attempting to write, dma_data_ready=0 (which
 * stalls MIC, which is OK).  This means FIFO mem doesn't have to be
 * true dual-ported, giving the compiler better choice of its implementation.
 *
 * The FIFO operates on "chunks" (say 64 bytes) though its contents are
 * tracked at the dword level.  This allows (at least) one chunk to be
 * entirely buffered before we flag the FIFO as readable for the DP (which
 * will plough on), giving some time to be buffering the next.  It's
 * just one way to do a low/high water mark.
 *
 * ME 6 April 2022
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

module sd_dma_tx_fifo(input wire         clk,
                      input wire         reset,

                      input wire         dp_ptr_reset,
                      input wire         dp_read_strobe, /* Only valid if dp_can_read! */
                      output wire [31:0] dp_rdata,
                      output wire        dp_can_read,    /* A chunk can be read */
                      output wire        dp_underflow,

                      input wire         dma_ptr_reset,
                      input wire         dma_data_valid,
                      output wire        dma_data_ready,
                      input wire [63:0]  dma_wdata
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

   /* NOTE: The following RAM idiom is slightly annoying because the read enable
    * is not independent of the write enable.  It would be preferable to have
    * a read enable, holding the output data stable (to be consumed at leisure
    * of the downstream component).  However, ISE enjoys wasting integer days
    * of my time by quietly creating ROMs instead of RAMs (with independent RD
    * strobe, for sure).  This idiom is an attempt to avoid this sadness,
    * at the expense of having to manually capture/hold the output value (see
    * held_ram_data).
    */
   always @ (posedge clk) begin
      if (ram_EN) begin
         if (ram_WE) begin
            buffer_mem[ram_addr][63:0] <= ram_wr_data[63:0];
         end
         ram_rd_data[63:0] <= buffer_mem[ram_addr][63:0];
      end
   end

   wire [FIFO_SIZE_L2-1:0]      dp_read_addr;
   wire                         dp_read_req;
   wire [FIFO_SIZE_L2-1:0]      dma_write_addr;
   wire                         dma_write_req;

   // FIFO storage access arbiter
   wire                         do_ram_read  = dp_read_req;
   wire                         do_ram_write = !dp_read_req && dma_write_req;
   assign ram_EN                             = do_ram_read | do_ram_write;
   assign ram_WE                             = do_ram_write;
   assign ram_addr                           = do_ram_read ? dp_read_addr :
                                               do_ram_write ? dma_write_addr :
                                               {FIFO_SIZE_L2{1'bx}};


   ////////////////////////////////////////////////////////////////////////////////
   // FIFO -> Datapath

   // Using port A, read data from the buffer -- downsizing 64 to 32
   reg [FIFO_SIZE_L2+1:0]               dp_idx;         /* One extra bit of index for word count */
   wire                                 dp_wrap         = dp_idx[FIFO_SIZE_L2+1];
   wire [FIFO_SIZE_L2-1:0]              dp_fifo_ptr     = dp_idx[FIFO_SIZE_L2:1];
   wire [FIFO_SIZE_L2-DMA_CHUNK_L2-1:0] dp_chunk        = dp_fifo_ptr[FIFO_SIZE_L2-1:DMA_CHUNK_L2];
   reg [63:0]                           dp_output_capture;
   reg                                  dp_output_select;
   reg                                  dp_read_req_last;
   wire [63:0]                          held_ram_data;

   /* The RAM output will change when a write cycle occurs, due to the nature
    * of the enable/write-strobe.  In the cycle after the read (when the
    * RAM output is correct) we use the value directly whilst we capture it
    * for use in future cycles.
    */
   assign held_ram_data = dp_output_select ? ram_rd_data : dp_output_capture;
   assign dp_underflow  = dp_read_strobe && !dp_can_read;
   /* dp_idx will be "one on" at the time data is read, i.e. it points to
    * next read address.  So, when odd, output low word.
    */
   assign dp_rdata      = !dp_idx[0] ? held_ram_data[63:32] : held_ram_data[31:0];

   always @(posedge clk) begin
      if (dp_ptr_reset) begin
         dp_idx <= 0;
      end else if (dp_read_strobe && dp_can_read) begin
         dp_idx <= dp_idx + 1;
      end
      /* Hmm, if !can_read and a strobe, something's failed.
       * dp_underflow indicates this.
       */
      if (dp_read_req) begin
         dp_output_select <= 1;
      end else begin
         dp_output_select <= 0;
      end

      dp_read_req_last <= dp_read_req;

      if (dp_read_req_last)
        dp_output_capture <= ram_rd_data;

      if (reset) begin
         dp_idx            <= 0;
         dp_output_select  <= 0;
         dp_output_capture <= 0;
         dp_read_req_last  <= 0;
     end
   end

   assign dp_read_addr  = dp_fifo_ptr;
   assign dp_read_req   = dp_read_strobe && !dp_idx[0]; /* New read on even indices */


   ////////////////////////////////////////////////////////////////////////////////
   // DMA -> FIFO

   reg [FIFO_SIZE_L2:0]                 dma_idx;
   wire                                 dma_wrap     = dma_idx[FIFO_SIZE_L2];
   wire [FIFO_SIZE_L2-1:0]              dma_fifo_ptr = dma_idx[FIFO_SIZE_L2-1:0];
   wire [FIFO_SIZE_L2-DMA_CHUNK_L2-1:0] dma_chunk    = dma_fifo_ptr[FIFO_SIZE_L2-1:3];

   always @(posedge clk) begin
      if (dma_ptr_reset) begin
         dma_idx <= 0;
      end else if (dma_write_req) begin
         dma_idx <= dma_idx + 1;
      end

      if (reset) begin
         dma_idx <= 0;
      end
   end

   wire can_write_dma;
   /* This will put backpressure onto MIC if this cycle happens to compete with
    * the DP read port (which will win):
    */
   assign dma_data_ready        = can_write_dma && !dp_read_req;
   assign dma_write_req         = dma_data_valid && dma_data_ready;
   assign dma_write_addr        = dma_fifo_ptr;
   assign ram_wr_data           = dma_wdata;


   ////////////////////////////////////////////////////////////////////////////////
   // FIFO status

   /* Read if there is at least one *chunk* ready.  (Empty if R==W and wrap bits same.) */
   assign dp_can_read  = (dp_chunk != dma_chunk) || (dma_wrap != dp_wrap);
   /* Can write if not full.  (Full if R==W and wrap bits differ.)
    *
    * Choice of when to signal can_write_dma:
    * Could choose to compare chunks, but actually a DMA *beat*
    * can be written if dma_fifo_ptr != dp_fifo_ptr || dma_wrap == dp_wrap.
    * In the former, flow control happens at the chunk level, but dword is better.
    */
   assign can_write_dma = (dp_fifo_ptr != dma_fifo_ptr) || (dma_wrap == dp_wrap);

endmodule // sd_dma_fifo
