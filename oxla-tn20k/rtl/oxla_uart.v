// 8N1 UART with a fractional baud generator, so any baud rate works from any
// system clock (CLK_HZ / BAUD need not be an integer; keep it above 8).

//   A frame, and where the receiver looks at the line. It sees the falling
//   edge of the start bit, waits half a bit, and from there samples once per
//   bit time, in the middle of every bit:
//
//         idle    start   d0    d1    d2    d3    d4    d5    d6    d7   stop
//   rxd  ------+       +-----+     +-----------+     +-----+-----+     +------
//              |       |     |     |           |     |           |     |
//              +-------+     +-----+           +-----+           +-----+
//                  ^      ^     ^     ^     ^     ^     ^     ^     ^     ^
//   bitn           0      1     2     3     4     5     6     7     8     9
//                  |      |<------------- data, low bit first ---->|     |
//           must still                                              must be
//           be low                                                  high
//
//   A bit time is CLK_HZ / BAUD clocks, which need not be a whole number.
//   Each clock adds INC = 2^24 * BAUD / CLK_HZ to a 24 bit accumulator, and
//   the carry out of it (acc[24]) is the tick. The ticks are then at most one
//   clock early or late and never drift. At 3 Mbaud from 135 MHz a bit is
//   45 clocks; from 108 MHz, 36; from a 100 MHz clock it would be 33, 33,
//   34, 33, 33, 34 and so on.

`default_nettype none

module oxla_uart_rx #(
    parameter CLK_HZ = 108000000,
    parameter BAUD   = 3000000
) (
    input  wire       clk,
    input  wire       rst,
    input  wire       rxd,
    output reg  [7:0] data,
    output reg        valid
);
    localparam [63:0] INC64 = (64'd1 << 24) * BAUD / CLK_HZ;
    localparam [24:0] INC = INC64[24:0];

    reg [1:0]  sync;
    reg [24:0] acc;         // bit 24 is the carry: one tick per bit time
    reg [3:0]  bitn;
    reg        busy;
    wire       rx = sync[1];

    always @(posedge clk) begin
        sync <= {sync[0], rxd};
        valid <= 1'b0;
        if (rst) begin
            busy <= 1'b0;
        end else if (!busy) begin
            if (!rx) begin
                busy <= 1'b1;
                acc <= 25'h0800000;         // first tick half a bit from here
                bitn <= 4'd0;
            end
        end else begin
            acc <= {1'b0, acc[23:0]} + INC;
            if (acc[24]) begin
                bitn <= bitn + 1'b1;
                if (bitn == 4'd0) begin
                    if (rx) busy <= 1'b0;   // not a start bit after all
                end else if (bitn == 4'd9) begin
                    busy <= 1'b0;
                    valid <= rx;            // stop bit must be high
                end else
                    data <= {rx, data[7:1]};
            end
        end
    end
endmodule

module oxla_uart_tx #(
    parameter CLK_HZ = 108000000,
    parameter BAUD   = 3000000
) (
    input  wire       clk,
    input  wire       rst,
    input  wire [7:0] data,
    input  wire       start,        // ignored while busy
    output reg        busy,
    output reg        txd
);
    localparam [63:0] INC64 = (64'd1 << 24) * BAUD / CLK_HZ;
    localparam [24:0] INC = INC64[24:0];

    reg [24:0] acc;
    reg [8:0]  sr;
    reg [3:0]  n;

    always @(posedge clk) begin
        if (rst) begin
            busy <= 1'b0;
            txd <= 1'b1;
        end else if (!busy) begin
            txd <= 1'b1;
            if (start) begin
                busy <= 1'b1;
                txd <= 1'b0;
                sr <= {1'b1, data};
                n <= 4'd9;
                acc <= 25'd0;
            end
        end else begin
            acc <= {1'b0, acc[23:0]} + INC;
            if (acc[24]) begin
                if (n == 4'd0)
                    busy <= 1'b0;
                else begin
                    txd <= sr[0];
                    sr <= {1'b1, sr[8:1]};
                    n <= n - 1'b1;
                end
            end
        end
    end
endmodule

`default_nettype wire
