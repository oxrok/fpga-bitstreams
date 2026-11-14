// Behavioural model of a 4 x 2048 x 256 x 32 bit SDR SDRAM, enough to check
// the controller: it decodes commands, stores data, drives read data with the
// programmed CAS latency for one clock per READ, and complains about the
// timing rules the controller could break. Not a vendor model.

`timescale 1ns/1ps

module sdram_model #(
    parameter real TCK_NS = 9.26
) (
    input  wire        clk,
    input  wire        cke,
    input  wire        cs_n,
    input  wire        ras_n,
    input  wire        cas_n,
    input  wire        we_n,
    input  wire [10:0] addr,
    input  wire [1:0]  ba,
    input  wire [3:0]  dqm,
    // The data bus, split so simulators without delayed tristates can run it.
    input  wire [31:0] dq_i,
    input  wire        dq_i_valid,      // the controller is driving
    output reg  [31:0] dq_o,
    output reg         dq_o_valid
);
    reg [31:0] mem [0:(1<<21)-1];

    reg        row_open [0:3];
    reg [10:0] row [0:3];
    real       t_act [0:3];
    real       t_pre, t_ref, t_mrs, t_wr;
    reg        mode_set;
    reg [2:0]  cl;
    integer    errors;
    integer    refreshes;

    // Read pipeline: data for a READ registered at edge e is driven from
    // e + (cl-1) clocks + tAC until e + cl clocks + tOH.
    reg [31:0] rd_pipe [0:3];
    reg [3:0]  rd_vld;
    localparam real TAC_NS = 5.4;

    wire [2:0] cmd = {ras_n, cas_n, we_n};
    integer i;

    initial begin
        for (i = 0; i < 4; i = i + 1) begin row_open[i] = 0; t_act[i] = -1000; end
        t_pre = -1000; t_ref = -1000; t_mrs = -1000; t_wr = -1000;
        mode_set = 0; cl = 3; errors = 0; refreshes = 0;
        rd_vld = 0; dq_o_valid = 0;
    end

    task err;
        input [255:0] msg;
        begin
            errors = errors + 1;
            $display("SDRAM ERROR at %0t: %0s", $time, msg);
        end
    endtask

    always @(posedge clk) if (cke) begin
        // Output stage.
        dq_o_valid <= #(TAC_NS) (cl == 3) ? rd_vld[1] : rd_vld[0];
        dq_o <= #(TAC_NS) (cl == 3) ? rd_pipe[1] : rd_pipe[0];
        rd_vld <= {rd_vld[2:0], 1'b0};
        rd_pipe[3] <= rd_pipe[2]; rd_pipe[2] <= rd_pipe[1]; rd_pipe[1] <= rd_pipe[0];

        if (!cs_n) case (cmd)
            3'b111: ;
            3'b011: begin // ACT
                if (row_open[ba]) err("ACT on an open bank");
                if ($realtime - t_pre < 15.0) err("tRP");
                if ($realtime - t_ref < 60.0) err("tRFC before ACT");
                if (!mode_set) err("ACT before MRS");
                row_open[ba] = 1; row[ba] = addr; t_act[ba] = $realtime;
            end
            3'b101: begin // READ
                if (!row_open[ba]) err("READ on a closed bank");
                if ($realtime - t_act[ba] < 15.0) err("tRCD read");
                rd_pipe[0] <= mem[{ba, row[ba], addr[7:0]}];
                rd_vld[0] <= 1'b1;
            end
            3'b100: begin // WRITE
                if (!row_open[ba]) err("WRITE on a closed bank");
                if ($realtime - t_act[ba] < 15.0) err("tRCD write");
                if (!dq_i_valid) err("WRITE with DQ floating");
                if (dq_o_valid) err("WRITE while the SDRAM drives DQ");
                if (dqm != 4'b0) err("WRITE with DQM set");
                mem[{ba, row[ba], addr[7:0]}] = dq_i;
                t_wr = $realtime;
            end
            3'b010: begin // PRE
                if ($realtime - t_wr < 2 * TCK_NS - 0.1) err("tWR");
                for (i = 0; i < 4; i = i + 1)
                    if (addr[10] || ba == i) begin
                        if (row_open[i] && $realtime - t_act[i] < 42.0) err("tRAS min");
                        row_open[i] = 0;
                    end
                t_pre = $realtime;
            end
            3'b001: begin // REF
                if (row_open[0] || row_open[1] || row_open[2] || row_open[3])
                    err("REF with a bank open");
                if ($realtime - t_pre < 15.0) err("tRP before REF");
                if ($realtime - t_ref < 60.0) err("tRFC");
                t_ref = $realtime;
                refreshes = refreshes + 1;
            end
            3'b000: begin // MRS
                if (addr[2:0] != 3'b000) err("burst length is not 1");
                cl = addr[6:4];
                mode_set = 1;
                t_mrs = $realtime;
            end
            default: err("unknown command");
        endcase
    end

    // A row may not stay open longer than tRAS max.
    always @(posedge clk)
        for (i = 0; i < 4; i = i + 1)
            if (row_open[i] && $realtime - t_act[i] > 100000.0) begin
                err("tRAS max");
                t_act[i] = $realtime;
            end
endmodule
