// Synchronous first-word-fall-through FIFO on block RAM.
//
// The RAM is read at the next read pointer, so its output always shows the
// word at the head, and a register after it holds the word the consumer
// sees. A pop every clock works. A word written into an empty FIFO shows up
// three clocks later.
//
// The register is there for timing: without it the consumer's logic hangs
// off the block RAM's output, and at 135 MHz four of seven placements of
// the 16 channel build then miscounted on the board while nextpnr's timing
// report passed. With it, sixteen of sixteen work.

//                     +----------------------+
//    din  ----------->|  block RAM           | ram_dout  +-------+
//    push ----------->|  2^AW words          |---------->| dout  |----> dout
//                     |                      |  ram_pop  | (reg) |----> valid
//    wr_ptr --------->| write address        |---------->|  CE   |
//    rd_next -------->| read address         |           +-------+
//                     +----------------------+               ^
//                                                            | pop
//       rd_next = ram_pop ? rd_ptr + 1   (the RAM always reads the word that
//                         : rd_ptr            will be at its head next clock)
//       ram_pop = ram_valid and
//                 (not valid or pop)
//
//   pop comes late in the clock (it is the SDRAM controller's decision to
//   write), so nothing is computed from it: rd_ptr + 1 is kept in a register
//   of its own, and pop only chooses between two registers.
//
//   A word going through an empty FIFO, clock by clock:
//
//     1   push is high; at the end of the clock the RAM is written
//     2   the RAM is read at that address
//     3   ram_valid: ram_dout is the word; it moves into dout
//     4   valid: the consumer sees the word and can pop it

`default_nettype none

module oxla_fifo #(
    parameter WIDTH = 36,
    parameter AW    = 9
) (
    input  wire             clk,
    input  wire             clr,
    input  wire             push,
    input  wire [WIDTH-1:0] din,
    output wire             full,
    input  wire             pop,        // ignored unless valid
    output reg              valid,
    output reg  [WIDTH-1:0] dout
);
    reg [WIDTH-1:0] mem [0:(1<<AW)-1];
    reg [WIDTH-1:0] ram_dout;
    reg             ram_valid;
    reg [AW:0]      wr_ptr, rd_ptr, rd_ptr1;    // rd_ptr1 is rd_ptr + 1

    // The RAM's head moves into the output register when that is empty or
    // being emptied.
    wire        ram_pop = ram_valid && (!valid || pop);
    wire [AW:0] rd_next = ram_pop ? rd_ptr1 : rd_ptr;
    wire        more0 = (rd_ptr != wr_ptr);     // a word at rd_ptr
    wire        more1 = (rd_ptr1 != wr_ptr);    // a word after it

    assign full = (wr_ptr[AW] != rd_ptr[AW]) && (wr_ptr[AW-1:0] == rd_ptr[AW-1:0]);

    always @(posedge clk) begin
        if (push && !full)
            mem[wr_ptr[AW-1:0]] <= din;
        ram_dout <= mem[rd_next[AW-1:0]];
    end

    always @(posedge clk) begin
        if (ram_pop)
            dout <= ram_dout;

        if (clr) begin
            wr_ptr <= 0;
            rd_ptr <= 0;
            rd_ptr1 <= 1;
            ram_valid <= 1'b0;
            valid <= 1'b0;
        end else begin
            if (push && !full)
                wr_ptr <= wr_ptr + 1'b1;
            if (ram_pop) begin
                rd_ptr <= rd_ptr1;
                rd_ptr1 <= rd_ptr1 + 1'b1;
            end
            // wr_ptr here is the pointer before this clock's push, so the
            // word at rd_next was written at least one clock ago.
            ram_valid <= ram_pop ? more1 : more0;
            if (ram_pop)
                valid <= 1'b1;
            else if (pop)
                valid <= 1'b0;
        end
    end
endmodule

`default_nettype wire
