/* MIC to APB bridge
 *
 * Supports PREADY (flow control from completer).
 *
 * Do not send bursts at this!  Included is some basic protection (sinks >1
 * write data beat and attempts to give number of requested read data beats),
 * but APB doesn't support bursts.
 *
 * Does not bridge between MIC/APB clock domains; they are assumed to be the
 * same clock.
 *
 * This component does not multiplex a number of input PRDATA buses; it
 * outputs a PSEL value which is decoded to peripheral selects and mux
 * control externally.
 *
 * ME 29/5/20
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

module s_mic_apb(input wire                      clk,
		 input wire 			 reset,

		 /* MIC requests in */
		 input wire 			 I_TVALID,
		 output wire 			 I_TREADY,
		 input wire [63:0] 		 I_TDATA,
		 input wire 			 I_TLAST,

		 /* MIC responses out */
		 output wire 			 O_TVALID,
		 input wire 			 O_TREADY,
		 output reg [63:0] 		 O_TDATA,
		 output wire 			 O_TLAST,

		 /* APB */
		 output wire [DECODE_BITS-1:0] 	 PADDR,
		 output wire 			 PWRITE,
		 output wire 			 PSEL,
		 output wire [NUM_CSEL_LOG2-1:0] PSEL_BANK,
		 output wire 			 PENABLE,
		 output wire [31:0] 		 PWDATA,
		 input wire [31:0] 		 PRDATA,
		 input wire 			 PREADY
		 );

   parameter DECODE_BITS = 16; // Address bits 16 upwards decodes peripheral selects (64KB each)
   parameter NUM_CSEL_LOG2 = 3; // Decode 8 devices


   reg [3:0] 				       state;
`define MIC_APB_STATE_IDLE      4'h0

`define MIC_APB_STATE_WWAIT     4'h1
`define MIC_APB_STATE_WSEL      4'h2
`define MIC_APB_STATE_WEN       4'h3
`define MIC_APB_STATE_WACK      4'h4

`define MIC_APB_STATE_RSEL      4'ha
`define MIC_APB_STATE_REN       4'hb
`define MIC_APB_STATE_RACK      4'hc
`define MIC_APB_STATE_RDATA     4'hd

   /* MIC input header */
   wire [31:3] 				       req_addr = I_TDATA[31:3];
   wire [1:0] 				       req_type = I_TDATA[33:32];
   wire [7:0] 				       req_rlen = I_TDATA[47:40];
   wire [7:0] 				       req_route = I_TDATA[55:48];
   wire [4:0] 				       req_ben = I_TDATA[63:59];

   reg [31:3] 				       captured_address;
   reg [7:0] 				       captured_route;
   reg [4:0] 				       captured_ben;
   reg [7:0] 				       captured_rlen;
   reg 					       captured_type; // 0 RD, 1 WR

   /* Bit is 1 for accesses in [63:32] range */
   wire 				       req_word_high = captured_ben[2];

   /* MIC response header */
   wire [63:0] 				       resp_hdr = {8'h0, captured_route,
							   14'h0, 1'b1, captured_type,
							   captured_address[31:3], 3'h0};
   /* APB state */
   reg [31:0] 				       data_reg;


   /* States */
   always @(posedge clk) begin
      case (state)
	`MIC_APB_STATE_IDLE: begin
	   if (I_TVALID) begin
	      if (req_type == 2'b00) begin // Read
		 state       <= `MIC_APB_STATE_RSEL;
	      end else if (req_type == 2'b01) begin // Write
		 state       <= `MIC_APB_STATE_WWAIT;
	      end

	      captured_address       <= req_addr;
	      captured_route         <= req_route;
	      captured_ben           <= req_ben;
	      /* The read length must be zero.  However, programming errors
	       * etc. might lead to a burst access of this bridge; as a
	       * decadent favour to the world, we shouldn't deadlock the
	       * system.  So, provide fake beats when a burst occurs.
	       */
	      captured_rlen          <= req_rlen;
	      captured_type          <= req_type[0]; /* 0 RD, 1 WR */
	   end
	end


	`MIC_APB_STATE_WWAIT: begin
	   if (I_TVALID && I_TLAST) begin
	      /* Note, waiting for I_TLAST is a hack that
	       * sinks any multi-beat writes.  They should not be
	       * sent, but this helps half-way...
	       */
	      data_reg       <= req_word_high ? I_TDATA[63:32] : I_TDATA[31:0];
	      state          <= `MIC_APB_STATE_WSEL;
	   end
	end

	`MIC_APB_STATE_WSEL: begin
	   /* Nothing interesting; PSEL goes high now */
	   state <= `MIC_APB_STATE_WEN;
	end

	`MIC_APB_STATE_WEN: begin
	   if (PREADY) begin
	      state          <= `MIC_APB_STATE_WACK;
	      O_TDATA        <= resp_hdr;
	   end
	end

	`MIC_APB_STATE_WACK: begin
	   if (O_TREADY) begin
	      /* They got the message. */
	      state          <= `MIC_APB_STATE_IDLE;
	   end
	end


	`MIC_APB_STATE_RSEL: begin
	   /* Nothing interesting; PSEL goes high now */
	   state             <= `MIC_APB_STATE_REN;
	end

	`MIC_APB_STATE_REN: begin
	   if (PREADY) begin
	      /* Data's ready from APB, capture it */
	      data_reg       <= PRDATA;
	      /* ...and output a read response header: */
	      state          <= `MIC_APB_STATE_RACK;
	      O_TDATA        <= resp_hdr;
	   end
	end

	`MIC_APB_STATE_RACK: begin
	   if (O_TREADY) begin
	      /* They got header; next they'll get the data. */
	      state          <= `MIC_APB_STATE_RDATA;
	      if (req_word_high)
		O_TDATA      <= {data_reg, 32'h0};
	      else
		O_TDATA      <= {32'h0, data_reg};
	   end
	end

	`MIC_APB_STATE_RDATA: begin
	   if (O_TREADY) begin
	      /* They got the data. */
	      if (captured_rlen == 0) begin
		 state       <= `MIC_APB_STATE_IDLE;
	      end else begin
		 /* A response beat was accepted, BUT the read request was
		  * for a burst.  Fake up some more beats, to avoid the
		  * requester deadlocking.
		  */
		 captured_rlen <= captured_rlen - 1;
	      end
	   end
	end
      endcase // case (state)

      if (reset) begin
	 state          <= `MIC_APB_STATE_IDLE;
      end
   end


   /* Assign outputs */
   assign I_TREADY = (state == `MIC_APB_STATE_IDLE) || (state == `MIC_APB_STATE_WWAIT);
   assign O_TVALID = (state == `MIC_APB_STATE_WACK) ||
		     (state == `MIC_APB_STATE_RACK) || (state == `MIC_APB_STATE_RDATA);
   assign O_TLAST = (state == `MIC_APB_STATE_WACK) ||
		    ((state == `MIC_APB_STATE_RDATA) && (captured_rlen == 0));

   assign PADDR = {captured_address[DECODE_BITS-1:3],
		   req_word_high,
		   2'b00};
   assign PWRITE = (state == `MIC_APB_STATE_WSEL) || (state == `MIC_APB_STATE_WEN);
   assign PSEL = (state == `MIC_APB_STATE_WSEL) || (state == `MIC_APB_STATE_WEN) ||
		 (state == `MIC_APB_STATE_RSEL) || (state == `MIC_APB_STATE_REN);
   assign PSEL_BANK = captured_address[NUM_CSEL_LOG2+DECODE_BITS-1:DECODE_BITS];
   assign PENABLE = (state == `MIC_APB_STATE_WEN) || (state == `MIC_APB_STATE_REN);
   assign PWDATA = data_reg;

endmodule // mic_apb
