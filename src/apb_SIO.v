/* Simple IO with an APB interface.
 *
 * Addr 0:	32-bit output port (R/W)
 * Addr 4:	W1S output (WO)
 * Addr 8:	W1C output (WO)
 * Addr c:	32-bit input port (RO)
 *
 * 19/1/17 Matt Evans
 *
 * Copyright 2017, 2022 Matt Evans
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

module	apb_SIO(input wire	   PCLK,
                input wire         nRESET,
                input wire         PENABLE,
                input wire         PSEL,
                input wire         PWRITE,
                input wire [31:0]  PWDATA,
                input wire [3:0]   PADDR,
                output wire [31:0] PRDATA,

		output reg [31:0]  outport,
		input wire [31:0]  inport
		);

   parameter	RESET_VALUE  = 0;

   always @(posedge PCLK) begin
      if (PSEL & PENABLE & PWRITE) begin
	   // Reg write
	   case (PADDR[3:0])
	     4'h0: begin
		outport <= PWDATA[31:0];
		$display("Port set to %08x\n", PWDATA[31:0]);
	     end
	     4'h4: begin
		outport <= outport | PWDATA[31:0];
		$display("Port bits %08x set\n", PWDATA[31:0]);
	     end
	     4'h8: begin
		outport <= outport & ~PWDATA[31:0];
		$display("Port bits %08x cleared\n", PWDATA[31:0]);
	     end
	   endcase
        end

      if (nRESET == 0) begin
	 outport <= RESET_VALUE;
      end
   end

   // Input port + synchroniser:
   reg	[31:0]		in_syncA;
   reg	[31:0]		in_syncB;

   always @(posedge PCLK) begin
      in_syncA	<= inport;
      in_syncB	<= in_syncA;

      if (nRESET == 0) begin
	 in_syncA 	<= 0;
	 in_syncB 	<= 0;
      end
   end

   assign	PRDATA	= (PADDR[3:0] == 4'hc) ? in_syncB : outport;

endmodule


