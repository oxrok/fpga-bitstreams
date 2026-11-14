// The sample path: sampler -> trigger -> packer. All of it runs on the one
// system clock and is held in reset while `run` is low.
//
// W is the number of channels (8, 14 or 16) and P the number of samples taken
// per clock (1, or 2 when the inputs go through IDDR cells). Sample i of a
// clock is bits [i*W +: W]; sample 0 is the earlier one.

//   A sample takes eight clocks from the pin to the FIFO, and the trigger
//   mark travels with the sample it belongs to:
//
//    pins   d1   d2  s_data  d1/ma/mb  t_data  q_data    acc    pdata
//     |     |    |     |        |      t_mark  q_mark   fill    push
//     v     v    v     v        v        v       v        v       v
//    -o---[FF]-[FF]--[FF]-----[FF]-----[FF]----[FF]-----[FF]----[FF]--> FIFO
//         \_________/  |       \_________/      \__________________/
//           sampler    |         trigger               packer
//         synchronizer |   stage 1     stage 2   stage 1   stage 2
//                  test pattern   match   sequence  sample   bits into
//                  goes in here   A and B and count limit    words

`default_nettype none

// ---------------------------------------------------------------------------
// Sampler: input synchronizer, sample rate divider, test pattern.

//   The divider, for cfg_div = 2 (one sample every three clocks):
//
//   clk      _|~|_|~|_|~|_|~|_|~|_|~|_|~|_|~|_|~|_
//   cnt        0   2   1   0   2   1   0   2   1
//   tick     ~~~~|_______|~~~|_______|~~~|_______
//   s_valid  ____|~~~|_______|~~~|_______|~~~|___      one clock after tick
//   s_data   ----< n >-------<n+1>-------<n+2>---
//   adc_clk  ________|~~~|_______|~~~|_______|~~~      high while cnt > div/2
//
//   With two samples per clock (P = 2, cfg_ddr, cfg_div = 0) both halves of
//   s_data are valid every clock: [W-1:0] is the sample taken on the rising
//   edge, [2W-1:W] the one taken on the falling edge after it.
module oxla_sampler #(
    parameter W = 16,
    parameter P = 1
) (
    input  wire           clk,
    input  wire           run,
    input  wire [P*W-1:0] din,
    input  wire [23:0]    cfg_div,      // one sample every cfg_div + 1 clocks
    input  wire           cfg_ddr,      // P = 2: take both samples (cfg_div must be 0)
    input  wire           cfg_test,     // samples are a counter, not the pins
    input  wire [W-1:0]   cfg_chmask,
    output reg  [P*W-1:0] s_data,
    output reg  [P-1:0]   s_valid,
    output reg            adc_clk       // high for the first half of a sample period
);
    reg [P*W-1:0] d1, d2;
    reg [23:0]    cnt;
    reg [W-1:0]   pat;

    wire tick = (cnt == 24'd0);
    wire ddr  = (P > 1) && cfg_ddr && (cfg_div == 24'd0);

    integer i;
    always @(posedge clk) begin
        d1 <= din;
        d2 <= d1;

        // The divider runs all the time, so an ADC keeps its clock.
        cnt <= tick ? cfg_div : cnt - 1'b1;
        adc_clk <= (cnt > {1'b0, cfg_div[23:1]});

        for (i = 0; i < P; i = i + 1)
            s_data[i*W +: W] <= cfg_test ? pat + i[W-1:0]
                                         : d2[i*W +: W] & cfg_chmask;

        if (!run) begin
            s_valid <= {P{1'b0}};
            pat <= {W{1'b0}};
        end else begin
            s_valid <= {P{1'b0}};
            s_valid[0] <= tick;
            if (P > 1)
                s_valid[P-1] <= tick & ddr;
            // s_data is one clock behind pat, as s_valid is behind tick.
            if (tick)
                pat <= pat + (ddr ? 2'd2 : 2'd1);
        end
    end
endmodule

// ---------------------------------------------------------------------------
// Trigger: two terms, A and B, and a way of combining them.
//
// A term gives every channel one of: don't care, low, high, rising, falling,
// either edge. The term matches a sample when all its channels do, as a
// sigrok trigger stage does. A term with no conditions matches every sample.
//
//   mode 0  immediate     the first sample
//        1  A
//        2  B
//        3  A or B
//        4  A and B       on the same sample
//        5  A then B      B on a later sample than A
//        6  B then A
//
// The trigger fires on the (cfg_count + 1)th event of the selected kind.
// Nothing counts, and no sequence advances, while `enable` is low.

//   One term on one channel. The five registers each have a bit per channel,
//   and a channel can have a level and an edge condition at once:
//
//       mask  val                      rise  fall  edge
//        0     x    don't care          1     0     0    0 -> 1
//        1     0    must be low         0     1     0    1 -> 0
//        1     1    must be high        0     0     1    either
//
//                      +------------------+
//    sample ---------->| every channel's  |    all of them
//    sample before --->| conditions hold? |---- AND ----> term matches
//                      +------------------+
//
//   The two "then" modes are a two state machine; the others have no state:
//
//    mode 5, A then B                      (mode 6 is the same with A and B
//                                           the other way round)
//          +---------+   A matches    +---------+   B matches
//     ---->| waiting |--------------->| waiting |---------------> event
//          |  for A  |                |  for B  |
//          +---------+                +---------+
//               ^                          |
//               +--------------------------+
//                 event, with cfg_count events still to go
//
//   Every event counts down from cfg_count, and the event that finds the
//   count at zero fires the trigger: t_mark is set on that sample, once.
module oxla_trigger #(
    parameter W = 16,
    parameter P = 1
) (
    input  wire           clk,
    input  wire           run,
    input  wire           enable,
    input  wire [P*W-1:0] s_data,
    input  wire [P-1:0]   s_valid,
    input  wire [2:0]     cfg_mode,
    input  wire [15:0]    cfg_count,
    input  wire [W-1:0]   cfg_a_mask, cfg_a_val, cfg_a_rise, cfg_a_fall, cfg_a_edge,
    input  wire [W-1:0]   cfg_b_mask, cfg_b_val, cfg_b_rise, cfg_b_fall, cfg_b_edge,
    output reg  [P*W-1:0] t_data,
    output reg  [P-1:0]   t_valid,
    output reg  [P-1:0]   t_mark,       // the sample the trigger fired on
    output reg            fired
);
    function term;
        input [W-1:0] d, p;
        input         hp;               // p is a real previous sample
        input [W-1:0] mask, val, rise, fall, edg;
        begin
            term = &(~mask | ~(d ^ val))
                 & &(~rise | ({W{hp}} &  d & ~p))
                 & &(~fall | ({W{hp}} & ~d &  p))
                 & &(~edg  | ({W{hp}} & (d ^ p)));
        end
    endfunction

    // Stage 1: match both terms on every sample of the clock.
    reg [W-1:0]   last;
    reg           have_last;
    reg [P-1:0]   ma, mb, v1;
    reg [P*W-1:0] d1;

    integer i;
    always @(posedge clk) begin
        d1 <= s_data;
        v1 <= run ? s_valid : {P{1'b0}};
        for (i = 0; i < P; i = i + 1) begin
            ma[i] <= term(s_data[i*W +: W],
                          i == 0 ? last : s_data[(i == 0 ? 0 : i-1)*W +: W],
                          i == 0 ? have_last : 1'b1,
                          cfg_a_mask, cfg_a_val, cfg_a_rise, cfg_a_fall, cfg_a_edge);
            mb[i] <= term(s_data[i*W +: W],
                          i == 0 ? last : s_data[(i == 0 ? 0 : i-1)*W +: W],
                          i == 0 ? have_last : 1'b1,
                          cfg_b_mask, cfg_b_val, cfg_b_rise, cfg_b_fall, cfg_b_edge);
        end
        if (!run)
            have_last <= 1'b0;
        else if (s_valid[0]) begin
            have_last <= 1'b1;
            last <= s_valid[P-1] ? s_data[(P-1)*W +: W] : s_data[W-1:0];
        end
    end

    // Stage 2: the sequence and the event counter.
    // The count is compared here, on the register, and the events of this
    // clock are only counted (v_dec), so that with two samples per clock
    // there is no subtraction in front of a comparison.
    reg        seen;                    // first term of a "then" has matched
    reg [15:0] cnt;
    reg        v_fired, v_seen, v_ev;
    reg [1:0]  v_dec;                   // events on this clock so far
    wire       cnt_is0 = (cnt == 16'd0);
    wire       cnt_is1 = (cnt == 16'd1);

    always @(posedge clk) begin
        t_data <= d1;
        t_valid <= run ? v1 : {P{1'b0}};
        t_mark <= {P{1'b0}};
        if (!run) begin
            fired <= 1'b0;
            seen <= 1'b0;
            cnt <= cfg_count;
        end else begin
            v_fired = fired;
            v_seen = seen;
            v_dec = 2'd0;
            for (i = 0; i < P; i = i + 1) begin
                if (v1[i] && enable && !v_fired) begin
                    v_ev = 1'b0;
                    case (cfg_mode)
                        3'd0: v_ev = 1'b1;
                        3'd1: v_ev = ma[i];
                        3'd2: v_ev = mb[i];
                        3'd3: v_ev = ma[i] | mb[i];
                        3'd4: v_ev = ma[i] & mb[i];
                        3'd5: if (v_seen) v_ev = mb[i]; else v_seen = ma[i];
                        3'd6: if (v_seen) v_ev = ma[i]; else v_seen = mb[i];
                        default: v_ev = 1'b0;
                    endcase
                    if (v_ev) begin
                        if (v_dec == 2'd0 ? cnt_is0 : cnt_is1) begin
                            v_fired = 1'b1;
                            t_mark[i] <= 1'b1;
                        end else begin
                            v_dec = v_dec + 1'b1;
                            v_seen = 1'b0;      // a "then" starts over
                        end
                    end
                end
            end
            fired <= v_fired;
            seen <= v_seen;
            cnt <= cnt - {14'd0, v_dec};
        end
    end
endmodule

// ---------------------------------------------------------------------------
// Packer: samples into 32 bit memory words, plus three flag bits that travel
// with the word through the FIFO:
//
//   [31:0]   the word
//   [32]     trig: the trigger sample is in this word
//   [34:33]  sub:  which sample of the word it is (raw mode)
//   [35]     last: the capture ends with this word
//
// Raw mode packs 32/W samples per word, the earliest in the low bits. When
// W does not divide 32 (14 channels) the samples are a continuous stream of
// bits instead, low bit first, cut into words wherever 32 bits are full; a
// sample then may straddle two words, and `sub` counts the samples that
// start in the word.
// RLE mode (RLE = 1 and cfg_rle; P must be 1) writes {count, sample}: the
// sample was seen count + 1 times in a row. The trigger sample always starts
// a new run, so it is the first sample of the word flagged trig.
//
// cfg_post_samples samples are taken after the trigger sample and then the
// capture ends (0xffffffff: no limit here; the word count in oxla_core ends
// it). stop_req ends it at once. Either way the word in progress is written
// with `last`, and last_bits says how many of its bits are real.

//   What goes into the FIFO, 36 bits:
//
//      35   34  33   32  31                                         0
//    +------+-------+------+-----------------------------------------+
//    | last |  sub  | trig |               memory word               |
//    +------+-------+------+-----------------------------------------+
//
//   The memory word, by mode. Time runs from the low bits up:
//
//    raw, 16 channels      31            16 15             0
//                         +----------------+----------------+
//                         |    sample 1    |    sample 0    |
//                         +----------------+----------------+
//
//    raw, 8 channels       31     24 23     16 15      8 7       0
//                         +---------+---------+---------+---------+
//                         |   s3    |   s2    |   s1    |   s0    |
//                         +---------+---------+---------+---------+
//
//    raw, 14 channels: the samples are a stream of bits cut every 32, so
//    16 samples fill 7 words exactly and then the pattern repeats:
//
//                          31  28 27          14 13           0
//             word 0      +------+--------------+--------------+
//                         |s2 lo |      s1      |      s0      |
//                         +------+--------------+--------------+
//                          31    24 23          10 9           0
//             word 1      +--------+--------------+------------+
//                         | s4 lo  |      s3      |   s2 hi    |
//                         +--------+--------------+------------+
//                          ...
//                          31          18 17           4 3     0
//             word 6      +--------------+--------------+-------+
//                         |     s15      |     s14      |s13 hi |
//                         +--------------+--------------+-------+
//
//    RLE, 16 channels      31            16 15             0
//                         +----------------+----------------+
//                         |  run length-1  |     sample     |
//                         +----------------+----------------+
//
//    RLE, 8 channels       31                         8 7       0
//                         +----------------------------+---------+
//                         |        run length-1        | sample  |
//                         +----------------------------+---------+
//
//   RLE on a line that goes 5 5 5 5 9 9 5, with the trigger on the second 9:
//
//    samples    5   5   5   5   9   9   5
//                                   ^ trigger
//    words         {3, 5}      {0, 9}  {0, 9}+trig   (5 still being counted)
//
//   The trigger sample always starts a run of its own, so the word flagged
//   trig begins exactly at the trigger.
module oxla_packer #(
    parameter W   = 16,
    parameter P   = 1,
    parameter RLE = 0
) (
    input  wire           clk,
    input  wire           run,
    input  wire           stop_req,
    input  wire           cfg_rle,
    input  wire [31:0]    cfg_post_samples,
    input  wire [21:0]    cfg_pre_words,
    input  wire [P*W-1:0] t_data,
    input  wire [P-1:0]   t_valid,
    input  wire [P-1:0]   t_mark,
    output reg            push,
    output reg  [35:0]    pdata,
    output reg            pre_ok,       // cfg_pre_words words have been written
    output reg  [5:0]     last_bits
);
    localparam integer CW = 32 - W;     // width of the run count

    // Stage 1: count the samples after the trigger and flag the last one.
    // Samples after it are dropped here. The comparisons are on registers,
    // not on the result of this clock's subtraction, which is what lets two
    // samples per clock through at speed.
    reg [P*W-1:0] q_data;
    reg [P-1:0]   q_valid, q_mark, q_last;
    reg           post_on, ended;
    reg [31:0]    rem;
    reg           post_off, post_is0, post_is1;
    wire          rem_is1 = (rem == 32'd1);
    wire          rem_is2 = (rem == 32'd2);
    wire          two = (P > 1) && t_valid[P-1];

    always @(posedge clk) begin
        post_off <= (cfg_post_samples == 32'hffffffff);
        post_is0 <= (cfg_post_samples == 32'd0);
        post_is1 <= (cfg_post_samples == 32'd1);

        q_data <= t_data;
        q_valid <= ended ? {P{1'b0}} : t_valid;
        q_mark <= ended ? {P{1'b0}} : t_mark;
        q_last <= {P{1'b0}};

        if (!run) begin
            post_on <= 1'b0;
            ended <= 1'b0;
            q_valid <= {P{1'b0}};
            q_mark <= {P{1'b0}};
        end else if (!ended && t_valid[0]) begin
            if (post_on) begin
                rem <= rem - (two ? 32'd2 : 32'd1);
                if (rem_is1) begin
                    q_last[0] <= 1'b1;
                    ended <= 1'b1;
                    if (P > 1) q_valid[P-1] <= 1'b0;
                end else if (rem_is2 && two) begin
                    q_last[P-1] <= 1'b1;
                    ended <= 1'b1;
                end
            end else if (!post_off) begin
                if (t_mark[0]) begin
                    post_on <= 1'b1;
                    rem <= cfg_post_samples - (two ? 32'd1 : 32'd0);
                    if (post_is0) begin
                        q_last[0] <= 1'b1;
                        ended <= 1'b1;
                        if (P > 1) q_valid[P-1] <= 1'b0;
                    end else if (post_is1 && two) begin
                        q_last[P-1] <= 1'b1;
                        ended <= 1'b1;
                    end
                end else if (P > 1 && t_mark[P-1]) begin
                    post_on <= 1'b1;
                    rem <= cfg_post_samples;
                    if (post_is0) begin
                        q_last[P-1] <= 1'b1;
                        ended <= 1'b1;
                    end
                end
            end
        end
    end

    // Stage 2: pack.
    reg        s_done;
    reg [21:0] emitted;

    // RLE mode.
    reg          have;
    reg [W-1:0]  cur;
    reg [CW-1:0] rcnt;
    reg          ctrig;
    reg          flush;

    // Raw mode: acc holds the bits not yet written, fill how many.
    // Two samples of up to 15 bits on top of 31 are 61 at most, and one word
    // leaves per clock while there are 32 or more.
    reg [63:0] acc, v_acc;
    reg [5:0]  fill, v_fill;
    reg        pt0, pt1, v_t0, v_t1;    // trig, for the low and the high word
    reg [1:0]  ps0, ps1, v_s0, v_s1;    // sub
    reg [1:0]  pn0, pn1, v_n0, v_n1;    // samples that started in the word
    reg        ending;


    wire [W-1:0] d0 = q_data[W-1:0];

    integer i;
    always @(posedge clk) begin
        push <= 1'b0;
        pre_ok <= (emitted >= cfg_pre_words);
        if (push && emitted != 22'h3fffff)
            emitted <= emitted + 1'b1;

        if (!run) begin
            s_done <= 1'b0;
            emitted <= 22'd0;
            pre_ok <= 1'b0;
            have <= 1'b0;
            flush <= 1'b0;
            last_bits <= 6'd0;
            fill <= 6'd0;
            acc <= 64'd0;
            pt0 <= 1'b0; ps0 <= 2'd0; pn0 <= 2'd0;
            pt1 <= 1'b0; ps1 <= 2'd0; pn1 <= 2'd0;
            ending <= 1'b0;
        end else if (s_done) begin
            // The capture has ended; oxla_core drops run once the last word
            // is in memory.
        end else if (RLE != 0 && cfg_rle) begin
            if (flush) begin
                push <= 1'b1;
                pdata <= {1'b1, 2'b00, ctrig, rcnt, cur};
                last_bits <= have ? 6'd32 : 6'd0;
                s_done <= 1'b1;
            end else begin
                if (q_valid[0]) begin
                    if (!have) begin
                        have <= 1'b1;
                        cur <= d0;
                        rcnt <= {CW{1'b0}};
                        ctrig <= q_mark[0];
                    end else if (d0 == cur && !q_mark[0] && rcnt != {CW{1'b1}}) begin
                        rcnt <= rcnt + 1'b1;
                    end else begin
                        push <= 1'b1;
                        pdata <= {1'b0, 2'b00, ctrig, rcnt, cur};
                        cur <= d0;
                        rcnt <= {CW{1'b0}};
                        ctrig <= q_mark[0];
                    end
                end
                // The run in progress goes out on the next clock.
                if (stop_req || q_last[0])
                    flush <= 1'b1;
            end
        end else begin
            // Raw mode, for every channel count: the samples are a stream
            // of bits. acc holds up to two words' worth. A full low word
            // goes out on the clock after it filled, straight from the
            // register, and the only logic in front of acc is one shift per
            // sample by the low bits of fill. (Building the word and
            // pushing it in the same clock failed on the board at 135 MHz
            // with two samples per clock, while nextpnr's report passed.)
            //
            //         63            32 31             0
            //        +----------------+----------------+
            //   acc  |  next word     |  word going    |   fill = bits held
            //        |  flags t1/s1/n1|  out, t0/s0/n0 |
            //        +----------------+----------------+
            v_acc = acc;
            v_fill = fill;
            v_t0 = pt0; v_s0 = ps0; v_n0 = pn0;
            v_t1 = pt1; v_s1 = ps1; v_n1 = pn1;
            if (ending) begin
                // No more samples: write out what is held, the last word
                // with as many real bits as are left.
                push <= 1'b1;
                if (fill > 6'd32) begin
                    pdata <= {1'b0, ps0, pt0, acc[31:0]};
                    v_acc = {32'd0, acc[63:32]};
                    v_fill = fill - 6'd32;
                    v_t0 = pt1; v_s0 = ps1; v_n0 = pn1;
                    v_t1 = 1'b0; v_s1 = 2'd0; v_n1 = 2'd0;
                end else begin
                    pdata <= {1'b1, ps0, pt0, acc[31:0]};
                    last_bits <= fill;
                    s_done <= 1'b1;
                end
            end else begin
                if (fill[5]) begin
                    push <= 1'b1;
                    pdata <= {1'b0, ps0, pt0, acc[31:0]};
                    v_acc = {32'd0, acc[63:32]};
                    v_fill = {1'b0, fill[4:0]};
                    v_t0 = pt1; v_s0 = ps1; v_n0 = pn1;
                    v_t1 = 1'b0; v_s1 = 2'd0; v_n1 = 2'd0;
                end
                for (i = 0; i < P; i = i + 1) begin
                    if (q_valid[i]) begin
                        v_acc = v_acc | ({{(64-W){1'b0}}, q_data[i*W +: W]} << v_fill);
                        // The word the sample starts in gets the mark.
                        if (!v_fill[5]) begin
                            if (q_mark[i]) begin v_t0 = 1'b1; v_s0 = v_n0; end
                            v_n0 = v_n0 + 1'b1;
                        end else begin
                            if (q_mark[i]) begin v_t1 = 1'b1; v_s1 = v_n1; end
                            v_n1 = v_n1 + 1'b1;
                        end
                        v_fill = v_fill + W[5:0];
                        if (q_last[i])
                            ending <= 1'b1;
                    end
                end
                if (stop_req)
                    ending <= 1'b1;
            end
            acc <= v_acc;
            fill <= v_fill;
            pt0 <= v_t0; ps0 <= v_s0; pn0 <= v_n0;
            pt1 <= v_t1; ps1 <= v_s1; pn1 <= v_n1;
        end
    end
endmodule

`default_nettype wire
