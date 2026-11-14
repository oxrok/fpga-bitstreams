// Tang Nano 20K top level: PLL, I/O cells and the SDRAM clock around
// oxla_core. One source, several bitstreams; the Makefile sets the
// parameters per variant.

//                  +--------+  clk (54/108/135 MHz)
//   clk27 -------->|  rPLL  |-------------+---------------------------+
//   (pin 4)        |        |  clk_sd     |                           |
//                  +--------+----+        v                           |
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
    parameter CLK_MHZ   = 108,      // 54, 81, 108 or 135: multiples of the 27 MHz crystal
    parameter BAUD      = 3000000,
    parameter W         = 16,
    parameter P         = 1,
    parameter RLE       = 0,
    parameter ADC       = 0
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
    // CLKOUT = 27 MHz * (FBDIV_SEL + 1); ODIV keeps the VCO in 500..1250 MHz.
    localparam integer FBDIV_SEL = CLK_MHZ / 27 - 1;
    localparam integer ODIV_SEL  = (CLK_MHZ >= 135) ? 4 :
                                   (CLK_MHZ >= 81)  ? 8 : 16;

    // The SDRAM clock is the PLL's second output: the system clock shifted
    // by SD_PSDA sixteenths of a period (the Makefile's SD_PHASE). The duty
    // setting is the phase plus eight for a square wave. 13 is the middle
    // of the settings that work on the board; see the README.
`ifndef SD_PSDA
`define SD_PSDA "1101"
`define SD_DUTY "0101"
`endif

    wire clk, clk_sd, pll_lock;

    rPLL #(
        .FCLKIN("27"),
        .IDIV_SEL(0),
        .FBDIV_SEL(FBDIV_SEL),
        .ODIV_SEL(ODIV_SEL),
        .PSDA_SEL(`SD_PSDA),
        .DUTYDA_SEL(`SD_DUTY),
        .DEVICE("GW2AR-18C")
    ) u_pll (
        .CLKIN(clk27), .CLKFB(1'b0), .RESET(1'b0), .RESET_P(1'b0),
        .FBDSEL(6'b0), .IDSEL(6'b0), .ODSEL(6'b0),
        .PSDA(4'b0), .DUTYDA(4'b0), .FDLY(4'b0),
        .CLKOUT(clk), .LOCK(pll_lock),
        .CLKOUTP(clk_sd), .CLKOUTD(), .CLKOUTD3());

    // Reset until the PLL has been locked for a while.
    reg [7:0] rst_cnt = 8'd0;
    reg       rst = 1'b1;
    always @(posedge clk) begin
        if (!pll_lock) begin
            rst_cnt <= 8'd0;
            rst <= 1'b1;
        end else if (rst_cnt != 8'hff)
            rst_cnt <= rst_cnt + 1'b1;
        else
            rst <= 1'b0;
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
        .CLK_HZ(CLK_MHZ * 1000000), .BAUD(BAUD),
        .W(W), .P(P), .RLE(RLE), .ADC(ADC)
    ) u_core (
        .clk(clk), .rst(rst), .din(din),
        .rxd(uart_rx), .txd(uart_tx),
        .adc_clk(adc_clk_i), .trig_out(trig_out), .led(led),
        .sd_cke(O_sdram_cke), .sd_cs_n(O_sdram_cs_n), .sd_ras_n(O_sdram_ras_n),
        .sd_cas_n(O_sdram_cas_n), .sd_we_n(O_sdram_wen_n),
        .sd_addr(O_sdram_addr), .sd_ba(O_sdram_ba),
        .sd_dq_o(dq_o), .sd_dq_oe(dq_oe), .sd_dq_i(IO_sdram_dq));
endmodule

`default_nettype wire
