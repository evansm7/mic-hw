/* sd_cmd.v: SD host interface command processing
 *
 * Manage the CMD line of the SD card -- sending & receiving commands.
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

module sd_cmd(input wire          clk,
              input wire          reset,

              // Physical:
              input wire          sd_cmd_in,
              output reg          sd_cmd_out,
              output wire         sd_cmd_out_en,

              input wire          sd_clk_rising,
              input wire          sd_clk_falling,

              // Command buffer:
              input wire [47:0]   cb,

              // Control from register interface/top level:
              input wire [1:0]    cmd_resp_len,
              input wire          cmd_pending,
              output reg          cmd_ack,
              output reg [1:0]    cmd_status,

              // This pulses when a response arrives:
              output reg          cmd_rx_trigger,

              output wire [127:0] rb
              );

   parameter    CMD_TIMEOUT = 1000;     // Max 64c, but let's be generous

   // Change bits on falling edge of SD clock: card samples input on clk _|
   // (Could give entire clock tho...?)

   reg [9:0]         timeout_ctr;
`define SD_CST_IDLE             0
`define SD_CST_TXCMD_S          1
`define SD_CST_TXCMD_T          2
`define SD_CST_TXCMD            3
`define SD_CST_CHANGEOVER       4
`define SD_CST_RXRESP_S         5
`define SD_CST_RXRESP           6
`define SD_CST_GO_IDLE          7
   reg [2:0]         cmd_state;
   reg [(8*4)-1:0]   cmd_state_name;
   reg [7:0]         cmd_idx;
   reg               cmd_resp_large;
   reg [3:0]         cmd_count;
   wire              cmd_tx_bit = cb[cmd_idx];
   reg               sd_cmd_in_r;
   wire              rx_crc_correct;
   reg [126:0]       rb_r;

   always @(posedge clk) begin
      case (cmd_state)
        `SD_CST_IDLE:
          if (cmd_pending) begin
             cmd_idx        <= 45;
             cmd_state      <= `SD_CST_TXCMD_S;
             cmd_state_name <= "TX_S";
          end

        `SD_CST_TXCMD_S:
          if (sd_clk_falling) begin
             sd_cmd_out     <= 0;     // Start bit
             cmd_state      <= `SD_CST_TXCMD_T;
             cmd_state_name <= "TX_T";
          end

        `SD_CST_TXCMD_T:
          if (sd_clk_falling) begin
             sd_cmd_out <= 1; // T=1=host
             cmd_state  <= `SD_CST_TXCMD;
             cmd_state_name <= "TXC";
          end

        `SD_CST_TXCMD:
          if (sd_clk_falling) begin
             if (cmd_idx == 0) begin
                // Done last user-provided bit 1; output end bit 0
                sd_cmd_out          <= 1;
                // If asked to capture a response do so, else go idle:
                if (cmd_resp_len[1] == 0) begin
                   cmd_status       <= 2'b00;
                   cmd_state        <= `SD_CST_IDLE; // Go directly, card wasn't on bus
                   cmd_state_name   <= "IDLE";
                   cmd_ack          <= ~cmd_ack;

                end else begin
                   // Go on to wait for a response, of certain size:
                   if (cmd_resp_len[0]) begin // 136b response
                      // Start bit is b135
                      cmd_idx        <= 134;
                      cmd_resp_large <= 1;
                   end else begin // 48b response
                      // Start bit is b47; rest are 46 downwards:
                      cmd_idx        <= 46;
                      cmd_resp_large <= 0;
                   end
                   cmd_state      <= `SD_CST_CHANGEOVER;
                   cmd_state_name <= "CHGO";
                   cmd_count      <= 1;
                end

             end else begin // if (cmd_idx == 0)
                sd_cmd_out    <= cmd_tx_bit;
                cmd_idx       <= cmd_idx - 1;
             end
          end

        `SD_CST_CHANGEOVER:
          // Ncr (2) cycles for CMD to go hi-Z before card drives it:
          if (sd_clk_falling) begin
             if (cmd_count == 0) begin
                cmd_state      <= `SD_CST_RXRESP_S;
                cmd_state_name <= "RX_S";
                timeout_ctr    <= CMD_TIMEOUT;
             end else begin
                cmd_count      <= cmd_count - 1;
             end
          end

        `SD_CST_RXRESP_S:
          // Wait for zero (start bit), or time out
          if (sd_clk_rising) begin
             if (sd_cmd_in_r == 0) begin      // Note registered sample
                cmd_state      <= `SD_CST_RXRESP;
                cmd_state_name <= "RXR";
                cmd_rx_trigger <= 1;
             end else begin
                if (timeout_ctr == 0) begin
                   cmd_status     <= 2'b01;   // Timeout

                   cmd_state      <= `SD_CST_GO_IDLE;
                   cmd_state_name <= "GIDL";
                   cmd_ack        <= ~cmd_ack;
                   cmd_count      <= 7;
                end
                timeout_ctr  <= timeout_ctr - 1;
             end
          end

        `SD_CST_RXRESP:
          if (sd_clk_rising) begin
             // Here comes transmission bit (ignore), (reserved region in 136b,) then data
             if (cmd_idx == 0) begin
                /* RX done; how did it go?
                 * - Was there an End bit of 1?  (If not, status 10)
                 * - Was there a correct CRC?  (If not, status 11)
                 *    Note this isn't fatal, as CRC3 intentionally sends a shit CRC, FFS.
                 */
                cmd_status     <= !sd_cmd_in_r ? 2'b10 :
                                  rx_crc_correct ? 2'b00 : 2'b11;

                cmd_state      <= `SD_CST_GO_IDLE;
                cmd_state_name <= "GIDL";
                cmd_ack        <= ~cmd_ack;
                cmd_count      <= 7;
             end else begin
                cmd_idx               <= cmd_idx - 1;

                /* Capture the input bit, unless it's in the range
                 * [135:128].  No point storing
                 * the start/transmission/reserved bits.
                 * The final storage holds response bits [127:1], as
                 * the stop bit is also not captured (cmd_idx == 0).
                 */
                if (cmd_idx[7] == 0) begin
                   rb_r[126:0] <= {rb_r[125:0], sd_cmd_in_r};
                end
             end
             cmd_rx_trigger   <= 0;
          end // if (sd_clk_rising)

        `SD_CST_GO_IDLE:
          // Let card cool down for Nrc (8) cycles before driving CMD:
          if (sd_clk_rising) begin
             if (cmd_count == 0) begin
                cmd_state             <= `SD_CST_IDLE;
                cmd_state_name        <= "IDLE";
             end else begin
                cmd_count             <= cmd_count - 1;
             end
          end
      endcase // case (cmd_state)

      sd_cmd_in_r <= sd_cmd_in;       // Delayed by 1 host clock, but registered

      if (reset) begin
         cmd_state      <= `SD_CST_IDLE;
         cmd_state_name <= "IDLE";
         sd_cmd_out     <= 1;    // Idles to 1
         cmd_ack        <= 0;
         cmd_status     <= 0;
         cmd_rx_trigger <= 0;
         sd_cmd_in_r    <= 0;
     end
   end

   assign rb[127:0] = {rb_r, 1'b0};     // Stop bit fake
   assign sd_cmd_out_en = !(cmd_state == `SD_CST_RXRESP_S || cmd_state == `SD_CST_RXRESP ||
                            cmd_state == `SD_CST_GO_IDLE);

   ////////////////////////////////////////////////////////////////////////////////
   // CRC7

   wire [6:0] rx_crc;

   sd_crc7 RXCRC(.clk(clk),
                 .crc(rx_crc),
                 .in_bit(sd_cmd_in_r),
                 .enable(sd_clk_rising && (cmd_state == `SD_CST_RXRESP) &&
                         (cmd_idx < 128) && (cmd_idx > 7)),
                 .clear(cmd_state == `SD_CST_RXRESP_S)
                 );

   // This is valid when cmd_idx < 8:
   assign rx_crc_correct = (rx_crc[6:0] == rb_r[7:0]);

endmodule // sd_cmd
