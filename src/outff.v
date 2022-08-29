/*
 * A wrapper for an output Xilinx FDRE instance, as an attempt
 * to rationalise IOB=FORCE behaviour into one place and avoid
 * equivalent-logic or other optimisations removing FFs or
 * re-using output nets!
 *
 * Copyright 2019 Matt Evans
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

`define REFCLK_FREQ 192

module outff(clk, reset,
	     CE, D, Q);

   parameter WIDTH = 1;
   parameter INIT  = 0;
   parameter DELAY = 0;

   input wire clk;
   input wire reset;
   input wire CE;
   input wire [WIDTH-1:0] D;
   output wire [WIDTH-1:0] Q;

   wire [WIDTH-1:0] inter;

   genvar 		  i;
   generate
      for (i=0; i<WIDTH; i=i+1) begin: foo
	 (* IOB = "FORCE" *) FDRE    #(.INIT(INIT))
                               ff     (.C(clk), .CE(CE), .R(reset),
	                               .D(D[i]), .Q(inter[i]));
         if (DELAY != 0) begin
            IODELAY # (
                       .DELAY_SRC("O"),
                       .IDELAY_TYPE("FIXED"),
                       .IDELAY_VALUE(0),
                       .ODELAY_VALUE(DELAY),
                       .REFCLK_FREQUENCY(`REFCLK_FREQ)
              ) IODELAY_INST (.DATAOUT(Q[i]),
                              .IDATAIN(1'b0),
                              .DATAIN(1'b0),
                              .ODATAIN(inter[i]),
                              .T(1'b0),
                              .CE(1'b0),
                              .INC(1'b0),
                              .C(1'b0),
                              .RST(1'b0));
         end else begin // if (DELAY != 0)
            assign Q[i] = inter[i];
         end // if (DELAY != 0)
      end
   endgenerate

endmodule // outff
