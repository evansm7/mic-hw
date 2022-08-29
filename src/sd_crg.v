/* sd_crg: SD host interface Clock Rate Generator
 *
 * SD card clock generation; super-simple divider from system clock.
 *
 * ME 7 March 2022
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

module sd_crg(input wire       clk,
              input wire       reset,

              input wire [7:0] clkdiv_val,

              /* FIXME: Ensure IOB-packed! */
              output reg       sd_clk_out,
              output wire      sd_clk_rising,
              output wire      sd_clk_falling,
              output reg       ms_pulse
              );

   parameter CLK_RATE = 50000000;       // Must be provided!

   reg [7:0]         clk_div;

   always @(posedge clk) begin
      if (clk_div == 0) begin
         sd_clk_out   <= ~sd_clk_out;
         clk_div      <= clkdiv_val;
      end else begin
         clk_div      <= clk_div - 1;
      end

      if (reset) begin
         clk_div         <= clkdiv_val;
         sd_clk_out      <= 0;
      end
   end
   assign       sd_clk_rising   = (clk_div == 0) && !sd_clk_out;
   assign       sd_clk_falling  = (clk_div == 0) && sd_clk_out;

   /* Provide a 1ms pulse to the rest; this is done to keep
    * various timeout counters small.
    */
   reg [17:0]   ms_timer;       // FIXME: assert size w.r.t. CLK_RATE/1000

   always @(posedge clk) begin
      if (ms_timer == CLK_RATE/1000) begin
         ms_timer <= 0;
         ms_pulse <= 1;
      end else begin
         ms_timer <= ms_timer + 1;
         ms_pulse <= 0;
      end

      if (reset) begin
         ms_timer <= 0;
      end
   end

endmodule
