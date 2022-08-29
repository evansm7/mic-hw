/* SD host controller register offsets
 *
 * Copyright 2022 Matt Evans
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

`define SD_REG_RB0      8'h00
`define SD_REG_RB1      8'h04
`define SD_REG_RB2      8'h08
`define SD_REG_RB3      8'h0c
`define SD_REG_CB0      8'h10
`define SD_REG_CB1      8'h14
`define SD_REG_CTRL     8'h18
`define SD_REG_STATUS   8'h1c
`define SD_REG_STATUS2  8'h20
`define SD_REG_RCRC0    8'h28
`define SD_REG_RCRC1    8'h2c
`define SD_REG_DATACFG  8'h30
`define SD_REG_DMAADDR  8'h38
`define SD_REG_IRQ      8'h3c
