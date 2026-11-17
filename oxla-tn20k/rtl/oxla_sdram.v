// SDR SDRAM controller for the 64 Mbit, 32 bit wide die inside the GW2AR-18
// (4 banks x 2048 rows x 256 columns = 2^21 words).
//
// Built for a logic analyzer, not for a CPU:
//
// - Writes are single-word WRITE commands on consecutive cycles (mode
//   register burst length 1), so a row takes one word per clock for as long
//   as the FIFO has data, and stays open across a short gap only until the
//   next refresh is due. Sustained rate is about 0.95 words per clock.
// - Reads are slow on purpose (the UART is the bottleneck by four orders of
//   magnitude). The same READ is issued on six consecutive cycles, which
//   holds the word on DQ for six clocks, and DQ is sampled in the middle.
//   That makes the read independent of the clock-to-pad round trip, at
//   any clock frequency, with no phase tuning.
// - DQ is driven from the ACT of a write row to its PRE, not per word, so
//   the output enable is never in a timing path. Switched per word, the
//   first word of every burst was wrong on the board at 108 MHz.
//
// The SDRAM clock is the inverted system clock (an ODDR in the top level),
// so command, address and write data, which change on the rising edge of
// clk, are sampled by the SDRAM mid-cycle.

//   A word address, as the SDRAM wants it:
//
//       20  19 18                    8 7              0
//      +------+-----------------------+----------------+
//      | bank |          row          |     column     |
//      +------+-----------------------+----------------+
//        sd_ba   sd_addr with ACT        sd_addr with READ / WRITE
//
//   The states. S_WAIT is a counter of NOPs that every command passes
//   through on its way to the state in `ret`:
//
//     reset
//       |
//       v  200 us      PRE all       REF x 8        MRS
//    [S_WAIT] --> [S_INIT_PRE] --> [S_INIT_REF] --> [S_INIT_MRS]
//                                                        |
//             +------------------------------------------+
//             v
//        +---------+  ref_due         REF, wait tRFC
//        | S_IDLE  |----------------------------------------> back to S_IDLE
//        |         |
//        |         |  wr_valid        ACT, wait tRCD
//        |         |-----------> [S_WR] --+ WRITE, one per clock, while there
//        |         |               ^      | is data, the row has not ended
//        |         |               +------+ and no refresh is due
//        |         |                 |
//        |         |                 | otherwise: wait tWR
//        |         |                 v
//        |         |              [S_PRE] PRE, wait tRP ---> back to S_IDLE
//        |         |                 ^
//        |         |  rd_req         | wait
//        |         |-----------> [S_RD] x 6 READ --> [S_RD_CAP] rd_data, rd_done
//        +---------+   ACT, wait tRCD
//
//   A write burst, as the SDRAM sees it (one clock after the states above,
//   because the outputs are registered). DQ is driven from the ACT on:
//
//   command  ACT  nop  nop  WR   WR   WR   WR   nop  nop  nop  nop  PRE  nop
//   address  row            c    c+1  c+2  c+3                      A10
//   DQ       <-- driven --  d0   d1   d2   d3 >
//   dq_oe    ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~|____________________________
//            |<- tRCD ->|                  |<----- tWR, tRAS ---->|<- tRP ->
//
//   A read. The same READ six times keeps the word on DQ for six clocks, and
//   dq_r takes it in the middle, so it does not matter where in the clock
//   the data really arrives:
//
//   clock      0    1    2    3    4    5    6    7    8    9
//   command    RD   RD   RD   RD   RD   RD   nop  nop
//   DQ                        <------- the word ------------->
//                          2.5 ^            ^ 6            8.5 ^
//                                       dq_r samples

`default_nettype none

module oxla_sdram #(
    parameter CLK_HZ  = 135000000,     // the fastest clock it will be run at
    parameter INIT_US = 200            // power-up pause; shortened in simulation
) (
    input  wire        clk,
    input  wire        rst,
    input  wire [15:0] ref_cyc,        // clocks between refreshes, for the clock as it is
    output reg         ready,

    // Write port. wr_valid/wr_addr/wr_data must be first-word-fall-through:
    // the word is consumed in the cycle wr_ack is high, and wr_addr must be
    // one higher in the next cycle.
    input  wire        wr_valid,
    input  wire [20:0] wr_addr,
    input  wire        wr_wrap,     // wr_addr is the last of the ring: the next is 0
    input  wire [31:0] wr_data,
    output wire        wr_ack,

    // Read port. Hold rd_req until rd_done pulses.
    input  wire        rd_req,
    input  wire [20:0] rd_addr,
    output reg  [31:0] rd_data,
    output reg         rd_done,

    // SDRAM pins (clock is driven by the top level).
    output wire        sd_cke,
    output wire        sd_cs_n,
    output reg         sd_ras_n,
    output reg         sd_cas_n,
    output reg         sd_we_n,
    output reg  [10:0] sd_addr,
    output reg  [1:0]  sd_ba,
    output reg  [31:0] sd_dq_o,
    output reg         sd_dq_oe,
    input  wire [31:0] sd_dq_i
);
    // Timing, in clocks, from conservative figures that cover the -5, -6
    // and -7 speed grades of the usual 2M x 32 parts. The waits are counted
    // for CLK_HZ and are only longer than they need to be at a slower clock.
    function integer cyc;               // ceil(ns * CLK_HZ / 1e9), at least 2
        input integer ns;
        integer c;
        begin
            c = (ns * (CLK_HZ / 1000) + 999999) / 1000000;
            cyc = (c < 2) ? 2 : c;
        end
    endfunction

    localparam integer T_RP   = cyc(21);    // precharge to next command
    localparam integer T_RCD  = cyc(21);    // activate to read/write
    localparam integer T_RFC  = cyc(70);    // refresh to next command
    localparam integer T_RAS  = cyc(49);    // activate to precharge, minimum
    localparam integer T_MRD  = 3;          // mode register set to next command
    // Last write (or a row opened and not written) to precharge: tWR is two
    // clocks, and the row must have been open for tRAS.
    localparam integer T_WEND = (T_RAS - T_RCD > 3) ? T_RAS - T_RCD : 3;
    localparam integer T_INIT = INIT_US * (CLK_HZ / 1000000);

    localparam [2:0] CMD_NOP = 3'b111, CMD_ACT = 3'b011, CMD_READ = 3'b101,
                     CMD_WRITE = 3'b100, CMD_PRE = 3'b010, CMD_REF = 3'b001,
                     CMD_MRS = 3'b000;

    // CAS latency 3, sequential, burst length 1.
    localparam [10:0] MODE = 11'b0_1_00_011_0_000;

    localparam [3:0] S_INIT = 0, S_INIT_PRE = 1, S_INIT_REF = 2, S_INIT_MRS = 3,
                     S_IDLE = 4, S_WAIT = 5, S_WR = 6, S_PRE = 7, S_RD = 8,
                     S_RD_CAP = 9;

    reg [3:0]  state, ret;
    reg [23:0] wait_cnt;
    reg [3:0]  init_refs;
    reg [2:0]  rd_cnt;
    reg        row_end;         // the word just written was the row's last
    reg [15:0] ref_cnt;
    reg        ref_due;
    reg [31:0] dq_r;

    assign sd_cke  = 1'b1;
    assign sd_cs_n = 1'b0;

    assign wr_ack = (state == S_WR) && wr_valid && !row_end && !ref_due;

    always @(posedge clk) begin
        dq_r <= sd_dq_i;
        rd_done <= 1'b0;
        {sd_ras_n, sd_cas_n, sd_we_n} <= CMD_NOP;

        if (ref_cnt == 0) begin
            ref_cnt <= ref_cyc;
            ref_due <= 1'b1;
        end else
            ref_cnt <= ref_cnt - 1'b1;

        if (rst) begin
            state <= S_WAIT;
            ret <= S_INIT_PRE;
            wait_cnt <= T_INIT[23:0] + 24'd2;
            ready <= 1'b0;
            init_refs <= 4'd8;
            ref_cnt <= ref_cyc;
            ref_due <= 1'b0;
            row_end <= 1'b0;
            rd_cnt <= 3'd0;
            sd_dq_oe <= 1'b0;
        end else case (state)
            // A command issued in one state is followed by N clocks of NOP
            // here, so two commands are N + 1 clocks apart.
            S_WAIT: begin
                wait_cnt <= wait_cnt - 1'b1;
                if (wait_cnt == 24'd1)
                    state <= ret;
            end

            S_INIT_PRE: begin
                {sd_ras_n, sd_cas_n, sd_we_n} <= CMD_PRE;
                sd_addr <= 11'h400;                 // A10: all banks
                state <= S_WAIT; wait_cnt <= T_RP; ret <= S_INIT_REF;
            end

            S_INIT_REF: begin
                {sd_ras_n, sd_cas_n, sd_we_n} <= CMD_REF;
                init_refs <= init_refs - 1'b1;
                state <= S_WAIT; wait_cnt <= T_RFC;
                ret <= (init_refs == 4'd1) ? S_INIT_MRS : S_INIT_REF;
            end

            S_INIT_MRS: begin
                {sd_ras_n, sd_cas_n, sd_we_n} <= CMD_MRS;
                sd_addr <= MODE;
                sd_ba <= 2'b00;
                ready <= 1'b1;
                state <= S_WAIT; wait_cnt <= T_MRD; ret <= S_IDLE;
            end

            S_IDLE: begin
                row_end <= 1'b0;
                if (ref_due) begin
                    {sd_ras_n, sd_cas_n, sd_we_n} <= CMD_REF;
                    ref_due <= 1'b0;
                    state <= S_WAIT; wait_cnt <= T_RFC; ret <= S_IDLE;
                end else if (wr_valid) begin
                    {sd_ras_n, sd_cas_n, sd_we_n} <= CMD_ACT;
                    sd_ba <= wr_addr[20:19];
                    sd_addr <= wr_addr[18:8];
                    sd_dq_oe <= 1'b1;
                    state <= S_WAIT; wait_cnt <= T_RCD - 1; ret <= S_WR;
                end else if (rd_req) begin
                    {sd_ras_n, sd_cas_n, sd_we_n} <= CMD_ACT;
                    sd_ba <= rd_addr[20:19];
                    sd_addr <= rd_addr[18:8];
                    rd_cnt <= 3'd0;
                    state <= S_WAIT; wait_cnt <= T_RCD - 1; ret <= S_RD;
                end
            end

            S_WR: begin
                if (wr_ack) begin
                    {sd_ras_n, sd_cas_n, sd_we_n} <= CMD_WRITE;
                    sd_addr <= {3'b000, wr_addr[7:0]};
                    sd_dq_o <= wr_data;
                    row_end <= (wr_addr[7:0] == 8'hff) || wr_wrap;
                end else begin
                    sd_dq_oe <= 1'b0;
                    state <= S_WAIT; wait_cnt <= T_WEND; ret <= S_PRE;
                end
            end

            S_PRE: begin
                {sd_ras_n, sd_cas_n, sd_we_n} <= CMD_PRE;
                sd_addr <= 11'h400;
                state <= S_WAIT; wait_cnt <= T_RP - 1; ret <= S_IDLE;
            end

            // READ on six consecutive clocks. With CAS latency 3 and the
            // inverted clock, DQ holds the word from 2.5 to 8.5 clocks after
            // the first READ reaches the pins; dq_r takes it at 6.
            S_RD: begin
                {sd_ras_n, sd_cas_n, sd_we_n} <= CMD_READ;
                sd_addr <= {3'b000, rd_addr[7:0]};
                rd_cnt <= rd_cnt + 1'b1;
                if (rd_cnt == 3'd5) begin
                    state <= S_WAIT; wait_cnt <= 24'd1; ret <= S_RD_CAP;
                end
            end

            S_RD_CAP: begin
                rd_data <= dq_r;
                rd_done <= 1'b1;
                state <= S_WAIT; wait_cnt <= T_WEND; ret <= S_PRE;
            end

            default: state <= S_IDLE;
        endcase
    end
endmodule

`default_nettype wire
