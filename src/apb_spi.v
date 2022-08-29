/* apb_spi
 *
 * Simple SPI host controller
 *
 * Supports PIO transfers only (for now).  8-bit transfer granule, MSB first.
 * Two TX/RX buffers are provided, A and B.  There are two 'RUN' bits, which invoke a transfer
 * from the corresponding buffer.  It's envisaged that, for a long transfer, the driver will
 * fill A, set RUN_A, then fill B, set RUN_B, then wait for A to complete (RUN_A=0) and so on.
 *
 * CTRL         +00
 *  [0]         CPOL
 *  [1]         CPHA
 *  [7]         RUN_A
 *              Write to 1 to start xfer; HW returns it to 0 when complete.
 *              Note: SW cannot set this to 0, so setting either RUN bit can be
 *              achieved by writing 0 to the other (an ongoing transfer is unaffected).
 *  [9:8]       XFLEN_A
 *              Transfer len minus 1. (1-4 bytes.)
 *  [10]        RUN_B
 *  [12:11]     XFLEN_B
 *              Transfer len minus 1. (1-4 bytes.)
 *
 * TX_DATA_A    +04
 *  [31:0]      TX data A
 *              Transmit data, LE (from [7:0] first).
 *
 * RX_DATA_A    +08
 *  [31:0]      RX data A
 *
 * CSEL         +0c
 *  [0]         CS0 output
 *
 * CLKDIV       +10
 *  [7:0]       CLK_DIV
 *              Output clock rate = sysclk/(CLK_DIV*2+2)
 *
 * TX_DATA_B    +14
 *  [31:0]      TX data B
 *
 * RX_DATA_B    +18
 *  [31:0]      RX data B
 *
 * 21/4/21 ME
 *
 * Copyright 2021-2022 Matt Evans
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

module	apb_spi(input wire 	   clk,
                input wire 	   reset,

		/* Assume PCLK = clk */
                input wire 	   PENABLE,
                input wire 	   PSEL,
                input wire 	   PWRITE,
                input wire [31:0]  PWDATA,
                input wire [4:0]   PADDR,
                output wire [31:0] PRDATA,

		output reg 	   spi_clk,
		output reg 	   spi_dout,
		input wire 	   spi_din,
		output reg	   spi_cs
		);

   parameter	NR_CS = 1; // In future, support multiple inputs/CSes

   reg [63:0] 			   txd; // A is 31:0, B is 63:32
   reg [63:0] 			   rxd; // Same
   reg 				   cpol;
   reg 				   cpha;
   reg 				   run_a;
   reg 				   run_b;
   reg [1:0] 			   xflen_a;
   reg [1:0] 			   xflen_b;
   reg [7:0] 			   clkdiv;
   reg [7:0] 			   clkdiv_counter;

   reg 				   last_clk;
   wire 			   clk_active = (cpol ? 1'b0 : 1'b1);
   wire 			   clk_idle = (cpol ? 1'b1 : 1'b0);

   reg [2:0] 			   state;
`define ST_IDLE   3'h0
`define ST_SHIFT  3'h1
`define ST_SAMP   3'h2
`define ST_FINI   3'h3

   reg 				   rx_bit;
   reg 				   buffer_sel; // 0=A, 1=B
   wire [2:0] 			   transfer_len = buffer_sel ? (xflen_b + 1) : (xflen_a + 1);
   reg [5:0] 			   tbit_sel; // 0-31 for Nth bit in 4B transfer (wire order)
   reg [4:0] 			   rbit_sel;

   wire [2:0] 			   bit_in_byte_to_tx = (7 - tbit_sel[2:0]); /* MSB-first */
   wire [2:0] 			   bit_in_byte_to_rx = (7 - rbit_sel[2:0]); /* MSB-first */

   wire 			   bit_to_tx = txd[ {buffer_sel, tbit_sel[4:3], bit_in_byte_to_tx} ];

   wire                            done = (state == `ST_FINI) && (clkdiv_counter == 0);
   wire 			   done_clear_run_a = done && !buffer_sel;
   wire 			   done_clear_run_b = done && buffer_sel;
   wire 			   set_run_a = PSEL && PENABLE && PWRITE && (PADDR[4:0] == 5'h00) && PWDATA[7];
   wire 			   set_run_b = PSEL && PENABLE && PWRITE && (PADDR[4:0] == 5'h00) && PWDATA[10];

   always @(posedge clk) begin
      //////////////////////////////////////////////////////////////////////
      case (state)
        `ST_IDLE: begin
	   spi_clk <= clk_idle;

	   if (run_a || run_b) begin
	      buffer_sel <= run_a ? 1'b0 : 1'b1;
	      state <= `ST_SHIFT;
	      tbit_sel <= 6'd0;  // 6 bits to capture '32' as a 'done'
	      rbit_sel <= 5'd31; // Immediately wraps to 0
	      clkdiv_counter <= clkdiv;
	      last_clk <= clk_idle;
	   end
        end

        //////////////////////////////////////////////////////////////////////
        // We oscillate between ST_SHIFT and ST_SAMP; in this state, we change DO
        // and update the bit count.  We also set the clock to 'active'.
        `ST_SHIFT: begin
	   if (clkdiv_counter != 0) begin
	      clkdiv_counter <= clkdiv_counter - 1;
	   end else begin
	      tbit_sel <= tbit_sel + 1;
	      rbit_sel <= rbit_sel + 1;
	      spi_dout <= bit_to_tx;
	      spi_clk <= cpha ? clk_active : last_clk;
	      last_clk <= clk_active;

	      // Also capture the previously-captured DI bit into the RX reg:
	      rxd[ {buffer_sel, rbit_sel[4:3], bit_in_byte_to_rx} ] <= rx_bit;

	      state <= `ST_SAMP;
	      clkdiv_counter <= clkdiv;
	   end

        end

        //////////////////////////////////////////////////////////////////////
        // In this state we sample DI and set the clock 'inactive'
        `ST_SAMP: begin
	   if (clkdiv_counter != 0) begin
	      clkdiv_counter <= clkdiv_counter - 1;
	   end else begin
	      rx_bit <= spi_din;
	      spi_clk <= cpha ? clk_idle : last_clk;
	      last_clk <= clk_idle;

	      clkdiv_counter <= clkdiv;
	      if (tbit_sel[5:3] != transfer_len) begin
	         state <= `ST_SHIFT;
	      end else begin
	         state <= `ST_FINI;
	      end
	   end
        end // case: `ST_SAMP

        //////////////////////////////////////////////////////////////////////
        `ST_FINI: begin
           if (clkdiv_counter != 0) begin
	      clkdiv_counter <= clkdiv_counter - 1;
	   end else begin
	      // Capture the final DI bit into the RX reg:
	      rxd[ {buffer_sel, rbit_sel[4:3], bit_in_byte_to_rx} ] <= rx_bit;
	      spi_clk                                               <= clk_idle;
	      state                                                 <= `ST_IDLE;
           end

	   // Correspodning run bit is cleared below
        end

      endcase // case (state)

      //////////////////////////////////////////////////////////////////////
      /* APB register write */
      if (PSEL & PENABLE & PWRITE) begin
         case (PADDR[4:0])
	   5'h00: begin // CTRL
	      cpol <= PWDATA[0];
	      cpha <= PWDATA[1];
	      xflen_a <= PWDATA[9:8];
	      xflen_b <= PWDATA[12:11];
	      // See run bit prioritsation below
	   end

	   5'h04: begin // TXD_A
	      txd[31:0] <= PWDATA[31:0];
	   end

	   5'h08: begin // RXD
	      // RO
	   end

	   5'h0c: begin // CSEL
	      spi_cs <= PWDATA[0];
	   end

	   5'h10: begin // CLKDIV
	      clkdiv <= PWDATA[7:0];
	   end

	   5'h14: begin // TXD_B
	      txd[63:32] <= PWDATA[31:0];
	   end

	   5'h18: begin // RXD
	      // RO
	   end

         endcase
      end // if (PSEL & PENABLE & PWRITE)

      /* Software shouldn't try to set a run bit that's already set.  So, we shouldn't see an attempt to
       * set a bit that's about to be cleared (because it's already set/done a transfer).  The clear then
       * takes priority; otherwise, the bits stay the same unless written to a 1:
       */
      run_a <= done_clear_run_a ? 1'b0 :
	       set_run_a ? 1'b1 : run_a;
      run_b <= done_clear_run_b ? 1'b0 :
	       set_run_b ? 1'b1 : run_b;


      if (reset) begin
	 run_a <= 0;
	 run_b <= 0;
	 spi_cs <= 1;
	 state <= `ST_IDLE;
      end
   end


   //////////////////////////////////////////////////////////////////////

   reg [31:0] 			    rd; // Wire

   /* APB register read */
   always @(*) begin
      rd = 32'h0;

      case (PADDR[4:0])
	5'h00: begin // CTRL
	   rd[0] = cpol;
	   rd[1] = cpha;
	   rd[7] = run_a;
	   rd[9:8] = xflen_a;
	   rd[10] = run_b;
	   rd[12:11] = xflen_b;
	end

	5'h04: // TXD_A
	  rd = txd[31:0];

	5'h08: // RXD_A
	  rd = rxd[31:0];

	5'h0c: // CSEL
	  rd[0] = spi_cs;

	5'h10: // CLKDIV
	  rd[7:0] = clkdiv;

	5'h14: // TXD_B
	  rd = txd[63:32];

	5'h18: // RXD_B
	  rd = rxd[63:32];
      endcase
   end

   assign	PRDATA = rd;

endmodule
