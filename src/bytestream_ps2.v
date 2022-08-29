/* bytetream_ps2
 *
 * This component provides a PS/2 serial TX/RX interface into an 8-bit
 * send/receive channel interface.  See bytestream_uart.v etc.
 *
 *
 * Magic operation:
 * This is generally RX but I do want to support TX.  A state machine goes into
 * ST_TX when a TX byte is present (and returns to ST_IDLE after).
 *
 * In ST_IDLE:
 * - If CLK goes low, start bit is being transmitted; go to ST_RX and
 *   wait for D0-D7 (plus parity, plus stop).  Sample data when CLK is low.
 * - If TX and CLK high, go into ST_TX; pull CLK low for >=100us, DAT low,
 *   release CLK, change data when CLK goes low.  There are 11 falling edges,
 *   1 start, 8 data, 1 parity, 1 stop, then a final rising edge where device
 *   asserts ACK.
 *
 * Should implement timeouts on the CLK edges -- abort a TX/RX if there's no clock
 * for say 10ms.  Expected clock is about 10KHz (i.e. much slower than system clock).
 *
 * 15/3/21 ME
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


module bytestream_ps2(input wire        clk,
		      input wire        reset,

		      /* PS2 interface: */
                      input wire        ps2_clk_in,
		      output wire       ps2_clk_pd, // 1=Pull-down
                      input wire        ps2_dat_in,
		      output wire       ps2_dat_pd, // 1=Pull-down

		      /* Bytestream interface: */
		      input wire [7:0]  bs_data_in,
		      input wire        bs_data_in_valid,
		      output wire       bs_data_in_consume,

		      output wire [7:0] bs_data_out,
		      output wire       bs_data_out_produce
		      );

   parameter CLK_RATE = 50*1000*1000;
   parameter TIMEOUT  = (CLK_RATE/100);

   localparam START_TX_DELAY = CLK_RATE/5000;	// 200us

   reg                                  dat_pd;
   reg                                  clk_pd;
   reg [1:0]                            dati;
   reg [1:0]                            clki;
   reg [3:0]                            dsr;
   reg [3:0]                            csr;
   // Debounced inputs: are the last N samples the same? (biased high but hey)
`ifdef TEST_NO_DEBOUNCE
   wire                                 pdat = ps2_dat_in;
   wire                                 pclk = ps2_clk_in;
`else
   wire                                 pdat = &dsr[3:0];
   wire                                 pclk = &csr[3:0];
`endif

   reg [3:0]                            state;
`define ST_IDLE 	0
`define ST_RX 		1
`define ST_RX_WH	2
`define ST_TX		3
`define ST_TX_WL	4
`define ST_TX_WH	5

   reg [3:0]                            count;
   reg [9:0]                            ldata;
   reg                                  produce;
   reg                                  consume;
   reg                                  last_pclk;
   reg [19:0]                           timeout;

   // Odd parity:  1 if there are an even number of 1s in the data.
   wire                                 rparity = ~(^ldata[7:0]);
   wire                                 tparity = ~(^bs_data_in[7:0]);

   ////////////////////////////////////////////////////////////////////////////////
   // Main FSM

   always @(posedge clk) begin
      /* Input synch/debouncing */
      dati[1:0] <= {dati[0], ps2_dat_in};
      clki[1:0] <= {clki[0], ps2_clk_in};

      dsr[3:0]  <= {dsr[2:0], dati[1]};
      csr[3:0]  <= {csr[2:0], clki[1]};

      last_pclk <= pclk;


      /* FSM */
      case (state)

        `ST_IDLE: begin
           dat_pd        <= 0;
           clk_pd        <= 0;
           produce       <= 0;
           consume       <= 0;

           // A falling edge marks the start of a transmission from device:
           if (last_pclk == 1 && pclk == 0) begin
              if (pdat == 0) begin
                 state      <= `ST_RX;
                 count      <= 10;       	// 10 falling edges (8+par+stop)
                 timeout    <= TIMEOUT;
              end
              // Else, what if start bit was 1?

           end else if (bs_data_in_valid) begin
              ldata   <= {1'b0, tparity, bs_data_in};
              consume <= 1;		// For a cycle
              state   <= `ST_TX;
              count   <= 11;       	// 11 rising edges (st+8+par+stop)
              // Initiate TX by holding CLK low for >100us:
              timeout <= START_TX_DELAY;
              clk_pd	 <= 1;
           end
        end


        `ST_RX: begin
           // Just wait for a rising edge:
           if (last_pclk == 0 && pclk == 1) begin
              // If we're done, send data.
              if (count == 0) begin
                 // Saw the final edge.  Now, ldata is {stop, parity, data}.
                 if (ldata[9] != 1 || ldata[8] != rparity) begin
                    // FIXME: complain
                 end else begin
                    // RX'd data!  Strobe for 1 clock:
                    produce <= 1;
                 end
                 state   <= `ST_IDLE;

              end else begin // if (count == 0)
                 // Go wait for a falling edge & new bit:
                 timeout <= TIMEOUT;
                 state   <= `ST_RX_WH;
              end

           end else begin
              if (timeout == 0)	// FIXME complain
                state <= `ST_IDLE;
              else
                timeout <= timeout - 1;
           end
        end


        `ST_RX_WH: begin
           // Wait for a falling edge and sample new data:
           if (last_pclk == 1 && pclk == 0) begin
              ldata   <= {pdat, ldata[9:1]};
              count   <= count-1;
              timeout <= TIMEOUT;
              state   <= `ST_RX;

           end else begin
              if (timeout == 0)	// FIXME complain
                state <= `ST_IDLE;
              else
                timeout <= timeout - 1;
           end
        end


        `ST_TX: begin
           consume     <= 0;
           // CLK is being held low.
           if (timeout == 0) begin
              // 100us done!  Bring DAT low, release CLK
              dat_pd  <= 1;
              clk_pd  <= 0;
              timeout <= TIMEOUT;
              state   <= `ST_TX_WL;

           end else begin
              timeout <= timeout - 1;
           end
        end // case: `ST_TX


        `ST_TX_WL: begin
           // Wait for device to bring CLK low, then we emit a data bit:
           if (last_pclk == 1 && pclk == 0) begin
              dat_pd  <= ~ldata[0];
              ldata   <= {2'b11, ldata[8:1]};
              count   <= count - 1;
              timeout <= TIMEOUT;
              state   <= `ST_TX_WH;

           end else begin
              if (timeout == 0)	// FIXME complain
                state <= `ST_IDLE;
              else
                timeout <= timeout - 1;
           end
        end


        `ST_TX_WH: begin
           // Wait for device to bring CLK high
           if (last_pclk == 0 && pclk == 1) begin

              if (count == 0) begin
                 // Sample ACK bit
                 if (pdat == 1) begin
                    // No ACK!  FIXME complain
                 end
                 state <= `ST_IDLE;

              end else begin
                 timeout <= TIMEOUT;
                 state   <= `ST_TX_WL;
              end

           end else begin
              if (timeout == 0)	// FIXME complain
                state <= `ST_IDLE;
              else
                timeout <= timeout - 1;
           end

        end

        default: begin
        end
      endcase

      if (reset) begin
         state   <= `ST_IDLE;
         produce <= 0;
      end
   end

   ////////////////////////////////////////////////////////////////////////////////

   assign bs_data_out = ldata[7:0];
   assign bs_data_out_produce = produce;
   assign bs_data_in_consume = consume;

   assign ps2_clk_pd = clk_pd;
   assign ps2_dat_pd = dat_pd;


endmodule // bytestream_ps2
