/* I2S output
 *
 * This component outputs stereo s16 PCM, at a fixed sample rate (i.e. 44.1KHz).
 * This is a MIC requester and APB completer, much like LCDC.
 *
 * For now supports only a 3-wire (BCLK, DOUT, WCLK) I2S interface using
 * I2S 64-bit (32bit/sample) format.  (As taken by, e.g., PCM5102A.)
 *
 * (c) Matt Evans, 30 Nov 2020
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

/*
 * Register interface:
 *
 * Offset       Reg
 * 00           CTRL
 *              [0]     Enable
 *              [1]     IRQEnable
 *              [5]     BCA: Buffer ctrl A
 *              [6]     BCB: Buffer ctrl B
 *              [9:8]   Buffer size:
 *                      00 - 4KB
 *                      01 - 1KB
 *                      10 - 512B
 *
 * 04           STATUS (RO)
 *              [4]     Current buffer (0=A, 1=B)
 *              [5]     BSA: Buffer status A
 *              [6]     BSB: Buffer status B
 *
 * 08           BUF_A_BASE
 *              [31:3]  Base address of buffer
 *
 * 0c           BUF_B_BASE
 *              [31:3]  Base address of buffer
 *
 * 10           VOL
 *              [7:0]   Volume 0-255
 *
 * Volume control consumes one 16x8=>24 multiplier.
 *
 * Future:
 * - ID reg for caps, and cheaper volume:  shift s16 left/right into the 32b
 *   sample output field.
 * - Variable-sized buffers
 * - Buffers larger than 4K, or chains/rings
 *
 *
 * Theory of operation:
 *
 * Double-buffered continuous playback.  Each buffer has a concept of "validity"
 * in that a valid buffer is used (or queued) for playback, and when consumed
 * it becomes invalid/does not play.  A handshake is used to convey when these
 * state changes occur:
 *
 * - Buffers have a control bit (SW) and a status bit (HW).  A buffer is valid
 *   when ctrl != valid.
 *
 * - Software toggles ctrl when marking an invalid buffer as valid, and hardare
 *   consumes a valid buffer indicated by CB.
 *
 * - When hardware has fully read a buffer, it:
 *  -- Toggles the corresponding BSx to mark the buffer invalid
 *  -- Toggles CB to indicate it will consume the other buffer next
 *  -- Sends an edge IRQ, if IRQEnable=1.
 *
 * If CB changes to a buffer that is not valid, zeros are output.  CB does not
 * change thereafter unless the current buffer is later made valid, played and
 * consumed.
 *
 * Buffers are interleaved L-R s16 PCM samples, and of variable size.  Size can
 * be configured to 4KB (i.e. 1024 samples for each channel) 1KB or 512B.  The
 * smaller sizes are mostly of use to memory-constrained (e.g. firmware) polled-
 * mode usage.
 *
 * Example:
 *
 * From a starting state with Current Buffer (CB) 0 (A) and buffer A/B
 * invalid (BCA == BSA, BCB == BSB), playback is started by:
 * - Writing BUF_A_BASE to point to a sample buffer
 * - Writing BCA=1; now BCA != BCB and A is valid.
 * DMA begins fetching A and playback begins.  Note BCA and BCB can both be
 * toggled in one go (after setting up both BUF_x_BASE regs).
 *
 * When buffer A is complete, BSA is toggled (set 1 in this example) and CB
 * changes to buffer B.
 *
 * Software can either poll BRx bits (refilling buffers for which BRx becomes
 * zero, then setting BRx again) or wait for an IRQ saying BRx has changed.
 * Needs to be quick, though!  Setting BRA will also read-mod-write the existing
 * value to BRB; if BRB just finished then it's been set to 1 again ... weird
 * stuff will happen.
 *
 * Stopping playback:
 * - Either wait for both buffers to become invalid, or rush things
 *   by clearing Enable.
 *
 * Enable:
 * - Starts up clock generation
 * - Starts/stops DMA too.
 * - BSx/CB are not set to zero when Enable=0
 *
 *
 * Caveats:
 * This component doesn't do anything clever with clocking.  Ideally, it
 * would take a high-quality external clock for BCLK/LRCK etc.  Currently,
 * it derives these with a BRG from the system clock.
 *
 */

module r_i2s_apb(input wire         clk,
		 input wire 	    reset,

                  /* MIC request port out */
                 output wire 	    O_TVALID,
                 input wire 	    O_TREADY,
                 output wire [63:0] O_TDATA,
                 output wire 	    O_TLAST,

                  /* MIC response port in */
                 input wire 	    I_TVALID,
                 output wire 	    I_TREADY,
                 input wire [63:0]  I_TDATA,
                 input wire 	    I_TLAST,

                  /* APB completer */
                 input wire 	    PCLK, /* Unused */
                 input wire 	    nRESET,
                 input wire 	    PENABLE,
                 input wire 	    PSEL,
                 input wire 	    PWRITE,
                 input wire [31:0]  PWDATA,
                 input wire [5:0]   PADDR,
                 output reg [31:0]  PRDATA,

		 output wire 	    IRQ_edge,

		 /* I2S out: */
		 output reg 	    i2s_dout,
		 output reg 	    i2s_bclk,
		 output reg 	    i2s_wclk
		 );

   parameter SAMPLE_RATE = 44100;
   parameter CLK_RATE = 48000000;


   /* After DMA, the samples are buffered internally to smooth out
    * any interconnect delays.  This is the buffer size in bytes and
    * must be a multiple of 8 (the MIC beat size) and a minimum of 8:
    */
   localparam INT_BUFFER_SIZE = 64;

   /***************************************************************************/
   /* APB register interface and internal state */

   reg 				    enable;
   reg 				    irq_enable;
   reg 				    bca;
   reg 				    bcb;
   reg 				    bsa;
   reg 				    bsb;
   reg 				    cb; // 0=A, 1=B
   reg [31:0] 			    buf_a_base;
   reg [31:0] 			    buf_b_base;
   reg [1:0]                        buf_size; // 00=4K, 01=1K, 10=0.5K
   reg [7:0]                        volume;
   wire 			    buf_a_valid = (bca != bsa);
   wire 			    buf_b_valid = (bcb != bsb);
   wire				    consume_buffer;


   always @(posedge clk) begin
      // Reg write?
      if (PSEL & PENABLE & PWRITE) begin
         case (PADDR[5:0])
           6'h00: begin // CTRL
	      enable      <= PWDATA[0];
	      irq_enable  <= PWDATA[1];
	      bca         <= PWDATA[5];
	      bcb         <= PWDATA[6];
              buf_size    <= PWDATA[9:8];
	   end

           6'h08: begin // BUF_A_BASE
	      buf_a_base  <= {PWDATA[31:3], 3'h0};
	   end

           6'h0c: begin // BUF_B_BASE
	      buf_b_base  <= {PWDATA[31:3], 3'h0};
	   end

           6'h10: begin // VOL
	      volume      <= PWDATA[7:0];
	   end
	 endcase // case (PADDR[5:0])
      end // if (PSEL & PENABLE & PWRITE)


      /* Buffer management: */
      /* if a buffer is valid and matches cb, it is fetched next
       current fetch completed? toggle bsx corresponding to cb, and cb
       if cb isn't valid when a new fetch is requested, none starts and
       the internal buffer underruns (filling zero)
       */

      // Flags from DMA FSM below
      if (enable && consume_buffer) begin
	 if (cb)
	   bsb   <= ~bsb;
	 else
	   bsa   <= ~bsa;

	 cb      <= ~cb;
      end

      if (reset) begin
	 enable         <= 0;
	 irq_enable     <= 0;
	 bsa            <= 0;
	 bsb            <= 0;
	 cb             <= 0;
      end
   end // always @ (posedge clk)

   /* APB read data: */
   always @(*) begin
      case (PADDR[5:0])
	6'h00: // CTRL
          PRDATA[31:0]  = {22'h0, buf_size, 1'b0, bcb, bca, 3'h0, irq_enable, enable};

	6'h04: // STATUS
          PRDATA[31:0]  = {25'h0, bsb, bsa, cb, 4'h0};

	6'h08: // BUF_A_BASE
          PRDATA[31:0]  = {buf_a_base[31:3], 3'h0};

	6'h0c: // BUF_B_BASE
          PRDATA[31:0]  = {buf_b_base[31:3], 3'h0};

	6'h10: // VOL
          PRDATA[31:0]  = {24'h0, volume[7:0]};

	default:
          PRDATA[31:0]  = 32'h0;
      endcase // case (PADDR[5:0])
   end

   /* IRQ generation: one pulse at system clock */
   assign IRQ_edge = enable && irq_enable && consume_buffer;


   /***************************************************************************/
   /* DMA/buffering */

   /* There are two internal buffers, int_buf_a and int_buf_b.  Each is filled
    * by a MIC burst by the FSM below, and consumed by the output data
    * formatter.
    */

   /* MIC interface */
   wire 			    req_ready;
   reg 				    req_start;
   reg [31:0] 			    req_address;
   wire [7:0] 			    req_len = (INT_BUFFER_SIZE/8)-1;
   wire [63:0] 			    read_data;
   wire 			    read_data_valid;

   mic_m_if #(.NAME("MIC_I2S"))
            mif (.clk(clk),
		 .reset(reset),
		 /* MIC signals */
		 .O_TVALID(O_TVALID), .O_TREADY(O_TREADY),
		 .O_TDATA(O_TDATA), .O_TLAST(O_TLAST),
		 .I_TVALID(I_TVALID), .I_TREADY(I_TREADY),
		 .I_TDATA(I_TDATA), .I_TLAST(I_TLAST),

		 /* Control/data signals */
		 .req_ready(req_ready),
		 .req_start(req_start),
		 .req_RnW(1'b1),
		 .req_beats(req_len),
		 .req_address(req_address[31:3]),
		 .req_byte_enables(5'h1f),

		 .read_data(read_data),
		 .read_data_valid(read_data_valid),
		 .read_data_ready(1'b1),

		 .write_data(64'h0000000000000000),
		 .write_data_valid(1'b0),
		 .write_data_ready()
		 );



   reg [63:0] 			    int_buf_a[((INT_BUFFER_SIZE/8)-1):0];
   reg [63:0] 			    int_buf_b[((INT_BUFFER_SIZE/8)-1):0];

   reg 				    int_buf_a_valid;
   reg 				    int_buf_b_valid;
   wire 			    consume_int_a; // From consumer
   wire 			    consume_int_b; // From consumer
   reg 				    int_wr_buf;

   reg [1:0] 			    fetch_state;
   reg [7:0] 			    fetch_index;
`define FETCH_IDLE      0
`define FETCH_REQ       1
`define FETCH_REQ_DATA  2
   reg [13:0] 			    fetch_total;
   wire 			    start_fetch;
   wire 			    fill_new_buffer;
   reg [13:0]                       buffer_size_bytes;

   // Does the current internal buffer need to be filled?
   assign fill_new_buffer = (!int_buf_a_valid && !int_wr_buf) ||
			    (!int_buf_b_valid && int_wr_buf);

   assign start_fetch = fill_new_buffer &&
			enable &&
			((buf_a_valid && !cb) ||
			 (buf_b_valid && cb));


   always @(posedge clk) begin
      if (consume_int_a)
	int_buf_a_valid      <= 0;
      if (consume_int_b)
	int_buf_b_valid      <= 0;

      case (fetch_state)

	/* Wait for an (external) buffer to become valid and
	 * set up a sequence of fetches from it.
	 */
	`FETCH_IDLE: begin
	   if (start_fetch) begin
	      /* The current buffer is valid (checked in start_fetch),
	       * so choose a base address from cb:
	       */
	      if (cb)
		req_address     <= buf_b_base;
	      else
		req_address     <= buf_a_base;

	      fetch_total       <= 0;
	      fetch_state       <= `FETCH_REQ;

              buffer_size_bytes <= (buf_size == 2'b01) ? 14'd1024 :
                                   ((buf_size == 2'b10) ? 14'd512 : 14'd4096);
	   end
	end

	/* For a chosen external buffer, do a series of
	 * MIC requests to fill internal buffers until the
	 * external buffer is fully consumed.
	 */
	`FETCH_REQ: begin
	   if (fetch_total == buffer_size_bytes || !enable) begin
	      // Finished reading the ext buffer.  Consume it:
	      fetch_state    <= `FETCH_IDLE;
	   end else if (fill_new_buffer && req_ready) begin
	      req_start      <= 1;
	      fetch_index    <= 0;
	      fetch_state    <= `FETCH_REQ_DATA;
	   end
	end

	/* A MIC request is ongoing; capture the incoming data. */
	`FETCH_REQ_DATA: begin
	   req_start <= 0;

	   if (read_data_valid) begin
	      // Write buffer
	      if (int_wr_buf)
		int_buf_b[fetch_index]       <= read_data;
	      else
		int_buf_a[fetch_index]       <= read_data;

	      if (fetch_index == (INT_BUFFER_SIZE/8)-1) begin
		 // Mark int buffer as valid for consumer:
		 if (int_wr_buf && !consume_int_b)
		   int_buf_b_valid   <= 1;
		 else if (!consume_int_a)
		   int_buf_a_valid   <= 1;

		 // And, now other buffer gets our attention:
		 int_wr_buf  <= ~int_wr_buf;

		 req_address <= req_address + INT_BUFFER_SIZE;
		 fetch_total <= fetch_total + INT_BUFFER_SIZE;
		 fetch_state <= `FETCH_REQ;

	      end else begin
		 fetch_index <= fetch_index + 1;
	      end
	   end
	end
      endcase // case (fetch_state)

      if (reset) begin
	 fetch_state    <= `FETCH_IDLE;
	 req_start      <= 0;
	 int_wr_buf     <= 0; // a

	 int_buf_a_valid        <= 0;
	 int_buf_b_valid        <= 0;
      end
   end

   assign consume_buffer = (fetch_state == `FETCH_REQ) &&
			   (fetch_total == buffer_size_bytes);


   /***************************************************************************/
   /* Buffer output formatting */

   reg [9:0] 			    out_buf_idx; // Up to 1K buffer!
   wire [63:0] 			    out_dword;
   // Indicates which (internal) buffer is being read:
   reg 				    int_rd_buf;
   // At the end/last entry of the current buffer?
   wire 			    int_buf_end;
   // Signals that the shifter has grabbed the buffer entry:
   wire 			    out_consume;
   wire 			    buf_underrun;

   always @(posedge clk) begin
      // Output data is selected below
      if ((int_rd_buf && int_buf_b_valid) ||
	  (!int_rd_buf && int_buf_a_valid)) begin

	 // FIXME: read 16b at a time, pipeline through volume scaling towards SR

	 if (out_consume) begin // added
	    if (int_buf_end) begin
	       out_buf_idx      <= 0;

	       // Buffer flagged as consumed; now look at other:
	       int_rd_buf       <= ~int_rd_buf;

	    end else begin
	       out_buf_idx <= out_buf_idx + 8;
	    end
	 end
      end

      if (reset) begin
	 int_rd_buf     <= 0; // a
	 out_buf_idx    <= 0;
      end
   end

   assign out_dword     = (int_rd_buf && int_buf_b_valid) ? int_buf_b[out_buf_idx[9:3]]
			  : ( (!int_rd_buf && int_buf_a_valid) ? int_buf_a[out_buf_idx[9:3]]
			      : 64'h0 /* Underflow */ );

   assign buf_underrun  = out_consume && (!int_rd_buf && !int_buf_a_valid) ||
			  (int_rd_buf && !int_buf_b_valid);
   assign int_buf_end   = (out_buf_idx == INT_BUFFER_SIZE-8);
   assign consume_int_a = !int_rd_buf && int_buf_end && out_consume;
   assign consume_int_b = int_rd_buf && int_buf_end && out_consume;


   /***************************************************************************/
   /* Volume control and framing */

   /* The shifter asks for a *32b* sample using consume_word.
    * This is generated from a 16b sample in the buffer, which is 1/4 of the
    * current out_dword.  This FSM counts 0-3 (resetting every two_word_strobe)
    * to select the 16b sample of interest.
    */

   reg [1:0] 			    sample_idx;
   wire 			    two_word_strobe;
   wire 			    consume_word;
   reg [15:0] 			    out_sample; // Wire

   always @(posedge clk) begin
      if (two_word_strobe) begin
	 sample_idx  <= 0;
      end else if (consume_word) begin
	 sample_idx  <= sample_idx + 1;
      end

      if (reset) begin
	 sample_idx     <= 0;
      end
   end // always @ (posedge clk)

   always @(*) begin
      if (sample_idx == 0)
	out_sample      = out_dword[15:0];
      else if (sample_idx == 1)
	out_sample      = out_dword[31:16];
      else if (sample_idx == 2)
	out_sample      = out_dword[47:32];
      else // (sample_idx == 3)
	out_sample      = out_dword[63:48];
   end

   assign out_consume = two_word_strobe;

   /* A little trick here:  delay the sample by 4 clocks (keeping in
    * sync with the framing of the serialiser), expanding and
    * scaling volume in an unhurried manner.
    */
   reg signed [9:0] 		    vpl_svol;
   reg signed [15:0] 		    vpl_sample1;
   reg signed [24:0] 		    vpl_sample2;
   reg signed [24:0] 		    vpl_sample3;
   reg signed [24:0] 		    vpl_sample4;

   always @(posedge clk) begin
      vpl_svol       <= volume + 1;

      if (consume_word) begin
	 vpl_sample1    <= out_sample;
	 // 16*10 multiply => 26 bits, though only 9 bits of vol
	 // are the value; we end up truncating to 24 anyway.
	 vpl_sample2    <= vpl_sample1 * vpl_svol;
	 // Dummy cycles permit the tools to optimise the multiply
	 vpl_sample3    <= vpl_sample2;
	 vpl_sample4    <= vpl_sample3;
	 // The final value is a 24-bit value in 23:0; see load_val
      end

      if (reset) begin
         /* We could reset these to avoid a glitch, if we care: */
         /*
	  vpl_sample1    <= 16'h0;
	  vpl_sample2    <= 16'h0;
	  vpl_sample3    <= 32'h0;
	  vpl_sample4    <= 32'h0;
          */
      end
   end


   /***************************************************************************/
   /* I2S clock rate/strobe generation */

   wire 			    bclk_rising_strobe;
   wire 			    bclk_falling_strobe;
   wire 			    wclk_rising_strobe;
   wire 			    wclk_falling_strobe;

   r_i2s_apb_crg #(.SAMPLE_RATE(SAMPLE_RATE),
		   .CLK_RATE(CLK_RATE))
                 CRG
                 (.clk(clk),
		  .reset(reset),
		  .bclk_rising_strobe(bclk_rising_strobe),
		  .bclk_falling_strobe(bclk_falling_strobe),
		  .wclk_rising_strobe(wclk_rising_strobe),
		  .wclk_falling_strobe(wclk_falling_strobe),
		  .two_word_strobe(two_word_strobe)
		  );


   /***************************************************************************/
   /* Output generation: */

   /* Left is top word, right is bottom word */
   reg [31:0] 			    shift_reg;
   wire [31:0] 			    load_val = {vpl_sample4[23:0], 8'h0};

   always @(posedge clk) begin
      /* Note that, unlike the "left-justified" format, the I2S
       * output data bit trails the word clock edges by one BCLK.
       *
       * Data is output MSB first, two 32-bit words per frame.
       */
      if (enable) begin
	 if (bclk_rising_strobe) begin
	    // Device samples data on this edge
	    i2s_bclk    <= 1;
	 end else if (bclk_falling_strobe) begin
	    // New data out!
	    i2s_dout    <= shift_reg[31];
	    shift_reg   <= {shift_reg[30:0], 1'bx};
	    i2s_bclk    <= 0;
	 end

	 // A new 32b sample is loaded on both edges of WCLK:
	 if (wclk_rising_strobe) begin
	    i2s_wclk    <= 1; // R
	    shift_reg   <= load_val;
	 end else if (wclk_falling_strobe) begin
	    i2s_wclk    <= 0; // L
	    shift_reg   <= load_val;
	 end
      end else begin // if (enable)

	 shift_reg      <= 0;
	 i2s_dout       <= 0;
	 i2s_bclk       <= 0;
	 i2s_wclk       <= 0;
      end
   end // always @ (posedge clk)

   assign consume_word = wclk_rising_strobe || wclk_falling_strobe;

endmodule // r_i2s_apb


/* A trivially-simple clock rate generator providing strobes
 * for BCLK/WCLK edges.  These strobes are used to load sample data
 * and shift bits.
 */
module r_i2s_apb_crg(input wire  clk,
		     input wire  reset,

		     output wire bclk_rising_strobe,
		     output wire bclk_falling_strobe,

		     output wire wclk_rising_strobe,
		     output wire wclk_falling_strobe,

		     // Used to synchronise reading a pair of samples (64b)
		     output wire two_word_strobe
		     );

   parameter SAMPLE_RATE = 44100;
   parameter CLK_RATE = 48000000;

   localparam CLKS_PER_BCLK = CLK_RATE/SAMPLE_RATE/2/32;
   localparam BCLKS_PER_WCLK = 64;

   reg [7:0] 			 bcounter;
   reg [5:0] 			 wcounter;
   reg 				 pair;

   always @(posedge clk) begin
      if (bcounter == CLKS_PER_BCLK-1) begin
	 bcounter     <= 0;
	 if (wcounter == BCLKS_PER_WCLK-1) begin
	    wcounter  <= 0;
	    pair      <= ~pair;
	 end else begin
	    wcounter  <= wcounter + 1;
	 end
      end else begin
	 bcounter     <= bcounter + 1;
      end

      if (reset) begin
	 bcounter        <= 0;
	 wcounter        <= 0;
	 pair            <= 0;
      end
   end

   assign bclk_rising_strobe = (bcounter == 0);
   assign bclk_falling_strobe = (bcounter == CLKS_PER_BCLK/2);

   assign wclk_rising_strobe = (bclk_falling_strobe && (wcounter == BCLKS_PER_WCLK/2));
   assign wclk_falling_strobe = (bclk_falling_strobe && (wcounter == 0));

   assign two_word_strobe = pair & wclk_falling_strobe;

endmodule
