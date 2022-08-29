/* apb_intc
 *
 * Simple interrupt controller, "largely compatible" with the xps_intc driver.
 *
 * Supports level and edge interrupts (synchronised to sysclk).
 *
 * Interrupt Status Register         +00  ISR
 * Interrupt Pending Register        +04  IPR
 * Interrupt Enable Register         +08  IER
 * Interrupt Acknowledge Register    +0c  IAR
 * Set Interrupt Enable Bits         +10  SIE
 * Clear Interrupt Enable Bits       +14  CIE
 * Interrupt Vector Register         +18  IVR
 * Master Enable Register            +1c  MER
 *
 * 13/1/21 ME
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

module	apb_intc(input wire 	    clk,
                 input wire 	    reset,

		 /* Assume PCLK = clk */
                 input wire 	    PENABLE,
                 input wire 	    PSEL,
                 input wire 	    PWRITE,
                 input wire [31:0]  PWDATA,
                 input wire [4:0]   PADDR,
                 output wire [31:0] PRDATA,

		 input wire [31:0]  irqs,
		 output reg 	    irq_out
		 );

   parameter	NR_IRQS = 8;
   /* First N are level, remainder edge.  Note lower numbers are higher
    * priority.  Needs finesse.
    */
   parameter	NR_LEVEL = 4;


   reg [NR_IRQS-1:0] 		    enabled /*verilator public*/;
   reg [NR_IRQS-NR_LEVEL-1:0] 	    pending /*verilator public*/;
   wire [NR_IRQS-1:0] 		    effective_pending;
   wire [NR_IRQS-1:0] 		    asserted;
   reg 				    hie /*verilator public*/;
   reg 				    me /*verilator public*/;
   reg [NR_IRQS-1:0] 		    irqs_int; // One stage of pipelining for inputs
   reg [NR_IRQS-1:0] 		    irqs_int_last; // FIXME: doesn't need to capture level
   reg [31:0] 			    vector;

   assign effective_pending = {pending, irqs_int[NR_LEVEL-1:0]};
   assign asserted = enabled & effective_pending;


   always @(posedge clk) begin
      irqs_int_last   <= irqs_int;
      irqs_int        <= irqs;
      /* Capture any positive edges in the edge-sensitive span: */
      pending         <= pending | (irqs_int[NR_IRQS-1:NR_LEVEL] &
				    (irqs_int[NR_IRQS-1:NR_LEVEL] ^ irqs_int_last[NR_IRQS-1:NR_LEVEL]));

      irq_out         <= |asserted & me;

      /* Priority encoder for IVR: */
      casez ({{32-NR_IRQS{1'b0}}, asserted})
        32'b???????????????????????????????1:   vector <= 32'h0;
        32'b??????????????????????????????1?:   vector <= 32'h1;
        32'b?????????????????????????????1??:   vector <= 32'h2;
        32'b????????????????????????????1???:   vector <= 32'h3;
        32'b???????????????????????????1????:   vector <= 32'h4;
        32'b??????????????????????????1?????:   vector <= 32'h5;
        32'b?????????????????????????1??????:   vector <= 32'h6;
        32'b????????????????????????1???????:   vector <= 32'h7;
        32'b???????????????????????1????????:   vector <= 32'h8;
        32'b??????????????????????1?????????:   vector <= 32'h9;
        32'b?????????????????????1??????????:   vector <= 32'ha;
        32'b????????????????????1???????????:   vector <= 32'hb;
        32'b???????????????????1????????????:   vector <= 32'hc;
        32'b??????????????????1?????????????:   vector <= 32'hd;
        32'b?????????????????1??????????????:   vector <= 32'he;
        32'b????????????????1???????????????:   vector <= 32'hf;
        32'b???????????????1????????????????:   vector <= 32'h10;
        32'b??????????????1?????????????????:   vector <= 32'h11;
        32'b?????????????1??????????????????:   vector <= 32'h12;
        32'b????????????1???????????????????:   vector <= 32'h13;
        32'b???????????1????????????????????:   vector <= 32'h14;
        32'b??????????1?????????????????????:   vector <= 32'h15;
        32'b?????????1??????????????????????:   vector <= 32'h16;
        32'b????????1???????????????????????:   vector <= 32'h17;
        32'b???????1????????????????????????:   vector <= 32'h18;
        32'b??????1?????????????????????????:   vector <= 32'h19;
        32'b?????1??????????????????????????:   vector <= 32'h1a;
        32'b????1???????????????????????????:   vector <= 32'h1b;
        32'b???1????????????????????????????:   vector <= 32'h1c;
        32'b??1?????????????????????????????:   vector <= 32'h1d;
        32'b?1??????????????????????????????:   vector <= 32'h1e;
        32'b1???????????????????????????????:   vector <= 32'h1f;
        default:
          vector        <= 32'hffffffff;
      endcase

      /* APB register write */
      if (PSEL & PENABLE & PWRITE) begin
         case (PADDR[4:0])
	   5'h00: begin // ISR
	      // This doesn't support writing ISR.
	   end
	   5'h04: begin // IPR
	      // Read-only
	   end
	   5'h08: begin // IER
	      enabled <= PWDATA[NR_IRQS-1:0];
	   end
	   5'h0c: begin // IAR
	      // Clear edge pending status, i.e. bits NR_LEVEL and up:
	      pending <= pending & ~PWDATA[NR_IRQS-1:NR_LEVEL];
	   end
	   5'h10: begin // SIE
	      enabled <= enabled | PWDATA[NR_IRQS-1:0];
	   end
	   5'h14: begin // CIE
	      enabled <= enabled & ~PWDATA[NR_IRQS-1:0];
	   end
	   5'h18: begin // IVR
	      // Read-only
	   end
	   5'h1c: begin // MER
	      me      <= PWDATA[0];
	      hie     <= PWDATA[1];
	   end
         endcase
      end

      if (reset) begin
         enabled         <= {NR_IRQS{1'b0}};
         pending         <= {NR_IRQS-NR_LEVEL{1'b0}};
         hie             <= 1'b0;
         me              <= 1'b0;
         irqs_int        <= {NR_IRQS{1'b0}};
         irqs_int_last   <= {NR_IRQS{1'b0}};
         vector          <= 32'hffffffff;
         irq_out         <= 1'b0;
      end
   end


   reg [31:0] 			    rd; // Wire

   /* APB register read */
   always @(*) begin
      case (PADDR[4:0])
	5'h00: // ISR
	  rd = {{32-NR_IRQS{1'b0}}, effective_pending};
	5'h04: // IPR
	  rd = {{32-NR_IRQS{1'b0}}, asserted};
	5'h08: // IER
	  rd = {{32-NR_IRQS{1'b0}}, enabled};
	5'h0c: // IAR
	  rd = 32'h0;
	5'h10: // SIE
	  rd = 32'h0;
	5'h14: // CIE
	  rd = 32'h0;
	5'h18: // IVR
	  rd = vector;
	5'h1c: // MER
	  rd = {30'h0, hie, me};

	default:
	  rd = 32'h0;
      endcase
   end

   assign	PRDATA = rd;

endmodule