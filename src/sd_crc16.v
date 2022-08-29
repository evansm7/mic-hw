/* sd_crc16: SD host interface crc16 calculation
 *
 * ME 7 Mar 2022
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

module sd_crc16(input wire        clk,
                output reg [15:0] crc,
                input wire        in_bit,
                input wire        enable,
                input wire        clear
               );

   wire                   crc_in = in_bit ^ crc[15];

   always @(posedge clk)
     if (clear)
       crc[15:0]        <= 16'h0;
     else if (enable)
       crc[15:0] <= {crc[14:12], // 3
                     crc_in ^ crc[11],
                     crc[10:5], // 6
                     crc_in ^ crc[4],
                     crc[3:0],  // 4
                     crc_in};

endmodule
