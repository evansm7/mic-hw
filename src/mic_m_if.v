/*
 * mic_m_if
 *
 * Wrap up the MIC request logic, to factor this out of most requesters and avoid
 * reimplementation.  Most components with a MIC request interface instantiate
 * this module.
 *
 * Usage:
 * - If req_ready==1, then bring req_start=1 to start a transaction of
 *   type req_RnW, for req_beats from/to req_address
 * - For a read, data appears on read_data qualified by read_data_valid.  If you
 *   cannot consume that data, mark read_data_ready=0; otherwise new data will
 *   appear in a subsequent cycle if there are more beats left.
 * - For a write, provide data on write_data qualified by write_data_valid.  This
 *   is consumed by this component unless write_data_ready=0 (if so, wait).
 *
 * The m_memtest component was kind of a prototype for this, and this inherits
 * that design.
 *
 * Copyright 2017, 2019-2022 Matt Evans
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

module mic_m_if(input wire         clk,
                input wire 	   reset,

                /* MIC request port out */
                output reg 	   O_TVALID,
                input wire 	   O_TREADY,
                output reg [63:0]  O_TDATA,
                output reg 	   O_TLAST,

                /* MIC response port in */
                input wire 	   I_TVALID,
                output wire 	   I_TREADY,
                input wire [63:0]  I_TDATA,
                input wire 	   I_TLAST,

                /* Control port */
                output wire 	   req_ready,	/* Can accept a new request */
                input wire 	   req_start,	/* Initiate request */
                input wire 	   req_RnW,
                input wire [7:0]   req_beats,
                input wire [31:3]  req_address,
		input wire [4:0]   req_byte_enables,

                /* Data out, for reads */
                output wire [63:0] read_data,
                output wire 	   read_data_valid,
                input wire 	   read_data_ready,

                /* Data in, for writes */
                input wire [63:0]  write_data,
                input wire 	   write_data_valid,
                output wire 	   write_data_ready
                );

   parameter NAME = "MIC_M_IF";

`define STATE_IDLE       0
`define STATE_RD         1
`define STATE_WR         2
`define STATE_WAIT_RESP  3

   reg [2:0]         state;

   /* Handshakes between request and response channels */
   reg               response_handshake_a;
   reg               response_handshake_b;

   wire [63:0]       rd_header;
   wire [63:0]       wr_header;
   assign rd_header[63:0] = { req_byte_enables, 3'h0, 8'h00 /* src */,
                              req_beats[7:0], 6'h00, 2'b00 /* Read */,
                              req_address, 3'h0};
   assign wr_header[63:0] = { req_byte_enables, 3'h0, 8'h00 /* src */,
                              8'h00 /* RD len */, 6'h00, 2'b01 /* Write */,
                              req_address, 3'h0};

   reg [8:0]         write_limit;
   reg [8:0]         write_counter;
   reg [7:0]         read_len;

   assign req_ready = (state == `STATE_IDLE);
   assign write_data_ready = O_TREADY && (state == `STATE_WR);

   /* Request/output channel */
   always @(posedge clk) begin
      case (state)
        `STATE_IDLE:
          begin
             if (req_start) begin
                if (req_RnW) begin
                   /* READ */
                   O_TDATA <= rd_header;
                   O_TVALID <= 1;
                   O_TLAST <= 1; /* A read is only one beat */
                   read_len <= req_beats;
                   state <= `STATE_RD;

`ifdef DEBUG            $display("%s:  Read of %d beats from %x\n", NAME, req_beats+1, {req_address, 3'h0});  `endif
                end else begin
                   /* WRITE */
                   O_TDATA <= wr_header;
                   O_TVALID <= 1;
                   O_TLAST <= 0; /* A write is always >1 beat */
                   write_limit <= {1'b0,req_beats};
                   write_counter <= 0;
                   state <= `STATE_WR;

`ifdef DEBUG            $display("%s:  Write of %d beats to %x\n", NAME, req_beats+1, {req_address, 3'h0});  `endif
                end // else: !if(do_write)
             end
          end

        `STATE_RD:
          begin
             if (O_TREADY) begin
                /* OK, other side got our request, we're done. */
                O_TVALID <= 0;
                state <= `STATE_WAIT_RESP;
                response_handshake_a <= ~response_handshake_a;
                O_TLAST <= 0;
             end
          end

        `STATE_WR:
          begin
             if (O_TREADY) begin
                /* One beat consumed, either prepare another or we're done. */
                if (write_counter > write_limit) begin
                   O_TVALID <= 0;
                   state <= `STATE_WAIT_RESP;
                   response_handshake_a <= ~response_handshake_a;
                   O_TLAST <= 0;
`ifdef DEBUG            $display("%s:  Write burst complete, %d beats total\n", NAME, write_counter);  `endif
                end else begin
                   if (write_data_valid) begin
                      O_TVALID <= 1;
                      if (write_counter == write_limit) begin
                         O_TLAST <= 1;
                      end
                      O_TDATA <= write_data;
                      write_counter <= write_counter + 1;
`ifdef DEBUG               $display("%s:  Write beat %d: data %x", NAME, write_counter, write_data);  `endif
                   end else begin
                      O_TVALID <= 0;
                   end
                end
             end
          end // case: `STATE_WR_DATA

        `STATE_WAIT_RESP:
          begin
             /* Do nothing until the response for our request comes in. */
             if (response_handshake_a == response_handshake_b)
               state <= `STATE_IDLE;
          end
      endcase // case (state)

      if (reset) begin
         state                <= `STATE_IDLE;
         O_TVALID             <= 0;
         response_handshake_a <= 0;
      end
   end


   /* Response/input channel */
   wire [1:0]        pkt_type;
   wire [31:3]       in_address;
   reg [1:0]         pkt_type_r;
   reg [31:3]        in_address_r;
   reg               is_header;
   reg [9:0]         count;

   assign pkt_type = I_TDATA[33:32];
   assign in_address = I_TDATA[31:3];

   assign I_TREADY = is_header || read_data_ready;
   assign read_data = I_TDATA;
   assign read_data_valid = I_TVALID && I_TREADY && !is_header;

   always @(posedge clk)
     begin
        if (I_TVALID && I_TREADY) begin
           if (is_header) begin
              /* Actually only type, src_id and possibly len are valid. */
`ifdef DEBUG     $display("%s:   Got pkt type %d, addr %x", NAME, pkt_type, {in_address, 3'h0});  `endif
              pkt_type_r <= pkt_type;
              in_address_r <= in_address;

              if (!I_TLAST) begin
                 // There's more than just the header.
                 if (pkt_type != 2'b10) begin // RDATA
`ifdef SIM
                    $error("%s:  *** Multi-beat packet that isn't an RDATA", NAME);
                    $fatal(1);
`endif
                 end
                 is_header <= 0;
                 count <= 0;
              end else begin
                 if (pkt_type == 2'b11) begin // WRACK
`ifdef DEBUG           $display("%s:   Got WRACK for addr %x\n", NAME, {in_address, 3'h0});  `endif
                 end else begin
`ifdef SIM
                    $error("%s:  *** Got mystery 1-beat packet type %d\n", NAME, pkt_type);
                    $fatal(1);
`endif
                 end

                 /* Tell the other side it can continue. */
                 response_handshake_b <= ~response_handshake_b;
              end
           end else begin // if (is_header)
              // Count non-header beats
              count <= count + 1;
              /* I_TDATA is output on read_data to the outside world. */

              if (I_TLAST) begin
                 // OK, done; next beat is the next packet's header.
                 is_header <= 1;
                 /* Tell the other side it can continue. */
                 response_handshake_b <= ~response_handshake_b;

                 if (pkt_type_r == 2'b10) begin
`ifdef DEBUG
                    $display("%s:   ReadData total %d beats read from address %x\n",
                             NAME, count+1, {in_address_r, 3'h0});
`endif
                    if (read_len != count) begin
`ifdef SIM
                       $error("%s:  *** Read count %d instead of %d\n", NAME, count+1, read_len);
                       $fatal(1);
`endif
                    end
                 end else begin
`ifdef SIM
                    $error("%s:  *** Mystery multi-beat packet was %d beats long\n", NAME, count);
                    $fatal(1);
`endif
                 end
              end
           end // else: !if(is_header)
        end

        if (reset) begin
           is_header <= 1;
           response_handshake_b <= 0;
        end
     end


endmodule // mic_m_if
