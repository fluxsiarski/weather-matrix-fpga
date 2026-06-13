// display_formatter.v
// Wypełnia bufor tekstowy 96 znaków (6 wierszy × 16 kolumn) i generuje
// sygnał refresh co 0.5 s lub przy zmianie trybu/enable.
//
// Tryby SW[1:0]:
//   00 = BME680 temperatura       01 = BME680 wilgotność
//   10 = BME680 ciśnienie         11 = diagnostyka RAW HEX (BME + AQS)

module display_formatter (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        enable,
    input  wire [1:0]  mode,

    input  wire [15:0] temp_c_x10,    // temperatura w 0.1 °C
    input  wire [15:0] hum_pct_x10,   // wilgotność w 0.1 %RH
    input  wire [15:0] press_hpa,     // ciśnienie w hPa
    input  wire        bme_valid,

    input  wire [15:0] eco2_ppm,
    input  wire [15:0] tvoc_ppb,
    input  wire        aqs_valid,

    // Diagnostyka AQS
    input  wire [7:0]  aqs_dbg_status,  // rejestr STATUS (0x00)
    input  wire [7:0]  aqs_dbg_raw0,    // HW_ID sensora (oczekiwane: 0x81)
    input  wire [7:0]  aqs_dbg_raw1,

    // Dane surowe BME680 do trybu diagnostycznego
    input  wire [19:0] bme_raw_temp,
    input  wire [19:0] bme_raw_press,
    input  wire [15:0] bme_raw_hum,

    input  wire [6:0]  buf_addr,
    output reg  [7:0]  buf_data,

    output reg         refresh
);

    reg [7:0] text_buf [0:95];   // bufor znaków ASCII, indeks = wiersz*16 + kolumna

    reg [1:0]  prev_mode;
    reg        prev_enable;
    reg [27:0] auto_refresh_cnt;
    reg [3:0]  refresh_pulse;
    reg        do_update;

    localparam [27:0] AUTO_REFRESH_PERIOD = 28'd62_500_000;  // 0.5 s przy 125 MHz

    integer i;

    wire eco2_invalid = (eco2_ppm == 16'hFFFF);
    wire tvoc_invalid = (tvoc_ppb == 16'hFFFF);

    // Zwraca cyfrę dziesiętną na pozycji pos (0=jedności) z liczby 16-bitowej
    function [3:0] digit5;
        input [15:0] num;
        input [3:0]  pos;
        begin
            case (pos)
                4'd0: digit5 = num % 16'd10;
                4'd1: digit5 = (num / 16'd10)    % 16'd10;
                4'd2: digit5 = (num / 16'd100)   % 16'd10;
                4'd3: digit5 = (num / 16'd1000)  % 16'd10;
                4'd4: digit5 = (num / 16'd10000) % 16'd10;
                default: digit5 = 4'd0;
            endcase
        end
    endfunction

    // Konwertuje 4-bitowy nibble na znak ASCII hex ('0'-'9' lub 'A'-'F')
    function [7:0] hex_char;
        input [3:0] nibble;
        begin
            if (nibble < 4'd10)
                hex_char = 8'h30 + {4'b0, nibble};
            else
                hex_char = 8'h41 + {4'b0, nibble} - 8'd10;
        end
    endfunction

    always @(posedge clk) begin
        if (!rst_n) begin
            for (i=0; i<96; i=i+1) text_buf[i] <= 8'h20;
            prev_mode        <= 2'b00;
            prev_enable      <= 1'b0;
            refresh          <= 1'b0;
            auto_refresh_cnt <= 0;
            refresh_pulse    <= 4'd0;
            do_update        <= 1'b0;
        end else begin
            refresh   <= 1'b0;
            do_update <= 1'b0;

            // Auto-refresh: pulsuje do_update co 0.5 s gdy system aktywny
            if (enable) begin
                if (auto_refresh_cnt == 0) begin
                    auto_refresh_cnt <= AUTO_REFRESH_PERIOD;
                    do_update <= 1'b1;
                end else auto_refresh_cnt <= auto_refresh_cnt - 1'b1;
            end else auto_refresh_cnt <= 0;

            // Aktualizacja bufora przy zmianie trybu, enable lub auto-refresh
            if (enable && (mode != prev_mode || enable != prev_enable || do_update)) begin
                // Wyczyść bufor spacjami
                for (i=0; i<96; i=i+1) text_buf[i] <= 8'h20;

                // Wiersz 0: nagłówek "MACIERZ SENS" (wspólny dla wszystkich trybów)
                text_buf[0]  <= "M"; text_buf[1]  <= "A"; text_buf[2]  <= "C";
                text_buf[3]  <= "I"; text_buf[4]  <= "E"; text_buf[5]  <= "R";
                text_buf[6]  <= "Z"; text_buf[7]  <= " ";
                text_buf[8]  <= "S"; text_buf[9]  <= "E"; text_buf[10] <= "N";
                text_buf[11] <= "S";

                case (mode)
                    // Wiersz 1: "BME680", wiersz 2: "TEMP:", wiersz 3: XX.X C
                    2'b00: begin
                        text_buf[24] <= "B"; text_buf[25] <= "M";
                        text_buf[26] <= "E"; text_buf[27] <= "6";
                        text_buf[28] <= "8"; text_buf[29] <= "0";
                        text_buf[36] <= "T"; text_buf[37] <= "E";
                        text_buf[38] <= "M"; text_buf[39] <= "P";
                        text_buf[40] <= ":";
                        text_buf[60] <= " ";
                        text_buf[61] <= "0" + digit5(temp_c_x10, 2);
                        text_buf[62] <= "0" + digit5(temp_c_x10, 1);
                        text_buf[63] <= ".";
                        text_buf[64] <= "0" + digit5(temp_c_x10, 0);
                        text_buf[65] <= " ";
                        text_buf[66] <= "C";
                    end

                    // Wiersz 1: "BME680", wiersz 2: "WILG:", wiersz 3: XX.X %
                    2'b01: begin
                        text_buf[24] <= "B"; text_buf[25] <= "M";
                        text_buf[26] <= "E"; text_buf[27] <= "6";
                        text_buf[28] <= "8"; text_buf[29] <= "0";
                        text_buf[36] <= "W"; text_buf[37] <= "I";
                        text_buf[38] <= "L"; text_buf[39] <= "G";
                        text_buf[40] <= ":";
                        text_buf[60] <= " ";
                        text_buf[61] <= "0" + digit5(hum_pct_x10, 2);
                        text_buf[62] <= "0" + digit5(hum_pct_x10, 1);
                        text_buf[63] <= ".";
                        text_buf[64] <= "0" + digit5(hum_pct_x10, 0);
                        text_buf[65] <= " ";
                        text_buf[66] <= "%";
                    end

                    // Wiersz 1: "BME680", wiersz 2: "CISN:", wiersz 3: XXXX hPa
                    2'b10: begin
                        text_buf[24] <= "B"; text_buf[25] <= "M";
                        text_buf[26] <= "E"; text_buf[27] <= "6";
                        text_buf[28] <= "8"; text_buf[29] <= "0";
                        text_buf[36] <= "C"; text_buf[37] <= "I";
                        text_buf[38] <= "S"; text_buf[39] <= "N";
                        text_buf[40] <= ":";
                        text_buf[60] <= "0" + digit5(press_hpa, 3);
                        text_buf[61] <= "0" + digit5(press_hpa, 2);
                        text_buf[62] <= "0" + digit5(press_hpa, 1);
                        text_buf[63] <= "0" + digit5(press_hpa, 0);
                        text_buf[64] <= " ";
                        text_buf[65] <= "h"; text_buf[66] <= "P";
                        text_buf[67] <= "a";
                    end

                    // Tryb 11: diagnostyka RAW HEX
                    // W2: "DIAG"
                    // W3: T + 5 hex nibble raw_temp  (20-bit BME680)
                    // W4: P + 5 hex nibble raw_press (20-bit BME680)
                    // W5: H + 4 hex nibble raw_hum   (16-bit BME680)
                    // W6: S + 2 hex STATUS AQS | W + 2 hex HW_ID AQS
                    2'b11: begin
                        text_buf[24] <= "D"; text_buf[25] <= "I";
                        text_buf[26] <= "A"; text_buf[27] <= "G";

                        text_buf[36] <= "T";
                        text_buf[37] <= hex_char(bme_raw_temp[19:16]);
                        text_buf[38] <= hex_char(bme_raw_temp[15:12]);
                        text_buf[39] <= hex_char(bme_raw_temp[11:8]);
                        text_buf[40] <= hex_char(bme_raw_temp[7:4]);
                        text_buf[41] <= hex_char(bme_raw_temp[3:0]);

                        text_buf[48] <= "P";
                        text_buf[49] <= hex_char(bme_raw_press[19:16]);
                        text_buf[50] <= hex_char(bme_raw_press[15:12]);
                        text_buf[51] <= hex_char(bme_raw_press[11:8]);
                        text_buf[52] <= hex_char(bme_raw_press[7:4]);
                        text_buf[53] <= hex_char(bme_raw_press[3:0]);

                        text_buf[60] <= "H";
                        text_buf[61] <= hex_char(bme_raw_hum[15:12]);
                        text_buf[62] <= hex_char(bme_raw_hum[11:8]);
                        text_buf[63] <= hex_char(bme_raw_hum[7:4]);
                        text_buf[64] <= hex_char(bme_raw_hum[3:0]);

                        text_buf[72] <= "S";
                        text_buf[73] <= hex_char(aqs_dbg_status[7:4]);
                        text_buf[74] <= hex_char(aqs_dbg_status[3:0]);
                        text_buf[76] <= "W";
                        text_buf[77] <= hex_char(aqs_dbg_raw0[7:4]);
                        text_buf[78] <= hex_char(aqs_dbg_raw0[3:0]);
                    end
                endcase

                prev_mode     <= mode;
                prev_enable   <= enable;
                refresh_pulse <= 4'd10;
            end

            // Utrzymuj refresh=1 przez 10 cykli po aktualizacji bufora
            if (refresh_pulse != 0) begin
                refresh       <= 1'b1;
                refresh_pulse <= refresh_pulse - 1'b1;
            end
        end
    end

    // Asynchroniczny odczyt bufora przez sterownik OLED
    always @(posedge clk) begin
        buf_data <= text_buf[buf_addr];
    end

endmodule