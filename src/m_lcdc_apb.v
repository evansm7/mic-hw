/* Video display controller with MIC for DMA, APB for configuration.
 *
 * Output is 24bits/clk plus HS, VS, DE; supports 1/2/4/8bpp palette modes and
 * 16/32bpp true-colour.  Also supports pixel- and line-doubling.
 *
 * ME, 24/6/2019
 *
 * Derived from "pulse_timer"'s apb_lcdc.v version 2ab97dea4a0435d2b93b19aaa3f0cedc0bc48c18 29/6/2017
 *
 * There are three clocks in use:
 * - System clock (MIC, internals)
 * - Pixel clock (Pixel output)
 * - APB clock (Todo: this can probably use the system clock, longer-term)
 *
 * TODO:
 * - Reconcile APB/sysclk
 * - Implement blanking output for plasma panel
 * - Fix position of frame re-init
 * - The CDC of config-to-pclk is a bit ... nasty/incorrect.
 * - Refactor/split: both messier and more complex than necessary
 *
 * ---------------------------------------------------------------------------
 *
 * Register interface:
 *      Offset          Reg
 * 00                   [9:0]   = vert (RO)
 *                      [26:16] = horiz (RO)
 *                      [30]    = border enable
 *                      [31]    = display enable
 *
 * 04                   [10:0]  = DISP_WIDTH
 *                      [15:11] = PIX_MULT_X (pixels per pixel, minus one)
 *                      [26:16] = DISP_HEIGHT
 *                      [31:27] = PIX_MULT_Y (rows per row, minus one)
 *
 * 08                   [7:0]   = VSYNC_WIDTH
 *                      [15:8]  = VSYNC_FRONT_PORCH
 *                      [23:16] = VSYNC_BACK_PORCH
 *                      [24]    = VSYNC_POLARITY
 *
 * 0c                   [7:0]   = HSYNC_WIDTH
 *                      [15:8]  = HSYNC_FRONT_PORCH
 *                      [23:16] = HSYNC_BACK_PORCH
 *                      [24]    = HSYNC_POLARITY
 *                      [25]    = DE_POLARITY
 *                      [26]    = BLANK_POLARITY
 *
 * 10                   [31:3]  = FB_BASE_ADDR
 *
 * 14                   [31:0]  = ID_FIELD = 0x44430001
 *
 * 18                   [10:0]  = DWORDS_PER_LINE        (BPP*DISP_WIDTH/PIX_MULT_X/64)-1
 *                                minus one.
 *                                In the current implementation, a line is 2KB max (i.e. 512 words).
 *                      [13:11] = BPPL2
 *                                where BPP = 1<<BPPL2
 *                                Depths < 16 (BPPL2=4) use palette.
 *
 * 1c                   [7:0]   = PALETTE_OFFSET
 *                                Sets the palette entry written when register 0x24 is written
 *
 * 20                   [7:0]   = PAL_R
 *                      [15:8]  = PAL_G
 *                      [23:16] = PAL_B
 *
 *
 *
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


/* Defaults for registers: */
`define DISPENABLE      0 /* Disabled out of reset */
`define DISPWIDTH       640
`define DISPHEIGHT      480
`define DISPXMUL        1 /* Doubled */
`define DISPYMUL        1 /*  '' ''  */
`define VSYNCWIDTH      3
`define VSYNCFRONTPORCH 1
`define VSYNCBACKPORCH  26
`define HSYNCWIDTH      64
`define HSYNCFRONTPORCH 16
`define HSYNCBACKPORCH  120

`define BLANKENDWIDTH   11 // This happens immediately from last visible (DE) line (during VSYNC front porch)
`define BLANKSTARTWIDTH 10 // This happens immediately before start of first visible (DE) line

`define VSYNCPOLARITY   1 /* -ve */
`define HSYNCPOLARITY   1 /* -ve */
`define BLANKPOLARITY   1 /* -ve */
`define DEPOLARITY      1 /* -ve */

`define ID_FIELD        32'h44430001
`define BORDER_ENABLE   0

`define BPPL2           3
`define DWORDS_PER_LINEM1        ((1<<`BPPL2)*`DISPWIDTH/(`DISPXMUL+1)/64)-1

`define FETCH_MAXBURST  32 /* 8-byte beats */


module m_lcdc_apb(input wire         sys_clk, /* System clock, MIC */
                  input wire         reset,

                  /* MIC request port out */
                  output wire        O_TVALID,
                  input wire         O_TREADY,
                  output wire [63:0] O_TDATA,
                  output wire        O_TLAST,

                  /* MIC response port in */
                  input wire         I_TVALID,
                  output wire        I_TREADY,
                  input wire [63:0]  I_TDATA,
                  input wire         I_TLAST,

                  /* APB completer */
                  input wire         PCLK,
                  input wire         nRESET,
                  input wire         PENABLE,
                  input wire         PSEL,
                  input wire         PWRITE,
                  input wire [31:0]  PWDATA,
                  input wire [5:0]   PADDR,
                  output reg [31:0]  PRDATA,

                  /* Video data */
                  input wire         pixel_clk,
                  output wire [23:0] rgb,
                  output wire        hs,
                  output wire        vs,
                  output wire        de,
                  output wire        blank,

                  /* Interrupt pulses/edges (w.r.t. PCLK) from HS/VS */
                  output reg         IRQ_VS,
                  output reg         IRQ_HS
                  );

   reg [10:0]   horiz;
   reg [10:0]   disp_x;
   reg [10:0]   vert;

   wire [21:0] 	xy = {vert[10:0], horiz[10:0]};

   /* Final outputs are registered here: */
   reg [23:0]   rgb_p;
   /* Three cycles delay for internal signals to external */
   reg          vs_p[2:0];
   reg          hs_p[2:0];
   reg          de_p[2:0];
   reg          blank_p[2:0];
   /* Two cycle delay for border, as it's folded into the post-palette rgb_p */
   reg  [7:0]   border_p[2:0];

   assign rgb   = rgb_p;
   assign hs    = hs_p[0];
   assign vs    = vs_p[0];
   assign de    = de_p[0];
   assign blank = blank_p[0];

   wire         int_den;
   wire         int_hs;
   wire         int_vs;
   wire 	int_blank;
   wire         int_hs_noninv;
   wire         int_vs_noninv;

   /* Timing parameters */
   reg [10:0]   tim_disp_width;
   reg [10:0]   tim_disp_height;
   reg [4:0]    tim_disp_x_mul;
   reg [4:0]    tim_disp_y_mul;
   reg [7:0]    tim_vsync_width;
   reg [7:0]    tim_vsync_fporch;
   reg [7:0]    tim_vsync_bporch;
   reg [7:0]    tim_hsync_width;
   reg [7:0]    tim_hsync_fporch;
   reg [7:0]    tim_hsync_bporch;
   reg [7:0]    tim_blank_start_width;
   reg [7:0]    tim_blank_end_width;
   reg [10:0]   tim_dwords_per_line_m1;
   reg          hs_polarity_inv;
   reg          vs_polarity_inv;
   reg		de_polarity_inv;
   reg		blank_polarity_inv;
   reg          display_enable;
   reg          border_enable;
   reg [2:0]    bppl2;          // log2(BPP)

   /* Derived timing params */
   reg [10:0]   tim_width_m1;   // tim_disp_width + tim_hsync_width + tim_hsync_fporch + tim_hsync_bporch - 1
   reg [10:0]   tim_height_m1;  // tim_disp_height + tim_vsync_width + tim_vsync_fporch + tim_vsync_bporch - 1
   reg [10:0]   tim_hstart;     // tim_hsync_width + tim_hsync_bporch
   reg [10:0]   tim_hlast;      // tim_hsync_width + tim_hsync_bporch + tim_disp_width - 1
   reg [10:0]   tim_vstart;     // tim_vsync_width + tim_vsync_bporch
   reg [10:0]   tim_vlast;      // tim_vsync_width + tim_vsync_bporch + tim_disp_height - 1
   /* Blank signal is a bit strange, as it strobes on a vsync basis, but we want
    * control of it to consider X as well.  Although it is active at vsync time,
    * it trails hsync so start/end points must consider X.
    * Blank A is at start of frame, blank B is at end of frame:
    */
   reg [21:0] 	tim_blank_a_start; 	// (tim_vsync_width + tim_vsync_bporch - tim_blank_start_width, hsync)
   reg [21:0] 	tim_blank_a_end; 	// (tim_vsync_width + tim_vsync_bporch, hsync+1)
   reg [21:0] 	tim_blank_b_start; 	// (tim_vsync_width + tim_vsync_bporch + tim_disp_height, hsync)
   reg [21:0] 	tim_blank_b_end; 	// (tim_vsync_width + tim_vsync_bporch + tim_disp_height + tim_blank_end_width, hsync+1)

   reg          sum;

   wire 	on_display;
   assign       on_display = display_enable &
                             (horiz >= tim_hstart) &
                             (horiz <= tim_hlast) &
                             (vert >= tim_vstart) &
                             (vert <= tim_vlast);
   assign       int_den = on_display ^ de_polarity_inv;
   assign       int_hs_noninv  = (display_enable & (horiz < tim_hsync_width));
   assign       int_vs_noninv  = (display_enable & (vert < tim_vsync_width));

   assign       int_hs  = int_hs_noninv ^ hs_polarity_inv;
   assign       int_vs  = int_vs_noninv ^ vs_polarity_inv;

   assign       int_blank = (display_enable & (((xy > tim_blank_a_start) & (xy < tim_blank_a_end)) |
					       ((xy > tim_blank_b_start) & (xy < tim_blank_b_end)))
			     ) ^ blank_polarity_inv;

   /* Used to reset DMA: */
   wire         last_vsync_line;
   assign       last_vsync_line = (vert == tim_vsync_width);

   /* For palette lookup, pixel value drives palette BRAM index.  Otherwise, pixel value is latched here. */
   reg [23:0]   non_palette_output_latch_rgb;

   wire         palette_in_use;
   assign       palette_in_use  = !bppl2[2];    /* BPPL2 <= 3 (i.e. 1-8 bits) */

   /* White border for debugging: */
   wire [7:0]   border;
   assign       border = !display_enable || (horiz == tim_hstart || horiz == tim_hlast ||
                          vert == tim_vstart || vert == tim_vlast) ? 8'hff : 8'h00;

   /* For RAM interface: */
   wire [63:0]  fetch_data;
   wire         fetch_data_en;
   reg [7:0] 	fetch_addr;             /* See RAMs: 256*8 (2KB) per bank. */
   reg          fetch_buffer;

   reg 		frame_init_d;           /* Display version */
   reg 		frame_init_f;           /* Fetcher version */

   reg  [31:3]  fb_base_addr;

   reg [10:0]   disp_pixel_index;	/* Maxiumum 2048 px wide, matching DISP_WIDTH */
   reg [4:0]    disp_pixel_index_last;
   reg          disp_buffer;

   reg [31:0] 	palette_read_data;

   /* Buffer management:
    *
    * Support >2 buffers by having a multi-bit reg for buffer_display and
    * buffer_fetcher.
    * A buffer can be displayed if buffer_display[n] == buffer_fetcher[n].
    *
    * NOTE: buffer_display and buffer_fetcher are managed in different clock
    * domains!
    *
    * After displaying buffer n, it's consumed by toggling buffer_display[n].
    *
    * The display hardware is reset at start of frame to begin with buffer 0.
    * The display maintains buffer_current, and uses buffers in RR order.
    *
    * Overrun has occurred if, when completing display of a buffer, the
    * flag-toggle makes the flags equal rather than different (i.e. the fetch
    * hasn't completed by the time the previous user completes).
    */
   reg [1:0] 	buffer_display;
   reg [1:0] 	buffer_fetcher;
   reg 		buffer_current;

   reg [5:0]    x_ctr;
   reg [5:0]    y_ctr;


   ////////////////////////////////////////////////////////////////////////////////

   /* Timing FSM */
   always @ (posedge pixel_clk) begin
      /* We've 1 cycle for this mux, easy.  Nicer than muxing afer the palette bram in same cycle. */

      /* Note: bppl2 is from the other clock domain, but
       * that's OK.  It doesn't* change and if anything here
       * does go metastable, then ... it will presumably
       * resolve reasonably quickly.  :-)
       */

      if (palette_in_use) begin
         /* Output RGB latches direct from the BRAM output.  Note LE BGR in palette, RGB in output. */
         if (border_enable)
           rgb_p         <= {palette_read_data[7:0],palette_read_data[15:8],palette_read_data[23:16]}
                            | {border_p[0], border_p[0], border_p[0]};
         else
           rgb_p         <= {palette_read_data[7:0],palette_read_data[15:8],palette_read_data[23:16]};
      end else begin
         if (bppl2 == 5) begin
            /* 32BPP:
             * Output is (MSB) RGB (LSB) order; 32BPP framebuffer is ABGR order:
             */
            non_palette_output_latch_rgb <= {disp_data[7:0],disp_data[15:8],disp_data[23:16]};
         end else if (bppl2 == 4) begin
            /* 16BPP (565): */
            non_palette_output_latch_rgb <= disp_pixel_index_last[0] ?
                                            { disp_data[20:16],
                                                {3{disp_data[16]}}, disp_data[26:21],
                                                {2{disp_data[21]}}, disp_data[31:27],
                                                {3{disp_data[27]}} } :
                                              { disp_data[4:0],
                                                  {3{disp_data[0]}}, disp_data[10:5],
                                                  {2{disp_data[5]}}, disp_data[15:11],
                                                  {3{disp_data[11]}} };
               end

         if (border_enable) begin
            rgb_p <= non_palette_output_latch_rgb | {border_p[0], border_p[0], border_p[0]};
         end else begin
            rgb_p <= non_palette_output_latch_rgb;
         end
      end
      /* Since we're using den internally to enable RAMs and
       * they'll take a cycle, plus palette lookup (or latch into
       * non_palette_output_latch_rgb) cycle, then a final mux cycle,
       * delay internal signals by 3 cycles to match pixel output
       * pipeline:
       */
      vs_p[2]     <= int_vs;
      hs_p[2]     <= int_hs;
      de_p[2]     <= int_den;
      blank_p[2]  <= int_blank;
      vs_p[0]     <= vs_p[1];
      hs_p[0]     <= hs_p[1];
      de_p[0]     <= de_p[1];
      blank_p[0]  <= blank_p[1];
      vs_p[1]     <= vs_p[2];
      hs_p[1]     <= hs_p[2];
      de_p[1]     <= de_p[2];
      blank_p[1]  <= blank_p[2];

      border_p[1] <= border;
      border_p[0] <= border_p[1];

      /* Store the lower bits of the pixel index that were used
       * 'last cycle' to fetch whatever is present at the
       * disp_data BRAM outputs this cycle:
       */
      disp_pixel_index_last <= disp_pixel_index[4:0];

      if (horiz == tim_width_m1) begin
         /* End of line. */
         horiz         <= 0;
         disp_x        <= 0;
         disp_pixel_index <= 0;
         x_ctr         <= 0;

         if (vert == tim_height_m1) /* End of last line */
           begin
              vert     <= 0;
              y_ctr    <= 0;

              /* Reset display state */
	      buffer_current      <= 0;
	      buffer_display[1:0] <= 0;

	      /* Signal to the fetcher that it should re-init.
	       * If the display/fetcher versions of frame_init are
	       * different, then the fetcher performs
	       * start-of-frame re-initialisation and toggles its
	       * version, making them the same.
	       *
	       * TODO:  Don't do this right at the end of the frame; do it
	       * towards the end of VSYNC.
	       */
	      frame_init_d <= ~frame_init_d;
           end
         else
           begin
              vert     <= vert + 1;
           end
      end else begin
         /* Regular pixel, not at end of line. */
         horiz                 <= horiz + 1;

         if (on_display) begin    // If on-screen pixel
            // Count N output pixels for each mem pixel:
            if (x_ctr != tim_disp_x_mul) begin
               x_ctr           <= x_ctr + 1;
            end else begin
               x_ctr           <= 0;
               /* Move onto next pixel; this might be to select a new
                * pixel from 32-bit read data or to read new data w/
                * new address.
                *
                * This is used to generate read data address and also
                * to select a pixel from read word, depending on the BPP:
                */
               disp_pixel_index <= disp_pixel_index + 1;
            end
            disp_x    <= disp_x + 1;

            if (horiz == tim_hlast) begin
               /* Do we want to use the buffer again for the next line? */
               if (y_ctr != tim_disp_y_mul) begin
                  y_ctr <= y_ctr + 1;
               end else begin
                  y_ctr        <= 0;
                  /* We're displaying the last pixel and have used the buffer for the last time.
                   ********************************************************************************
                   * Flag the currently-displayed buffer as consumed.
                   ********************************************************************************
                   * The fetcher machine will then refill it.
                   */
		  if (buffer_current == 0) begin
		     buffer_display[0] <= ~buffer_display[0];
		     buffer_current <= 1;
		  end else begin
		     buffer_display[1] <= ~buffer_display[1];
		     buffer_current <= 0;
		  end
               end
            end
         end
      end

      if (reset) begin
         hs_p[0]                      <= 1;
         vs_p[0]                      <= 1;
         de_p[0]                      <= 0;
	 blank_p[0]                   <= 1;
         hs_p[1]                      <= 1;
         vs_p[1]                      <= 1;
         de_p[1]                      <= 0;
	 blank_p[1]                   <= 1;

         border_p[0]                  <= 0;
         border_p[1]                  <= 0;

         non_palette_output_latch_rgb <= 0;

	 buffer_current               <= 0;
	 buffer_display[1:0]          <= 0;
	 frame_init_d                 <= 0;
      end
   end


   ////////////////////////////////////////////////////////////////////////////////

   /* RAMs for pixel data */

   /* The plan for timing output:
    * On first pixel of line, read RAM to get a word.
    *  Start a timer for number of pixels this word is used for.
    *  Start a 2nd timer for number of pixels a slice of this word is used for.
    *
    * E.g., for 2BPP, pixel doubled: 32bits is 16 x 2-bit pixels; word
    *  is used for 32 pixels and slice is rotated into new 2-bit slice
    *  every 2 pixels.  (MUX) At HSYNC, decrement counter for number
    *  of lines that this buffer is used for.  If zero, mark buffer as
    *  consumed and move to other buffer.  Reload counter.  Only
    *  consume buffers on visible lines.  (No need to mark consumed on
    *  last line.)
    *
    * For read machine, fill a buffer when it is marked consumed.  At
    * line -1, mark both buffers consumed.  (Both buffers filled in
    * order 0 then 1.)  Consumed flag is a producer vs consumer flag
    * being different.
    */

   /* See comment below regarding display width limits. */
   wire [8:0]   disp_addr;
   assign disp_addr[8:0]  = (bppl2 == 0) ? {3'b000, disp_pixel_index[10:5]} :   /* 1BPP */
                            (bppl2 == 1) ? {2'b00, disp_pixel_index[10:4]} :    /* 2BPP */
                            (bppl2 == 2) ? {1'b0, disp_pixel_index[10:3]} :     /* 4BPP */
                            (bppl2 == 3) ? {disp_pixel_index[10:2]} :     	/* 8BPP */
                            (bppl2 == 4) ? {disp_pixel_index[9:1]} :      	/* 16BPP */
                            disp_pixel_index[8:0];                              /* 32BPP */

   /* Memory buffers for displayline/fetchline A/B.  Each buffer is 2KB. */

   /* 4KB, 2x banks of 512 words:
    * FIXME, increase for greater bit-depths
    *
    * The current design implies a buffer per line, so for a 2KB buffer that
    * limits display width to 512px @32BPP, 1024px @16BPP, or (the index limit)
    * 2048px at 8BPP and below.
    */
   reg [63:0] 	video_ram [511:0];
   reg [63:0] 	disp_data_read;
   reg          disp_data_read_wordsel;
   reg [31:0] 	disp_data; // Wire

   /* Idiom to infer dual-ported RAM; one write, one read: */
   always @(posedge sys_clk) begin
	if (fetch_data_en) begin
	   /* 64-bit write port */
	   video_ram[{fetch_buffer, fetch_addr}] <= fetch_data[63:0];
	end
     end

   always @(posedge pixel_clk) begin
      // Was if (on_display)
      disp_data_read <= video_ram[{buffer_current, disp_addr[8:1]}];
      disp_data_read_wordsel <= disp_addr[0];
   end

   always @(*) begin
      disp_data = disp_data_read_wordsel ? disp_data_read[63:32] : disp_data_read[31:0];
   end

   ////////////////////////////////////////////////////////////////////////////////

   /* Palette RAM:
    * Two ports; one for reads for pixel lookups, one for write from programming interface.
    */
   wire [7:0]   palette_read_address;
   wire         palette_write_enable;
   reg [7:0]    palette_write_address;

   /* Infer a BRAM for this plz: */
   reg [31:0] 	pal_ram[255:0];
   reg [31:0] 	idx;
   initial begin
      for (idx = 0; idx < 256; idx = idx + 1) begin
	 pal_ram[idx] = idx | (idx+1)<<8 | (idx+2)<<16;
      end
   end

   always @(posedge PCLK)
     begin
	/* 32-bit write port */
	if (palette_write_enable) begin
	   pal_ram[palette_write_address] <= PWDATA[31:0];
	end
     end
   always @(posedge pixel_clk)
     begin
	/* 32-bit read port */
	if (display_enable && palette_in_use) begin
	   palette_read_data <= pal_ram[palette_read_address];
	end
     end

   /* I tried operators like disp_data[ disp_pixel_index_last[4:0] +: 1 ];
    * but that didn't seem to work... so do this mux the dumb way:
    */
   wire         pixel_value_1bpp;
   /* Pixels in a byte, in the rest of the world, seem to go right to left... */
`ifdef PIXEL_ORDER_STRICTLY_INCREASE
   assign pixel_value_1bpp = disp_pixel_index_last[4:0] == 0 ? disp_data[0] :
                             disp_pixel_index_last[4:0] == 1 ? disp_data[1] :
                             disp_pixel_index_last[4:0] == 2 ? disp_data[2] :
                             disp_pixel_index_last[4:0] == 3 ? disp_data[3] :
                             disp_pixel_index_last[4:0] == 4 ? disp_data[4] :
                             disp_pixel_index_last[4:0] == 5 ? disp_data[5] :
                             disp_pixel_index_last[4:0] == 6 ? disp_data[6] :
                             disp_pixel_index_last[4:0] == 7 ? disp_data[7] :
                             disp_pixel_index_last[4:0] == 8 ? disp_data[8] :
                             disp_pixel_index_last[4:0] == 9 ? disp_data[9] :
                             disp_pixel_index_last[4:0] == 10 ? disp_data[10] :
                             disp_pixel_index_last[4:0] == 11 ? disp_data[11] :
                             disp_pixel_index_last[4:0] == 12 ? disp_data[12] :
                             disp_pixel_index_last[4:0] == 13 ? disp_data[13] :
                             disp_pixel_index_last[4:0] == 14 ? disp_data[14] :
                             disp_pixel_index_last[4:0] == 15 ? disp_data[15] :
                             disp_pixel_index_last[4:0] == 16 ? disp_data[16] :
                             disp_pixel_index_last[4:0] == 17 ? disp_data[17] :
                             disp_pixel_index_last[4:0] == 18 ? disp_data[18] :
                             disp_pixel_index_last[4:0] == 19 ? disp_data[19] :
                             disp_pixel_index_last[4:0] == 20 ? disp_data[20] :
                             disp_pixel_index_last[4:0] == 21 ? disp_data[21] :
                             disp_pixel_index_last[4:0] == 22 ? disp_data[22] :
                             disp_pixel_index_last[4:0] == 23 ? disp_data[23] :
                             disp_pixel_index_last[4:0] == 24 ? disp_data[24] :
                             disp_pixel_index_last[4:0] == 25 ? disp_data[25] :
                             disp_pixel_index_last[4:0] == 26 ? disp_data[26] :
                             disp_pixel_index_last[4:0] == 27 ? disp_data[27] :
                             disp_pixel_index_last[4:0] == 28 ? disp_data[28] :
                             disp_pixel_index_last[4:0] == 29 ? disp_data[29] :
                             disp_pixel_index_last[4:0] == 30 ? disp_data[30] :
                             disp_data[31];
`else
   assign pixel_value_1bpp = disp_pixel_index_last[4:0] == 0 ? disp_data[7] :
                             disp_pixel_index_last[4:0] == 1 ? disp_data[6] :
                             disp_pixel_index_last[4:0] == 2 ? disp_data[5] :
                             disp_pixel_index_last[4:0] == 3 ? disp_data[4] :
                             disp_pixel_index_last[4:0] == 4 ? disp_data[3] :
                             disp_pixel_index_last[4:0] == 5 ? disp_data[2] :
                             disp_pixel_index_last[4:0] == 6 ? disp_data[1] :
                             disp_pixel_index_last[4:0] == 7 ? disp_data[0] :
                             disp_pixel_index_last[4:0] == 8 ? disp_data[15] :
                             disp_pixel_index_last[4:0] == 9 ? disp_data[14] :
                             disp_pixel_index_last[4:0] == 10 ? disp_data[13] :
                             disp_pixel_index_last[4:0] == 11 ? disp_data[12] :
                             disp_pixel_index_last[4:0] == 12 ? disp_data[11] :
                             disp_pixel_index_last[4:0] == 13 ? disp_data[10] :
                             disp_pixel_index_last[4:0] == 14 ? disp_data[9] :
                             disp_pixel_index_last[4:0] == 15 ? disp_data[8] :
                             disp_pixel_index_last[4:0] == 16 ? disp_data[23] :
                             disp_pixel_index_last[4:0] == 17 ? disp_data[22] :
                             disp_pixel_index_last[4:0] == 18 ? disp_data[21] :
                             disp_pixel_index_last[4:0] == 19 ? disp_data[20] :
                             disp_pixel_index_last[4:0] == 20 ? disp_data[19] :
                             disp_pixel_index_last[4:0] == 21 ? disp_data[18] :
                             disp_pixel_index_last[4:0] == 22 ? disp_data[17] :
                             disp_pixel_index_last[4:0] == 23 ? disp_data[16] :
                             disp_pixel_index_last[4:0] == 24 ? disp_data[31] :
                             disp_pixel_index_last[4:0] == 25 ? disp_data[30] :
                             disp_pixel_index_last[4:0] == 26 ? disp_data[29] :
                             disp_pixel_index_last[4:0] == 27 ? disp_data[28] :
                             disp_pixel_index_last[4:0] == 28 ? disp_data[27] :
                             disp_pixel_index_last[4:0] == 29 ? disp_data[26] :
                             disp_pixel_index_last[4:0] == 30 ? disp_data[25] :
                             disp_data[24];
   // FIXME: Determine whether 2BPP/4BBP need same treatment ;(
`endif

   wire [1:0]   pixel_value_2bpp;
   assign pixel_value_2bpp = disp_pixel_index_last[3:0] == 0 ? disp_data[1:0] :
                             disp_pixel_index_last[3:0] == 1 ? disp_data[3:2] :
                             disp_pixel_index_last[3:0] == 2 ? disp_data[5:4] :
                             disp_pixel_index_last[3:0] == 3 ? disp_data[7:6] :
                             disp_pixel_index_last[3:0] == 4 ? disp_data[9:8] :
                             disp_pixel_index_last[3:0] == 5 ? disp_data[11:10] :
                             disp_pixel_index_last[3:0] == 6 ? disp_data[13:12] :
                             disp_pixel_index_last[3:0] == 7 ? disp_data[15:14] :
                             disp_pixel_index_last[3:0] == 8 ? disp_data[17:16] :
                             disp_pixel_index_last[3:0] == 9 ? disp_data[19:18] :
                             disp_pixel_index_last[3:0] == 10 ? disp_data[21:20] :
                             disp_pixel_index_last[3:0] == 11 ? disp_data[23:22] :
                             disp_pixel_index_last[3:0] == 12 ? disp_data[25:24] :
                             disp_pixel_index_last[3:0] == 13 ? disp_data[27:26] :
                             disp_pixel_index_last[3:0] == 14 ? disp_data[29:28] :
                             disp_data[31:30];

   wire [3:0]   pixel_value_4bpp;
   assign pixel_value_4bpp = disp_pixel_index_last[2:0] == 0 ? disp_data[3:0] :
                             disp_pixel_index_last[2:0] == 1 ? disp_data[7:4] :
                             disp_pixel_index_last[2:0] == 2 ? disp_data[11:8] :
                             disp_pixel_index_last[2:0] == 3 ? disp_data[15:12] :
                             disp_pixel_index_last[2:0] == 4 ? disp_data[19:16] :
                             disp_pixel_index_last[2:0] == 5 ? disp_data[23:20] :
                             disp_pixel_index_last[2:0] == 6 ? disp_data[27:24] :
                             disp_data[31:28];

   wire [7:0]   pixel_value_8bpp;
   assign pixel_value_8bpp = disp_pixel_index_last[1:0] == 0 ? disp_data[7:0] :
                             disp_pixel_index_last[1:0] == 1 ? disp_data[15:8] :
                             disp_pixel_index_last[1:0] == 2 ? disp_data[23:16] :
                             disp_data[31:24];
   assign palette_read_address = (bppl2 == 0) ? { 7'b0000000, pixel_value_1bpp } :
                                 (bppl2 == 1) ? { 6'b000000, pixel_value_2bpp } :
                                 (bppl2 == 2) ? { 4'b0000, pixel_value_4bpp } :
                                 /* bppl2 == 3 */ pixel_value_8bpp;


   ////////////////////////////////////////////////////////////////////////////////

   /* Register interface */
   always @(posedge PCLK) begin
      if (PSEL & PENABLE & PWRITE)
        begin
           // Reg write
           case (PADDR[5:0])
             6'h00:
               begin
                  display_enable    <= PWDATA[31];
                  border_enable     <= PWDATA[30];
               end

             6'h04:
               begin
                  tim_disp_width    <= PWDATA[10:0];
                  tim_disp_x_mul    <= PWDATA[15:11];
                  tim_disp_height   <= PWDATA[26:16];
                  tim_disp_y_mul    <= PWDATA[31:27];
               end

             6'h08:
               begin
                  tim_vsync_width   <= PWDATA[7:0];
                  tim_vsync_fporch  <= PWDATA[15:8];
                  tim_vsync_bporch  <= PWDATA[23:16];
                  vs_polarity_inv   <= PWDATA[24];
               end

             6'h0c:
               begin
                  tim_hsync_width   <= PWDATA[7:0];
                  tim_hsync_fporch  <= PWDATA[15:8];
                  tim_hsync_bporch  <= PWDATA[23:16];
                  hs_polarity_inv   <= PWDATA[24];
                  de_polarity_inv   <= PWDATA[25];
                  blank_polarity_inv <= PWDATA[26];
               end

             6'h10:
               begin
                  fb_base_addr      <= PWDATA[31:3];
               end

             // 0x14 is ID_FIELD, RO

             6'h18:
               begin
                  tim_dwords_per_line_m1 <= PWDATA[10:0];
                  bppl2[2:0]        <= PWDATA[13:11];
               end

             6'h1c:
               begin
                  palette_write_address <= PWDATA[7:0];
               end

             // 0x20 is palette BRAM write, which is decoded separately into palette_write_enable
           endcase
           /* Re-sum the intermediate timing state */
           sum <= 1;
        end

      if (sum == 1)
        begin
           sum <= 0;

           tim_width_m1     <= tim_disp_width + tim_hsync_width +
                               tim_hsync_fporch + tim_hsync_bporch - 1;
           tim_height_m1    <= tim_disp_height + tim_vsync_width +
                               tim_vsync_fporch + tim_vsync_bporch - 1;
           tim_hstart       <= tim_hsync_width + tim_hsync_bporch;
           tim_hlast        <= tim_hsync_width + tim_hsync_bporch + tim_disp_width - 1;
           tim_vstart       <= tim_vsync_width + tim_vsync_bporch;
           tim_vlast        <= tim_vsync_width + tim_vsync_bporch + tim_disp_height - 1;
	   // Note: These encode X/Y (compared to xy signal):
	   tim_blank_a_start <= {tim_vsync_width + tim_vsync_bporch - tim_blank_start_width, 3'h0, tim_hsync_width};
	   tim_blank_a_end   <= {tim_vsync_width + tim_vsync_bporch, 3'h0, tim_hsync_width + 8'd1};
	   tim_blank_b_start <= {tim_vsync_width + tim_vsync_bporch + tim_disp_height, 3'h0, tim_hsync_width};
	   tim_blank_b_end   <= {tim_vsync_width + tim_vsync_bporch + tim_disp_height + tim_blank_end_width, 3'h0, tim_hsync_width + 8'd1};
        end

      if (nRESET == 0) begin
         tim_disp_width        <= `DISPWIDTH;
         tim_disp_height       <= `DISPHEIGHT;
         tim_disp_x_mul        <= `DISPXMUL;
         tim_disp_y_mul        <= `DISPYMUL;
         tim_vsync_width       <= `VSYNCWIDTH;
         tim_vsync_fporch      <= `VSYNCFRONTPORCH;
         tim_vsync_bporch      <= `VSYNCBACKPORCH;
         tim_hsync_width       <= `HSYNCWIDTH;
         tim_hsync_fporch      <= `HSYNCFRONTPORCH;
         tim_hsync_bporch      <= `HSYNCBACKPORCH;
	 tim_blank_start_width <= `BLANKSTARTWIDTH;
	 tim_blank_end_width   <= `BLANKENDWIDTH;
         tim_dwords_per_line_m1 <= `DWORDS_PER_LINEM1;
         hs_polarity_inv       <= `HSYNCPOLARITY;
         vs_polarity_inv       <= `VSYNCPOLARITY;
	 de_polarity_inv       <= `DEPOLARITY;
	 blank_polarity_inv    <= `BLANKPOLARITY;
         display_enable        <= `DISPENABLE;
         border_enable         <= `BORDER_ENABLE;
         sum                   <= 1;   /* Update intermediates out of reset */
         fb_base_addr          <= 0;
         bppl2                 <= `BPPL2;
         palette_write_address <= 0;
      end
   end // always @ (posedge PCLK)


   /* Palette write:
    * There might be a critical path through PWDATA into the
    * BRAM write port.  An alternative way to write the palette may be to provide a
    * register that latches write data, then write this to the BRAM when the
    * *address* register is written with a value.
    */
   assign palette_write_enable = (PSEL & PENABLE & PWRITE) && (PADDR == 6'h20);


   /* Synchronisers for readback of status/position from pixel_clk to PCLK domain: */
   reg [10:0]   sync_horiz[1:0];
   reg [10:0]   sync_vert[1:0];
   wire [10:0]  status_horiz;
   wire [10:0]  status_vert;
   /* Interrupts: sample HS/VS from pixel_clk to PCLK domain and ensure output pulses for at least one PCLK */
   reg          sync_hs[2:0];
   reg          sync_vs[2:0];

   always @(posedge PCLK) begin
      sync_horiz[0]      <= horiz;
      sync_vert[0]       <= vert;
      if (PSEL)  /* Ha! Saving 1E-300J */
        begin
           sync_horiz[1] <= sync_horiz[0];
           sync_vert[1]  <= sync_vert[0];
        end

      /* IRQ generation: */
      sync_hs[0]         <= int_hs_noninv;
      sync_hs[1]         <= sync_hs[0];
      sync_hs[2]         <= sync_hs[1];
      if (!IRQ_HS && sync_hs[2] == 0 && sync_hs[1] == 1) begin
         /* If hsync just activated and IRQ isn't asserted then set the IRQ */
         IRQ_HS          <= 1;
      end else if (IRQ_HS) begin
         /* IRQ pulse is for one PCLK cycle */
         IRQ_HS          <= 0;
      end

      sync_vs[0]         <= int_vs_noninv;
      sync_vs[1]         <= sync_vs[0];
      sync_vs[2]         <= sync_vs[1];
      if (!IRQ_VS && sync_vs[2] == 0 && sync_vs[1] == 1) begin
         /* If vsync just activated and IRQ isn't asserted then set the IRQ */
         IRQ_VS          <= 1;
      end else if (IRQ_VS) begin
         /* IRQ pulse is for one PCLK cycle */
         IRQ_VS          <= 0;
      end

      if (nRESET == 0) begin
         IRQ_HS          <= 0;
         IRQ_VS          <= 0;
      end
   end

   assign       status_horiz    = sync_horiz[1];
   assign       status_vert     = sync_vert[1];

   /* Read MUX: */
   always @(*)
     begin
        if (PADDR == 6'h00)
          begin
             PRDATA[10:0]       = status_vert;
             PRDATA[15:11]      = 5'h00;
             PRDATA[26:16]      = status_horiz;
             PRDATA[30:27]      = 4'h0;
             PRDATA[30]         = border_enable;
             PRDATA[31]         = display_enable;
          end
        else if (PADDR == 6'h04)
          begin
             PRDATA[10:0]       = tim_disp_width;
             PRDATA[15:11]      = tim_disp_x_mul;
             PRDATA[26:16]      = tim_disp_height;
             PRDATA[31:27]      = tim_disp_y_mul;
          end
        else if (PADDR == 6'h08)
          begin
             PRDATA[7:0]        = tim_vsync_width;
             PRDATA[15:8]       = tim_vsync_fporch;
             PRDATA[23:16]      = tim_vsync_bporch;
             PRDATA[24]         = vs_polarity_inv;
             PRDATA[31:25]      = 7'h00;
          end
        else if (PADDR == 6'h0c)
          begin
             PRDATA[7:0]        = tim_hsync_width;
             PRDATA[15:8]       = tim_hsync_fporch;
             PRDATA[23:16]      = tim_hsync_bporch;
             PRDATA[24]         = hs_polarity_inv;
	     PRDATA[25]         = de_polarity_inv;
	     PRDATA[26]         = blank_polarity_inv;
             PRDATA[31:25]      = 5'h00;
          end
        else if (PADDR == 6'h10)
          begin
             PRDATA[31:0]       = {fb_base_addr, 3'b000};
          end
        else if (PADDR == 6'h14)
          begin
             PRDATA[31:0]       = `ID_FIELD;
          end
        else if (PADDR == 6'h18)
          begin
             PRDATA[10:0]       = tim_dwords_per_line_m1[10:0];
             PRDATA[13:11]      = bppl2;
             PRDATA[31:14]      = 18'h00000;
          end
        else if (PADDR == 6'h1c)
          begin
             PRDATA[7:0]        = palette_write_address;
	     PRDATA[31:8]       = 24'h0;
          end
        else
            PRDATA = 32'h00000000;
     end


   ////////////////////////////////////////////////////////////////////////////////

   /* Memory interface for video DMA */

   /* MIC interface */
   wire        req_ready;
   wire        req_start;
   reg [31:3]  req_address;
   reg [7:0]   req_len;
   wire [63:0] read_data;
   wire        read_data_valid;
   wire        read_data_ready;

   mic_m_if #(.NAME("MIC_LCDC"))
   mif (.clk(sys_clk), .reset(reset),
        /* MIC signals */
        .O_TVALID(O_TVALID), .O_TREADY(O_TREADY),
        .O_TDATA(O_TDATA), .O_TLAST(O_TLAST),
        .I_TVALID(I_TVALID), .I_TREADY(I_TREADY),
        .I_TDATA(I_TDATA), .I_TLAST(I_TLAST),
        /* Control/data signals */
        .req_ready(req_ready), .req_start(req_start), .req_RnW(1'b1),
        .req_beats(req_len), .req_address(req_address),
	.req_byte_enables(5'h1f),

        .read_data(read_data), .read_data_valid(read_data_valid),
        .read_data_ready(read_data_ready),

        .write_data(64'h0000000000000000), .write_data_valid(1'b0),
        .write_data_ready()
        );

   assign fetch_data_en = read_data_valid;
   assign read_data_ready = 1;
   assign fetch_data = read_data;


   /* Fetch controller FSM:
    *
    * Monitors buffer status, display start-of-frame flag, and generates a
    * sequence of bursts (asserting burst_req) to satisfy a buffer fetch.
    */
`define FETCH_IDLE     0
`define FETCH_START    1
`define FETCH_REQUEST  2
`define FETCH_WAIT     3
   reg [1:0] 	fetcher_state;

   reg [1:0] 	buffer_display_r;       /* Synchroniser for pixel_clk to sys_clk */
   reg [1:0] 	buffer_display_rr;

   reg [31:3]   dma_address;            /* */
   reg [10:0] 	fetch_remaining;        /* Counter for remaining data in line (from 1) */

   reg 		frame_init_r;           /* Synchroniser for pixel_clk to sys_clk */
   reg 		frame_init_rr;
   reg [7:0]    req_count;              /* Ongoing counter of burst completeness */

   assign       req_start = (fetcher_state == `FETCH_REQUEST) && req_ready;


   /* Buffer fetch logic: */
   always @(posedge sys_clk) begin
      /* Synchronised inputs: */
      buffer_display_r <= buffer_display;
      buffer_display_rr <= buffer_display_r;
      frame_init_r <= frame_init_d;
      frame_init_rr <= frame_init_r;

      /* FSM */
      case (fetcher_state)
	`FETCH_IDLE: begin
	   /* First, check flag from display: re-init frame if flagged */
	   if (frame_init_rr != frame_init_f) begin

	      /* Initialise buffer states: */
	      buffer_fetcher[1:0] <= 2'b11; /* Buffers need refreshing */
	      dma_address         <= fb_base_addr[31:3];
	      frame_init_f        <= ~frame_init_f;

	   end else begin
	      /* Consider buffer states:
	       *
	       * Lower-numbered buffers take priority, as buffers are ordered;
	       * e.g. on init, lowest addresses are buffer 0.
	       */

	      if (buffer_fetcher[0] != buffer_display_rr[0]) begin
		 fetch_buffer     <= 0;
		 fetch_remaining  <= tim_dwords_per_line_m1 + 1;
		 fetch_addr       <= 0;
		 fetcher_state    <= `FETCH_START;
	      end else if (buffer_fetcher[1] != buffer_display_rr[1]) begin
		 fetch_buffer     <= 1;
		 fetch_remaining  <= tim_dwords_per_line_m1 + 1;
		 fetch_addr       <= 0;
		 fetcher_state    <= `FETCH_START;
	      end
	      /* Otherwise, nothing to do yet. */
	   end
	end

	`FETCH_START: begin
	   /* Set up inputs to MIC interface: */
	   req_address   <= dma_address;
	   req_count     <= 0;
	   /* Remember, req_len counts from 0, i.e. 0 = 1 beat! */
	   req_len       <= (fetch_remaining > `FETCH_MAXBURST) ? `FETCH_MAXBURST-1 : fetch_remaining-1;
	   fetcher_state <= `FETCH_REQUEST;
	end

	`FETCH_REQUEST: begin
	   /* If interface is ready, kick off a MIC request: */
	   if (req_ready) begin
	      /* req_start is asserted here */
	      fetcher_state <= `FETCH_WAIT;
	   end
	end

	`FETCH_WAIT: begin
	   if (read_data_valid) begin
	      fetch_addr <= fetch_addr + 1;
	      if (req_count != req_len)  begin
		 /* Ongoing data transfer, */
		 req_count <= req_count + 1;
	      end else begin
		 /* Burst is complete. */

		 /* Increment address for (possibly) next burst */
		 dma_address <= dma_address + req_len + 1;
		 /* Decrement the number of remaining beats in the line */
		 fetch_remaining <= fetch_remaining - req_len - 1;

		 /* Remember non-blocking assignment, comparison w/ value before dec */
		 if (fetch_remaining > (req_len+1)) begin
		    fetcher_state <= `FETCH_START;
		 end else begin
		    /* All done!  Toggle the buffer flag to publish to consumer: */
		    if (fetch_buffer == 0) begin
		       buffer_fetcher[0] <= ~buffer_fetcher[0];
		    end else begin
		       buffer_fetcher[1] <= ~buffer_fetcher[1];
		    end
		    fetcher_state <= `FETCH_IDLE;
		 end
	      end
	   end
	end // case: `FETCH_WAIT

      endcase // case (fetcher_state)

      if (reset) begin
         fetch_buffer        <= 0;
	 fetcher_state       <= `FETCH_IDLE;
	 frame_init_f        <= 1;       /* Different to display version */
      end
   end

endmodule
