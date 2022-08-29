/* PS/2 interface, presented like a UART with an APB register set.
 *
 * ME 17 September 2021
 *
 * Copyright 2021 Matt Evans
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

module	apb_uart_ps2(input wire	  	clk,
		     input wire         reset,

                     input wire         PENABLE,
                     input wire         PSEL,
                     input wire         PWRITE,
                     input wire [31:0]  PWDATA,
                     input wire [3:0]   PADDR,
                     output wire [31:0] PRDATA,

                     input              ps2_clk_in,
                     output             ps2_clk_pd,
                     input              ps2_dat_in,
                     output             ps2_dat_pd,

		     output wire        IRQ
		     );

   parameter 	CLK_RATE	= 50*1000*1000;
   parameter	RX_FIFO_LOG2	= 3;
   parameter	TX_FIFO_LOG2	= 2;


   wire [7:0] 			    next_tx_byte;
   wire 			    tx_has_data;
   wire 			    tx_fifo_cons_strobe;

   wire 			    rxd_ovf;
   wire [7:0] 			    rxd_new;
   wire 			    rxd_new_load;
   wire 			    rx_has_space;
   wire 			    bsu_rx_strobe;

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


   bytestream_ps2 #(.CLK_RATE(CLK_RATE))
                   BSPS2(.clk(clk),
			 .reset(reset),

                         .ps2_clk_in(ps2_clk_in),
                         .ps2_clk_pd(ps2_clk_pd),
                         .ps2_dat_in(ps2_dat_in),
                         .ps2_dat_pd(ps2_dat_pd),

			 .bs_data_in(next_tx_byte),
			 .bs_data_in_valid(tx_has_data),
			 .bs_data_in_consume(tx_fifo_cons_strobe),

			 .bs_data_out(rxd_new),
			 .bs_data_out_produce(bsu_rx_strobe)
			 );

   assign rxd_new_load = bsu_rx_strobe && rx_has_space;
   assign rxd_ovf = bsu_rx_strobe && !rx_has_space;

endmodule


