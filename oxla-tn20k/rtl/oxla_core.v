// The logic analyzer behind the pins, with no vendor primitives, so it
// simulates as it is.
//
// Samples go sampler -> trigger -> packer -> FIFO -> SDRAM. The SDRAM is a
// ring of 2^21 words that is written for as long as the capture runs; the
// trigger does not start the writing, it starts the count of the words (or
// samples) that are still to come. The host then reads backwards from where
// the writing stopped.

//   The data path, left to right, and the names of what flows between the
//   blocks (W bits per sample, P samples per clock):
//
//    din      +---------+ s_data  +---------+ t_data  +--------+ p_data
//   --------->| sampler |-------->| trigger |-------->| packer |-------+
//             |         | s_valid |         | t_valid |        | p_push|
//             +---------+         +---------+ t_mark  +--------+       |
//               ^   divider,        ^   A, B,           ^  raw / RLE,  |
//               |   test pattern    |   mode, count     |  sample limit|
//               |                   |    ^ pre_ok       |              v
//         +-----+-------------------+----+--------------+-+        +------+
//         |             oxla_host: cfg_* registers        |        | FIFO |
//         |  rxd -> commands        answers, memory -> txd|        | 512  |
//         +----------------------------------+------------+        +--+---+
//                     ^ rd_data, rd_done     | rd_req, rd_addr        | f_dout
//                     |                      v                        v f_valid
//                  +--+----------------------------------------------------+
//                  |                     oxla_sdram                        |
//                  |   write port: wr_ptr, f_dout[31:0], wr_ack (pops FIFO)|
//                  +--------------------------+----------------------------+
//                                             |
//                                        SDRAM pins
//
//   The memory is a ring. Writing starts at address 0 on ARM and goes round
//   for as long as the capture runs, over its own tail if it has to:
//
//       0                                              MEM_WORDS - 1
//       +------------------------------------------------------+
//       |#############################|.......|################|
//       +------------------------------------------------------+
//         newer  ^            ^       ^                 older
//                |            |       |
//            trig_addr        |    stop_addr = wr_ptr when the capture ended
//         (word with the      |    (the next word that would have been written,
//          trigger sample)    |     so the oldest word still in memory)
//                             |
//                <-post_words->  words written after the trigger word
//
//   The capture the host reads is the last COUNT words before stop_addr, in
//   rising address order (wrapping): pre-trigger words, the trigger word,
//   post_words words.
//
//   One capture, as the control logic below sees it:
//
//       ARM          trigger word written      last word written
//        |                   |                        |
//   run  |___________________|________________________|
//   _____|                                            |_________
//                            |________________________|__________
//   triggered _______________|
//                                                     |__________
//   done  ____________________________________________|

`default_nettype none

module oxla_core #(
    parameter HOST_HZ = 108000000,  // hclk
    parameter BAUD    = 3000000,
    parameter HOLD_BITS = 17,       // see oxla_host
    parameter W       = 16,         // channels: 8, 14 or 16
    parameter P       = 1,          // samples per clock: 1 or 2
    parameter RLE     = 0,          // run length encoding available (P = 1)
    parameter ADC     = 0,          // the channels are a parallel ADC's data
    parameter INIT_US = 200
) (
    input  wire           hclk,         // host side: a fixed clock
    input  wire           hrst,
    input  wire           clk,          // capture side: the PLL
    input  wire           pll_lock,
    output wire [1:0]     clksel,       // what the PLL should make: 0 = 81, 1 = 108, 2 = 135 MHz
    input  wire [P*W-1:0] din,
    input  wire           rxd,
    output wire           txd,
    output wire           adc_clk,
    output wire           trig_out,
    output wire [5:0]     led,          // active high here

    output wire           sd_cke,
    output wire           sd_cs_n,
    output wire           sd_ras_n,
    output wire           sd_cas_n,
    output wire           sd_we_n,
    output wire [10:0]    sd_addr,
    output wire [1:0]     sd_ba,
    output wire [31:0]    sd_dq_o,
    output wire           sd_dq_oe,
    input  wire [31:0]    sd_dq_i
);
    // Samples of W bits repeat their position in 32 bit words every
    // W / gcd(W, 32) words: 1 for 8 and 16 channels, 7 for 14. The ring is
    // the largest multiple of that in the 2^21 words there are, so a word's
    // address says where the samples in it start.
    function integer group;
        input integer w;
        integer g;
        begin
            g = 1;
            while (g < 32 && w % (2 * g) == 0)
                g = 2 * g;
            group = w / g;
        end
    endfunction
    localparam integer MEM_WORDS = ((1 << 21) / group(W)) * group(W);
    localparam [20:0]  LAST_ADDR = MEM_WORDS - 1;

    // Two clocks. The host side (UART, commands, registers, readout) has a
    // fixed one; everything that touches samples or the SDRAM is on the
    // PLL the host can retune. What crosses, and how:
    //
    //      host side (hclk)                         capture side (clk)
    //
    //   cfg_* registers  ------------------------->  used as they are: the
    //                                                host only writes them
    //                                                while nothing runs
    //   arm, stop, soft_rst  --[toggle]--[sync]-->   one-clock pulses
    //   clk_hold  ---------------------[sync]---->   reset while the PLL
    //                                                settles
    //   rd_req, rd_addr  --------------[sync]---->   read one word
    //   rd_ack  <----------------------[sync]-----   rd_data is the word
    //   status bits  <-----------------[sync]-----   run, triggered, done,
    //                                                overflow, SDRAM ready
    //   trig, stop, count, rd_data  <-------------   read only once done or
    //                                                rd_ack says they are still

    // Clocks between SDRAM refreshes (4096 per 64 ms is one per 15.6 us;
    // this is 7 us), for the clock as it is.
    wire [15:0] ref_cyc  = (clksel == 2'd0) ? 16'd567 :
                           (clksel == 2'd2) ? 16'd945 : 16'd756;

    wire [23:0]  cfg_div;
    wire [21:0]  cfg_post_words, cfg_pre_words;
    wire [31:0]  cfg_post_samples;
    wire         cfg_rle, cfg_ddr, cfg_test;
    wire [W-1:0] cfg_chmask;
    wire [2:0]   cfg_tmode;
    wire [15:0]  cfg_tcount;
    wire [W-1:0] cfg_a_mask, cfg_a_val, cfg_a_rise, cfg_a_fall, cfg_a_edge;
    wire [W-1:0] cfg_b_mask, cfg_b_val, cfg_b_rise, cfg_b_fall, cfg_b_edge;
    wire         arm_h, stop_h, soft_rst_h;     // pulses on hclk
    wire         clk_hold;

    // Capture side reset: while the host side holds it (after power up and
    // after a change of clock), while the PLL is not locked, and for 255
    // clocks more.
    reg [2:0] hold_s = 3'b111;
    reg [7:0] rst_cnt = 8'd0;
    reg       rst = 1'b1;
    always @(posedge clk) begin
        hold_s <= {hold_s[1:0], clk_hold | hrst};
        if (hold_s[2] || !pll_lock) begin
            rst_cnt <= 8'd0;
            rst <= 1'b1;
        end else if (rst_cnt != 8'hff)
            rst_cnt <= rst_cnt + 1'b1;
        else
            rst <= 1'b0;
    end

    // Pulses from the host side: a toggle there, an edge here.
    reg [2:0] t_h = 3'b000;
    reg [2:0] t_s0, t_s1, t_s2;
    always @(posedge hclk)
        t_h <= t_h ^ {soft_rst_h, stop_h, arm_h};
    always @(posedge clk) begin
        t_s0 <= t_h;
        t_s1 <= t_s0;
        t_s2 <= t_s1;
    end
    wire arm      = t_s2[0] ^ t_s1[0];
    wire stop     = t_s2[1] ^ t_s1[1];
    wire soft_rst = t_s2[2] ^ t_s1[2];

    reg          run, triggered, done, overflow, stop_req;
    reg  [20:0]  wr_ptr, trig_addr, stop_addr;
    reg  [1:0]   trig_sub;
    reg  [21:0]  wr_count, post_rem;

    wire         sd_ready;
    wire         rd_req_h, rd_done;
    wire [20:0]  rd_addr;
    wire [31:0]  rd_data;
    wire [5:0]   last_bits;
    reg  [5:0]   last_fill;     // real bits in the final word
    wire         wr_wrap = (wr_ptr == LAST_ADDR);
    wire [20:0]  wr_next = wr_wrap ? 21'd0 : wr_ptr + 1'b1;

    // Memory read: the request crosses as a level, the answer as a level
    // that stays until the request is gone.
    reg [1:0] rd_req_s;
    reg       rd_ack;
    always @(posedge clk) begin
        rd_req_s <= {rd_req_s[0], rd_req_h};
        if (rst || !rd_req_s[1])
            rd_ack <= 1'b0;
        else if (rd_done)
            rd_ack <= 1'b1;
    end

    // Status to the host side.
    reg [4:0] st_s0, st_s1;
    reg [1:0] rd_ack_s;
    always @(posedge hclk) begin
        st_s0 <= {sd_ready, overflow, done, triggered, run};
        st_s1 <= st_s0;
        rd_ack_s <= {rd_ack_s[0], rd_ack};
    end

    wire [31:0] st_status = {18'd0, last_fill, 3'd0, st_s1};
    wire [31:0] st_trig   = {6'd0, trig_sub, 3'd0, trig_addr};
    wire [31:0] st_stop   = {11'd0, stop_addr};
    wire [31:0] st_count  = {10'd0, wr_count};

    oxla_host #(.CLK_HZ(HOST_HZ), .BAUD(BAUD), .HOLD_BITS(HOLD_BITS),
                .W(W), .P(P), .RLE(RLE), .ADC(ADC), .MEM_WORDS(MEM_WORDS)) u_host (
        .clk(hclk), .rst(hrst), .rxd(rxd), .txd(txd),
        .clksel(clksel), .clk_hold(clk_hold),
        .cfg_div(cfg_div), .cfg_post_words(cfg_post_words),
        .cfg_pre_words(cfg_pre_words), .cfg_post_samples(cfg_post_samples),
        .cfg_rle(cfg_rle), .cfg_ddr(cfg_ddr), .cfg_test(cfg_test),
        .cfg_chmask(cfg_chmask), .cfg_tmode(cfg_tmode), .cfg_tcount(cfg_tcount),
        .cfg_a_mask(cfg_a_mask), .cfg_a_val(cfg_a_val), .cfg_a_rise(cfg_a_rise),
        .cfg_a_fall(cfg_a_fall), .cfg_a_edge(cfg_a_edge),
        .cfg_b_mask(cfg_b_mask), .cfg_b_val(cfg_b_val), .cfg_b_rise(cfg_b_rise),
        .cfg_b_fall(cfg_b_fall), .cfg_b_edge(cfg_b_edge),
        .arm(arm_h), .stop(stop_h), .soft_rst(soft_rst_h),
        .st_status(st_status), .st_trig(st_trig), .st_stop(st_stop),
        .st_count(st_count),
        .rd_req(rd_req_h), .rd_addr(rd_addr), .rd_data(rd_data), .rd_ack(rd_ack_s[1]));

    // Sample path.
    wire [P*W-1:0] s_data, t_data;
    wire [P-1:0]   s_valid, t_valid, t_mark;
    wire           fired, pre_ok;
    wire           p_push;
    wire [35:0]    p_data;

    oxla_sampler #(.W(W), .P(P)) u_sampler (
        .clk(clk), .run(run), .din(din),
        .cfg_div(cfg_div), .cfg_ddr(cfg_ddr), .cfg_test(cfg_test),
        .cfg_chmask(cfg_chmask),
        .s_data(s_data), .s_valid(s_valid), .adc_clk(adc_clk));

    oxla_trigger #(.W(W), .P(P)) u_trigger (
        .clk(clk), .run(run), .enable(pre_ok),
        .s_data(s_data), .s_valid(s_valid),
        .cfg_mode(cfg_tmode), .cfg_count(cfg_tcount),
        .cfg_a_mask(cfg_a_mask), .cfg_a_val(cfg_a_val), .cfg_a_rise(cfg_a_rise),
        .cfg_a_fall(cfg_a_fall), .cfg_a_edge(cfg_a_edge),
        .cfg_b_mask(cfg_b_mask), .cfg_b_val(cfg_b_val), .cfg_b_rise(cfg_b_rise),
        .cfg_b_fall(cfg_b_fall), .cfg_b_edge(cfg_b_edge),
        .t_data(t_data), .t_valid(t_valid), .t_mark(t_mark), .fired(fired));

    oxla_packer #(.W(W), .P(P), .RLE(RLE)) u_packer (
        .clk(clk), .run(run), .stop_req(stop_req),
        .cfg_rle(cfg_rle), .cfg_post_samples(cfg_post_samples),
        .cfg_pre_words(cfg_pre_words),
        .t_data(t_data), .t_valid(t_valid), .t_mark(t_mark),
        .push(p_push), .pdata(p_data), .pre_ok(pre_ok), .last_bits(last_bits));

    // FIFO between the sample path and the memory.
    wire        f_valid, f_full, wr_ack;
    wire [35:0] f_dout;
    wire        f_trig = f_dout[32];
    wire [1:0]  f_sub  = f_dout[34:33];
    wire        f_last = f_dout[35];

    oxla_fifo #(.WIDTH(36), .AW(9)) u_fifo (
        .clk(clk), .clr(!run), .push(p_push), .din(p_data), .full(f_full),
        .pop(wr_ack), .valid(f_valid), .dout(f_dout));

    oxla_sdram #(.INIT_US(INIT_US)) u_sdram (
        .clk(clk), .rst(rst), .ref_cyc(ref_cyc), .ready(sd_ready),
        .wr_valid(f_valid && run), .wr_addr(wr_ptr), .wr_wrap(wr_wrap),
        .wr_data(f_dout[31:0]),
        .wr_ack(wr_ack),
        .rd_req(rd_req_s[1] && !rd_ack), .rd_addr(rd_addr), .rd_data(rd_data),
        .rd_done(rd_done),
        .sd_cke(sd_cke), .sd_cs_n(sd_cs_n), .sd_ras_n(sd_ras_n),
        .sd_cas_n(sd_cas_n), .sd_we_n(sd_we_n), .sd_addr(sd_addr), .sd_ba(sd_ba),
        .sd_dq_o(sd_dq_o), .sd_dq_oe(sd_dq_oe), .sd_dq_i(sd_dq_i));

    // Capture control. post_rem counts the words still to be written after
    // the word that holds the trigger sample; post_one says it is at 1, and
    // is kept as a register so the end of the capture does not wait for a
    // comparison.
    reg fin;
    reg post_one, post_cfg0, post_cfg1;
    always @(posedge clk) begin
        post_cfg0 <= (cfg_post_words == 22'd0);
        post_cfg1 <= (cfg_post_words == 22'd1);

        if (rst || soft_rst) begin
            run <= 1'b0;
            triggered <= 1'b0;
            done <= 1'b0;
            overflow <= 1'b0;
            stop_req <= 1'b0;
        end else if (!run) begin
            if (arm) begin
                run <= 1'b1;
                triggered <= 1'b0;
                done <= 1'b0;
                overflow <= 1'b0;
                stop_req <= 1'b0;
                wr_ptr <= 21'd0;
                wr_count <= 22'd0;
            end
        end else begin
            fin = 1'b0;
            if (stop)
                stop_req <= 1'b1;
            if (p_push && f_full) begin
                overflow <= 1'b1;
                fin = 1'b1;
            end
            if (wr_ack) begin
                wr_ptr <= wr_next;
                if (wr_count != MEM_WORDS)
                    wr_count <= wr_count + 1'b1;
                if (f_trig && !triggered) begin
                    triggered <= 1'b1;
                    trig_addr <= wr_ptr;
                    trig_sub <= f_sub;
                    post_rem <= cfg_post_words;
                    post_one <= post_cfg1;
                    if (post_cfg0)
                        fin = 1'b1;
                end else if (triggered) begin
                    post_rem <= post_rem - 1'b1;
                    post_one <= (post_rem == 22'd2);
                    if (post_one)
                        fin = 1'b1;
                end
                if (f_last)
                    fin = 1'b1;
            end
            if (fin) begin
                run <= 1'b0;
                done <= 1'b1;
                stop_addr <= wr_ack ? wr_next : wr_ptr;
                if (wr_ack && f_last)
                    last_fill <= last_bits;
                else
                    last_fill <= 6'd32;
            end
        end
    end

    assign trig_out = fired;

    // A slow blink shows the clock and the SDRAM are alive.
    reg [25:0] beat;
    always @(posedge clk)
        beat <= beat + 1'b1;

    assign led = {overflow, done, triggered, run, !rxd, sd_ready & beat[25]};
endmodule

`default_nettype wire
