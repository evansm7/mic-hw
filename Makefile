# mic-hw component testbenches makefile
#
# Copyright 2017, 2019-2022 Matt Evans
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
#
# Licensed under the Solderpad Hardware License v 2.1 (the “License”); you may
# not use this file except in compliance with the License, or, at your option,
# the Apache License version 2.0. You may obtain a copy of the License at
#
#  https://solderpad.org/licenses/SHL-2.1/
#
# Unless required by applicable law or agreed to in writing, any work
# distributed under the License is distributed on an “AS IS” BASIS, WITHOUT
# WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. See the
# License for the specific language governing permissions and limitations
# under the License.
#

PATHS=-y. -y$(XILINX_SIMPATH)  -ysrc/ -I. -Isrc/ -Itb/
DEFS=-DSIM
MODELS ?=../models/
IVFLAGS = -g2009 -Wall -Wno-timescale

# Keep *.vcd around:
.SECONDARY:	tb_top.vcd

# This is the most complex test:
all:	tb_top_mic.wave

%.wave:	%.vcd
	gtkwave $<

%.vcd:	%.vvp
	vvp $<

tb_top.vvp:	tb/tb_top.v src/m_pktgen.v src/m_pktsink.v src/s_responder.v
	iverilog $(IVFLAGS) $(DEFS) $(PATHS) -o $@ tb/tb_top.v

tb_top_multi.vvp:	tb/tb_top_multi.v src/m_pktgen.v src/m_pktsink.v src/s_responder.v src/i_merge.v src/i_steer.v
	iverilog $(IVFLAGS) $(DEFS) $(PATHS) -o $@ tb/tb_top_multi.v

tb_top_mic.vvp:	tb/tb_top_mic.v src/m_pktgen.v src/m_pktsink.v src/s_responder.v src/i_merge.v src/i_steer.v src/i_merge4.v src/i_steer4.v src/mic_4r2c.v
	iverilog $(IVFLAGS) $(DEFS) $(PATHS) -o $@ tb/tb_top_mic.v

tb_component_s_bram.vvp:	tb/tb_component_s_bram.v
	iverilog $(IVFLAGS) $(DEFS) $(PATHS) -o $@ $<

tb_component_s_ssram.vvp:	tb/tb_component_s_ssram.v
	iverilog $(IVFLAGS) $(DEFS) $(PATHS) -o $@ tb/tb_component_s_ssram.v $(MODELS)/1471BV33/CY7C1471BV33.v

tb_component_m_blockcopy_apb.vvp:	tb/tb_component_m_blockcopy_apb.v
	iverilog $(IVFLAGS) $(DEFS) $(PATHS) -o $@ $<

tb_component_m_lcdc_apb.vvp:	tb/tb_component_m_lcdc_apb.v
	iverilog $(IVFLAGS) $(DEFS) $(PATHS) -o $@ $<

tb_component_mic_apb.vvp:	tb/tb_component_mic_apb.v
	iverilog $(IVFLAGS) $(DEFS) $(PATHS) -o $@ $<

tb_component_apb_uart.vvp:	tb/tb_component_apb_uart.v
	iverilog $(IVFLAGS) $(DEFS) $(PATHS) -o $@ $<

tb_component_apb_uart_ft232.vvp:	tb/tb_component_apb_uart_ft232.v
	iverilog $(IVFLAGS) $(DEFS) $(PATHS) -o $@ $<

tb_component_r_debug.vvp:	tb/tb_component_r_debug.v
	iverilog $(IVFLAGS) $(DEFS) $(PATHS) -o $@ $<

tb_component_r_i2s_apb.vvp:	tb/tb_component_r_i2s_apb.v
	iverilog $(IVFLAGS) $(DEFS) $(PATHS) -o $@ $<

tb_component_bytestream_ps2.vvp:	tb/tb_component_bytestream_ps2.v
	iverilog $(IVFLAGS) $(DEFS) $(PATHS) -o $@ $<

tb_component_apb_spi.vvp:	tb/tb_component_apb_spi.v
	iverilog $(IVFLAGS) $(DEFS) $(PATHS) -o $@ $<

tb_component_sd.vvp:	tb/tb_component_sd.v
	# Set MODELS to path of SD-card-controller models:
	iverilog $(IVFLAGS) $(DEFS) $(PATHS) -y$(MODELS) -o $@ $<

clean:
	rm -rf *.vvp *.vcd *~ src/*~ tb/*~
