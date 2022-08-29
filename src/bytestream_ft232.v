/* bytetream_ft232
 *
 * This component interfaces an FTDI FT232-like interface into an 8-bit
 * send/receive channel interface.  See bytestream_uart for a similar
 * component for a genuine UART stream (and for interface behaviour).
 *
 * ME 10/8/20
 *
 * Copyright 2020, 2022 Matt Evans
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


module bytestream_ft232(input wire        clk,
			input wire 	  reset,

			/* FT232 interface: */
			inout [7:0] 	  ft_data,
			input wire 	  ft_nRXF, // Active low data ready
			output wire 	  ft_nRD, // |_ read strobe

			input wire 	  ft_nTXE, // Active low TX buffer ready
			output wire 	  ft_nWR, // |_ write strobe

			/* Bytestream interface: */
			input wire [7:0]  bs_data_in, // TX/Wr
			input wire 	  bs_data_in_valid,
			output wire 	  bs_data_in_consume,

			output wire [7:0] bs_data_out, // RX/Rd
			output wire 	  bs_data_out_produce
			);

   /* This component uses a simple FSM to time things right:
    *
    * nRD after nRXF: >= 0ns
    * nRD |_ to data valid: <= 14ns
    * nRD |_ to nRD _|: >= 30ns
    *
    * nWR after nTXE: >= 0ns
    * Data setup before nWR |_: >= 5ns
    * Data hold after nWR |_: >= 5ns
    * nWR |_ to nWR _|: >= 30ns
    *
    * Parameters in units of clock cycles, minus one.  Defaults assume 100MHz
    * system clock (and are safe at slower clocks):
    */
   parameter STROBE_WIDTH = 3-1;
   parameter SETUP = 1-1;
   parameter HOLD = 1-1;
   parameter DVALID = 2-1;
   parameter IDLE_WAIT = 1 /* synchronisers */ + 5 /* "precharge"?? */;

   /* Synchronisers are unnecessary for data because we know it's
    * stable from the relationship with the strobes.
    *
    * But strobe inputs do need synchronisers:
    */
   reg [1:0] 				  nRXF;
   reg [1:0] 				  nTXE;

   always @(posedge clk) begin
      nRXF <= {ft_nRXF, nRXF[1]}; // Access as nRXF[0]
      nTXE <= {ft_nTXE, nTXE[1]}; // Access as nTXE[0]
   end


   /* FSM */
   reg [2:0] 				  state;
`define STATE_IDLE      3'h0
`define STATE_RDWAIT    3'd1
`define STATE_RDPROD    3'd2
`define STATE_WRSETUP   3'd3
`define STATE_WRHOLD    3'd4
`define STATE_IDLE_WAIT 3'd5
   reg [7:0] 				  state_timer;

   reg 					  nRD;
   reg 					  nWR; // Wire
   reg 					  in_consume; // Wire
   reg 					  out_produce; // Wire

   // IO
   reg [7:0] 				  read_cap;
   reg 					  write_enable;
   wire [7:0] 				  write_data;
   wire [7:0] 				  read_data;

   assign read_data = ft_data;
   assign ft_data = write_enable ? write_data : 8'hz;
   assign write_data = bs_data_in; // Could register this at IDLE->WRSETUP transition


   always @(posedge clk) begin
      case (state)
	`STATE_IDLE: begin
	   /* Arbitrate:
	    *
	    * If bs_data_in_valid (want transmit) at the same time as !ft_nRXF (RX ready),
	    * then prioritise one over the other.  Aim for fairness by changing the
	    * preference over time... FIXME FIXME!
	    */
	   if (bs_data_in_valid && !nTXE[0]) begin
	      // Start a transmit/write:
	      state_timer    <= SETUP;
	      state          <= `STATE_WRSETUP;
	      nRD            <= 1;
	      nWR            <= 1;
	      write_enable   <= 1; // Output enable

	   end else if (!nRXF[0]) begin
	      state_timer    <= DVALID;
	      state          <= `STATE_RDWAIT;
	      nRD            <= 0;
	      nWR            <= 1;

	   end else begin
	      nRD            <= 1;
	      nWR            <= 1;
	   end
	end

	`STATE_RDWAIT: begin
	   // nRD is asserted; count down till read.
	   if (state_timer == 0) begin
	      read_cap       <= read_data;
	      // Make up minimum strobe width with any time left over from DVALID:
	      state_timer    <= STROBE_WIDTH-DVALID;
	      state          <= `STATE_RDPROD;
	   end else begin
	      state_timer    <= state_timer - 1;
	   end
	end

	`STATE_RDPROD: begin
	   if (state_timer == 0) begin
	      // Produce is strobed when time=0, see comb below.
	      nRD            <= 1;
	      state          <= `STATE_IDLE_WAIT;
              state_timer    <= IDLE_WAIT; // for synchronisers to see new inputs...
	   end else begin
	      state_timer    <= state_timer - 1;
	   end
	end

	`STATE_WRSETUP: begin
	   if (state_timer == 0) begin
	      nWR            <= 0; // |_ to write
	      state_timer    <= HOLD > STROBE_WIDTH ? HOLD : STROBE_WIDTH;
	      state          <= `STATE_WRHOLD;
	   end else begin
	      state_timer    <= state_timer - 1;
	   end
	end

	`STATE_WRHOLD: begin
	   if (state_timer == 0) begin
	      // Consume is strobed when time=0, see comb below.
	      nWR            <= 1; // WR cycle done
	      write_enable   <= 0; // Outputs off
	      state          <= `STATE_IDLE_WAIT;
              state_timer    <= IDLE_WAIT; // for synchronisers to see new inputs...
           end else begin
	      state_timer    <= state_timer - 1;
	   end
	end

        `STATE_IDLE_WAIT: begin
           /* If we go back to idle too quickly, the FIFO will have dropped
            * its 'data ready' but we won't see it because that async input
            * goes through a synchroniser.  This extra state delays so we
            * see something up-to-date in IDLE.
            */
           if (state_timer == 0) begin
	      state          <= `STATE_IDLE;
	   end else begin
	      state_timer    <= state_timer - 1;
	   end
        end
      endcase // case (state)

      if (reset) begin
	 state          <= `STATE_IDLE;
	 state_timer    <= 0;
	 nRD            <= 1;
	 write_enable   <= 0;
      end
   end

   always @(*) begin
      in_consume = (reset == 0) &&
		   bs_data_in_valid &&
		   (state == `STATE_WRHOLD) && (state_timer == 0);

      out_produce = (reset == 0) &&
		    (state == `STATE_RDPROD) && (state_timer == 0);
   end

   /* Assign outputs: */
   assign ft_nRD = nRD;
   assign ft_nWR = nWR;
   assign bs_data_in_consume = in_consume;
   assign bs_data_out_produce = out_produce;
   assign bs_data_out = read_cap;

endmodule
