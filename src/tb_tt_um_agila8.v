`default_nettype none
`timescale 1ns/1ps

module tb_tt_um_agila8;

    reg clk = 0;
    reg rst_n = 0;
    always #(1000.0/64.0/2.0) clk = ~clk;  // 64MHz

    reg  [7:0] ui_in  = 8'h00;   // set ui_in[7] BEFORE releasing rst_n
    wire [7:0] uo_out;
    reg  [7:0] uio_in = 8'h00;
    wire [7:0] uio_out;
    wire [7:0] uio_oe;

    tt_um_agila8 dut (
        .ui_in  (ui_in),
        .uo_out (uo_out),
        .uio_in (uio_in),
        .uio_out(uio_out),
        .uio_oe (uio_oe),
        .ena    (1'b1),
        .clk    (clk),
        .rst_n  (rst_n)
    );

    wire flash_cs_n  = uio_out[0];
    wire psram_cs_n  = uio_out[6];   // CS1
    wire genspi_cs_n = uio_out[7];   // CS2
    wire spi_mosi    = uio_out[1];
    wire spi_sck     = uio_out[3];

    // ---------------- Behavioral flash model (03h Read Data only) -------
    reg  flash_miso;
    reg [7:0]  fmem [0:511];
    initial $readmemh("imem.hex", fmem);

    reg [30:0] f_cmd_addr_sh;
    reg [5:0]  f_cnt;
    reg [7:0]  f_data_byte;

    always @(posedge spi_sck or posedge flash_cs_n) begin
        if (flash_cs_n) begin
            f_cnt <= 6'd0;
        end else begin
            if (f_cnt < 6'd32)
                f_cmd_addr_sh <= {f_cmd_addr_sh[29:0], spi_mosi};
            if (f_cnt == 6'd31)
                f_data_byte <= fmem[{f_cmd_addr_sh[7:0], spi_mosi}];
            f_cnt <= f_cnt + 6'd1;
        end
    end

    always @(negedge spi_sck or posedge flash_cs_n) begin
        if (flash_cs_n) begin
            flash_miso <= 1'b0;
        end else if (f_cnt >= 6'd32) begin
            case (f_cnt - 6'd32)
                6'd0: flash_miso <= f_data_byte[7];
                6'd1: flash_miso <= f_data_byte[6];
                6'd2: flash_miso <= f_data_byte[5];
                6'd3: flash_miso <= f_data_byte[4];
                6'd4: flash_miso <= f_data_byte[3];
                6'd5: flash_miso <= f_data_byte[2];
                6'd6: flash_miso <= f_data_byte[1];
                6'd7: flash_miso <= f_data_byte[0];
                default: flash_miso <= 1'b0;
            endcase
        end
    end

    // ---------------- Behavioral PSRAM A model (02h Write / 03h Read) ---
    // On CS1. Used for normal DMEM in default mode; should see NO
    // traffic at all in RAM-B mode (verified below).
    reg [7:0]  pmemA [0:255];
    integer piA;
    initial for (piA = 0; piA < 256; piA = piA + 1) pmemA[piA] = 8'h00;

    reg [5:0]  pA_cnt;
    reg [7:0]  pA_opcode_sh;
    reg [23:0] pA_addr_sh;
    reg [7:0]  pA_wdata_sh;
    reg        psramA_miso;

    always @(posedge spi_sck or posedge psram_cs_n) begin
        if (psram_cs_n) begin
            pA_cnt <= 6'd0;
        end else begin
            if (pA_cnt < 6'd8) begin
                pA_opcode_sh <= {pA_opcode_sh[6:0], spi_mosi};
            end else if (pA_cnt < 6'd32) begin
                pA_addr_sh <= {pA_addr_sh[22:0], spi_mosi};
            end else begin
                pA_wdata_sh <= {pA_wdata_sh[6:0], spi_mosi};
                if (pA_cnt == 6'd39 && pA_opcode_sh == 8'h02)
                    pmemA[pA_addr_sh[7:0]] <= {pA_wdata_sh[6:0], spi_mosi};
            end
            pA_cnt <= pA_cnt + 6'd1;
        end
    end

    always @(negedge spi_sck or posedge psram_cs_n) begin
        if (psram_cs_n) begin
            psramA_miso <= 1'b0;
        end else if (pA_cnt >= 6'd32 && pA_opcode_sh == 8'h03) begin
            case (pA_cnt - 6'd32)
                6'd0: psramA_miso <= pmemA[pA_addr_sh[7:0]][7];
                6'd1: psramA_miso <= pmemA[pA_addr_sh[7:0]][6];
                6'd2: psramA_miso <= pmemA[pA_addr_sh[7:0]][5];
                6'd3: psramA_miso <= pmemA[pA_addr_sh[7:0]][4];
                6'd4: psramA_miso <= pmemA[pA_addr_sh[7:0]][3];
                6'd5: psramA_miso <= pmemA[pA_addr_sh[7:0]][2];
                6'd6: psramA_miso <= pmemA[pA_addr_sh[7:0]][1];
                6'd7: psramA_miso <= pmemA[pA_addr_sh[7:0]][0];
                default: psramA_miso <= 1'b0;
            endcase
        end
    end

`ifdef RAMB_MODE
    // ---------------- RAM-B behavioral model, on CS2 --------------------
    // Physically what's connected when the switch is thrown to "RAM B" -
    // a SEPARATE chip/memory array from RAM A, to genuinely test that
    // RAM-B-mode traffic reaches a different backing store, not just
    // that CS2 toggles.
    reg [7:0]  pmemB [0:255];
    integer piB;
    initial for (piB = 0; piB < 256; piB = piB + 1) pmemB[piB] = 8'hAA; // distinct poison pattern

    reg [5:0]  pB_cnt;
    reg [7:0]  pB_opcode_sh;
    reg [23:0] pB_addr_sh;
    reg [7:0]  pB_wdata_sh;
    reg        psramB_miso;

    always @(posedge spi_sck or posedge genspi_cs_n) begin
        if (genspi_cs_n) begin
            pB_cnt <= 6'd0;
        end else begin
            if (pB_cnt < 6'd8) begin
                pB_opcode_sh <= {pB_opcode_sh[6:0], spi_mosi};
            end else if (pB_cnt < 6'd32) begin
                pB_addr_sh <= {pB_addr_sh[22:0], spi_mosi};
            end else begin
                pB_wdata_sh <= {pB_wdata_sh[6:0], spi_mosi};
                if (pB_cnt == 6'd39 && pB_opcode_sh == 8'h02)
                    pmemB[pB_addr_sh[7:0]] <= {pB_wdata_sh[6:0], spi_mosi};
            end
            pB_cnt <= pB_cnt + 6'd1;
        end
    end

    always @(negedge spi_sck or posedge genspi_cs_n) begin
        if (genspi_cs_n) begin
            psramB_miso <= 1'b0;
        end else if (pB_cnt >= 6'd32 && pB_opcode_sh == 8'h03) begin
            case (pB_cnt - 6'd32)
                6'd0: psramB_miso <= pmemB[pB_addr_sh[7:0]][7];
                6'd1: psramB_miso <= pmemB[pB_addr_sh[7:0]][6];
                6'd2: psramB_miso <= pmemB[pB_addr_sh[7:0]][5];
                6'd3: psramB_miso <= pmemB[pB_addr_sh[7:0]][4];
                6'd4: psramB_miso <= pmemB[pB_addr_sh[7:0]][3];
                6'd5: psramB_miso <= pmemB[pB_addr_sh[7:0]][2];
                6'd6: psramB_miso <= pmemB[pB_addr_sh[7:0]][1];
                6'd7: psramB_miso <= pmemB[pB_addr_sh[7:0]][0];
                default: psramB_miso <= 1'b0;
            endcase
        end
    end

    always @(*) begin
        if (!flash_cs_n)       uio_in[2] = flash_miso;
        else if (!psram_cs_n)  uio_in[2] = psramA_miso;
        else if (!genspi_cs_n) uio_in[2] = psramB_miso;
        else                   uio_in[2] = 1'b0;
    end
`else
    // ---------------- Loopback SPI slave, on CS2 -------------------------
    // Physically what's connected when the switch is thrown to
    // "external device" - default mode.
    wire genspi_miso = (!genspi_cs_n) ? spi_mosi : 1'b0;

    always @(*) begin
        if (!flash_cs_n)       uio_in[2] = flash_miso;
        else if (!psram_cs_n)  uio_in[2] = psramA_miso;
        else if (!genspi_cs_n) uio_in[2] = genspi_miso;
        else                   uio_in[2] = 1'b0;
    end
`endif

    reg [1:0] active_count;
    always @(negedge clk) begin
        if (rst_n) begin
            active_count = 0;
            if (!flash_cs_n)  active_count = active_count + 1;
            if (!psram_cs_n)  active_count = active_count + 1;
            if (!genspi_cs_n) active_count = active_count + 1;
            if (active_count > 1) begin
                $display("BUS CONTENTION at t=%0t: flash_cs_n=%b psram_cs_n=%b genspi_cs_n=%b",
                          $time, flash_cs_n, psram_cs_n, genspi_cs_n);
                $finish;
            end
        end
    end

    integer cycle_count = 0;
    always @(posedge clk) cycle_count = cycle_count + 1;

    initial begin
        rst_n = 0;
`ifdef RAMB_MODE
        ui_in[7] = 1'b1;
`else
        ui_in[7] = 1'b0;
`endif
        repeat (5) @(posedge clk);
        rst_n = 1;

        fork
            begin
                wait (dut.halted == 1);
                $display("HALTED at cycle %0d", cycle_count);
            end
            begin
                repeat (400000) @(posedge clk);
                $display("TIMEOUT: never halted (cycle=%0d)", cycle_count);
            end
        join_any
        disable fork;

        $display("=== FINAL STATE ===");
        $display("halted=%0d pc=0x%04x", dut.halted, dut.core.pc);
        $display("r1=%0d r2=%0d r3=%0d r4=%0d r5=%0d r6=%0d r7=%0d",
                  dut.core.regfile.regs[1], dut.core.regfile.regs[2],
                  dut.core.regfile.regs[3], dut.core.regfile.regs[4],
                  dut.core.regfile.regs[5], dut.core.regfile.regs[6],
                  dut.core.regfile.regs[7]);
        $display("pmemA[20]=%0d", pmemA[20]);
`ifdef RAMB_MODE
        $display("pmemB[20]=%0d", pmemB[20]);
`endif
        $display("uo_out=0x%02x", uo_out);
        $finish;
    end

endmodule
