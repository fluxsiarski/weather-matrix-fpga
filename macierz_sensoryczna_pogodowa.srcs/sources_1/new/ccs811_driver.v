// ccs811_driver.v
// Sterownik CCS811 (Pmod AQS): sekwencja boot → weryfikacja FW_MODE → APP_START
// → konfiguracja trybu pomiaru → cykliczny odczyt eCO2 i TVOC co 1 s.
// APP_START ponawiany do 5 razy jeśli sensor nie potwierdzi uruchomienia aplikacji.

module ccs811_driver #(
    parameter integer SYS_CLK_HZ = 125_000_000
)(
    input  wire        clk,
    input  wire        rst_n,
    input  wire        enable,

    output reg  [6:0]  i2c_dev_addr,
    output reg  [1:0]  i2c_mode,
    output reg  [3:0]  i2c_wr_len,
    output reg  [3:0]  i2c_rd_len,
    output reg         i2c_start,
    output reg  [7:0]  i2c_wr0, i2c_wr1, i2c_wr2, i2c_wr3,
    input  wire [7:0]  i2c_rd0, i2c_rd1, i2c_rd2, i2c_rd3,
    input  wire [7:0]  i2c_rd4, i2c_rd5, i2c_rd6, i2c_rd7,
    input  wire        i2c_busy,
    input  wire        i2c_done,
    input  wire        i2c_ack_error,

    output reg         aqs_wake_n,    // aktywny niski: 0 = sensor aktywny

    output reg [15:0] eco2_ppm,       // ekwiwalentne CO2 w ppm
    output reg [15:0] tvoc_ppb,       // TVOC w ppb
    output reg        data_valid,

    output reg [7:0]  dbg_status,     // ostatni odczytany rejestr STATUS (0x00)
    output reg [7:0]  dbg_raw0,       // HW_ID z rejestru 0x20 (oczekiwane: 0x81)
    output reg [7:0]  dbg_raw1        // bajt eco2_hi z ostatniego ALG_RESULT
);

    localparam [6:0] CCS811_ADDR = 7'h5B;
    localparam [1:0] MODE_WRITE  = 2'd0;
    localparam [1:0] MODE_READ   = 2'd1;

    localparam integer BOOT_WAIT  = SYS_CLK_HZ / 10;   // 100 ms - czas boot CCS811
    localparam integer APP_WAIT   = SYS_CLK_HZ / 10;   // 100 ms - czas po APP_START
    localparam integer CYCLE_WAIT = SYS_CLK_HZ;        // 1 s   - interwał pomiarowy

    localparam [4:0]
        S_IDLE         = 5'd0,
        S_WAKE         = 5'd1,   // odczekaj 100 ms po aktywacji WAKE
        S_RD_HWID      = 5'd20,  // odczyt HW_ID (0x20); weryfikacja obecności sensora
        S_RD_HWID_W    = 5'd21,
        S_RD_ST1       = 5'd2,   // odczyt STATUS przed APP_START
        S_RD_ST1_W     = 5'd3,
        S_CHK1         = 5'd4,   // sprawdź bit7 (FW_MODE); jeśli 1 → pomiń APP_START
        S_APP          = 5'd5,   // WRITE 0xF4 - komenda APP_START
        S_APP_W        = 5'd6,
        S_APP_DELAY    = 5'd7,   // odczekaj 100 ms na uruchomienie aplikacji
        S_RD_ST2       = 5'd8,   // odczyt STATUS po APP_START
        S_RD_ST2_W     = 5'd9,
        S_CHK2         = 5'd10,  // weryfikacja FW_MODE; retry do 5 razy
        S_MEAS         = 5'd11,  // WRITE 0x01 = 0x10 - tryb pomiaru co 1 s
        S_MEAS_W       = 5'd12,
        S_RD_STAT      = 5'd13,  // pętla: odczyt STATUS
        S_RD_STAT_W    = 5'd14,
        S_CHECK        = 5'd15,  // sprawdź bit3 DATA_READY
        S_RD_DATA      = 5'd16,  // READ ALG_RESULT_DATA (0x02), 4 bajty
        S_RD_DATA_W    = 5'd17,
        S_PROCESS      = 5'd18,  // przepisz eco2 i tvoc z bufora I2C
        S_CYCLE_WAIT   = 5'd19;  // odczekaj przed kolejnym odczytem STATUS

    reg [4:0]  state;
    reg [27:0] delay;
    reg [7:0]  status_byte;
    reg [2:0]  app_retries;

    always @(posedge clk) begin
        if (!rst_n) begin
            state        <= S_IDLE;
            delay        <= 0;
            i2c_dev_addr <= CCS811_ADDR;
            i2c_mode     <= MODE_WRITE;
            i2c_wr_len   <= 4'd1;
            i2c_rd_len   <= 4'd1;
            i2c_start    <= 1'b0;
            i2c_wr0      <= 8'h00;
            i2c_wr1      <= 8'h00;
            i2c_wr2      <= 8'h00;
            i2c_wr3      <= 8'h00;
            aqs_wake_n   <= 1'b1;
            eco2_ppm     <= 16'd0;
            tvoc_ppb     <= 16'd0;
            data_valid   <= 1'b0;
            status_byte  <= 8'h00;
            dbg_status   <= 8'hAA;
            dbg_raw0     <= 8'hAA;
            dbg_raw1     <= 8'hAA;
            app_retries  <= 3'd0;
        end else begin
            i2c_start <= 1'b0;

            case (state)
                S_IDLE: begin
                    if (enable) begin
                        aqs_wake_n  <= 1'b0;   // aktywuj sensor
                        delay       <= BOOT_WAIT;
                        app_retries <= 3'd0;
                        state       <= S_WAKE;
                    end else begin
                        aqs_wake_n <= 1'b1;    // usypiaj gdy nieaktywny
                    end
                end

                S_WAKE: begin
                    if (delay == 0) state <= S_RD_HWID;
                    else delay <= delay - 1'b1;
                end

                // Weryfikacja obecności sensora: HW_ID = 0x81 dla CCS811
                S_RD_HWID: begin
                    if (!i2c_busy) begin
                        i2c_dev_addr <= CCS811_ADDR;
                        i2c_mode     <= MODE_READ;
                        i2c_wr_len   <= 4'd1;
                        i2c_wr0      <= 8'h20;   // rejestr HW_ID
                        i2c_rd_len   <= 4'd1;
                        i2c_start    <= 1'b1;
                        state        <= S_RD_HWID_W;
                    end
                end

                S_RD_HWID_W: begin
                    if (i2c_done) begin
                        dbg_raw0 <= i2c_rd0;   // zachowaj HW_ID do diagnostyki
                        state    <= S_RD_ST1;
                    end
                end

                // Odczyt STATUS przed APP_START
                S_RD_ST1: begin
                    if (!i2c_busy) begin
                        i2c_dev_addr <= CCS811_ADDR;
                        i2c_mode     <= MODE_READ;
                        i2c_wr_len   <= 4'd1;
                        i2c_wr0      <= 8'h00;   // rejestr STATUS
                        i2c_rd_len   <= 4'd1;
                        i2c_start    <= 1'b1;
                        state        <= S_RD_ST1_W;
                    end
                end

                S_RD_ST1_W: begin
                    if (i2c_done) begin
                        status_byte <= i2c_rd0;
                        dbg_status  <= i2c_rd0;
                        state       <= S_CHK1;
                    end
                end

                // bit7=1: aplikacja już działa → przejdź do konfiguracji trybu
                // bit7=0: bootloader → wyślij APP_START
                S_CHK1: begin
                    if (status_byte[7])
                        state <= S_MEAS;
                    else
                        state <= S_APP;
                end

                // APP_START: zapis komendy 0xF4 bez danych (wr_len=1)
                S_APP: begin
                    if (!i2c_busy) begin
                        i2c_dev_addr <= CCS811_ADDR;
                        i2c_mode     <= MODE_WRITE;
                        i2c_wr_len   <= 4'd1;
                        i2c_wr0      <= 8'hF4;
                        i2c_start    <= 1'b1;
                        state        <= S_APP_W;
                    end
                end

                S_APP_W: begin
                    if (i2c_done) begin
                        delay <= APP_WAIT;
                        state <= S_APP_DELAY;
                    end
                end

                S_APP_DELAY: begin
                    if (delay == 0) state <= S_RD_ST2;
                    else delay <= delay - 1'b1;
                end

                // Weryfikacja STATUS po APP_START
                S_RD_ST2: begin
                    if (!i2c_busy) begin
                        i2c_dev_addr <= CCS811_ADDR;
                        i2c_mode     <= MODE_READ;
                        i2c_wr_len   <= 4'd1;
                        i2c_wr0      <= 8'h00;
                        i2c_rd_len   <= 4'd1;
                        i2c_start    <= 1'b1;
                        state        <= S_RD_ST2_W;
                    end
                end

                S_RD_ST2_W: begin
                    if (i2c_done) begin
                        status_byte <= i2c_rd0;
                        dbg_status  <= i2c_rd0;
                        state       <= S_CHK2;
                    end
                end

                // bit7=1: sukces; bit7=0: retry do 5 razy, potem kontynuuj mimo błędu
                S_CHK2: begin
                    if (status_byte[7]) begin
                        state <= S_MEAS;
                    end else if (app_retries < 3'd5) begin
                        app_retries <= app_retries + 1'b1;
                        state       <= S_APP;
                    end else begin
                        state <= S_MEAS;   // dbg_status = 0x00/0x10 wskaże problem
                    end
                end

                // Konfiguracja trybu pomiaru: WRITE 0x01 = 0x10 (Mode 1, co 1 s)
                S_MEAS: begin
                    if (!i2c_busy) begin
                        i2c_dev_addr <= CCS811_ADDR;
                        i2c_mode     <= MODE_WRITE;
                        i2c_wr_len   <= 4'd2;
                        i2c_wr0      <= 8'h01;   // rejestr MEAS_MODE
                        i2c_wr1      <= 8'h10;   // Mode 1: co 1 s
                        i2c_start    <= 1'b1;
                        state        <= S_MEAS_W;
                    end
                end

                S_MEAS_W: begin
                    if (i2c_done) begin
                        delay <= CYCLE_WAIT;
                        state <= S_CYCLE_WAIT;
                    end
                end

                // Pętla główna: odczyt STATUS co 1 s
                S_RD_STAT: begin
                    if (!i2c_busy) begin
                        i2c_dev_addr <= CCS811_ADDR;
                        i2c_mode     <= MODE_READ;
                        i2c_wr_len   <= 4'd1;
                        i2c_wr0      <= 8'h00;
                        i2c_rd_len   <= 4'd1;
                        i2c_start    <= 1'b1;
                        state        <= S_RD_STAT_W;
                    end
                end

                S_RD_STAT_W: begin
                    if (i2c_done) begin
                        status_byte <= i2c_rd0;
                        dbg_status  <= i2c_rd0;
                        state       <= S_CHECK;
                    end
                end

                // bit3 DATA_READY=1 → czytaj wyniki; 0 → czekaj kolejny cykl
                S_CHECK: begin
                    if (status_byte[3])
                        state <= S_RD_DATA;
                    else begin
                        delay <= CYCLE_WAIT;
                        state <= S_CYCLE_WAIT;
                    end
                end

                // Odczyt ALG_RESULT_DATA: 4 bajty od rejestru 0x02
                // Kolejność: eco2_hi, eco2_lo, tvoc_hi, tvoc_lo
                S_RD_DATA: begin
                    if (!i2c_busy) begin
                        i2c_dev_addr <= CCS811_ADDR;
                        i2c_mode     <= MODE_READ;
                        i2c_wr_len   <= 4'd1;
                        i2c_wr0      <= 8'h02;   // rejestr ALG_RESULT_DATA
                        i2c_rd_len   <= 4'd4;
                        i2c_start    <= 1'b1;
                        state        <= S_RD_DATA_W;
                    end
                end

                S_RD_DATA_W: begin
                    if (i2c_done) begin
                        dbg_raw1 <= i2c_rd0;   // eco2_hi do diagnostyki
                        state    <= S_PROCESS;
                    end
                end

                // Złożenie 16-bitowych wyników z par bajtów
                S_PROCESS: begin
                    eco2_ppm   <= {i2c_rd0, i2c_rd1};
                    tvoc_ppb   <= {i2c_rd2, i2c_rd3};
                    data_valid <= ~data_valid;
                    delay      <= CYCLE_WAIT;
                    state      <= S_CYCLE_WAIT;
                end

                S_CYCLE_WAIT: begin
                    if (!enable) state <= S_IDLE;
                    else if (delay == 0) state <= S_RD_STAT;
                    else delay <= delay - 1'b1;
                end

                default: state <= S_IDLE;
            endcase
        end
    end

endmodule