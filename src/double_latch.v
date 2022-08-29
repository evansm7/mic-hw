/* double_latch
 * This is a skid-buffering pipeline storage element; primary purpose is to
 * give a stage of pipelining but be able to push back "not-valid" whilst
 * accepting a new item.  This way, a pipeline constructed of these elements
 * can be stalled from head to tail without any bubbles (i.e. full throughput).
 *
 * Copyright 2019-2022 Matt Evans
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

module double_latch(input wire              clk,
		    input wire 		    reset,
		    // input port
		    input wire 		    s_valid,
		    output wire 	    s_ready,
		    input wire [WIDTH-1:0]  s_data,
		    // output port
		    output wire 	    m_valid,
		    input wire 		    m_ready,
		    output wire [WIDTH-1:0] m_data
		    );

   parameter WIDTH = 64;

/* Double-storage latch to increase throughput:
 * Two storage elements, 0 and 1.  Full 0 and full 1.
 * Full0	Full1
 *     0	    0	A:  Latch empty.
 *     1	    0	B:  Latch full.
 *     1            1   C:  Latch really full.
 *     0            1   D:  Doesn't happen
 *
 * On s_valid, if !full0, latch data0 and make full0.
 * Assert m_valid if 0 or 1 full.
 * On s_valid, if full0 but !full1, latch data1 and make full1.
 * Assert s_ready if !(full0 && full1)
 * On m_ready, clear full0 if full0 and not full1; clear full1 if... no
 *
 * Point is to enable flow-through, i.e. latch every cycle into data0 unless !m_ready.
 * S_ready unless both full (OK).
 */
   reg [WIDTH-1:0] 			    storage;
   reg [WIDTH-1:0] 			    storageB;
   reg [1:0] 				    state;
`define STATE_EMPTY	0
`define STATE_HALF	1
`define STATE_FULL	2

   assign s_ready 	= (state != `STATE_FULL);
   assign m_valid 	= (state != `STATE_EMPTY);
   assign m_data	= storage;

   always @(posedge clk)
     begin
	case (state)
	  `STATE_EMPTY: begin
	     if (s_valid) begin
		storage <= s_data;
		state <= `STATE_HALF;
	     end
	  end
	  `STATE_HALF: begin
	     if (s_valid) begin
		if (!m_ready) begin
		   // Downstream is blocked; accept one more.
		   storageB <= s_data;
		   state <= `STATE_FULL;
		end else /* ack asserted */ begin
		   // flowthrough: latch a new bit of data on the same edge as downstream consuming the current one
		   storage <= s_data;
		end
	     end else if (m_ready) begin
		// No input and downstream consumed current data
		state <= `STATE_EMPTY;
		storage <= {WIDTH{1'bx}};
	     end
	  end
	  `STATE_FULL: begin
	     /* Ignore s_valid. */
	     if (m_ready) begin
		storageB <= {WIDTH{1'bx}};
	     storage <= storageB;
	     state <= `STATE_HALF;
	  end
	  end
	  default: begin
	  end
	endcase // case (state)

        if (reset) begin
           /* Last assignment wins */
           state <= `STATE_EMPTY;
        end
     end // always @ (posedge clk)

endmodule // p_st
