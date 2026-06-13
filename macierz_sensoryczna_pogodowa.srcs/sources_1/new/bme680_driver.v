// bme680_driver.v
// Sterownik BME680: konfiguruje sensor, wyzwala pomiar w trybie forced,
// odczytuje 8 bajtów danych surowych i przelicza je na temperaturę, wilgotność
// i ciśnienie. Cykl powtarza się co ~300 ms (50 ms pomiar + 250 ms przerwa).

module bme680_driver #(
    parameter integer SYS_CLK_HZ = 125_000_000
)(
    input  wire        clk,
    input  wire        rst_n,
    input  wire        enable,

    // Interfejs do i2c_master
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

    // Wyniki pomiarów
    output reg [15:0] temp_c_x10,    // temperatura w 0.1 °C (np. 225 = 22.5 °C)
    output reg [15:0] hum_pct_x10,   // wilgotność w 0.1 % RH
    output reg [15:0] press_hpa,     // ciśnienie w hPa
    output reg        data_valid,

    // Diagnostyka
    output reg [19:0] raw_temp_out,
    output reg [19:0] raw_press_out,
    output reg [15:0] raw_hum_out,
    output reg        dbg_ack_err    // 1 = ostatnia transakcja bez ACK od slave
);

    localparam [6:0] BME680_ADDR = 7'h77;

    localparam [1:0] MODE_WRITE = 2'd0;
    localparam [1:0] MODE_READ  = 2'd1;

    localparam integer MEAS_WAIT  = SYS_CLK_HZ / 20;   // 50 ms - czas pomiaru
    localparam integer CYCLE_WAIT = SYS_CLK_HZ / 4;    // 250 ms - przerwa między cyklami

    localparam [3:0]
        S_IDLE        = 4'd0,
        S_WR_HUM      = 4'd1,    // zapis ctrl_hum (0x72)
        S_WR_HUM_W    = 4'd2,    // oczekiwanie na done
        S_WR_MEAS     = 4'd3,    // zapis ctrl_meas (0x74), tryb forced
        S_WR_MEAS_W   = 4'd4,
        S_MEAS_DELAY  = 4'd5,    // odczekaj 50 ms na zakończenie pomiaru
        S_RD          = 4'd6,    // odczyt 8 bajtów od rejestru 0x1F
        S_RD_W        = 4'd7,
        S_PROCESS     = 4'd8,    // parsowanie i skalowanie danych surowych
        S_CYCLE_WAIT  = 4'd9;    // przerwa 250 ms przed kolejnym cyklem

    reg [3:0]  state;
    reg [27:0] delay;

    reg [19:0] raw_temp, raw_press;
    reg [15:0] raw_hum;
    reg [7:0]  tick_counter;

    // Flaga aktywności sensora: raw_temp poza zakresem all-ones i all-zeros
    wire sensor_alive = (raw_temp != 20'hFFFFF) && (raw_temp != 20'h00000);

    always @(posedge clk) begin
        if (!rst_n) begin
            state        <= S_IDLE;
            delay        <= 0;
            i2c_dev_addr <= BME680_ADDR;
            i2c_mode     <= MODE_WRITE;
            i2c_wr_len   <= 4'd1;
            i2c_rd_len   <= 4'd1;
            i2c_start    <= 1'b0;
            i2c_wr0      <= 8'h00;
            i2c_wr1      <= 8'h00;
            i2c_wr2      <= 8'h00;
            i2c_wr3      <= 8'h00;
            temp_c_x10   <= 16'd0;
            hum_pct_x10  <= 16'd0;
            press_hpa    <= 16'd0;
            data_valid   <= 1'b0;
            raw_temp     <= 0;
            raw_press    <= 0;
            raw_hum      <= 0;
            raw_temp_out <= 0;
            raw_press_out<= 0;
            raw_hum_out  <= 0;
            dbg_ack_err  <= 1'b1;
            tick_counter <= 0;
        end else begin
            i2c_start <= 1'b0;

            case (state)
                S_IDLE: begin
                    if (enable) state <= S_WR_HUM;
                end

                // Krok 1: ustaw oversampling wilgotności - WRITE 0x72 = 0x01 (osrs_h=x1)
                S_WR_HUM: begin
                    if (!i2c_busy) begin
                        i2c_dev_addr <= BME680_ADDR;
                        i2c_mode     <= MODE_WRITE;
                        i2c_wr_len   <= 4'd2;
                        i2c_wr0      <= 8'h72;   // rejestr ctrl_hum
                        i2c_wr1      <= 8'h01;   // osrs_h = x1
                        i2c_start    <= 1'b1;
                        state        <= S_WR_HUM_W;
                    end
                end

                S_WR_HUM_W: begin
                    if (i2c_done) state <= S_WR_MEAS;
                end

                // Krok 2: wyzwól pomiar - WRITE 0x74 = 0x25 (forced mode, osrs_t=x2, osrs_p=x1)
                S_WR_MEAS: begin
                    if (!i2c_busy) begin
                        i2c_dev_addr <= BME680_ADDR;
                        i2c_mode     <= MODE_WRITE;
                        i2c_wr_len   <= 4'd2;
                        i2c_wr0      <= 8'h74;   // rejestr ctrl_meas
                        i2c_wr1      <= 8'h25;   // forced mode
                        i2c_start    <= 1'b1;
                        state        <= S_WR_MEAS_W;
                    end
                end

                S_WR_MEAS_W: begin
                    if (i2c_done) begin
                        delay <= MEAS_WAIT;
                        state <= S_MEAS_DELAY;
                    end
                end

                S_MEAS_DELAY: begin
                    if (delay == 0) state <= S_RD;
                    else delay <= delay - 1'b1;
                end

                // Krok 3: odczyt danych surowych - READ 8 bajtów od 0x1F
                // Kolejność: press_msb, press_lsb, press_xlsb,
                //            temp_msb,  temp_lsb,  temp_xlsb, hum_msb, hum_lsb
                S_RD: begin
                    if (!i2c_busy) begin
                        i2c_dev_addr <= BME680_ADDR;
                        i2c_mode     <= MODE_READ;
                        i2c_wr_len   <= 4'd1;
                        i2c_wr0      <= 8'h1F;   // rejestr startowy bloku danych
                        i2c_rd_len   <= 4'd8;
                        i2c_start    <= 1'b1;
                        state        <= S_RD_W;
                    end
                end

                S_RD_W: begin
                    if (i2c_done) begin
                        dbg_ack_err <= i2c_ack_error;
                        state       <= S_PROCESS;
                    end
                end

                // Krok 4: składanie wartości 20-bitowych i skalowanie liniowe
                // Wzory dopasowane empirycznie do konkretnego egzemplarza sensora:
                //   raw_temp  ≈ 513792 → 22.0 °C  (krok: 512 LSB / 0.1 °C)
                //   raw_press ≈ 335104 → 1009 hPa  (dzielnik: 332)
                //   raw_hum   ≈  18176 → 45 %RH    (dzielnik: 40)
                S_PROCESS: begin
                    raw_press <= {i2c_rd0, i2c_rd1, i2c_rd2[7:4]};
                    raw_temp  <= {i2c_rd3, i2c_rd4, i2c_rd5[7:4]};
                    raw_hum   <= {i2c_rd6, i2c_rd7};

                    raw_press_out <= {i2c_rd0, i2c_rd1, i2c_rd2[7:4]};
                    raw_temp_out  <= {i2c_rd3, i2c_rd4, i2c_rd5[7:4]};
                    raw_hum_out   <= {i2c_rd6, i2c_rd7};

                    tick_counter <= tick_counter + 1'b1;

                    if (sensor_alive) begin
                        if ({12'b0, i2c_rd3, i2c_rd4, i2c_rd5[7:4]} > 32'd513792)
                            temp_c_x10 <= (({12'b0, i2c_rd3, i2c_rd4, i2c_rd5[7:4]}
                                          - 32'd513792) / 32'd512) + 16'd220;
                        else
                            temp_c_x10 <= 16'd220 - (((32'd513792
                                          - {12'b0, i2c_rd3, i2c_rd4, i2c_rd5[7:4]})
                                          / 32'd512));

                        hum_pct_x10 <= {16'b0, i2c_rd6, i2c_rd7} / 32'd40;
                        press_hpa   <= {12'b0, i2c_rd0, i2c_rd1, i2c_rd2[7:4]} / 32'd332;
                    end else begin
                        temp_c_x10  <= 16'd0;
                        hum_pct_x10 <= 16'd0;
                        press_hpa   <= 16'd0;
                    end

                    data_valid <= ~data_valid;
                    delay      <= CYCLE_WAIT;
                    state      <= S_CYCLE_WAIT;
                end

                S_CYCLE_WAIT: begin
                    if (!enable) state <= S_IDLE;
                    else if (delay == 0) state <= S_WR_HUM;
                    else delay <= delay - 1'b1;
                end

                default: state <= S_IDLE;
            endcase
        end
    end

endmodule