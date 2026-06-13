// weather_matrix_top.v
// Top-level modułu: dwa niezależne I2C mastery (BME680 na JC, AQS/CCS811 na JD),
// formatter danych i sterownik wyświetlacza OLED RGB.
// Tryb SW[1:0] = 11 uruchamia diagnostykę AQS (RAW HEX).

module weather_matrix_top (
    input  wire        sysclk,
    input  wire [3:0]  sw,
    input  wire [3:0]  btn,
    output wire [3:0]  led,

    inout  wire        bme_sda,
    inout  wire        bme_scl,

    input  wire        aqs_int,
    output wire        aqs_wake,
    inout  wire        aqs_scl,
    inout  wire        aqs_sda,

    output wire        oled_cs,
    output wire        oled_mosi,
    output wire        oled_sck,
    output wire        oled_dc,
    output wire        oled_res,
    output wire        oled_vccen,
    output wire        oled_pmoden
);

    // -------------------------------------------------------------------------
    // Reset i synchronizacja przełączników
    // btn[0] (aktywny niski) przechodzi przez 4-stopniowy synchronizator.
    // Przełączniki SW synchronizowane 2-stopniowo, by uniknąć metastabilności.
    // -------------------------------------------------------------------------
    reg [3:0] rst_sync = 4'b0;
    always @(posedge sysclk) rst_sync <= {rst_sync[2:0], ~btn[0]};
    wire rst_n = rst_sync[3];

    reg [3:0] sw_sync_1 = 4'b0;
    reg [3:0] sw_sync_2 = 4'b0;
    always @(posedge sysclk) begin
        sw_sync_1 <= sw;
        sw_sync_2 <= sw_sync_1;
    end
    wire enable     = sw_sync_2[3]; // SW3 - główny włącznik systemu
    wire [1:0] mode = sw_sync_2[1:0]; // SW1/SW0 - wybór wyświetlanego sensora

    // -------------------------------------------------------------------------
    // I2C Master #1 - BME680 (Pmod JC, 100 kHz)
    // Obsługuje odczyt temperatury, wilgotności i ciśnienia.
    // -------------------------------------------------------------------------
    wire [6:0] bme_dev_addr;
    wire [1:0] bme_i2c_mode;
    wire [3:0] bme_wr_len, bme_rd_len;
    wire       bme_i2c_start;
    wire [7:0] bme_wr0, bme_wr1, bme_wr2, bme_wr3;
    wire [7:0] bme_rd0, bme_rd1, bme_rd2, bme_rd3;
    wire [7:0] bme_rd4, bme_rd5, bme_rd6, bme_rd7;
    wire       bme_i2c_busy, bme_i2c_done, bme_i2c_ackerr;
    wire       bme_scl_oe, bme_sda_oe;

    i2c_master #(.SYS_CLK_HZ(125_000_000), .I2C_CLK_HZ(100_000)) u_i2c_bme (
        .clk(sysclk), .rst_n(rst_n),
        .dev_addr(bme_dev_addr), .mode(bme_i2c_mode),
        .wr_len(bme_wr_len), .rd_len(bme_rd_len), .start(bme_i2c_start),
        .wr_data0(bme_wr0), .wr_data1(bme_wr1),
        .wr_data2(bme_wr2), .wr_data3(bme_wr3),
        .wr_data4(8'h00), .wr_data5(8'h00),
        .wr_data6(8'h00), .wr_data7(8'h00),
        .rd_data0(bme_rd0), .rd_data1(bme_rd1),
        .rd_data2(bme_rd2), .rd_data3(bme_rd3),
        .rd_data4(bme_rd4), .rd_data5(bme_rd5),
        .rd_data6(bme_rd6), .rd_data7(bme_rd7),
        .busy(bme_i2c_busy), .done(bme_i2c_done), .ack_error(bme_i2c_ackerr),
        .scl_oe(bme_scl_oe), .sda_oe(bme_sda_oe),
        .sda_in(bme_sda)
    );

    // Linie I2C w trybie open-drain: OE=1 → ciągnie do GND, OE=0 → hi-Z
    assign bme_scl = bme_scl_oe ? 1'b0 : 1'bz;
    assign bme_sda = bme_sda_oe ? 1'b0 : 1'bz;

    wire [15:0] temp_c_x10, hum_pct_x10, press_hpa;
    wire        bme_valid;
    wire [19:0] bme_raw_temp, bme_raw_press;
    wire [15:0] bme_raw_hum;
    wire        bme_ack_err;

    // Sterownik BME680: konfiguruje sensor, czyta dane kompensacyjne i ADC,
    // zwraca wyniki w formacie x10 (np. 253 = 25.3 °C).
    bme680_driver #(.SYS_CLK_HZ(125_000_000)) u_bme (
        .clk(sysclk), .rst_n(rst_n), .enable(enable),
        .i2c_dev_addr(bme_dev_addr), .i2c_mode(bme_i2c_mode),
        .i2c_wr_len(bme_wr_len), .i2c_rd_len(bme_rd_len),
        .i2c_start(bme_i2c_start),
        .i2c_wr0(bme_wr0), .i2c_wr1(bme_wr1),
        .i2c_wr2(bme_wr2), .i2c_wr3(bme_wr3),
        .i2c_rd0(bme_rd0), .i2c_rd1(bme_rd1),
        .i2c_rd2(bme_rd2), .i2c_rd3(bme_rd3),
        .i2c_rd4(bme_rd4), .i2c_rd5(bme_rd5),
        .i2c_rd6(bme_rd6), .i2c_rd7(bme_rd7),
        .i2c_busy(bme_i2c_busy), .i2c_done(bme_i2c_done),
        .i2c_ack_error(bme_i2c_ackerr),
        .temp_c_x10(temp_c_x10), .hum_pct_x10(hum_pct_x10),
        .press_hpa(press_hpa), .data_valid(bme_valid),
        .raw_temp_out(bme_raw_temp), .raw_press_out(bme_raw_press),
        .raw_hum_out(bme_raw_hum), .dbg_ack_err(bme_ack_err)
    );

    // -------------------------------------------------------------------------
    // I2C Master #2 - Pmod AQS / CCS811 (Pmod JD, 100 kHz)
    // Obsługuje odczyt eCO2 (ppm) i TVOC (ppb).
    // -------------------------------------------------------------------------
    wire [6:0] aqs_dev_addr;
    wire [1:0] aqs_i2c_mode;
    wire [3:0] aqs_wr_len, aqs_rd_len;
    wire       aqs_i2c_start;
    wire [7:0] aqs_wr0, aqs_wr1, aqs_wr2, aqs_wr3;
    wire [7:0] aqs_rd0, aqs_rd1, aqs_rd2, aqs_rd3;
    wire [7:0] aqs_rd4, aqs_rd5, aqs_rd6, aqs_rd7;
    wire       aqs_i2c_busy, aqs_i2c_done, aqs_i2c_ackerr;
    wire       aqs_scl_oe, aqs_sda_oe;

    i2c_master #(.SYS_CLK_HZ(125_000_000), .I2C_CLK_HZ(100_000)) u_i2c_aqs (
        .clk(sysclk), .rst_n(rst_n),
        .dev_addr(aqs_dev_addr), .mode(aqs_i2c_mode),
        .wr_len(aqs_wr_len), .rd_len(aqs_rd_len), .start(aqs_i2c_start),
        .wr_data0(aqs_wr0), .wr_data1(aqs_wr1),
        .wr_data2(aqs_wr2), .wr_data3(aqs_wr3),
        .wr_data4(8'h00), .wr_data5(8'h00),
        .wr_data6(8'h00), .wr_data7(8'h00),
        .rd_data0(aqs_rd0), .rd_data1(aqs_rd1),
        .rd_data2(aqs_rd2), .rd_data3(aqs_rd3),
        .rd_data4(aqs_rd4), .rd_data5(aqs_rd5),
        .rd_data6(aqs_rd6), .rd_data7(aqs_rd7),
        .busy(aqs_i2c_busy), .done(aqs_i2c_done), .ack_error(aqs_i2c_ackerr),
        .scl_oe(aqs_scl_oe), .sda_oe(aqs_sda_oe),
        .sda_in(aqs_sda)
    );

    assign aqs_scl = aqs_scl_oe ? 1'b0 : 1'bz;
    assign aqs_sda = aqs_sda_oe ? 1'b0 : 1'bz;

    wire [15:0] eco2_ppm, tvoc_ppb;
    wire        aqs_valid, aqs_wake_internal;
    wire [7:0]  aqs_dbg_status, aqs_dbg_raw0, aqs_dbg_raw1;

    // Sterownik CCS811: sekwencja boot → app_start → tryb pracy 1 (co 1 s),
    // odczytuje rejestry ALG_RESULT_DATA; dbg_* dostępne w trybie diagnostycznym.
    ccs811_driver #(.SYS_CLK_HZ(125_000_000)) u_aqs (
        .clk(sysclk), .rst_n(rst_n), .enable(enable),
        .i2c_dev_addr(aqs_dev_addr), .i2c_mode(aqs_i2c_mode),
        .i2c_wr_len(aqs_wr_len), .i2c_rd_len(aqs_rd_len),
        .i2c_start(aqs_i2c_start),
        .i2c_wr0(aqs_wr0), .i2c_wr1(aqs_wr1),
        .i2c_wr2(aqs_wr2), .i2c_wr3(aqs_wr3),
        .i2c_rd0(aqs_rd0), .i2c_rd1(aqs_rd1),
        .i2c_rd2(aqs_rd2), .i2c_rd3(aqs_rd3),
        .i2c_rd4(aqs_rd4), .i2c_rd5(aqs_rd5),
        .i2c_rd6(aqs_rd6), .i2c_rd7(aqs_rd7),
        .i2c_busy(aqs_i2c_busy), .i2c_done(aqs_i2c_done),
        .i2c_ack_error(aqs_i2c_ackerr),
        .aqs_wake_n(aqs_wake_internal),
        .eco2_ppm(eco2_ppm), .tvoc_ppb(tvoc_ppb),
        .data_valid(aqs_valid),
        .dbg_status(aqs_dbg_status),
        .dbg_raw0(aqs_dbg_raw0),
        .dbg_raw1(aqs_dbg_raw1)
    );

    assign aqs_wake = aqs_wake_internal;

    // -------------------------------------------------------------------------
    // Display formatter
    // Konwertuje dane sensorów na ciągi ASCII i zapisuje do bufora OLED.
    // Sygnał refresh pulsuje po każdej aktualizacji bufora.
    // -------------------------------------------------------------------------
    wire [6:0] buf_addr;
    wire [7:0] buf_data;
    wire       refresh;

    display_formatter u_fmt (
        .clk(sysclk), .rst_n(rst_n), .enable(enable), .mode(mode),
        .temp_c_x10(temp_c_x10), .hum_pct_x10(hum_pct_x10),
        .press_hpa(press_hpa), .bme_valid(bme_valid),
        .eco2_ppm(eco2_ppm), .tvoc_ppb(tvoc_ppb), .aqs_valid(aqs_valid),
        .aqs_dbg_status(aqs_dbg_status),
        .aqs_dbg_raw0(aqs_dbg_raw0),
        .aqs_dbg_raw1(aqs_dbg_raw1),
        .bme_raw_temp(bme_raw_temp),
        .bme_raw_press(bme_raw_press),
        .bme_raw_hum(bme_raw_hum),
        .buf_addr(buf_addr), .buf_data(buf_data),
        .refresh(refresh)
    );

    // -------------------------------------------------------------------------
    // Sterownik OLED RGB (Pmod OLEDrgb, SPI)
    // Inicjalizuje wyświetlacz, a następnie przy każdym refresh przepisuje bufor
    // znaków na ekran przez interfejs SPI.
    // -------------------------------------------------------------------------
    wire oled_ready;
    wire [3:0] oled_dbg;

    oled_final u_oled (
        .clk(sysclk), .rst_n(rst_n),
        .enable(enable), .refresh(refresh),
        .buf_addr(buf_addr), .buf_data(buf_data),
        .oled_cs(oled_cs), .oled_mosi(oled_mosi), .oled_sck(oled_sck),
        .oled_dc(oled_dc), .oled_res(oled_res),
        .oled_vccen(oled_vccen), .oled_pmoden(oled_pmoden),
        .ready(oled_ready), .dbg_phase(oled_dbg)
    );

    // -------------------------------------------------------------------------
    // Diagnostyka LED
    //   LD0 - system aktywny (SW3)
    //   LD1 - OLED gotowy
    //   LD2 - BME680 odpowiada (ACK OK)
    //   LD3 - AQS/CCS811 odpowiada (ACK OK)
    // -------------------------------------------------------------------------
    assign led[0] = enable;
    assign led[1] = oled_ready;
    assign led[2] = ~bme_ack_err;
    assign led[3] = ~aqs_i2c_ackerr;

endmodule