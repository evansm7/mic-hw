/* simple_fifo
 *
 * Derived from the original apb_uart FIFO, refactored.
 *
 * This doesn't do anything fancy like CDC, wrap bits, or flow-through.
 *
 * Writes:
 * - If data_in_ready=1, then there is space to write data.
 * - When data_in_ready=1, asserting data_in_strobe=1 at posedge writes data_in.
 * - It is an error to set data_in_strobe=1 if data_in_ready=0.
 *
 * Reads:
 * - If data_out_valid=1, there is valid data on data_out
 * - When data_out_valid=1, asserting data_out_consume_strobe=1 at posedge consumes the data.
 * - It is an error to set data_out_consume_strobe=1 if data_out_valid=0.
 * - data_out is held if data_out_consume_strobe=0.
 * - If data was valid and then consumed, data_out_valid might indicate non-valid
 *   for some time until new data arrives.
 *
 * ME 9 Aug 2020
 *
 * Copyright 2020-2022 Matt Evans
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

module simple_fifo(input wire clk,
		   input wire reset,

		   input wire [DWIDTH-1:0] data_in,
		   input wire data_in_strobe, // Produce
		   output wire data_in_ready,

		   output wire [DWIDTH-1:0] data_out,
		   output wire data_out_valid,
		   input wire data_out_consume_strobe // Consume
		   );

   parameter DWIDTH = 8;
   parameter LOG2_SZ = 3;

   reg [DWIDTH-1:0] 			    fifo[(1 << LOG2_SZ)-1:0];

   reg [LOG2_SZ-1:0] 			    wrptr;
   reg [LOG2_SZ-1:0] 			    rdptr;

   wire 				    is_empty;
   wire 				    is_full;
   wire [LOG2_SZ:0] 			    wr_plusone;

   assign	wr_plusone = wrptr + 1;

   assign	is_empty = (wrptr == rdptr);
   assign	is_full = (wr_plusone[LOG2_SZ-1:0] == rdptr);

   always @(posedge clk) begin
      if (data_in_strobe) begin
	 if (is_full) begin
`ifdef SIM
	    $fatal(1, "simple_fifo: Write when full!");
`endif
	 end else begin
	    fifo[wrptr] <= data_in;
	    wrptr <= wrptr + 1; // Implicitly wrapped
	 end
      end

      if (data_out_consume_strobe) begin
	 if (is_empty) begin
`ifdef SIM
	    $fatal(1, "simple_fifo: Consume when empty!");
`endif
	 end else begin
	    rdptr <= rdptr + 1;
	 end
      end

      if (reset) begin
	 wrptr <= 0;
	 rdptr <= 0;
      end
   end // always @ (posedge clk)

   assign data_out = fifo[rdptr];
   assign data_in_ready = !is_full;
   assign data_out_valid = !is_empty;

endmodule
