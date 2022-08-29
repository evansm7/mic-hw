/* Simple UART with a APB interface.
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
 * 20/10/16 Matt Evans
 * ME Converted from AHB to APB 29/5/20
 *
 * Copyright 2016, 2020, 2021 Matt Evans
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

module	apb_uart(input wire	    clk,
		 input wire 	    reset,

                 input wire 	    PENABLE,
                 input wire 	    PSEL,
                 input wire 	    PWRITE,
                 input wire [31:0]  PWDATA,
                 input wire [3:0]   PADDR,
                 output wire [31:0] PRDATA,

		 output wire 	    txd,
		 input wire 	    rxd,

		 output wire 	    IRQ
		 );

   parameter	CLK_DIVISOR	= 868;	// 115k2 at 100MHz
   parameter	RX_FIFO_LOG2	= 3;
   parameter	TX_FIFO_LOG2	= 3;


   wire [7:0] 			    next_tx_byte /*verilator public*/;
   wire 			    tx_has_data /*verilator public*/;
   wire 			    tx_fifo_cons_strobe /*verilator public*/;

   wire 			    rxd_ovf;
   wire [7:0] 			    rxd_new /*verilator public*/;
   wire 			    rxd_new_load;
   wire 			    rx_has_space /*verilator public*/;
   wire 			    bsu_rx_strobe /*verilator public*/;

   apb_uart_regif #(.TX_FIFO_LOG2(TX_FIFO_LOG2),
		    .RX_FIFO_LOG2(RX_FIFO_LOG2))
                  REGIF(.clk(clk),
			.reset(reset),

			.PENABLE(PENABLE),
			.PSEL(PSEL),
			.PWRITE(PWRITE),
			.PADDR(PADDR),
			.PWDATA(PWDATA),
			.PRDATA(PRDATA),

			.tx_data(next_tx_byte),
			.tx_has_data(tx_has_data),
			.tx_data_consume(tx_fifo_cons_strobe),

			.rx_data(rxd_new),
			.rx_has_space(rx_has_space),
			.rx_data_produce(rxd_new_load),

			.rx_overflow(rxd_ovf),

			.IRQ(IRQ)
			);

`ifndef VERILATOR_IO
   bytestream_uart #(.CLK_DIVISOR(CLK_DIVISOR))
                   BSUART(.clk(clk),
			  .reset(reset),

			  .uart_tx(txd),
			  .uart_rx(rxd),

			  .bs_data_in(next_tx_byte),
			  .bs_data_in_valid(tx_has_data),
			  .bs_data_in_consume(tx_fifo_cons_strobe),

			  .bs_data_out(rxd_new),
			  .bs_data_out_produce(bsu_rx_strobe)
			  );
`else // !`ifndef SIM
   // IO is done through Verilator emulation, so don't need the real UART
   assign txd = 1;
   assign rxd_new = 0;
   assign bsu_rx_strobe = 0;
   assign tx_fifo_cons_strobe = tx_has_data;
`endif // !`ifndef SIM

   assign rxd_new_load = bsu_rx_strobe && rx_has_space;
   assign rxd_ovf = bsu_rx_strobe && !rx_has_space;

endmodule


