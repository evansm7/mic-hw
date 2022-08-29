/* sd_crc7: SD host interface CRC7 calculation
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

module sd_crc7(input wire       clk,
               output reg [6:0] crc,
               input wire       in_bit,
               input wire       enable,
               input wire       clear
               );

   wire                         crc_in = in_bit ^ crc[6];

   always @(posedge clk)
     if (clear)
       crc[6:0] <= 7'h0;
     else if (enable)
       crc[6:0] <= {crc[5:3], crc_in ^ crc[2], crc[1:0], crc_in};

endmodule
