/*
 * m_blockcopy_apb
 *
 * A trivial bridge between APB (completer) and MIC (requester), allowing CPU on APB to
 * access a shared buffer and trigger transfers on MIC from the buffer.
 * (Actually, access one half at a time, to double-buffer.)
 * Buffer is 8KB (2x BRAMs of 2K, giving 64bit port on one side, and 32bit port
 * on APB side).
 * NOTE: Hmm, due to APB bridge limitations, no PREADY, synchronous read will be hard.
 * So, use an array, async read, and see what gets inferred; make the array small
 * so distributed RAM (or even FFs) is plausible, e.g. 64 bytes
 *
 * Arrangement of BRAMs is 32b ports; arranged as:
 *  - R0 port A[31:0]  read/written on APB when A[2]=0
 *  - R1 port A[31:0]  read/written on APB when A[2]=1
 *  - R0 port B[31:0]  read/written by MIC as D[31:0]
 *  - R1 port B[31:0]  read/written by MIC as D[63:32]
 * Only supports 32-bit APB accesses.
 * TODO: write strobes for 32-bit MIC access (current minimum 1 beat, not 0.5)
 *
 * Register interface:
 *
 * 0:   [0]       transfer_go
 *                Set to 1 to start; becomes 0 when complete
 *      [1]       transfer_RnW
 *                1 RD, 0 WR
 * 4:   [8:0]     transfer_beats
 *                Number of 8-byte transfers on MIC (max 512x8=4K)
 *      [18:16]   Offset of transfer in buffer (8 entries)
 * 8:   [31:3]    transfer_addr
 *                MIC-side address
 * 0x1000-0x1ffc: 32-bit access to buffer
 *
 * Copyright 2019-2021 Matt Evans
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

module m_blockcopy_apb(input wire         clk,
                       input wire         reset,

                       /* Request port out */
                       output wire        O_TVALID,
                       input wire         O_TREADY,
                       output wire [63:0] O_TDATA,
                       output wire        O_TLAST,

                       /* Response port in */
                       input wire         I_TVALID,
                       output wire        I_TREADY,
                       input wire [63:0]  I_TDATA,
                       input wire         I_TLAST,

                       /* APB interface */
                       input wire         PCLK,
                       input wire         PSEL,
                       input wire [31:0]  PWDATA,
                       output wire [31:0] PRDATA,
                       input wire         PENABLE,
                       input wire [12:0]  PADDR,
                       input wire         PWRITE
                       );

   parameter NAME = "Blockcopy";

   reg                                    transfer_go;
   reg                                    transfer_dir;
   reg [8:0]                              transfer_beats;
   reg [31:3]                             transfer_addr;
   reg [5:0]                              transfer_buf_addr;
   reg                                    mic_transfer_go[1:0]; /* W/ synchroniser */

   /* Handshakes:
    * A=0 B=0 -- do nothing
    * A=1 B=0 -- start request
    * A=1 B=1 -- request done, clear 'go', A=0
    * A=0 B=1 -- go idle, B=0
    *
    * Between 2 clock domains so need synchronisers.
    */
   reg                                    hs_a;
   reg [1:0]                              hs_a_sync;
   reg                                    hs_b;
   reg [1:0]                              hs_b_sync;

   ////////////////////////////////////////////////////////////////////////////////
   /* BRAM buffers */

   wire [31:0]                            apb_ram_out;

   // 64 bytes, 16 words, 8 dwords
   reg [63:0]                             ram_storage[7:0];

   wire [63:0]                            apb_ram_out_wide;
   assign apb_ram_out_wide = ram_storage[PADDR[5:3]];
   assign apb_ram_out = PADDR[2] ? apb_ram_out_wide[63:32] : apb_ram_out_wide[31:0];

   ////////////////////////////////////////////////////////////////////////////////
   /* APB interface */
   always @(posedge PCLK)
     if (reset) begin
        transfer_go <= 0;
        transfer_dir <= 0;
        transfer_beats <= 0;
        transfer_addr <= 0;

        hs_a <= 0;
        hs_b_sync[1:0] <= 2'h0;
     end else begin
        hs_b_sync[1:0] <= {hs_b_sync[0], hs_b};

        if (PSEL && PENABLE && PWRITE) begin
           // Reg write, PADDR[12:0]
           // capture PWDATA
           if (PADDR[12:0] == 13'h0000) begin
              transfer_go <= PWDATA[0];
              transfer_dir <= PWDATA[1];
           end else if (PADDR[12:0] == 13'h0004) begin
              transfer_beats <= PWDATA[7:0];
              transfer_buf_addr <= PWDATA[18:16];
           end else if (PADDR[12:0] == 13'h0008) begin
              transfer_addr <= PWDATA[31:3];
           end else if (PADDR[12] == 1) begin
              /* Writing RAM */
              if (PADDR[2]) begin
                 ram_storage[PADDR[5:3]][63:32] <= PWDATA[31:0];
              end else begin
                 ram_storage[PADDR[5:3]][31:0] <= PWDATA[31:0];
              end
           end
        end else begin // if (PSEL && PENABLE && PWRITE)
           if (!hs_a) begin
              if (transfer_go) begin
                 hs_a <= 1;
              end
           end else if (hs_a && hs_b_sync[1]) begin
              transfer_go <= 0;
              hs_a <= 0;
           end
        end // else: !if(PSEL && PENABLE && PWRITE)


     end // else: !if(reset)

   assign PRDATA = (PADDR[12:0] == 13'h0000) ? {30'h00000000, transfer_dir, transfer_go} :
                   (PADDR[12:0] == 13'h0004) ? {24'h000000, transfer_beats} :
                   (PADDR[12:0] == 13'h0008) ? {transfer_addr, 3'h0} :
                   (PADDR[12] == 1) ? apb_ram_out :
                   32'hcafebabe;

   ////////////////////////////////////////////////////////////////////////////////
   /* MIC interface */

   wire        req_ready;
   wire        req_start;

   /* This is sloppy; use the signals from a different clock domain directly
    /* without synchronisers.  However, we know these will be stable in the cycle
     /* that these are accessed. */
   wire        req_RnW = transfer_dir;
   wire [7:0]  req_beats = transfer_beats;
   wire [31:3] req_address = transfer_addr;

   wire [63:0] read_data;
   wire        read_data_valid;
   wire        read_data_ready;
   wire [63:0] write_data;
   wire        write_data_valid;
   wire        write_data_ready;

   mic_m_if #(.NAME("MICAPB"))
   mif (.clk(clk), .reset(reset),
        /* MIC signals */
        .O_TVALID(O_TVALID), .O_TREADY(O_TREADY),
        .O_TDATA(O_TDATA), .O_TLAST(O_TLAST),
        .I_TVALID(I_TVALID), .I_TREADY(I_TREADY),
        .I_TDATA(I_TDATA), .I_TLAST(I_TLAST),
        /* Control/data signals */
        .req_ready(req_ready), .req_start(req_start), .req_RnW(req_RnW),
        .req_beats(req_beats), .req_address(req_address),
	.req_byte_enables(5'h1f),

        .read_data(read_data), .read_data_valid(read_data_valid),
        .read_data_ready(read_data_ready),

        .write_data(write_data), .write_data_valid(write_data_valid),
        .write_data_ready(write_data_ready)
        );

   // argh dual-port how?
   // I don't know if Xilinx BRAMs support both async read and true dual-porting
   // HDL guide examples show two always blocks, different CLKs, assigning to RAM OK tho.

`define REQ_STATE_IDLE   0
`define REQ_STATE_RD     1
`define REQ_STATE_WR     2
`define REQ_STATE_WAIT   3

   reg [2:0]   req_state;
   reg [2:0]   trx_buf_addr;
   reg [8:0]   trx_count;

   assign read_data_ready = (req_state == `REQ_STATE_RD);
   assign req_start = (req_state == `REQ_STATE_IDLE) && req_ready && hs_a_sync[1];

   assign write_data = ram_storage[trx_buf_addr];
   assign write_data_valid = (req_state == `REQ_STATE_WR);


   always @(posedge clk)
     if (reset) begin
        req_state <= `REQ_STATE_IDLE;
        hs_b <= 0;
        hs_a_sync[1:0] <= 2'h0;

        trx_buf_addr <= 0;
        trx_count <= 0;
     end else begin
        hs_a_sync[1:0] <= {hs_a_sync[0], hs_a};

        case (req_state)
          `REQ_STATE_IDLE:
            begin
               if (req_ready && hs_a_sync[1]) begin
                  /* Start something */
                  hs_b <= 0;

                  if (req_RnW) begin
                     req_state <= `REQ_STATE_RD;
                  end else begin
                     req_state <= `REQ_STATE_WR;
                  end
                  trx_buf_addr <= transfer_buf_addr; /* Not synchronised */
                  trx_count <= 0;
                  /* req_start is asserted above */
               end
            end

          `REQ_STATE_RD:
            begin
               if (read_data_valid) begin
                  ram_storage[trx_buf_addr] <= read_data;

                  trx_buf_addr <= trx_buf_addr + 1;
                  if (trx_count == req_beats) begin
                     /* Done */
                     req_state <= `REQ_STATE_WAIT;
                     hs_b <= 1;
                  end else begin
                     trx_count <= trx_count + 1;
                  end
               end
            end

          `REQ_STATE_WR:
            begin
               /* write_data is assigned (async) from ram_storage */
               if (write_data_ready) begin
                  trx_buf_addr <= trx_buf_addr + 1;
                  if (trx_count == req_beats) begin
                     /* Done */
                     req_state <= `REQ_STATE_WAIT;
                     hs_b <= 1;
                  end else begin
                     trx_count <= trx_count + 1;
                  end
               end
            end

          `REQ_STATE_WAIT:
            begin
               /* hs_b is 1, wait for other FSM to notice/return hs_a to 0 */
               if (hs_a_sync[1] == 0) begin
                  hs_b <= 0;
                  req_state <= `REQ_STATE_IDLE;
               end
            end
        endcase
     end

endmodule
