// Tang Nano 20K top level: PLL, I/O cells and the SDRAM clock around
// oxla_core. One source, several bitstreams; the Makefile sets the
// parameters per variant. The clock is not one of them: the host picks 81,
// 108 or 135 MHz at run time.

//                  +--------+  clk (81/108/135 MHz)
//   clk27 -------->|  rPLL  |-------------+---------------------------+
//   (pin 4)        |        |  clk_sd     |                           |
//                  +--------+----+        v                           |
//     |                ^ FBDSEL  |        |                           |
//     |  +--------+    +---------|--------|------ clksel -------------+
//     +->|  rPLL  | hclk, 108 MHz, fixed: |       (a host register)   |
//        +--------+--------------|-----> the host side of the core,   |
//                                |       which keeps talking while    |
//                                |       the other PLL moves          |
//                                |   +----------------------------+   |
//   ch[W-1:0] ---> [IDDR] -------|-->| din                        |   |
//   (P = 2 only; plain wires     |   |                            |   |
//    when P = 1)                 |   |         oxla_core          |   |
//                                |   |                            |   |
//   uart_rx (70) ----------------|-->| rxd                    led |--> led_n[5:0]
//   uart_tx (69) <---------------|---| txd               trig_out |--> trig_out
//                                |   |                    adc_clk |--> adc_clk (ADC builds)
//                                |   |  sd_ras/cas/we, addr, ba   |
//                                |   +-----+----------------+-----+
//                                |         |                ^
//                                v         v                | sd_dq_i
//                             [ODDR]   O_sdram_*        IO_sdram_dq
//                                |         |             (tristate, dq_oe)
//                                v         v                ^
//                           O_sdram_clk  +-------------------------+
//                                        |  SDRAM inside the FPGA  |
//                                        |  package, 2M x 32 bit   |
//                                        +-------------------------+
//
//   The two clocks, for SD_PHASE = 13 (clk_sd is clk shifted by 13/16 of a
//   period). The core changes the SDRAM's inputs on the rising edge of clk;
//   the SDRAM takes them on the rising edge of clk_sd:
//
//             _______         _______         _______
//   clk    __|       |_______|       |_______|       |____
//               ^ outputs change here
//          ____         _______         _______         ___
//   clk_sd     |_______|       |_______|       |_______|
//                      ^ SDRAM samples here

`default_nettype none

module oxla_top #(
    parameter BAUD      = 3000000,
    parameter W         = 16,
    parameter P         = 1,
    parameter RLE       = 0,
    parameter ADC       = 0,
    parameter VERSION   = 0         // the release, a byte each for major, minor, patch
) (
    input  wire         clk27,
    input  wire [W-1:0] ch,
    input  wire         uart_rx,
    output wire         uart_tx,
    output wire [5:0]   led_n,
    output wire         trig_out,
`ifdef OXLA_ADC
    output wire         adc_clk,        // only the ADC variants have the pin
`endif

    output wire         O_sdram_clk,
    output wire         O_sdram_cke,
    output wire         O_sdram_cs_n,
    output wire         O_sdram_cas_n,
    output wire         O_sdram_ras_n,
    output wire         O_sdram_wen_n,
    output wire [3:0]   O_sdram_dqm,
    output wire [10:0]  O_sdram_addr,
    output wire [1:0]   O_sdram_ba,
    inout  wire [31:0]  IO_sdram_dq
);
    // The SDRAM clock is the PLL's second output: the system clock shifted
    // by SD_PSDA sixteenths of a period (the Makefile's SD_PHASE). The duty
    // setting is the phase plus eight for a square wave. 13 is the middle
    // of the settings that work on the board; see the README.
`ifndef SD_PSDA
`define SD_PSDA "1101"
`define SD_DUTY "0101"
`endif

    wire clk, clk_sd, pll_lock;

    // The clock is 27 MHz times 3, 4 or 5. The PLL's feedback divider is
    // set at run time through FBDSEL, which wants 64 minus the factor
    // (measured: 61, 60, 59 give 81, 108, 135 MHz, and it locks again after
    // every change). With the output divider at 8 the VCO is at 648, 864 or
    // 1080 MHz, inside its 500 to 1250.
    //
    // clksel comes from the host side of the core, which has a clock of
    // its own and so keeps talking while this one changes.
    wire [1:0] clksel;                  // 0 = 81, 1 = 108, 2 = 135 MHz
    wire [5:0] fbdsel = 6'd61 - {4'd0, clksel};

    rPLL #(
        .FCLKIN("27"),
        .IDIV_SEL(0),
        .FBDIV_SEL(3),
        .ODIV_SEL(8),
        .DYN_FBDIV_SEL("true"),
        .PSDA_SEL(`SD_PSDA),
        .DUTYDA_SEL(`SD_DUTY),
        .DEVICE("GW2AR-18C")
    ) u_pll (
        .CLKIN(clk27), .CLKFB(1'b0), .RESET(1'b0), .RESET_P(1'b0),
        .FBDSEL(fbdsel), .IDSEL(6'b0), .ODSEL(6'b0),
        .PSDA(4'b0), .DUTYDA(4'b0), .FDLY(4'b0),
        .CLKOUT(clk), .LOCK(pll_lock),
        .CLKOUTP(clk_sd), .CLKOUTD(), .CLKOUTD3());

    // The host side has the second PLL, fixed at 108 MHz. The crystal alone
    // would do for the logic, but not for the UART: at 27 MHz a bit at
    // 3 Mbaud is nine clocks, and the receiver then missed about one
    // command in thirty from the board's USB bridge. At 36 clocks a bit it
    // has not missed one.
    wire hclk, hpll_lock;

    rPLL #(
        .FCLKIN("27"),
        .IDIV_SEL(0),
        .FBDIV_SEL(3),
        .ODIV_SEL(8),
        .DEVICE("GW2AR-18C")
    ) u_hpll (
        .CLKIN(clk27), .CLKFB(1'b0), .RESET(1'b0), .RESET_P(1'b0),
        .FBDSEL(6'b0), .IDSEL(6'b0), .ODSEL(6'b0),
        .PSDA(4'b0), .DUTYDA(4'b0), .FDLY(4'b0),
        .CLKOUT(hclk), .LOCK(hpll_lock),
        .CLKOUTP(), .CLKOUTD(), .CLKOUTD3());

    // Host side reset: until that PLL has been locked for 255 clocks.
    reg [7:0] hrst_cnt = 8'd0;
    reg       hrst = 1'b1;
    always @(posedge hclk) begin
        if (!hpll_lock) begin
            hrst_cnt <= 8'd0;
            hrst <= 1'b1;
        end else if (hrst_cnt != 8'hff)
            hrst_cnt <= hrst_cnt + 1'b1;
        else
            hrst <= 1'b0;
    end

    // Inputs: plain for one sample per clock, IDDR for two (Q0 is the
    // sample taken on the rising edge, the earlier of the pair).
    wire [P*W-1:0] din;
    genvar g;
    generate
        if (P == 1) begin : g_sdr
            assign din = ch;
        end else begin : g_ddr
            for (g = 0; g < W; g = g + 1) begin : g_ch
                IDDR u_iddr (.D(ch[g]), .CLK(clk), .Q0(din[g]), .Q1(din[W + g]));
            end
        end
    endgenerate

    // SDRAM pins. The clock leaves through an ODDR cell, so its delay to
    // the pad is fixed. The other outputs are fabric flip-flops whose delay
    // depends on routing (ODDR cells on them left the SDRAM reading all
    // ones on the board, apycula 0.32), which is why the clock's phase is
    // a build setting: see the README for the measured window.
    wire [31:0] dq_o;
    wire        dq_oe;

    ODDR u_sdclk (.D0(1'b1), .D1(1'b0), .TX(1'b0), .CLK(clk_sd), .Q0(O_sdram_clk), .Q1());

    assign IO_sdram_dq  = dq_oe ? dq_o : 32'bz;
    assign O_sdram_dqm  = 4'b0000;

    wire [5:0] led;
    wire       adc_clk_i;
    assign led_n = ~led;
`ifdef OXLA_ADC
    assign adc_clk = adc_clk_i;
`endif

    oxla_core #(
        .HOST_HZ(108000000), .BAUD(BAUD), .HOLD_BITS(19),
        .W(W), .P(P), .RLE(RLE), .ADC(ADC), .VERSION(VERSION)
    ) u_core (
        .hclk(hclk), .hrst(hrst), .clk(clk), .pll_lock(pll_lock), .clksel(clksel),
        .din(din),
        .rxd(uart_rx), .txd(uart_tx),
        .adc_clk(adc_clk_i), .trig_out(trig_out), .led(led),
        .sd_cke(O_sdram_cke), .sd_cs_n(O_sdram_cs_n), .sd_ras_n(O_sdram_ras_n),
        .sd_cas_n(O_sdram_cas_n), .sd_we_n(O_sdram_wen_n),
        .sd_addr(O_sdram_addr), .sd_ba(O_sdram_ba),
        .sd_dq_o(dq_o), .sd_dq_oe(dq_oe), .sd_dq_i(IO_sdram_dq));
endmodule

`default_nettype wire
