// Testbench for oxla_core: a host on the UART, the SDRAM model on the memory
// pins, and the channels driven with a function of the clock count, so a
// capture can be checked without knowing the latency of the sample path.
//
// Run for one variant with -GW=.. -GP=.. -GRLE=.. (see the Makefile).

`timescale 1ns/1ps

module tb;
    parameter W = 16;
    parameter P = 1;
    parameter RLE = 1;

    parameter int CLK_HZ = 108000000;
    localparam real TCK = 1e9 / CLK_HZ;
    localparam int BAUD = CLK_HZ / 8;       // fast, to keep the readouts short
    localparam real TBIT = 1e9 / BAUD;
    // Samples repeat their position in the words every G words; the ring
    // is a multiple of that (see oxla_core).
    function automatic int group(input int w);
        int g = 1;
        while (g < 32 && w % (2 * g) == 0) g = 2 * g;
        return w / g;
    endfunction
    localparam int G = group(W);
    localparam int MEM = ((1 << 21) / G) * G;
    localparam int unsigned WMASK = (W == 32) ? 32'hffffffff : ((1 << W) - 1);

    logic clk = 0;
    always #(TCK / 2) clk = ~clk;
    logic rst = 1;

    // Channels: sample i of clock n is (P*n + i) >> shift.
    logic [P*W-1:0] din = '0;
    int unsigned n = 0;
    int shift = 0;
    always @(negedge clk) begin
        n <= n + 1;
        for (int i = 0; i < P; i++)
            din[i*W +: W] <= W'((P * n + i) >> shift);
    end

    logic rxd = 1;
    wire  txd, trig_out, adc_clk;
    wire [5:0] led;
    wire sd_cke, sd_cs_n, sd_ras_n, sd_cas_n, sd_we_n, sd_dq_oe;
    wire [10:0] sd_addr;
    wire [1:0] sd_ba;
    wire [31:0] sd_dq_o;
    wire [31:0] ram_q;
    wire        ram_q_valid;
    // What the controller's input cells see: the SDRAM's data while it
    // drives, garbage otherwise.
    wire [31:0] dq = ram_q_valid ? ram_q : 32'hdeadbeef;

    oxla_core #(.CLK_HZ(CLK_HZ), .BAUD(BAUD), .W(W), .P(P), .RLE(RLE), .ADC(0),
                .INIT_US(5)) dut (
        .clk(clk), .rst(rst), .din(din), .rxd(rxd), .txd(txd),
        .adc_clk(adc_clk), .trig_out(trig_out), .led(led),
        .sd_cke(sd_cke), .sd_cs_n(sd_cs_n), .sd_ras_n(sd_ras_n),
        .sd_cas_n(sd_cas_n), .sd_we_n(sd_we_n), .sd_addr(sd_addr), .sd_ba(sd_ba),
        .sd_dq_o(sd_dq_o), .sd_dq_oe(sd_dq_oe), .sd_dq_i(dq));

    sdram_model #(.TCK_NS(TCK)) ram (
        .clk(~clk), .cke(sd_cke), .cs_n(sd_cs_n), .ras_n(sd_ras_n),
        .cas_n(sd_cas_n), .we_n(sd_we_n), .addr(sd_addr), .ba(sd_ba),
        .dqm(4'b0), .dq_i(sd_dq_o), .dq_i_valid(sd_dq_oe),
        .dq_o(ram_q), .dq_o_valid(ram_q_valid));

    // ---- host -------------------------------------------------------------
    byte unsigned rxq[$];
    int fails = 0;

    initial forever begin
        logic [7:0] d;
        @(negedge txd);
        #(TBIT * 1.5);
        for (int b = 0; b < 8; b++) begin
            d[b] = txd;
            #(TBIT);
        end
        if (!txd) begin $display("FAIL: framing error"); fails++; end
        rxq.push_back(d);
    end

    task automatic send(input byte unsigned b);
        rxd = 0; #(TBIT);
        for (int i = 0; i < 8; i++) begin rxd = b[i]; #(TBIT); end
        rxd = 1; #(TBIT);
    endtask

    task automatic recv(output byte unsigned b);
        int guard = 0;
        while (rxq.size() == 0) begin
            #(TBIT);
            guard++;
            if (guard > 200000) begin $display("FAIL: no answer"); $fatal; end
        end
        b = rxq.pop_front();
    endtask

    task automatic recv32(output int unsigned v);
        byte unsigned b;
        v = 0;
        for (int i = 0; i < 4; i++) begin recv(b); v |= int'(b) << (8 * i); end
    endtask

    task automatic wreg(input byte unsigned a, input int unsigned v);
        send(8'h03); send(a);
        for (int i = 0; i < 4; i++) send(8'(v >> (8 * i)));
    endtask

    task automatic rreg(input byte unsigned a, output int unsigned v);
        send(8'h04); send(a);
        recv32(v);
    endtask

    // The words of the last readout, and the bit of words[0] at which its
    // first whole sample starts.
    int unsigned words[$];
    int unsigned off0;
    function automatic int unsigned first_start(input int unsigned a);
        return (W - (32 * (a % G)) % W) % W;
    endfunction
    task automatic rmem(input int unsigned a, input int unsigned cnt);
        int unsigned v;
        words.delete();
        off0 = first_start(a);
        send(8'h07);
        for (int i = 0; i < 3; i++) send(8'(a >> (8 * i)));
        for (int i = 0; i < 3; i++) send(8'(cnt >> (8 * i)));
        for (int unsigned i = 0; i < cnt; i++) begin recv32(v); words.push_back(v); end
    endtask

    task automatic check(input bit ok, input string what);
        if (!ok) begin $display("FAIL: %s", what); fails++; end
    endtask

    int unsigned status, trig, stop_a, count;
    task automatic wait_done(input int polls);
        for (int i = 0; i < polls; i++) begin
            rreg(8'h80, status);
            if (status[2]) break;
            #(TCK * 2000);
        end
        check(status[2], "capture did not finish");
        rreg(8'h81, trig);
        rreg(8'h82, stop_a);
        rreg(8'h83, count);
    endtask

    // Read the whole capture (the last `count` words before stop_a).
    task automatic read_capture;
        rmem((stop_a + MEM - count) % MEM, count);
    endtask

    function automatic int unsigned samp(input int unsigned i);
        longint unsigned b = off0 + longint'(i) * W;
        longint unsigned two = words[b / 32];
        if (b / 32 + 1 < words.size()) two |= longint'(words[b / 32 + 1]) << 32;
        return int'(two >> (b % 32)) & WMASK;
    endfunction
    // Whole samples in the readout.
    function automatic int unsigned nsamp;
        return (words.size() * 32 - off0) / W;
    endfunction

    // Index, in the words read by read_capture, of the trigger word.
    function automatic int unsigned trig_word;
        return ((trig & 'h1fffff) + MEM - ((stop_a + MEM - count) % MEM)) % MEM;
    endfunction
    function automatic int unsigned trig_samp;
        int unsigned a = (stop_a + MEM - count) % MEM;
        return (32 * trig_word() + first_start(a + trig_word()) - off0) / W
               + ((trig >> 24) & 3);
    endfunction

    task automatic reset_dev;
        for (int i = 0; i < 8; i++) send(8'h00);
        send(8'h01);
        #(TCK * 20);
    endtask

    // Raw capture from the pins; checks the stride and returns the trigger
    // sample.
    task automatic raw_capture(input string name, input int unsigned stride,
                               output int unsigned tsample);
        int unsigned ns, ti;
        send(8'h05);
        wait_done(400);
        read_capture();
        ns = nsamp();
        ti = trig_samp();
        check(status[1], {name, ": not triggered"});
        check(!status[3], {name, ": overflow"});
        for (int unsigned i = 1; i < ns; i++)
            if (samp(i) != ((samp(i-1) + stride) & WMASK)) begin
                $display("FAIL: %s: sample %0d is %0h after %0h", name, i, samp(i), samp(i-1));
                fails++;
                break;
            end
        tsample = samp(ti);
        $display("%s: %0d words, trigger at sample %0d = %0h", name, count, ti, tsample);
    endtask

    int unsigned v, ts;
    byte unsigned b;
    initial begin
        #(TCK * 20) rst = 0;

        // SDRAM comes up.
        for (int i = 0; i < 100; i++) begin
            rreg(8'h80, status);
            if (status[4]) break;
            #(TCK * 500);
        end
        check(status[4], "SDRAM not ready");

        // ID.
        send(8'h02);
        begin
            byte unsigned id[16];
            for (int i = 0; i < 16; i++) recv(id[i]);
            check(id[0] == "O" && id[1] == "X" && id[2] == "L" && id[3] == "A", "ID magic");
            check(id[4] == 1, "ID version");
            check(id[5] == 8'((P > 1) << 1 | (RLE != 0)), "ID caps");
            check(id[6] == W && id[7] == P, "ID geometry");
            check({id[11], id[10], id[9], id[8]} == CLK_HZ, "ID clock");
            check({id[15], id[14], id[13], id[12]} == MEM, "ID memory");
        end

        // 1. Test pattern, immediate trigger, full rate.
        reset_dev();
        wreg(8'h04, (P > 1) ? 32'h6 : 32'h4);
        wreg(8'h01, 600);
        send(8'h05);
        wait_done(100);
        check(status[1], "pattern: not triggered");
        check((trig & 'h1fffff) == 0 && ((trig >> 24) & 3) == 0, "pattern: trigger position");
        check(count == 601 && stop_a == 601, "pattern: word count");
        check(((status >> 8) & 63) == 32, "pattern: last word fill");
        rmem(0, 601);
        for (int unsigned i = 0; i < nsamp(); i++)
            if (samp(i) != (i & WMASK)) begin
                $display("FAIL: pattern: sample %0d is %0h", i, samp(i));
                fails++;
                break;
            end
        $display("pattern: ok");

        // 1b. The same, ended by a count of samples: an odd and an even
        // one, so with two samples per clock the last is either of the pair.
        for (int unsigned post = 37; post <= 38; post++) begin
            reset_dev();
            wreg(8'h04, (P > 1) ? 32'h6 : 32'h4);
            wreg(8'h01, 32'h1fffff);
            wreg(8'h03, post);
            send(8'h05);
            wait_done(100);
            check(count == ((post + 1) * W + 31) / 32, "sample limit: word count");
            check(((status >> 8) & 63) == (((post + 1) * W) % 32 == 0 ? 32 : ((post + 1) * W) % 32),
                  "sample limit: last word fill");
            rmem(0, count);
            for (int unsigned i = 0; i <= post; i++)
                if (samp(i) != (i & WMASK)) begin
                    $display("FAIL: sample limit: sample %0d is %0h", i, samp(i));
                    fails++;
                    break;
                end
        end
        $display("sample limit: ok");

        // 2. Pins, divided clock, level trigger with a pre-trigger hold-off.
        reset_dev();
        shift = 0;
        wreg(8'h00, 3);                 // every 4th clock
        wreg(8'h06, 1);                 // A
        wreg(8'h10, 32'hf0);
        wreg(8'h11, 32'h50);
        wreg(8'h02, 64);
        wreg(8'h01, 100);
        raw_capture("level", 4 * P, ts);
        check((ts & 'hf0) == 'h50, "level: trigger sample");
        check(trig_word() >= 64, "level: pre-trigger hold-off");
        check(count - 1 - trig_word() == 100, "level: post-trigger words");

        // 3. Edges and the combinations, full rate.
        reset_dev();
        if (P > 1) wreg(8'h04, 2);
        wreg(8'h01, 40);
        wreg(8'h02, 8);
        wreg(8'h12, 32'h20);            // A: channel 5 rises
        wreg(8'h1b, 32'h08);            // B: channel 3 falls
        wreg(8'h06, 5);                 // A then B
        wreg(8'h07, 2);                 // the third time
        raw_capture("A then B", 1, ts);
        check((ts & 'h3f) == 'h30, "A then B: trigger sample");

        wreg(8'h07, 0);
        wreg(8'h06, 6);                 // B then A
        raw_capture("B then A", 1, ts);
        check((ts & 'h3f) == 'h20, "B then A: trigger sample");

        wreg(8'h06, 3);                 // A or B
        raw_capture("A or B", 1, ts);
        check((ts & 'h3f) == 'h20 || (ts & 'h0f) == 0, "A or B: trigger sample");

        wreg(8'h1b, 32'h10);            // B: channel 4 falls
        wreg(8'h18, 32'h03);            // ... while channels 1:0 are 00
        wreg(8'h06, 4);                 // A and B
        raw_capture("A and B", 1, ts);
        check((ts & 'h3f) == 'h20, "A and B: trigger sample");

        wreg(8'h06, 2);                 // B alone, either-edge on channel 2
        wreg(8'h1b, 0);
        wreg(8'h18, 0);
        wreg(8'h1c, 32'h04);
        raw_capture("B edge", 1, ts);
        check((ts & 'h03) == 0, "B edge: trigger sample");

        // 4. A stop from the host, with a trigger that never comes.
        reset_dev();
        wreg(8'h00, 9);
        wreg(8'h06, 4);
        wreg(8'h10, 32'h1);
        wreg(8'h11, 32'h1);
        wreg(8'h18, 32'h1);             // A and B can not both hold
        send(8'h05);
        #(TCK * 3000);
        rreg(8'h80, status);
        check(status[0] && !status[1] && !status[2], "stop: should be running");
        send(8'h06);
        wait_done(20);
        check(!status[1], "stop: triggered");
        check(count > 50, "stop: nothing captured");
        $display("stop: %0d words, %0d bits in the last", count, (status >> 8) & 63);

        if (RLE != 0) begin
            int unsigned total, at, after, tw, bad;
            // 5. RLE: the value changes every 32 samples.
            reset_dev();
            shift = 5;
            #(TCK * 100);
            wreg(8'h04, 1);
            wreg(8'h06, 1);
            wreg(8'h10, 32'hff);
            wreg(8'h11, 32'h80);        // low byte is 0x80
            wreg(8'h02, 4);
            wreg(8'h01, 32'h1fffff);
            wreg(8'h03, 1000);          // samples after the trigger sample
            send(8'h05);
            wait_done(400);
            read_capture();
            tw = trig_word();
            check(status[1] && !status[3], "rle: status");
            check(((status >> 8) & 63) == 32, "rle: last word fill");
            check((words[tw] & 'hff) == 'h80, "rle: trigger word value");
            after = 0;
            bad = 0;
            for (int unsigned i = 0; i < count; i++) begin
                int unsigned val = words[i] & WMASK;
                int unsigned run = (words[i] >> W) + 1;
                if (i >= tw) after += run;
                if (i > 0 && val != (((words[i-1] & WMASK) + 1) & WMASK)) bad++;
                if (i > 0 && i < count - 1 && run != 32) bad++;
            end
            check(bad == 0, "rle: runs");
            check(after == 1001, "rle: samples from the trigger on");
            $display("rle: %0d words, %0d samples from the trigger on", count, after);

            // 6. RLE on a line that never changes: runs of the maximum
            // length, ended by the sample count.
            reset_dev();
            shift = 31;
            #(TCK * 100);
            wreg(8'h04, 1);
            wreg(8'h01, 32'h1fffff);
            wreg(8'h03, (W == 16) ? 200000 : 3000);
            send(8'h05);
            wait_done(400);
            read_capture();
            total = 0;
            for (int unsigned i = 0; i < count; i++) total += (words[i] >> W) + 1;
            check(total == ((W == 16) ? 200001 : 3001), "rle idle: sample count");
            $display("rle idle: %0d words, %0d samples", count, total);

            // 7. RLE on a line that changes every sample at full rate needs
            // a word per clock, which the memory can not take: overflow.
            reset_dev();
            shift = 0;
            #(TCK * 100);
            wreg(8'h04, 1);
            wreg(8'h01, 32'h1fffff);
            send(8'h05);
            wait_done(400);
            check(status[3], "rle overflow: not reported");
            $display("rle overflow: reported after %0d words", count);
        end

        // 8. The ring: trigger late enough that the memory has wrapped.
        begin
            int unsigned first, a;
            reset_dev();
            wreg(8'h04, (P > 1) ? 32'h6 : 32'h4);      // test pattern
            wreg(8'h06, 1);
            wreg(8'h10, WMASK);
            wreg(8'h11, 32'h34);
            wreg(8'h07, (W == 16) ? 70 : (W == 14) ? 300 : 33000);
            wreg(8'h01, 1000);
            send(8'h05);
            wait_done(40000);
            check(status[1] && !status[3], "ring: status");
            check(count == MEM, "ring: count should saturate");
            a = (stop_a + MEM - 3000) % MEM;
            rmem(a, 3000);
            first = 0;
            for (int unsigned i = 1; i < nsamp(); i++)
                if (samp(i) != ((samp(i-1) + 1) & WMASK)) begin first = i; break; end
            check(first == 0, "ring: samples before the stop");
            v = ((trig & 'h1fffff) + MEM - a) % MEM;        // trigger word
            check(3000 - 1 - v == 1000, "ring: post-trigger words");
            v = (32 * v + first_start(a + v) - off0) / W + ((trig >> 24) & 3);
            check(samp(v) == 'h34, "ring: trigger sample");
            // Across the end of the memory.
            rmem(MEM - 8, 16);
            first = 0;
            for (int unsigned i = 1; i < nsamp(); i++)
                if (samp(i) != ((samp(i-1) + 1) & WMASK)) begin first = i; break; end
            check(first == 0 || stop_a < 8 || stop_a > MEM - 8, "ring: wrap");
            $display("ring: %0d words long, stop at %0d, trigger at %0d, %0d refreshes",
                     MEM, stop_a, trig & 'h1fffff, ram.refreshes);
        end

        check(ram.errors == 0, "SDRAM protocol errors");
        if (fails == 0) $display("PASS W=%0d P=%0d RLE=%0d", W, P, RLE);
        else $display("FAILED W=%0d P=%0d RLE=%0d: %0d", W, P, RLE, fails);
        $finish;
    end
endmodule
