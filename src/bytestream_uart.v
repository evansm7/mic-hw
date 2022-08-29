/* bytetream_uart
 *
 * This component provides a UART-like serial TX/RX interface into an 8-bit
 * send/receive channel interface.  This interface is compatible with
 * simple_fifo's producer/consumer interfaces (with one tiny bit of glue):
 *
 * - Set bs_data_in_valid=1 when bs_data_in is valid
 * - This module asserts bs_data_in_consume=1 for a posedge when done with that data byte.
 * - This module asserts bs_data_out_produce=1 for a posedge when a new data_out is ready.
 *
 * One significant difference is the receive path, bs_data_out*, might assert
 * bs_data_out_produce regardless of whether the other end is ready.  Therefore,
 * to interface to a simple_fifo, one needs to only strobe data_in_strobe if
 * simple_fifo shows data_in_ready=1.  If *not*, the enclosing logic has the
 * opportunity to flag an overflow.
 *
 * ME Refactored from apb_uart 10/8/20
 *
 * Copyright 2016, 2020, 2022 Matt Evans
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


module bytestream_uart(input wire        clk,
		       input wire 	 reset,

		       /* UART interface: */
		       output wire 	 uart_tx,
		       input wire 	 uart_rx,

		       /* Bytestream interface: */
		       input wire [7:0]  bs_data_in,
		       input wire 	 bs_data_in_valid,
		       output wire 	 bs_data_in_consume,

		       output wire [7:0] bs_data_out,
		       output wire 	 bs_data_out_produce
		       );

   parameter CLK_DIVISOR = 868;	// 115k2 at 100MHz


   ////////////////////////////// UART TX //////////////////////////////

   reg [13:0]	                    tx_counter;
   reg [3:0] 			    tx_bit_count;
   reg [10:0] 			    tx_bits;
   reg 				    txd;

   always @(posedge clk) begin
      if (tx_bit_count == 4'h0) begin
	 if (bs_data_in_valid) begin
	    /* Data is ready at bs_data_in.
	     *
	     * Assemble a simple output packet with 1 start bit
	     * (0), data LSB first then 2 stop bits (1).  It's
	     * just plain simpler this way rather than having
	     * FSM states for start/stop/idle.
	     */
	    tx_bits 	           <= {2'b11, bs_data_in, 1'b0};
	    tx_bit_count        <= 12;
	    tx_counter          <= 0;
	 end

      end else begin
	 // Transmission bits:
	 if (tx_counter != 0) begin
	    tx_counter 	<= tx_counter - 1;

	 end else begin
	    // Note: can only be here if tx_bit_count != 0.
	    if (tx_bit_count != 1) begin
	       txd 		<= tx_bits[0];
	       tx_bits[10:0] <= {1'b0, tx_bits[10:1]};
	       tx_bit_count 	<= tx_bit_count - 1;
	    end else begin
	       tx_bit_count  <= 0; // Return to idle
	    end

	    tx_counter 	<= CLK_DIVISOR;
	 end
      end

      if (reset) begin
	 tx_counter 	<= 0;
	 txd 		<= 1;		// 'Natural' sense.
	 tx_bits	<= 0;
	 tx_bit_count 	<= 0;
      end
   end

   // In this state, data is registered, so consume it ready for next round:
   assign bs_data_in_consume = (reset == 0) && (tx_bit_count == 4'h0) && bs_data_in_valid;
   assign uart_tx = txd;

   ////////////////////////////// UART RX //////////////////////////////

   reg [13:0]	                    rx_counter;
   reg [3:0] 			    rx_bit_count;
   reg [7:0] 			    rx_bits;
   reg [1:0] 			    rxd_sync;

   assign bs_data_out = {rxd_sync[0], rx_bits[7:1]};
   assign bs_data_out_produce = (reset == 0) && (rx_counter == 0) && (rx_bit_count == 2);


   always @(posedge clk) begin
      // Synchroniser for uart_rx input:
      rxd_sync[1:0] 	<= {uart_rx, rxd_sync[1]};
      // TODO:  Input debouncing?

      if (rx_bit_count == 0) begin
	 // Waiting for a start bit.
	 if (rxd_sync[0] == 0) begin
	    // We got one!  Wait out this start bit and sample in the
	    // middle of the next bit:
	    rx_counter	<= CLK_DIVISOR*3/2;
	    rx_bit_count	<= 8+1;
	 end
      end else begin
	 if (rx_counter == 0) begin
	    // One bit time has passed.
	    if (rx_bit_count == 2) begin
	       // Sample last bit.
	       // See comb logic above, this case strobes bs_data_out_produce

               // We're not done yet.  Do a dummy extra cycle before
               // sampling a new start bit (otherwise we'll immediately
               // pick up the end of the last data bit!).
               rx_counter          <= CLK_DIVISOR;
               rx_bit_count        <= 1;
	    end else if (rx_bit_count == 1) begin
               // Wait it out before letting rx_bit_count
               // becoming 0 therefore being able to
               // start another start bit.
               rx_bit_count        <= 0;
            end else begin
	       // Several bits to go.
	       // Sample le bit:
	       rx_bits[7:0]	<= {rxd_sync[0], rx_bits[7:1]};
	       // Timer for next:
	       rx_counter 	      <= CLK_DIVISOR;
	       rx_bit_count        <= rx_bit_count - 1;
	    end
	 end else begin
	    rx_counter 	<= rx_counter - 1;
	 end
      end

      if (reset) begin
	 rx_counter 	<= 0;
	 rx_bits	<= 0;
	 rx_bit_count 	<= 0;
	 rxd_sync	<= 2'b11;
      end
   end

endmodule // bytestream_uart
