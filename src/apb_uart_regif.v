/* apb_uart_regif
 *
 * This module implements the APB-facing register interface for a byte-
 * oriented UART-like interface.
 *
 * (Refactored out of the original apb_uart component.)
 *
 * This interface can be assembled with different backends, e.g. a
 * real UART serial line, or a FT232-style parallel interface, or other
 * bytestream-oriented transports.
 *
 * Doesn't exercise PREADY.
 *
 * Programming "documentation":
 *
 * Registers are byte-wide:
 *
 * 0x0: DATA_FIFO
 * 	RD:	      	RX data FIFO or UNKNOWN if FIFO empty.
 * 	WR:		TX data into FIFO, discarded if FIFO full.
 *
 * 0x4:	FIFO_STATUS
 * 	RD:	b0:	RX fifo non-empty (can read)
 * 		b1:	TX fifo non-full (can write)
 * 		b[7:2]	RAZ
 * 	WR:	<writes ignored>
 *
 * 0x8: IRQ_STATUS
 * 	RD:	b0:	IRQ0: RX fifo went non-empty
 * 		b1:	IRQ1: TX fifo went non-full
 * 		b2:	IRQ2: RX OVF occurred
 * 	WR:	W1C of status above
 *
 * 0xc:	IRQ_ENABLE
 * 	RD/WR:	b0:	Assert output for IRQ 0
 * 		b1:	'' IRQ 1
 * 		b2:	'' IRQ 2
 *
 *
 * ME 100820
 *
 * Copyright 2016, 2020-2022 Matt Evans
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


module apb_uart_regif(input wire         clk,
		      input wire 	 reset,

		      /* APB interface */
                      input wire 	 PENABLE,
                      input wire 	 PSEL,
                      input wire 	 PWRITE,
                      input wire [3:0] 	 PADDR,
                      input wire [31:0]  PWDATA,
                      output wire [31:0] PRDATA,

		      /* Byte stream for TX */
		      output wire [7:0]  tx_data,
		      output wire 	 tx_has_data,
		      input wire 	 tx_data_consume,

		      /* Byte stream for RX */
		      input wire [7:0] 	 rx_data,
		      output wire 	 rx_has_space,
		      input wire 	 rx_data_produce,

		      /* Misc */
		      input wire 	 rx_overflow,

		      output wire 	 IRQ
		      );

   parameter TX_FIFO_LOG2       = 3;
   parameter RX_FIFO_LOG2       = 3;


   ////////////////////////////////////////////////////////////////////////////
   // Data FIFOs:

   wire [7:0] 				 next_rx_byte;
   wire 				 rx_has_data;
   reg 					 rx_fifo_cons_strobe; // Wire

   wire 				 tx_has_space;
   reg 					 tx_fifo_prod_strobe; // Wire


   simple_fifo #(.DWIDTH(8),
		 .LOG2_SZ(RX_FIFO_LOG2))
               RXFIFO(.clk(clk),
		      .reset(reset),

		      .data_in(rx_data),
		      .data_in_ready(rx_has_space),
		      .data_in_strobe(rx_data_produce),

		      .data_out(next_rx_byte),
		      .data_out_valid(rx_has_data),
		      .data_out_consume_strobe(rx_fifo_cons_strobe)
		      );

   simple_fifo #(.DWIDTH(8),
		 .LOG2_SZ(RX_FIFO_LOG2))
               TXFIFO(.clk(clk),
		      .reset(reset),

		      .data_in(PWDATA[7:0]),
		      .data_in_ready(tx_has_space),
		      .data_in_strobe(tx_fifo_prod_strobe),

		      .data_out(tx_data),
		      .data_out_valid(tx_has_data),
		      .data_out_consume_strobe(tx_data_consume)
		      );

   wire 				 tx_is_full = !tx_has_space;
   wire 				 rx_is_empty = !rx_has_data;

   reg 					 last_tx_is_full;
   reg 					 last_rx_is_empty;
   reg 					 last_ovf;

   // IRQs:
   reg [7:0] 				 irq_status /*verilator public*/;
   reg [7:0] 				 irq_enable /*verilator public*/;

   assign	IRQ = |(irq_status & irq_enable);

   ////////////////////////////////////////////////////////////////////////////

   always @(posedge clk) begin
      /* Register writes */
      if (PSEL && PENABLE) begin
	 if (PWRITE) begin
	    case (PADDR[3:0])
	      ////////// 0: DATA REG //////////
	      4'h0: begin
		 // Write TX data
		 if (!tx_is_full) begin
`ifdef SIM
 `ifndef VERILATOR_IO
		    // Verilator snarfs the written data in other ways
		    $write("%c", PWDATA[7:0]);
 `endif
`endif
		 end
	      end

	      ////////// 4: FIFO_STATUS //////////
	      4'h4: begin
		 // Nothing to do, no state changes possible
	      end

	      ////////// 8: IRQ_STATUS  //////////
	      4'h8: begin
		 // W1C on IRQ status
		 irq_status <= irq_status & ~(PWDATA[7:0]);
	      end

	      ////////// 8: IRQ_ENABLE  //////////
	      4'hc: begin
		 irq_enable <= PWDATA[7:0];
	      end
	    endcase

	 end else begin
	    /* Register reads */
	    case (PADDR[3:0])
	      ////////// 0: DATA REG //////////
	      4'h0: begin
		 /* Read RX data -- PRDATA is dealt with below.
		  * Generate one pulse on rx_fifo_cons_strobe:
		  */
		 if (rx_has_data) begin
		    /* In the absence of responder-driven wait states,
		     * PSEL && PENABLE is true for 1 edges, at which
		     * the requester registers next_rx_byte and
		     * we flag rx_fifo_cons_strobe.  (See comb below.)
		     */
		 end
	      end
	      /* No other read-sensitive locations, for now. */
	    endcase // case (PADDR[3:0])
	 end

      end

      /* Other non-register-related stuff, IRQs */
      last_rx_is_empty 	<= rx_is_empty;
      last_tx_is_full 	<= tx_is_full;
      last_ovf               <= rx_overflow;

      if (!last_ovf && rx_overflow) begin
	 irq_status[2] <= 1;
      end
      if (last_tx_is_full && !tx_is_full) begin
	 irq_status[1] <= 1;
      end
      if (last_rx_is_empty && !rx_is_empty) begin
	 irq_status[0] <= 1;
      end

      if (reset) begin
	 irq_status <= 0;
	 irq_enable <= 0;
      end
   end

   always @(*) begin
      tx_fifo_prod_strobe = PSEL && PENABLE && PWRITE &&
			    (PADDR[3:0] == 4'h0) &&
			    tx_has_space;

      rx_fifo_cons_strobe = PSEL && PENABLE && !PWRITE &&
			    (PADDR[3:0] == 4'h0) &&
			    rx_has_data;
   end


   ////////////////////////////// Read register data //////////////////////////////

   reg	[7:0]	                    rd_data; // Wire
   wire [7:0] 			    fifo_status;

   assign 	fifo_status = {6'h00, !tx_is_full, !rx_is_empty};

   /* PRDATA;
    * Assign output based on addr/en; also do read-sensitive stuff up there ^^
    */

   always @(*) begin
	case (PADDR[3:0])
	  4'h0:
	    rd_data = next_rx_byte;
	  4'h4:
	    rd_data = fifo_status;
	  4'h8:
	    rd_data = irq_status;
	  4'hc:
	    rd_data = irq_enable;
	  default:
	    rd_data = 8'h00;
	endcase
   end

   assign	PRDATA[31:0] = {24'h000000, rd_data};

endmodule // apb_uart_regif
