/* MIC-compliant Synchronous SRAM (NoBL)
 *
 * Sync SRAM has hte following properties:
 *
 * SSRAM expects cmd/data at a rising edge.  Using clock synchronous to system
 * clock, control & data is output at (just after) clk edge.  So, SSRAM picks up
 * cmd/data at next clk edge.  We are gambling that the delay of signals out
 * will satisfy the 0.5ns hold time (signals are registered at one clock, as the
 * FPGA changes signals at same edge).  We may have to tune ODELAY properties a
 * little on the control/DQ...
 *
 * Started 27th April 2019
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

module s_ssram(clk, reset,
	       I_TVALID, I_TREADY, I_TDATA, I_TLAST,
	       O_TVALID, O_TREADY, O_TDATA, O_TLAST,
	       sram_clk,
	       sram_ncen,
               sram_nce0,
               sram_nce1,
	       sram_advld,
	       sram_nwe,
	       sram_nbw,
	       sram_addr,
	       sram_dq
	      );

   parameter NAME  = "SSRAM";
   parameter ADDR_WIDTH  = 21;

   input 			clk;
   input                        reset;
   input                        I_TVALID;
   output                       I_TREADY;
   input [63:0]                 I_TDATA;
   input                        I_TLAST;
   output                       O_TVALID;
   input                        O_TREADY;
   output [63:0]                O_TDATA;
   output                       O_TLAST;

   output                       sram_clk;
   output                       sram_ncen;
   output                       sram_nce0;
   output                       sram_nce1;
   output                       sram_advld;
   output                       sram_nwe;
   output [7:0]                 sram_nbw;
   output [ADDR_WIDTH-1:0]      sram_addr;
   inout [63:0]                 sram_dq;


   wire                         clk;
   wire                         reset;

   wire                         I_TVALID;
   wire                         I_TREADY;
   wire [63:0]                  I_TDATA;
   wire                         I_TLAST;

   wire                         O_TVALID;
   wire                         O_TREADY;
   wire [63:0]                  O_TDATA;
   wire                         O_TLAST;

   reg                          sram_clk; /* FIXME: Was wire, see hax below. */
   reg                          sram_ncen;
   reg                          sram_advld;

   /* The following are wires from explicit outff register instances */
   wire                         sram_nce0;
   wire                         sram_nce1;
   wire                         sram_nwe;
   wire [7:0]                   sram_nbw;
   wire [ADDR_WIDTH-1:0]        sram_addr;
   wire [63:0]                  sram_dq;

   /* Request type */
   reg [1:0] 	     in_request;
`define REQ_NONE          0
`define REQ_RD            1
`define REQ_WR            2
`define REQ_WR_FIN        3

   reg [2:0] 	     output_state;
`define RESP_IDLE         0
`define RESP_RDATA_HDR    1
`define RESP_RDATA_DATA   2
`define RESP_WRACK_HDR    3
`define RESP_DONE         4

   /* Horrendous hack:
    * If the clocks are perfectly in-phase, then the SRAM model (correctly?)
    * causes read data to be present in the same cycle as the command, which
    * isn't realistic.  So, by skewing all outputs relative to the clock
    * (or, by moving the SRAM clock -1ns relative to system clk), the SRAM
    * receives the read command at the end of a (system cycle) and returns
    * data at the next edge.....  gross.  We'll see how this works on a PCB...
    */
   always @(clk) begin
      sram_clk = #4.5 !clk; // 10ns period, i.e. -1ns skew
   end

   /* SRAM bidirectional data bus: */
   wire [63:0] 	     sram_dq_out_final;
   reg 		     sram_dq_out_nvalid;
   reg [63:0] 	     sram_dq_out_p;
   reg 		     sram_dq_out_nvalid_p;

   /* Explicitly force output FF into IOBs; for DQ this
    * was fine in the UCF, but using outff for consistency of style with
    * sram_addr for which UCF was *not* fine:
    */
   outff	     #(.INIT(0), .WIDTH(64), .DELAY(8))
     sdout            (.clk(clk), .reset(reset), .CE(~reset),
                       .D(sram_dq_out_p), .Q(sram_dq_out_final));

   wire [63:0]       sram_read_in;
   assign sram_read_in = sram_dq;
   assign sram_dq = sram_dq_out_nvalid ? 64'bz : sram_dq_out_final;

   reg [ADDR_WIDTH-1:0] sram_addr_internal;

   reg [7:0] 	     req_srcid;
   reg [7:0] 	     req_len;
   reg 		     req_len_single;
   reg [1:0] 	     req_type;
   reg [31:3] 	     req_addr;
   reg [7:0] 	     req_wr_strobes;


   /***************************************************************************/
   /***************************************************************************/
   /**                                                                       **/
   /**                Input request FSM                                      **/
   /**                                                                       **/
   /***************************************************************************/
   /***************************************************************************/

   reg 		     is_header;

   /* Break out info from header: */
   wire [4:0] 	     header_byte_ens;
   wire [2:0] 	     header_dummy;
   wire [7:0] 	     header_src_id;
   wire [7:0] 	     header_rd_len;
   wire [1:0] 	     header_pkt_type;
   wire [31:3] 	     header_address;
   wire 	     header_address_valid;

   assign header_byte_ens = I_TDATA[63:59];
   assign header_src_id = I_TDATA[55:48];
   assign header_rd_len = I_TDATA[47:40];
   assign header_pkt_type = I_TDATA[33:32];
   assign header_address = I_TDATA[31:3];
   /* If a header for READ or WRITE is present this cycle: */
   assign header_address_valid = (in_request == `REQ_NONE) && I_TVALID && is_header &&
				 ((header_pkt_type == 2'b01) || (header_pkt_type == 2'b00));

   wire [7:0] 	     byte_strobes;

   /* Decode byte enables into strobes: */
   mic_ben_dec MBD(.byte_enables(header_byte_ens),
		   .byte_strobes(byte_strobes),
		   .addr_offset());

   /* TREADY=1 if input state is NONE or WR (moar data plz) but not WR_FIN or RD: */
   assign I_TREADY = (in_request == `REQ_NONE || in_request == `REQ_WR);

   /*
    * Input request state machine accepts incoming MIC requests and generates an
    * internal request which is then managed by the RD/WR address gen state
    * machines.
    *
    * Handshake between input and output:
    * When in_request is REQ_NONE, input is accepted.
    * When input is a valid request, in_request becomes REQ_RD or REQ_WR.
    * When REQ_RD/REQ_WR and output_state is ST_IDLE, an output request is generated.
    * When output is complete, and in_request is not REQ_NONE output_state is ST_DONE.
    * When output_state is ST_DONE, in_request returns to REQ_NONE.
    * When REQ_NONE, and output_state is ST_DONE, it goes to ST_IDLE.
    */

   /* Input request processing */
   always @(posedge clk)
     begin
	if (in_request == `REQ_NONE) begin
	   if (I_TVALID) begin
	      if (is_header) begin
`ifdef DEBUG	    $display("%s:  Got pkt type %d, addr %x, len %d, src_id %x",
			     NAME, header_pkt_type, {header_address, 3'h0}, header_rd_len, header_src_id);
`endif

		 req_srcid <= header_src_id; /* To route response */
		 req_type <= header_pkt_type;
		 req_addr <= header_address;

		 if (header_pkt_type == 2'b01) begin // WRITE
`ifdef DEBUG	       $display("%s:  Header complete; WRITE continues", NAME);  `endif
		    in_request <= `REQ_WR;
		    req_wr_strobes <= byte_strobes;
		    req_len <= 0; // len isn't used on write....
		    is_header <= 0;
		    if (I_TLAST) begin
`ifdef SIM
		       $fatal(1, "%s:  *** WRITE with 0 data!", NAME);
`endif
		    end
		 end else begin
		    /* Not a write, so should be Read */
		    if (header_pkt_type == 2'b00) begin // READ
		       if (!I_TLAST) begin
			  /* A Read is 1 beat! */
`ifdef SIM
			  $fatal(1, "%s:  *** Multi-beat packet that isn't a WRITE", NAME);
`endif
		       end
		       /* Initiate READ */
`ifdef DEBUG		  $display("%s:  Header complete; READ continues", NAME);  `endif
		       in_request <= `REQ_RD;
		    end else begin // if (header_pkt_type == 2'b00)
`ifdef SIM
		       $fatal(1, "%s:  *** Input packet isn't WRITE or READ", NAME);
`endif
		    end
		    req_len <= header_rd_len;   /* To generate correct number of response beats for RD */
		    /* It's useful to track a single beat, so that 'LAST'
		     * can be set more easily; the len here isn't available early enough.
		     */
		    req_len_single <= (header_rd_len == 0);
		 end // else: !if(header_pkt_type == 2'b01)
	      end else begin // if (is_header)
`ifdef SIM
		 $fatal(1, "%s:  *** Non-header beat in idle", NAME);
`endif
	      end
	   end // if (I_TVALID)
	   sram_dq_out_nvalid_p <= 1;
	end else if (in_request == `REQ_WR) begin
	   /* This is a non-header write data beat; capture the input data if valid.
	    * If not valid, capture that too-- that'll inhibit the write and address increment.
	    */
	   if (I_TVALID) begin
	      sram_dq_out_p <= I_TDATA;
	      /* Note:  do_write_command is 1 now too */
	      sram_dq_out_nvalid_p <= 0;
	      if (I_TLAST) begin
		 /* This is the last beat of the write request.  Exit WR.
		  * REQ_WR_FIN instructs the output processing to emit a
		  * write-response header on the output MIC channel.
		  */
		 in_request <= `REQ_WR_FIN;
		 /* FIXME: We actually ignore the number of beats in header.len;
		  * could assert that that count matches the actual number.
		  */
	      end
	   end else begin
	      sram_dq_out_nvalid_p <= 1;
	   end
	end else begin
	   /* Request is REQ_WR_FIN or REQ_RD.
	    *
	    * The RAM FSM and the output FSM are sorting it out.
	    * The output FSM signals that the response has been sent
	    * by sitting in RESP_DONE.
	    */
	   if (output_state == `RESP_DONE) begin // and RAM FSM done?
	      in_request <= `REQ_NONE;
	      is_header <= 1;
	   end
	   sram_dq_out_nvalid_p <= 1;
	end // else: !if(in_request <= `REQ_WR)

	/* Happens explicitly above: sram_dq_out_final <= sram_dq_out_p; */
	sram_dq_out_nvalid <= sram_dq_out_nvalid_p;

   	if (reset) begin
	   is_header <= 1;
	   req_len_single <= 0;
	   in_request <= `REQ_NONE;

	   sram_dq_out_nvalid <= 1;
	   sram_dq_out_nvalid_p <= 1;
	end

     end


   /***************************************************************************/
   /***************************************************************************/
   /**                                                                       **/
   /**                RAM control FSM                                        **/
   /**                                                                       **/
   /***************************************************************************/
   /***************************************************************************/

   /* RAM control:
    * When input processing ('in_request') has received a request, this FSM
    * generates SSRAM commands and addresses based on the initial address
    * in the MIC request.
    */

   /* Command issuance */
   wire              rd_consume;
   wire              rd_almost_full;
   wire              read_not_finished;
   reg [7:0] 	     read_beats_left;

   wire 	     do_read_command = (in_request == `REQ_RD) &&
		     (rd_consume || !rd_almost_full) &&
		     read_not_finished;

   wire 	     do_read_command_last = (read_beats_left == 1) || req_len_single;

   /* See input FSM above:  if we are latching input data this cycle,
    * we should be issuing a command next cycle.
    */
   wire 	     do_write_command = (in_request == `REQ_WR) && I_TVALID;

`define RAM_IDLE     0
`define RAM_WR       1
`define RAM_RD       2
`define RAM_RDWAIT   3

   reg [2:0]	     ram_state;
   reg 		     write_command_now;
   reg 		     read_command_now;
   reg 		     read_command_now_is_last;
   reg 		     read_command_prev;
   reg 		     read_command_prev_is_last;

   /* NOTE: Want do_read_command to immediately activate in parallel to the
    * response header write (in cxxx), meaning it should activate in the first
    * cycle of REQ_RD.  read_beats_left hasn't been initialised yet, though,
    * because it takes one cycle for this FSM to pick up the header request
    * value.  So, read_beats_left resets to non-zero before that point,
    * which is enough to kick-start "at least one read" before we start
    * tracking exactly when to finish, next cycle.
    *
    * This means that zero-length reads aren't possible (at least one command
    * is performed), but that's not possible in the MIC protocol anyway.
    */
   assign 	     read_not_finished = (read_beats_left != 0);

   /* FIFO control/status */
   assign            rd_consume = O_TREADY &&
		     (output_state == `RESP_RDATA_DATA);

   wire [64:0] 	     fifo_out;
   wire [63:0] 	     fifo_data;
   wire 	     fifo_last;
   assign fifo_data = fifo_out[63:0];
   assign fifo_last = fifo_out[64];
   wire 	     read_data_present;

   s_ssram_readfifo FIFO(.clk(clk), .reset(reset),
	                 .dq({read_command_prev_is_last, sram_read_in[63:0]}),
	                 .load(read_command_prev),
	                 .rdata(fifo_out),
	                 .consume(rd_consume),
	                 .non_empty(read_data_present),
	                 .almost_full(rd_almost_full)
	                 );

   /* All outputs are registered for maxi-lolz setup timez:
    */

   /* See notes below; these were set in normal regs by the always block
    * below, but now trying to work around tools ignoring request to place
    * the regs in IOBs with explicit out-ff instantiations. :(
    */
   outff             #(.INIT(1), .DELAY(8))
     snce0ff          (.clk(clk), .reset(reset), .CE(~reset),
                       .D((do_read_command || do_write_command) ? 1'b0 : 1'b1), .Q(sram_nce0));
   outff             #(.INIT(1), .DELAY(8))
     snce1ff          (.clk(clk), .reset(reset), .CE(~reset),
                       .D((do_read_command || do_write_command) ? 1'b0 : 1'b1), .Q(sram_nce1));
   outff             #(.INIT(1), .DELAY(8))
     snweff           (.clk(clk), .reset(reset), .CE(~reset),
                       .D(do_write_command ? 0 : 1), .Q(sram_nwe));
   outff             #(.INIT(1), .WIDTH(8), .DELAY(8))
     snbwff           (.clk(clk), .reset(reset), .CE(~reset),
                       .D(~req_wr_strobes), .Q(sram_nbw));

   /* It's pretty messy, but this refers to the commented places that
    * 'sram_addr' needs to be updated in the alwatys block below.
    */
   wire              addr_init                     = (ram_state == `RAM_IDLE) &&
                     ((in_request == `REQ_WR) || (in_request == `REQ_RD));
   wire              addr_increment = ((ram_state == `RAM_WR) && write_command_now) ||
                     ((ram_state == `RAM_RD) && read_command_now);

   wire [ADDR_WIDTH-1:0] addr_new                  = addr_init ? req_addr :
                         addr_increment ? sram_addr_internal : 0;
   outff             #(.INIT(0), .WIDTH(ADDR_WIDTH), .DELAY(8))
     saddff           (.clk(clk), .reset(reset),
                       .CE(addr_init || addr_increment), .D(addr_new), .Q(sram_addr));

   always @(posedge clk)
     begin
	sram_ncen                 <= 0;  /* Never changes */
        /* sram_nce{0,1}, sram_nwe, sram_nbw are latched on every cycle,
         * with inputs to outff instances from combinatorial statements above.
         */

	/* sram_dq_out is driven to the pins during a write-data cycle, being
	 * valid for the edge after a write-command.  That comes from
	 * sram_dq_out_p which is data in the write-command cycle.  If
	 * !sram_dq_out_nvalid_p, then the next cycle will be outputting data;
	 * put another way, the write command is qualified by
	 * sram_dq_out_nvalid_p and if not valid, is delayed.
	 */

	/* These FFs hold whether a command is currently being acted on by
	 * the SRAM in this cycle (having been issued by this module last
	 * cycle):
	 */
	write_command_now         <= do_write_command;
	read_command_now          <= do_read_command;
	read_command_prev         <= read_command_now;

	/* See note on read_not_finished; read_command_prev_is_last is pretty
	 * fiddly too.  It indicates to the FIFO (to tag the data capture)
	 * whether the expected beat is the last of the request.  This
	 * 'last-ness' follows beside do_read_command down a 2-cycle pipeline.

	 * We can't determine this in the very first cycle that
	 * do_read_command is active for a request, because read_beats_left
	 * is being captured in that same cycle.  Instead, the input FSM
	 * sets req_len_single for us to indicate one beat, and LAST is
	 * generated from that.
	 */
	read_command_now_is_last  <= do_read_command_last;
	read_command_prev_is_last <= read_command_now_is_last;

	/* Address-generation FSM: */
	case (ram_state)
	  `RAM_IDLE:
	    begin
	       if (in_request == `REQ_WR) begin
		  ram_state <= `RAM_WR;
		  /* Happens above: sram_addr <= req_addr; */
		  sram_addr_internal <= req_addr + 1;
	       end else if (in_request == `REQ_RD) begin
		  /* This FSM counts the number of requested RD beats,
		   * issues that number of commands, and flags 'last' when
		   * done.
		   */
		  ram_state <= `RAM_RD;
		  read_beats_left <= req_len;  /* Always do at least 1 */
		  /* Happens above: sram_addr <= req_addr; */
		  sram_addr_internal <= req_addr + 1;
	       end else begin
		  /* See the note on read_not_finished; this resets to non-0.
		   * There is at least one RAM_IDLE cycle between finishing
		   * prev read and issuing the next, due to the output/input
		   * handshake.
		   */
		  read_beats_left <= 8'hff;
	       end
	    end

	  `RAM_WR:
	    begin
	       /* If we're currently issuing a command then
		* increment the address used, for next time:
		*/
	       if (write_command_now) begin
		  /* The Xilinx FF-in-pad rules don't allow readback, so
                   * keep a shadow copy of the address;
		   * we never actually need to read the output FFs.
		   */

		  /* Happens above: sram_addr <= sram_addr_internal; */
		  sram_addr_internal <= sram_addr_internal + 1;
	       end

	       if (in_request == `REQ_WR_FIN) begin
		  ram_state <= `RAM_IDLE;
	       end
	    end

	  `RAM_RD:
	    begin
	       /* Reading underway. */
	       if (do_read_command) begin
		  /* If this cycle triggers a command next cycle,
		   * decrement beats left.  (do_read_command is
		   * based on read_beats_left!)
		   *
		   * Note: do_read_command is false if read_beats_left is zero
		   * so no need to test >0 before decrementing.
		   */
		  read_beats_left <= read_beats_left - 1;
	       end // if (do_read_command)

	       if (read_command_now) begin
		  /* Then, a cycle later, if we have a read command going on,
		   * incr address */
		  /* Happens above: sram_addr <= sram_addr_internal; */
		  sram_addr_internal <= sram_addr_internal + 1;
	       end

	       if (read_beats_left == 0) begin
		  /* Issued the last command this cycle, exit */
		  ram_state <= `RAM_RDWAIT;
	       end
	    end

	  `RAM_RDWAIT:
	    begin
	       /* Wait for the output FSM to complete response */
	       if (output_state == `RESP_DONE) begin
		  ram_state <= `RAM_IDLE;
	       end
	    end
	endcase

	if (reset) begin
	   sram_ncen                 <= 1;
	   sram_advld                <= 0;  /* Never changes */
	   ram_state                 <= `RAM_IDLE;
	   write_command_now         <= 0;
	   read_command_now          <= 0;
	   read_command_prev         <= 0;
	   read_command_now_is_last  <= 0;
	   read_command_prev_is_last <= 0;
	   read_beats_left           <= 8'hff;
        end
     end


   /***************************************************************************/
   /***************************************************************************/
   /**                                                                       **/
   /**                Output control FSM                                     **/
   /**                                                                       **/
   /***************************************************************************/
   /***************************************************************************/

   wire [63:0] 	     rdata_header;
   wire [63:0] 	     wrack_header;
   assign rdata_header[63:0] = { 8'h00, req_srcid, 8'h00 /* RD len */, 6'h00, 2'b10 /* RDATA */,
				 req_addr, 3'h0};
   assign wrack_header[63:0] = { 8'h00, req_srcid, 8'h00 /* RD len */, 6'h00, 2'b11 /* WRACK */,
				 req_addr, 3'h0};

   reg [7:0] 	     output_counter;

   reg 		     O_TVALID_int;
   reg 		     O_TLAST_int;
   /* Generally, TVALID/TLAST are driven from this FSM.  But, during read data
    * beats they are driven by FIFO not-empty:
    */
   assign O_TVALID = (output_state == `RESP_RDATA_DATA) ? read_data_present : O_TVALID_int;
   assign O_TLAST = (output_state == `RESP_RDATA_DATA) ? fifo_last : O_TLAST_int; // ME

   reg [63:0] 	     O_TDATA_int;
   /* The TDATA output is either a response header, or RAM read data direct from the FIFO: */
   assign O_TDATA = ((output_state == `RESP_RDATA_HDR) ||
		     (output_state == `RESP_WRACK_HDR)) ? O_TDATA_int : fifo_data;


   /* Output response processing */
   always @(posedge clk)
     begin
	case (output_state)
	  `RESP_IDLE:
	    begin
	       if (in_request == `REQ_RD) begin
		  O_TDATA_int <= rdata_header;
		  O_TVALID_int <= 1;
		  O_TLAST_int <= 0; /* Read data provides more beats */
		  output_state <= `RESP_RDATA_HDR;
`ifdef DEBUG	     $display("%s:   Sending ReadData response of %d beats to %x\n", NAME, req_len+1, req_srcid);  `endif
	       end else if (in_request == `REQ_WR) begin
		  /* Nothing happens here in REQ_WR; the request FSM
		   * captures input data and the RAM FSM above generates
		   * commands and addresses.  But once the burst's done,
		   * the request FSM drops into REQ_WR_FIN, which causes
		   * us to pop out a response, below:
		   */
	       end else if (in_request == `REQ_WR_FIN) begin
		  O_TDATA_int <= wrack_header;
		  O_TVALID_int <= 1;
		  O_TLAST_int <= 1;
		  output_state <= `RESP_WRACK_HDR;
`ifdef DEBUG   	     $display("%s:   Sending WrAck to %x\n", NAME, req_srcid);  `endif
	       end
	    end // case: `RESP_IDLE

	  ////////////////////////////////////////////////////////////////////////////////

	  `RESP_WRACK_HDR:
	    begin
	       if (O_TREADY) begin
		  /* OK, other side got our request, we're done. */
		  O_TVALID_int <= 0;
		  O_TLAST_int <= 0;
		  output_state <= `RESP_DONE;
	       end
	    end

	  ////////////////////////////////////////////////////////////////////////////////

	  `RESP_RDATA_HDR:
	    begin
	       if (O_TREADY) begin
		  /* OK, other side got our header, move onto data: */
		  O_TVALID_int <= 0;
		  output_state <= `RESP_RDATA_DATA;
	       end
	    end

	  `RESP_RDATA_DATA:
	    begin
	       /* In this state, O_TVALID is driven by read_data_present
		* and O_TDATA is driven by the FIFO output.
		*
		* O_TLAST is then driven by the FIFO too (so we don't have to
		* mess with 2 counters).  We'll stay here until RAM FSM flags
		* the last word using fifo_last/O_TLAST.
		*/
	       if (O_TREADY && fifo_last) begin
		  output_state <= `RESP_DONE;
	       end
	    end // case: `RESP_WR_DATA

	  ////////////////////////////////////////////////////////////////////////////////

	  `RESP_DONE:
	    begin
	       /* Synchronises against input FSM: when that passes through
		* idle, this also goes idle.
		*/
	       if (in_request == `REQ_NONE) begin
		  output_state <= `RESP_IDLE;
	       end
	    end
	endcase // case (state)

        if (reset) begin
	   output_state <= `RESP_IDLE;
	   O_TVALID_int <= 0;
	end
     end

endmodule // m_pktsink

/* 65 bits wide; lower 64 come direct from IOBs; 65th
 * bit is validity metadata from design.
 */
module s_ssram_readfifo(clk, reset, dq, load,
                        rdata, non_empty, consume,
                        almost_full
			);

   input wire               clk;
   input wire               reset;
   /* Input data */
   input wire [64:0]  	    dq;
   input wire               load;

   /* Output data */
   output wire [64:0]       rdata;
   output wire              non_empty;
   input wire               consume;

   /* Status */
   output wire              almost_full;

   /* 4-entry FIFO, arranged in a pipeline of FFs.  The idea is that the first
    * set of FFs is sampling input data with FFs in IOBs, so no MUX or anything
    * on input.
    */

   /* Here's the spec:
    * If load, sample dq, store it at edge.
    * - Can also store metadata about that word, e.g. last request,
    *   which can be emitted and helps output create 'last'.
    * If non_empty, rdata is new value.
    * If consume, data value is removed.
    * If empty, consume=1 isn't harmful but doesn't do anything.
    * If there are fewer than N entries left, then almost_full is true
    * - This is a high-water mark
    */
   (* IOB = "FORCE" *)
   reg [63:0]               storage_in_dq;
   reg 	                    storage_in_meta;
   wire [64:0]              storage_zero = {storage_in_meta, storage_in_dq};
   reg [64:0]               storage[3:1];
   reg [2:0]                pos;
   /* rpos:
    * 0 = invalid, no data
    * 1 = next output data in storage_in
    * 2 = next output data in storage[1]
    * 3 = next output data in storage[2]
    * 4 = next output data in storage[3]
    */

   assign almost_full = (pos >= 2);
   assign non_empty = (pos != 0);
   assign rdata = (pos == 1) ? storage_zero :
		  (pos == 2) ? storage[1] :
		  (pos == 3) ? storage[2] :
		  (pos == 4) ? storage[3] :
		  0 /* including when empty/pos=0 */;

   always @ (posedge clk) begin
      if (load) begin
	 storage_in_dq <= dq[63:0];	/* Samples pins in IOB! */
         storage_in_meta <= dq[64];
	 storage[1]    <= {storage_in_meta, storage_in_dq};
	 storage[2]    <= storage[1];
	 storage[3]    <= storage[2];

	 /* If completely empty, then flag that data is valid,
	  * one entry.  'consume' doesn't do anything in this case.
	  */
	 if (pos == 0) begin
	    pos <= 1;
	 end else begin
	    if (consume) begin
	       /* New data loaded, but existing data consumed in same cycle:
		* pos stays the same.  E.g. if 1 datum, pos=1, that data's output
		* and replaced in same cycle.
		*/
	    end else begin
	       /* New data loaded, not consumed: existing data moves down the
		* pipeline, so track that in output:
		*/
	       pos <= pos + 1;
	       if (pos > 4) begin
		  $display("  *** Broken!:  FIFO overflow!");
                  /*		     $finish(1); // Synth doesn't like this, for some reason... weh.  */
	       end
	    end
	 end
      end else begin
	 /* Not loaded, might consume data: */
	 if (consume) begin
	    if (pos != 0) begin
	       pos <= pos - 1;
	    end
	 end
      end // else: !if(load)

      if (reset) begin
	 pos <= 0; /* Empty */
      end
   end

endmodule // s_ssram_readfifo
