/* SD host interface: top-level
 *
 * An SD host controller that's as simple as possible whilst being
 * fairly performant.  Supports SDR at up to sysclk/2 clock rates.
 *
 * Features:
 * - DMA for TX/RX and interrupts on TX/RX completion
 * - PIO for commands, with response capture
 * - CRC checking of command responses
 * - CRC16 generation and checking for TX/RX data
 * - Timeout monitoring of command completion, RX and TX
 *
 * Future possibilities:
 * - CRC7 generation for commands
 * - Linking of common commands and operations, e.g.
 *   one touch TX/RX command, response, and DMA.
 * - CMD23 addition, CMD12 (stop) generation.
 *
 * See corresponding mr-sd Linux driver.
 *
 *
 * Matt Evans, March-April 2022
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

/* Reg i/f:
 *
 * +00          RB0             [31:0] of Response buffer (R/O)
 * +04          RB1             [63:32]
 * +08          RB2             [95:64]
 * +0c          RB3             [128:64]
 * +10          CB0             [31:0] of Command buffer
 * +14          CB1             [47:32]
 * +18          CTRL            [0]             CmdReq: toggle (make different from CmdAck) to start cmd
 *                                                      Sends cmd, waits for response, toggles CmdAck
 *                              [3:2]           Response len:   00  None
 *                                                              10  48b
 *                                                              11  136b
 *                              [4]             RX_Req
 *                              [8]             TX_Req
 *                              [23]            Bus width:      0   1 bit
 *                                                              1   4 bits
 *                              [31:24]         CLKDIV
 * +1c          STATUS          [0]             CmdAck (cmd ongoing if different to CmdReq)
 *                              [1]             CmdInProgress (req != ack)
 *                              [3:2]           Command status: 00  success
 *                                                              01  timeout on resp start bit
 *                                                              10  Bad resp stop bit
 *                                                              11  Stop bit OK, but CRC bad
 *                              [4]             RX_Ack
 *                              [5]             RXInProgress
 *                              [7:6]           RX status:      00  Success
 *                                                              01  Timeout on data start bit
 *                                                              10  Bad data stop bit
 *                                                              11  Stop bit OK, but CRC bad
 *                              [8]             TX_Ack
 *                              [9]             TXInProgress
 *                              [11:10]         TX status:      00  Success
 *                                                              01  T/o on status, or t/o on non-busy
 *                                                              10  Bad ack stop bit
 *                                                              11  Ack received, but indicates CRC fail
 *                              [12]            DMA busy (outstanding I/C response)
 *                                              MUST wait for non-busy before starting another TX/RX!
 *                              [15:14]         DMA status:     00  Success
 *                                                              01  RX data overflow
 *                                                              10  TX data underflow
 *                              [31]            RX idle
 * +20          STATUS2         [15:0]          TX block count (should equal num transfer blocks,
 *                                              once TX complete - otherwise shows block of
 *                                              timeout/CRC error/whatever as per TX status).
 * +24
 * +28          RDCRC0          [15:0]          CRC of D0 line
 *                              [31:0]          CRC of D1
 * +2c          RDCRC1          [15:0]          CRC of D2
 *                              [31:0]          CRC of D3
 * +30          DATACFG         [7:0]           Number of 32b words in a block (>0)
 *                                              Note: if not 128 (512B), num blocks must
 *                                              be 0 (1 block).
 *                              [31:16]         Number of blocks to transfer, minus 1
 * +34
 * +38          DMA_ADDR        [31:3]          DMA base address
 * +3c          IRQ             [0]             RX_complete active (W1C)
 *                              [1]             TX_complete active (W1C)
 *                              [8]             Enable RX_complete IRQ
 *                              [9]             Enable TX_complete IRQ
 *
 * R1/R3/R6/R7 responses are 48b:  actually 46b, or 39 after command index/end bit
 * 136b R2 response has 128b payload (actually 127), start/T bits and 6 bits reserved.
 * So, 128b is enough.
 */

`include "sd_regs.vh"

`ifdef SIM
 `define INITIAL_CLKDIV         0
`else
 `define INITIAL_CLKDIV         63
`endif

module sd(input wire         clk,
          input wire         reset,

          /* Assume PCLK = clk */
          input wire         PENABLE,
          input wire         PSEL,
          input wire         PWRITE,
          input wire [31:0]  PWDATA,
          input wire [7:0]   PADDR,
          output wire [31:0] PRDATA,
          output wire        irq, /* Level, active high */

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

          output wire        sd_clk,
          input wire [3:0]   sd_data_in,
          output wire [3:0]  sd_data_out,
          output wire        sd_data_out_en,

          input wire         sd_cmd_in,
          output wire        sd_cmd_out,
          output wire        sd_cmd_out_en
          );

   parameter CLK_RATE = 50*1000*1000;

   parameter TX_TIMEOUT = 200;  // ms
   parameter RX_TIMEOUT = 200;  // ms


   ////////////////////////////////////////////////////////////////////////////////
   // IO/"phy": SDR for now!

   // Common signals
   wire              sd_clk_rising;
   wire              sd_clk_falling;

   wire [15:0]       crc_val0;
   wire [15:0]       crc_val1;
   wire [15:0]       crc_val2;
   wire [15:0]       crc_val3;
   wire              ms_pulse;


   ////////////////////////////////////////////////////////////////////////////////
   // Register interface/APB

   wire [127:0]      rb;
   reg [47:0]        cb; // FIXME: Really only needs 6+32+8=46
   wire              crb_busy;
   reg               cmd_req;
   wire              cmd_ack;
   reg               rx_req;
   wire              rx_ack;
   reg               tx_req;
   wire              tx_ack;
   reg [1:0]         cmd_resp_len;
   wire [1:0]        cmd_status;
   wire [1:0]        rx_status;
   wire              rx_idle;
   wire [1:0]        tx_status;
   wire [15:0]       rx_rd_crc0;
   wire [15:0]       rx_rd_crc1;
   wire [15:0]       rx_rd_crc2;
   wire [15:0]       rx_rd_crc3;
   reg [7:0]         blk_words_len;
   reg [15:0]        transfer_blks_len;
   wire [15:0]       tx_block_count;
   reg [7:0]         clkdiv_val;
   wire              cmd_pending = cmd_req != cmd_ack;
   wire              rx_pending = rx_req != rx_ack;
   wire              tx_pending = (tx_req != tx_ack) && !rx_pending;
   wire              dma_busy;
   reg [31:0]        dma_addr;
   wire [1:0]        dma_status;
   reg               irq_rx_active;
   reg               irq_rx_enable;
   reg               irq_tx_active;
   reg               irq_tx_enable;
   reg               bus_width_4;

   always @(posedge clk) begin
      /* APB register write */
      if (PSEL & PENABLE & PWRITE) begin
         case ({PADDR[7:2], 2'b00})
           `SD_REG_CB0:
             cb[31:0]       <= PWDATA[31:0];

           `SD_REG_CB1:
             cb[47:32]      <= PWDATA[15:0];

           `SD_REG_CTRL: begin
              cmd_req         <= PWDATA[0];
              cmd_resp_len    <= PWDATA[3:2];
              rx_req          <= PWDATA[4];
              tx_req          <= PWDATA[8];
              bus_width_4     <= PWDATA[23];
              clkdiv_val      <= PWDATA[31:24];
           end

           `SD_REG_DATACFG: begin
              blk_words_len     <= PWDATA[7:0];
              transfer_blks_len <= PWDATA[31:16];
           end

           `SD_REG_DMAADDR: begin
              dma_addr        <= {PWDATA[31:3], 3'h0};
           end

           `SD_REG_IRQ: begin
              irq_rx_enable   <= PWDATA[8];
              irq_tx_enable   <= PWDATA[9];
              /* Activity bits are dealt with below. */
           end
         endcase
      end // if (PSEL & PENABLE & PWRITE)

      if (reset) begin
         cmd_req           <= 0;
         cmd_resp_len      <= 0;
         rx_req            <= 0;
         clkdiv_val        <= `INITIAL_CLKDIV;
         tx_req            <= 0;
      end // else: !if(reset)
   end


   reg [31:0]        rd; // Wire

   /* APB register read */
   always @(*) begin
      rd = 32'h0;

      case ({PADDR[7:2], 2'b00})
        `SD_REG_RB0:            rd[31:0] = rb[31:0];
        `SD_REG_RB1:            rd[31:0] = rb[63:32];
        `SD_REG_RB2:            rd[31:0] = rb[95:64];
        `SD_REG_RB3:            rd[31:0] = rb[127:96];
        `SD_REG_CB0:            rd[31:0] = cb[31:0];
        `SD_REG_CB1:            rd[31:0] = {16'h0, cb[47:32]};
        `SD_REG_CTRL:           rd[31:0] = {clkdiv_val, bus_width_4, 7'h0, // 31:16
                                            4'h0,               // 15:12
                                            3'h0, tx_req,       // 11:8
                                            3'h0, rx_req,       // 7:4
                                            cmd_resp_len, 1'b0, cmd_req};
        `SD_REG_STATUS:         rd[31:0] = {rx_idle, 15'h0,
                                            dma_status, 1'b0, dma_busy,
                                            tx_status, tx_pending, tx_ack,
                                            rx_status, rx_pending, rx_ack,
                                            cmd_status, cmd_pending, cmd_ack};
        `SD_REG_STATUS2:        rd[31:0] = {16'h0, tx_block_count};
        `SD_REG_RCRC0:          rd[31:0] = {rx_rd_crc1, rx_rd_crc0};
        `SD_REG_RCRC1:          rd[31:0] = {rx_rd_crc3, rx_rd_crc2};
        `SD_REG_DATACFG:        rd[31:0] = {transfer_blks_len, 8'h00, blk_words_len};
        `SD_REG_DMAADDR:        rd[31:3] = dma_addr[31:3];
        `SD_REG_IRQ:            rd[15:0] = {6'h0, irq_tx_enable, irq_rx_enable,
                                            6'h0, irq_tx_active, irq_rx_active};
      endcase
   end

   assign       PRDATA = rd;


   /* Interrupt handling */
   reg rack_last;
   reg tack_last;

   always @(posedge clk) begin
      rack_last      <= rx_ack;
      tack_last      <= tx_ack;

      if (PSEL & PENABLE & PWRITE && {PADDR[7:2], 2'b00} == `SD_REG_IRQ) begin
         if (PWDATA[0])
           irq_rx_active <= 0;
         if (PWDATA[1])
           irq_tx_active <= 0;
      end else begin
         if (rx_ack != rack_last)
           irq_rx_active <= 1;
         if (tx_ack != tack_last)
           irq_tx_active <= 1;
      end

      if (reset) begin
         irq_rx_active  <= 0;
         irq_tx_active  <= 0;
         rack_last      <= 0;
         tack_last      <= 0;
      end
   end

   assign irq = (irq_rx_active && irq_rx_enable) ||
                (irq_tx_active && irq_tx_enable);

   ////////////////////////////////////////////////////////////////////////////////
   // Input data registration

   reg [3:0]       sd_data_in_r;
   always @(posedge clk)
     sd_data_in_r       <= sd_data_in;


   ////////////////////////////////////////////////////////////////////////////////
   // Command interface

   wire         rbe;
   wire         rbnd;
   wire         rx_trigger;

   sd_cmd SD_CMD(.clk(clk),
                 .reset(reset),

                 // Physical:
                 .sd_cmd_in(sd_cmd_in),
                 .sd_cmd_out(sd_cmd_out),
                 .sd_cmd_out_en(sd_cmd_out_en),

                 .sd_clk_rising(sd_clk_rising),
                 .sd_clk_falling(sd_clk_falling),

                 .cb(cb),
                 .cmd_resp_len(cmd_resp_len),
                 .cmd_pending(cmd_pending),
                 .cmd_ack(cmd_ack),
                 .cmd_status(cmd_status),
                 .cmd_rx_trigger(rx_trigger),

                 .rb(rb)
                 );

   ////////////////////////////////////////////////////////////////////////////////
   // Data TX/RX
   wire         tx_crc_enable;
   wire         tx_crc_clear;
   wire [3:0]   tx_crc_data;
   wire [31:0]  tx_data_in;
   wire         tx_data_strobe;
   wire         tx_block_starting;
   wire         tx_block_is_first;
   wire         tx_data_ready;
   wire         rx_crc_enable;
   wire         rx_crc_clear;
   wire [31:0]  rx_data_out;
   wire         rx_data_strobe;
   wire         rx_block_starting;
   wire         rx_block_is_first;
   wire         rx_dma_done;

   sd_data_tx #(.TX_TIMEOUT(TX_TIMEOUT))
              SD_DATA_TX(.clk(clk),
                         .reset(reset),

                         .sd_din(sd_data_in_r),
                         .sd_data_out(sd_data_out),
                         .sd_data_out_en(sd_data_out_en),
                         .sd_clk_rising(sd_clk_rising),
                         .sd_clk_falling(sd_clk_falling),

                         .wide_bus(bus_width_4),

                         .tx_data_in(tx_data_in),
                         .tx_data_strobe(tx_data_strobe),
                         .tx_block_starting(tx_block_starting),
                         .tx_block_is_first(tx_block_is_first),
                         .tx_data_ready(tx_data_ready),

                         .ms_pulse(ms_pulse),

                         .tx_pending(tx_pending),
                         .tx_blocks_len_m1(transfer_blks_len),
                         .tx_block_count(tx_block_count),       /* For SW's benefit */
                         .tx_status(tx_status),
                         .tx_ack(tx_ack),

                         .tx_crc_enable(tx_crc_enable),
                         .tx_crc_clear(tx_crc_clear),
                         .tx_crc_data(tx_crc_data),
                         .crc0(crc_val0),
                         .crc1(crc_val1),
                         .crc2(crc_val2),
                         .crc3(crc_val3)
                         );

   sd_data_rx #(.RX_TIMEOUT(RX_TIMEOUT))
              SD_DATA_RX(.clk(clk),
                         .reset(reset),

                         .sd_din(sd_data_in_r),
                         .sd_clk_rising(sd_clk_rising),

                         .wide_bus(bus_width_4),

                         .rx_data_out(rx_data_out),
                         .rx_data_strobe(rx_data_strobe),
                         .rx_block_starting(rx_block_starting),
                         .rx_block_is_first(rx_block_is_first),
                         .rx_dma_done(rx_dma_done),

                         .ms_pulse(ms_pulse),

                         .rx_pending(rx_pending),
                         .rx_trigger(rx_trigger),
                         .rx_words_len(blk_words_len),
                         .rx_blocks_len_m1(transfer_blks_len),
                         .rx_status(rx_status),
                         .rx_ack(rx_ack),
                         .rx_is_idle(rx_idle),

                         .rx_crc_enable(rx_crc_enable),
                         .rx_crc_clear(rx_crc_clear),
                         .crc0(crc_val0),
                         .crc1(crc_val1),
                         .crc2(crc_val2),
                         .crc3(crc_val3),

                         // Debug guff:
                         .rx_crc0(rx_rd_crc0),
                         .rx_crc1(rx_rd_crc1),
                         .rx_crc2(rx_rd_crc2),
                         .rx_crc3(rx_rd_crc3)
                         );


   ////////////////////////////////////////////////////////////////////////////////
   // DMA/MIC interface

   sd_dma_ctrl_mic DMACTRL(.clk(clk),
                           .reset(reset),

                           .O_TDATA(O_TDATA),
                           .O_TVALID(O_TVALID),
                           .O_TREADY(O_TREADY),
                           .O_TLAST(O_TLAST),

                           .I_TDATA(I_TDATA),
                           .I_TVALID(I_TVALID),
                           .I_TREADY(I_TREADY),
                           .I_TLAST(I_TLAST),

                           .tx_pending(tx_pending),
                           .tx_data_out(tx_data_in),
                           .tx_data_strobe(tx_data_strobe),
                           .tx_block_starting(tx_block_starting),
                           .tx_block_is_first(tx_block_is_first),
                           .tx_data_ready(tx_data_ready),

                           .rx_pending(rx_pending),
                           .rx_data_in(rx_data_out),
                           .rx_data_strobe(rx_data_strobe),
                           .rx_block_starting(rx_block_starting),
                           .rx_block_is_first(rx_block_is_first),
                           .rx_dma_done(rx_dma_done),

                           .dma_addr(dma_addr),
                           .dma_status(dma_status),
                           .dma_busy(dma_busy)
                           );


   ////////////////////////////////////////////////////////////////////////////////
   // RX & TX CRC calculation

   wire         crc_enable                          = rx_crc_enable || tx_crc_enable;
   wire         crc_clear                           = rx_crc_clear || tx_crc_clear;

   wire [3:0]                           crc_data_in = rx_crc_enable ? sd_data_in_r :
                tx_crc_enable ? tx_crc_data :
                4'hx;

   sd_crc16 CRC0(.clk(clk),
                 .crc(crc_val0),
                 .in_bit(crc_data_in[0]),
                 .enable(crc_enable),
                 .clear(crc_clear)
                 );
   sd_crc16 CRC1(.clk(clk),
                 .crc(crc_val1),
                 .in_bit(crc_data_in[1]),
                 .enable(crc_enable),
                 .clear(crc_clear)
                 );
   sd_crc16 CRC2(.clk(clk),
                 .crc(crc_val2),
                 .in_bit(crc_data_in[2]),
                 .enable(crc_enable),
                 .clear(crc_clear)
                 );
   sd_crc16 CRC3(.clk(clk),
                 .crc(crc_val3),
                 .in_bit(crc_data_in[3]),
                 .enable(crc_enable),
                 .clear(crc_clear)
                 );


   ////////////////////////////////////////////////////////////////////////////////
   // CRG

   sd_crg       #(.CLK_RATE(CLK_RATE))
                SD_CRG(.clk(clk),
                       .reset(reset),

                       .clkdiv_val(clkdiv_val),
                       .sd_clk_out(sd_clk),
                       .sd_clk_rising(sd_clk_rising),
                       .sd_clk_falling(sd_clk_falling),
                       .ms_pulse(ms_pulse)
                       );

endmodule // sd
