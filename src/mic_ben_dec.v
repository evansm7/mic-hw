/* MIC ByteEnable to byte strobes decoder
 *
 * ME 27/5/20
 *
 * Copyright 2020 Matt Evans
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

module mic_ben_dec(input wire [4:0]  byte_enables,
		   output wire [7:0] byte_strobes,
		   output wire [2:0] addr_offset
		   );

   reg [7:0] 			     bs; // Wire
   reg [2:0] 			     addr; // Wire

   always @(*) begin
      if (byte_enables[4:3] == 2'b00) begin // 8
	 case (byte_enables[2:0])
	   3'b001:  begin  addr = 3'h1;  bs = 8'b00000010; end
	   3'b010:  begin  addr = 3'h2;  bs = 8'b00000100; end
	   3'b011:  begin  addr = 3'h3;  bs = 8'b00001000; end
	   3'b100:  begin  addr = 3'h4;  bs = 8'b00010000; end
	   3'b101:  begin  addr = 3'h5;  bs = 8'b00100000; end
	   3'b110:  begin  addr = 3'h6;  bs = 8'b01000000; end
	   3'b111:  begin  addr = 3'h7;  bs = 8'b10000000; end
	   default: begin  addr = 3'h0;  bs = 8'b00000001; end
	 endcase

      end else if (byte_enables[4:3] == 2'b01) begin // 16
	 case (byte_enables[2:1])
	   2'b01:   begin  addr = 3'h2;  bs = 8'b00001100; end
	   2'b10:   begin  addr = 3'h4;  bs = 8'b00110000; end
	   2'b11:   begin  addr = 3'h6;  bs = 8'b11000000; end
	   default: begin  addr = 3'h0;  bs = 8'b00000011; end
	 endcase

      end else if (byte_enables[4:3] == 2'b10) begin // 32
	 case (byte_enables[2])
	   1'b1:    begin  addr = 3'h4;  bs = 8'b11110000; end
	   default: begin  addr = 3'h0;  bs = 8'b00001111; end
	 endcase

      end else begin // 64
	 addr = 3'h0;
	 bs = 8'hff;
      end
   end

   /* Assign outputs */
   assign byte_strobes = bs;
   assign addr_offset = addr;

endmodule // mic_ben_dec
