// Host side: the UART, the command parser, the configuration registers and
// the memory readout. The protocol is in docs/PROTOCOL.md.
//
// All of this runs on a fixed clock of its own, not on the capture clock,
// so the link to the host stays up while the capture PLL changes frequency. oxla_core
// carries what crosses between the two clocks.

//   The parser. Every command is one opcode byte and a fixed number of
//   argument bytes; answers go out through the same shift register, low byte
//   first:
//
//                     opcode with no arguments
//              +------------------------------------+
//              |                                    v
//          +--------+  WREG/RREG/RMEM  +--------+  last  +--------+
//   rx --->| S_IDLE |----------------->| S_ARGS |------->| S_EXEC |
//          +--------+                  +--------+  byte  +---+----+
//            ^  ^  ^                                         |
//            |  |  +-----------------------------------------+ RESET, WREG,
//            |  |          nothing to send                   | ARM, STOP
//            |  |                                            |
//            |  |    tx_n == 0                    ID, RREG   v
//            |  +--------------------------------------- +--------+
//            |                                           |  S_TX  |
//            |   mem_n == 0 or a byte arrived            +--------+
//          +-------+ <--------------------------------------+  ^
//          | S_MEM |             tx_n == 0, in a readout       |
//          +---+---+                                           |
//              | rd_req                                        |
//              v                                               |
//          +-----------+  rd_ack: 4 bytes to send              |
//          | S_MEMWAIT |---------------------------------------+
//          +-----------+
//
//   Argument bytes shift into the top of `args` and move down, so after the
//   last one the first byte sent is the lowest:
//
//                 47      40 39    32 31    24 23    16 15     8 7      0
//                +----------+--------+--------+--------+--------+--------+
//   WREG (5)     |          value, 32 bits             |  addr  |  old   |
//                +----------+--------+--------+--------+--------+--------+
//   RREG (1)     |   addr   |                    old                     |
//                +----------+--------+--------+--------+--------+--------+
//   RMEM (6)     |     word count, 24 bits    |   word address, 24 bits  |
//                +----------+--------+--------+--------+--------+--------+

`default_nettype none

module oxla_host #(
    parameter CLK_HZ = 108000000,   // this module's clock
    parameter BAUD   = 3000000,
    parameter HOLD_BITS = 17,       // capture side held in reset for 2^HOLD_BITS clocks
    parameter W      = 16,
    parameter P      = 1,
    parameter RLE    = 0,
    parameter ADC    = 0,
    parameter MEM_WORDS = 1 << 21
) (
    input  wire         clk,
    input  wire         rst,
    input  wire         rxd,
    output wire         txd,
    // The capture clock: 0 = 81, 1 = 108, 2 = 135 MHz. Not reset by the
    // RESET command. clk_hold is high for a few milliseconds after a change,
    // while the PLL settles.
    output reg  [1:0]   clksel,
    output wire         clk_hold,

    output reg  [23:0]  cfg_div,
    output reg  [21:0]  cfg_post_words,
    output reg  [21:0]  cfg_pre_words,
    output reg  [31:0]  cfg_post_samples,
    output reg          cfg_rle,
    output reg          cfg_ddr,
    output reg          cfg_test,
    output reg  [W-1:0] cfg_chmask,
    output reg  [2:0]   cfg_tmode,
    output reg  [15:0]  cfg_tcount,
    output reg  [W-1:0] cfg_a_mask, cfg_a_val, cfg_a_rise, cfg_a_fall, cfg_a_edge,
    output reg  [W-1:0] cfg_b_mask, cfg_b_val, cfg_b_rise, cfg_b_fall, cfg_b_edge,

    output reg          arm,            // pulses
    output reg          stop,
    output reg          soft_rst,

    input  wire [31:0]  st_status,
    input  wire [31:0]  st_trig,
    input  wire [31:0]  st_stop,
    input  wire [31:0]  st_count,

    output reg          rd_req,
    output reg  [20:0]  rd_addr,
    input  wire [31:0]  rd_data,
    input  wire         rd_ack          // level: rd_data is the word; falls after rd_req
);
    localparam [7:0] PROTO_VERSION = 8'd1;

    localparam [7:0] OP_NOP = 8'h00, OP_RESET = 8'h01, OP_ID = 8'h02,
                     OP_WREG = 8'h03, OP_RREG = 8'h04, OP_ARM = 8'h05,
                     OP_STOP = 8'h06, OP_RMEM = 8'h07;

    // Bit 3: the clock can be changed (register 08).
    wire [7:0] caps = {4'd0, 1'b1, ADC != 0, P > 1, RLE != 0};
    wire [7:0] w8 = W;
    wire [7:0] p8 = P;

    // Sent low byte first: "OXLA", version, caps, channels, samples per
    // clock, clock in Hz, length of the memory ring in words.
    wire [31:0] mem_words = MEM_WORDS;
    wire [31:0] clk_hz = (clksel == 2'd0) ? 32'd81000000 :
                         (clksel == 2'd2) ? 32'd135000000 : 32'd108000000;
    localparam [63:0] INC64 = (64'd1 << 24) * BAUD / CLK_HZ;
    wire [24:0] uart_inc = INC64[24:0];

    reg [HOLD_BITS-1:0] hold_cnt;
    assign clk_hold = (hold_cnt != 0);

    wire [127:0] id = {mem_words, clk_hz, p8, w8, caps, PROTO_VERSION,
                       "A", "L", "X", "O"};

    wire [7:0] rx_data;
    wire       rx_valid;
    reg  [7:0] tx_data;
    reg        tx_start;
    wire       tx_busy;

    oxla_uart_rx u_rx (
        .clk(clk), .rst(rst), .inc(uart_inc), .rxd(rxd), .data(rx_data), .valid(rx_valid));
    oxla_uart_tx u_tx (
        .clk(clk), .rst(rst), .inc(uart_inc), .data(tx_data), .start(tx_start),
        .busy(tx_busy), .txd(txd));

    localparam [2:0] S_IDLE = 0, S_ARGS = 1, S_EXEC = 2, S_TX = 3, S_MEM = 4,
                     S_MEMWAIT = 5;

    reg [2:0]   state;
    reg [7:0]   op;
    reg [2:0]   nargs;
    reg [47:0]  args;           // bytes shift in at the top
    reg [127:0] tx_sr;
    reg [4:0]   tx_n;
    reg         in_mem;         // S_TX returns to S_MEM
    reg         rx_seen;        // a byte arrived during a readout: abort it
    reg [21:0]  mem_n;

    // WREG: address in args[15:8], value in args[47:16].
    wire [7:0]  w_addr = args[15:8];
    wire [31:0] w_val  = args[47:16];
    // RREG: address in args[47:40].
    wire [7:0]  r_addr = args[47:40];

    reg [31:0] r_val;
    always @* begin
        case (r_addr)
            8'h80:   r_val = st_status;
            8'h81:   r_val = st_trig;
            8'h82:   r_val = st_stop;
            8'h83:   r_val = st_count;
            default: r_val = 32'd0;
        endcase
    end

    task defaults;
        begin
            cfg_div <= 24'd0;
            cfg_post_words <= 22'd0;
            cfg_pre_words <= 22'd0;
            cfg_post_samples <= 32'hffffffff;
            cfg_rle <= 1'b0;
            cfg_ddr <= 1'b0;
            cfg_test <= 1'b0;
            cfg_chmask <= {W{1'b1}};
            cfg_tmode <= 3'd0;
            cfg_tcount <= 16'd0;
            cfg_a_mask <= 0; cfg_a_val <= 0; cfg_a_rise <= 0; cfg_a_fall <= 0; cfg_a_edge <= 0;
            cfg_b_mask <= 0; cfg_b_val <= 0; cfg_b_rise <= 0; cfg_b_fall <= 0; cfg_b_edge <= 0;
        end
    endtask

    always @(posedge clk) begin
        arm <= 1'b0;
        stop <= 1'b0;
        soft_rst <= 1'b0;
        tx_start <= 1'b0;
        if (hold_cnt != 0)
            hold_cnt <= hold_cnt - 1'b1;
        if (rx_valid)
            rx_seen <= 1'b1;

        if (rst) begin
            state <= S_IDLE;
            rd_req <= 1'b0;
            clksel <= 2'd1;
            hold_cnt <= {HOLD_BITS{1'b1}};
            in_mem <= 1'b0;
            tx_n <= 5'd0;
            defaults;
        end else case (state)
            S_IDLE: if (rx_valid) begin
                op <= rx_data;
                case (rx_data)
                    OP_NOP:  ;
                    OP_WREG: begin nargs <= 3'd5; state <= S_ARGS; end
                    OP_RREG: begin nargs <= 3'd1; state <= S_ARGS; end
                    OP_RMEM: begin nargs <= 3'd6; state <= S_ARGS; end
                    default: state <= S_EXEC;
                endcase
            end

            S_ARGS: if (rx_valid) begin
                args <= {rx_data, args[47:8]};
                nargs <= nargs - 1'b1;
                if (nargs == 3'd1)
                    state <= S_EXEC;
            end

            S_EXEC: begin
                state <= S_IDLE;
                case (op)
                    OP_RESET: begin
                        soft_rst <= 1'b1;
                        defaults;
                    end
                    OP_ID: begin
                        tx_sr <= id;
                        tx_n <= 5'd16;
                        in_mem <= 1'b0;
                        state <= S_TX;
                    end
                    OP_WREG: case (w_addr)
                        8'h00: cfg_div <= w_val[23:0];
                        8'h01: cfg_post_words <= w_val[21:0];
                        8'h02: cfg_pre_words <= w_val[21:0];
                        8'h03: cfg_post_samples <= w_val;
                        8'h04: {cfg_test, cfg_ddr, cfg_rle} <= w_val[2:0];
                        8'h05: cfg_chmask <= w_val[W-1:0];
                        8'h06: cfg_tmode <= w_val[2:0];
                        8'h07: cfg_tcount <= w_val[15:0];
                        // The PLL follows clksel directly; the capture
                        // side stays in reset until it has settled.
                        8'h08: begin
                            clksel <= (w_val[1:0] == 2'd3) ? 2'd1 : w_val[1:0];
                            hold_cnt <= {HOLD_BITS{1'b1}};
                        end
                        8'h10: cfg_a_mask <= w_val[W-1:0];
                        8'h11: cfg_a_val <= w_val[W-1:0];
                        8'h12: cfg_a_rise <= w_val[W-1:0];
                        8'h13: cfg_a_fall <= w_val[W-1:0];
                        8'h14: cfg_a_edge <= w_val[W-1:0];
                        8'h18: cfg_b_mask <= w_val[W-1:0];
                        8'h19: cfg_b_val <= w_val[W-1:0];
                        8'h1a: cfg_b_rise <= w_val[W-1:0];
                        8'h1b: cfg_b_fall <= w_val[W-1:0];
                        8'h1c: cfg_b_edge <= w_val[W-1:0];
                        default: ;
                    endcase
                    OP_RREG: begin
                        tx_sr[31:0] <= r_val;
                        tx_n <= 5'd4;
                        in_mem <= 1'b0;
                        state <= S_TX;
                    end
                    OP_ARM:  arm <= 1'b1;
                    OP_STOP: stop <= 1'b1;
                    OP_RMEM: begin
                        // Address in args[20:0], word count in args[45:24].
                        rd_addr <= args[20:0];
                        mem_n <= args[45:24];
                        rx_seen <= 1'b0;
                        state <= S_MEM;
                    end
                    default: ;
                endcase
            end

            S_TX: begin
                if (tx_n == 5'd0)
                    state <= in_mem ? S_MEM : S_IDLE;
                else if (!tx_busy && !tx_start) begin
                    tx_data <= tx_sr[7:0];
                    tx_start <= 1'b1;
                    tx_sr <= {8'd0, tx_sr[127:8]};
                    tx_n <= tx_n - 1'b1;
                end
            end

            S_MEM: begin
                in_mem <= 1'b0;
                if (rx_seen || mem_n == 22'd0)
                    state <= S_IDLE;
                else if (!rd_ack) begin         // the last read has let go
                    rd_req <= 1'b1;
                    state <= S_MEMWAIT;
                end
            end

            S_MEMWAIT: if (rd_ack) begin
                rd_req <= 1'b0;
                tx_sr[31:0] <= rd_data;
                tx_n <= 5'd4;
                in_mem <= 1'b1;
                rd_addr <= (rd_addr == MEM_WORDS - 1) ? 21'd0 : rd_addr + 1'b1;
                mem_n <= mem_n - 1'b1;
                state <= S_TX;
            end

            default: state <= S_IDLE;
        endcase
    end
endmodule

`default_nettype wire
