# MR system hardware components

1.0, 24 August 2022

This repository is a library of components designed for the MR system
project.

(The [MR CPU](https://github.com/evansm7/MR-hw/) and MR top-level
system are separate repositories, as are firmware/Linux software.
**Cross-links TBD**)

As with the rest of the MR system, these have been developed with the
"blissful intentionally-NIH" principle, for the enjoyment/edification
of reinventing the wheel.  I would never suggest this is a good
principle for real work.  But this is fun, not real work. ,o/

These components might be useful to someone elsewhere, or as the basis
for other things.  It'd be great to hear from you if there's something
of use to you.

This README is a tour of the components: interconnects, UARTs, an interrupt
controller, video, SD, I2S, SPI, GPIO, etc.

First up: the namesake of this repository is MIC, the MR InterConnect
(or Matt Interconnect :P ) common interface.  This is an interface
(and system interconnect providing said interfaces) to handle
read/write transactions, to construct a memory system.


# MR InterConnect (MIC)

The goals of MIC were:

   * To enjoy designing an interconnect (!)
   * High-ish performance, fully pipelined
   * Relatively easy to design a requester, and a completer
   * Easily-composable interconnect, so SoC shape can be changed
     without too much fuss

The interface is lightly documented in `doc/mic.txt`.  In short, a
requester or completer have two channels (in and out).  Each channel
uses a ready/valid semantic (relative to the direction, e.g. the
"transmitter" goes valid and the "receiver" receives if ready).  Each
channel is 64b wide, and carries packets.  A packet has one beat
(valid data transfer) of a header which gives the address and request
type (read/write); packets making a write request also contain write
data after the header.  The response packet for a read contains read
data; a write response has no data.

A transaction is always a pair of packets: a request out, and a
completion back.  Transactions are non-posted and address-routed.

There aren't multiple channels like AXI; there aren't loads of signals
like WB Pipelined Uber 2000.  It's simple and easy to debug.  The
interconnect is split-transaction (requests can pass each other, or be
made to different completers without blocking), but not (currently)
out-of-order.  Responses are always returned to the requester in the
order the requests were made.  A requester can make multiple
outstanding requests, or one at a time; a completer can accept >1 or
one at a time.

That said, a pipelined burst transfer at 8 byte width gets a pretty
decent bandwidth.

The MIC implementation in this repository has several classes of
component:

   * Things that are used to build the core interconnect itself
   * Things that are requesters (have a MIC out/request port)
   * Things that are completers (have a MIC in/completer port)
   * Helper components that are re-used to simplify building
     requesters

The core interconnect is constructed from "steers" and "merges", in a
DAG.  For example, take the path downstream from one of several
requesters to one of several completers: a steer component is a
demultiplexer and selects (by address) between one of several branches
to a downstream component (which may itself further select other
branches).  A merge component downstream is a multiplexer and
"funnels" in requests from various sources.  Each step logs the
routing path taken to the completer; the response packet is routed
back based on this breadcrumb log.

```
         R0             R1
         |               |
       __|___         ___|__
      /______\       /______\   <- 1:2 Steers
        |   \         /   |
        |     \     /     |
        |       \ /       |
        |       / \       |
        |     /     \     |
        |   /         \   |
      __|_/___       ___\_|__
      \______/       \______/   <- 2:1 Merges
         |               |
         C0             C1
```

# Components

## Easily-composable interconnect parts

A few crossbar interconnect "shapes" are provided:

   * `src/mic_4r1c.v`:  4 requesters into 1 downstream
   * `src/mic_4r2c.v`:  4 requesters into 2 downstream
   * `src/mic_4r4c.v`:  4 requesters into 4 downstream
   * `src/mic_1r2c.v`:  1 input/requester into 2 downstream

These can be stacked and composed arbitrarily: for example, 7
requesters can be accommodated using the 4x4 with a 4x1 plugged into
one of the request ports "on top".  The 1x2 can be used to share a
downstream port between 2 completers (or other downstream
interconnects).  At a given component, the incoming address space is
split according to the number of completers: no split, /2, /4.

There are 8 bits of route, meaning up to 256 request ports can be
acommodated (this includes intermediate/nested ports).  Interconnects
can also be asymmetric in depth: for example, the MR SoC puts the CPU
and main memory directly on a 4x4 interconnect for minimum latency,
but stacked interconnects are used for less-important requesters at
the top, and less-important memories/peripherals at the bottom.

Note some devices might attach "twice": an APB port "in" for making
MMIO requests into it (for programming), and a MIC port "out" for DMA.

These interconnects are themselves made from merge/steer components
which can be used to create new configurations (though it's a lot of
typing; just stack the existing ones):

   * `src/i_merge.v`
   * `src/i_merge4.v`
   * `src/i_steer.v`
   * `src/i_steer4.v`

A special completer component, `src/s_mic_apb.v`, bridges into APB.
This allows simple (cheap) MMIO peripherals to be accessed from MIC
requesters.

The `src/mic_m_if.v` component implements requester logic in one
common place: all of my DMA-capable devices re-use this instead of
trying to implement MIC request ports themselves.

Finally, some submodule components not used
directly: `src/double_latch.v`, `src/mic_ben_dec.v`.


## Serial/bytestream components

This class of components has a certain "pluggability" too.  The plain
old UART, `src/apb_uart.v`, is internally composed of an
`src/apb_uart_regif.v` which provides the software-visible register
interface via APB, plus a "backend" `src/bytestream_uart.v` which
implements the async line comms.

The point here is the two talk over a generic 8-bit bidirectional
ready/valid "bytestream" interface, so we can re-use either side
elsewhere:

   * The `src/apb_uart_ft232.v` component provides a UART-like
     software view, but its `src/bytestream_ft232.v` backend talks to
     an FTDI FT232 FIFO parallel interface (not serial).

   * The `src/apb_uart_ps2.v` component uses `src/bytestream_ps2.v` to
     give a PS/2 physical interface (keyboard/mouse), presented with
     the familiar UART register model.


## Debug host interface

Another user of the bytestream interface is a debug host interface,
`src/r_debug.v`.

This can be coupled to a `bytestream_uart` or `bytestream_ft232` to
interface to a host machine, and receives commands from that host.
The commands are a superset of the simple LiteX read/write protocol.
This component allows a host computer to read/write FPGA SoC memory --
I use this for downloading kernels directly into RAM on boot.

(Host-side clients are in the MR-sys project.)


## I2S

A system needs an exciting synthesised startup chime (genuinely good
for debugging); `src/r_i2s_apb.v` is an I2S audio interface.
Registers programmed via APB, audio is DMA'd via MIC.  (Perhaps slight
overkill; to save some resources, this would be a good client of a
generic "DMA fetcher" unit.)

The format and sample rate are currently static build-time
configurations.  I use 44.1KHz stereo 24-bit I2S.  A hardware volume
control is provided (which uses a multiplier/DSP block).


## SPI

A PIO SPI interface (APB-only, no DMA):  `src/apb_spi.v`

## Interrupts

An APB-based interrupt controller, `src/apb_intc.v`, reimplementing
the Xilinx XPS interrupt controller core's software interface.  This
can therefore be used with the Linux `xps_intc` driver.

This is super-simple, parameterisable with number of IRQs, a
configurable subset of which are level vs edge.


## GPIO

A trivial GPIO (32 in, 32 out, no bidirectional) interface: `src/apb_SIO.v`


## LCDC/video controller

`src/m_lcdc_apb.v` turns MIC DMA requests into beautiful video :P
Generates timing, supports palettised 1/2/4/8bpp modes plus
true-colour 16/32bpp modes.  Uses an external pixel clock.  Provides
blank/DE signals for LCDs or DVI parts.


## Memory controllers

FPGA Block RAM memory: `src/s_bram.v`

(This doesn't directly instantiate memories, so should synthesise for
varied technologies.  I just said "should" and "fragile memory
inference" in the same sentence, ha.)

External pipelined ZBT static RAM controller: `src/s_ssram.v`

(Note in the tour of components so far, we can store data, access it
through an interconnect, and concurrently produce video and audio.)


## SD host

Now things are really getting fun...

The `src/sd.v` component provides a decent SD host controller.  (As
you might expect from the hierarchical names, the following are
internal components of the SD controller: `src/sd_cmd.v`,
`src/sd_crc16.v`, `src/sd_crc7.v`, `src/sd_crg.v`, `src/sd_data_rx.v`,
`src/sd_data_tx.v`, `src/sd_dma_ctrl_mic.v`, `src/sd_dma_rx_fifo.v`,
`src/sd_dma_tx_fifo.v`, `src/sd_regs.vh`)

Features are:

   * Supports SDR25 4-bit transfers (12.5MB/s)
   * (Supports SDR at up to sysclk/2 rates, actually)
   * Full DMA support for data transfers
   * Hardware CRC for data TX/RX
   * Supports CMD23 multi-block reads/large block transfers

(Linux driver is good/working, in a repo elsewhere. **TBD**)

It doesn't yet support SDIO, but this is possible.  It'd be nice to
find a free && good simulation model for SDIO; an enjoyable compromise
would be cosimulation via real GPIO pins and a real SDIO device. 🤘😁
In future I might also look at more complicated/faster PHYs, but SDR25
(or thereabouts) is fast enough for the slow MR CPU.


## Misc components

Finally, there are a bunch of less-interesting components that are
either used by previous devices (`src/outff.v`, `src/simple_fifo.v`)
or are specialist test thingoes (`src/m_blockcopy_apb.v`,
`src/m_memtest_apb.v`), or are useful simulation/testbench components:

   * `src/mic_sim.v`
   * `src/m_memtest.v`
   * `src/m_pktgen.v`
   * `src/m_pktsink.v`
   * `src/m_requester.v`
   * `src/s_responder.v`
   * `src/rng.v`


# Copyright & Licence

Unless otherwise specified in a particular file,

Copyright (c) 2017-2022 Matt Evans

This work is licenced under the Solderpad Hardware License v2.1.  You
may obtain a copy of the License at
<https://solderpad.org/licenses/SHL-2.1/>.
