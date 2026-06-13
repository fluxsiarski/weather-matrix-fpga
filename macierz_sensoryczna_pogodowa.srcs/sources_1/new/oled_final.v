// oled_final.v
// Sterownik Pmod OLEDrgb: inicjalizacja przez SPI, pusty ekran, a następnie
// cykliczne renderowanie bufora 12×8 znaków ASCII na wyświetlacz RGB565.
// SPI zaimplementowany inline (6.25 MHz). Rendering wyzwalany sygnałem refresh.

module oled_final (
    input  wire        clk,             // 125 MHz
    input  wire        rst_n,
    input  wire        enable,          // SW3 - główny włącznik
    input  wire        refresh,         // impuls 1-cyklowy: odśwież ekran

    // Bufor tekstowy (read-only, 96 bajtów ASCII)
    output reg  [6:0]  buf_addr,        // indeks znaku 0..95
    input  wire [7:0]  buf_data,        // znak ASCII pod buf_addr

    // Sygnały Pmod OLEDrgb (SPI)
    output reg         oled_cs,
    output reg         oled_mosi,
    output reg         oled_sck,
    output reg         oled_dc,
    output reg         oled_res,
    output reg         oled_vccen,
    output reg         oled_pmoden,

    output reg         ready,           // 1 = inicjalizacja zakończona, czeka na refresh
    output reg  [3:0]  dbg_phase        // faza FSM do diagnostyki LED
);

    // ROM 38 bajtów komend inicjalizacji SSD1331
    localparam integer INIT_LEN = 38;
    reg [7:0] init_rom [0:INIT_LEN-1];
    initial begin
        init_rom[ 0] = 8'hFD; init_rom[ 1] = 8'h12;
        init_rom[ 2] = 8'hAE;
        init_rom[ 3] = 8'hA0; init_rom[ 4] = 8'h72;
        init_rom[ 5] = 8'hA1; init_rom[ 6] = 8'h00;
        init_rom[ 7] = 8'hA2; init_rom[ 8] = 8'h00;
        init_rom[ 9] = 8'hA4;
        init_rom[10] = 8'hA8; init_rom[11] = 8'h3F;
        init_rom[12] = 8'hAD; init_rom[13] = 8'h8E;
        init_rom[14] = 8'hB0; init_rom[15] = 8'h0B;
        init_rom[16] = 8'hB1; init_rom[17] = 8'h31;
        init_rom[18] = 8'hB3; init_rom[19] = 8'hF0;
        init_rom[20] = 8'h8A; init_rom[21] = 8'h64;
        init_rom[22] = 8'h8B; init_rom[23] = 8'h78;
        init_rom[24] = 8'h8C; init_rom[25] = 8'h64;
        init_rom[26] = 8'hBB; init_rom[27] = 8'h3A;
        init_rom[28] = 8'hBE; init_rom[29] = 8'h3E;
        init_rom[30] = 8'h87; init_rom[31] = 8'h06;
        init_rom[32] = 8'h81; init_rom[33] = 8'h91;
        init_rom[34] = 8'h82; init_rom[35] = 8'h50;
        init_rom[36] = 8'h83; init_rom[37] = 8'h7D;
    end

    // Komenda CLEAR WINDOW (0x25): czyści cały obszar 96×64 px
    reg [7:0] clr_rom [0:4];
    initial begin
        clr_rom[0] = 8'h25;  // clear window
        clr_rom[1] = 8'h00;
        clr_rom[2] = 8'h00;
        clr_rom[3] = 8'h5F;
        clr_rom[4] = 8'h3F;
    end

    // -------------------------------------------------------------------------
    // Stany głównej FSM
    // -------------------------------------------------------------------------
    localparam [5:0]
        S_OFF          = 6'd0,   // OLED wyłączony, czeka na enable
        S_PMODEN_DLY   = 6'd1,   // odczekaj 50 ms po PMODEN
        S_RES_LO       = 6'd2,   // RES LOW przez 5 ms (reset sprzętowy)
        S_RES_HI       = 6'd3,   // RES HIGH przez 5 ms
        S_INIT_START   = 6'd4,   // wyślij kolejny bajt z init_rom
        S_INIT_BYTE    = 6'd5,   // czekaj na zakończenie SPI
        S_INIT_NEXT    = 6'd6,   // inkrementuj init_i lub przejdź dalej
        S_POST_INIT    = 6'd7,   // odczekaj 10 ms po init
        S_VCCEN_DLY    = 6'd8,   // włącz VCCEN, odczekaj 100 ms
        S_DISPON_START = 6'd9,   // wyślij komendę Display ON (0xAF)
        S_DISPON_WAIT  = 6'd10,
        S_DISP_DLY     = 6'd11,  // odczekaj 100 ms po Display ON
        S_CLR_START    = 6'd12,  // wyślij kolejny bajt komendy CLEAR
        S_CLR_WAIT     = 6'd13,
        S_CLR_NEXT     = 6'd14,
        S_READY        = 6'd15,  // gotowy: czeka na refresh lub disable
        // Renderowanie znaków z bufora
        S_CHAR_ADDR    = 6'd16,  // ustaw buf_addr dla bieżącego znaku
        S_CHAR_LATCH   = 6'd17,  // czekaj na buf_data, zatrzaśnij font_char
        S_WIN_START    = 6'd18,  // wyślij kolejny bajt komendy SET WINDOW 8×8
        S_WIN_WAIT     = 6'd19,
        S_WIN_NEXT     = 6'd20,
        S_PIX_PREP     = 6'd21,  // zatrzaśnij wiersz pikseli z font_rom
        S_PIX_HI       = 6'd22,  // wyślij bajt HIGH koloru RGB565
        S_PIX_HI_WAIT  = 6'd23,
        S_PIX_LO       = 6'd24,  // wyślij bajt LOW koloru RGB565
        S_PIX_LO_WAIT  = 6'd25,
        S_PIX_NEXT     = 6'd26,  // następna kolumna lub wiersz glypha
        S_NEXT_CHAR    = 6'd27;  // następny znak (char_col/char_row)

    reg [5:0] state;

    // -------------------------------------------------------------------------
    // Inline SPI master (6.25 MHz, MODE 0, MSB first)
    // -------------------------------------------------------------------------
    reg [3:0] bit_cnt;
    reg [4:0] sck_div;
    reg [7:0] shift_reg;
    reg       spi_busy;
    reg       send_request;
    localparam integer SCK_HALF = 10;   // półokres SCK w cyklach (125 MHz / 10 = 6.25 MHz)

    // Opóźnienia inicjalizacji
    reg [27:0] delay;
    localparam [27:0] D_50MS  = 28'd6_250_000;
    localparam [27:0] D_5MS   = 28'd625_000;
    localparam [27:0] D_10MS  = 28'd1_250_000;
    localparam [27:0] D_100MS = 28'd12_500_000;

    // Iteratory i liczniki renderowania
    reg [5:0]  init_i;
    reg [2:0]  clr_i;
    reg [3:0]  win_i;
    reg [3:0]  char_col;     // kolumna znaku 0..11
    reg [3:0]  char_row;     // wiersz znaku 0..7
    reg [2:0]  pix_row;      // wiersz w glyphie 8×8 (0..7)
    reg [3:0]  pix_col;      // kolumna w glyphie (0..7)
    reg [7:0]  font_char;    // zatrzaśnięty kod ASCII bieżącego znaku
    reg [7:0]  pixel_byte;   // zatrzaśnięty wiersz pikseli z font_rom

    // Font ROM 8×8 - zewnętrzna instancja
    wire [7:0] font_pixels;
    font_rom u_font (
        .char_code(font_char),
        .row      (pix_row),
        .pixels   (font_pixels)
    );

    reg refresh_pending;   // flaga: oczekuje renderowanie po następnym cyklu

    // Kolory tekstu i tła w formacie RGB565 (biały tekst, czarne tło)
    localparam [7:0] TXT_HI = 8'hFF;
    localparam [7:0] TXT_LO = 8'hFF;
    localparam [7:0] BG_HI  = 8'h00;
    localparam [7:0] BG_LO  = 8'h00;

    // Mapowanie stanu FSM na 4-bitowy dbg_phase (widoczny na LED)
    always @* begin
        case (state)
            S_OFF:                                       dbg_phase = 4'h0;
            S_PMODEN_DLY:                                dbg_phase = 4'h1;
            S_RES_LO:                                    dbg_phase = 4'h2;
            S_RES_HI:                                    dbg_phase = 4'h3;
            S_INIT_START, S_INIT_BYTE, S_INIT_NEXT:      dbg_phase = 4'h4;
            S_POST_INIT, S_VCCEN_DLY:                    dbg_phase = 4'h5;
            S_DISPON_START, S_DISPON_WAIT, S_DISP_DLY:   dbg_phase = 4'h6;
            S_CLR_START, S_CLR_WAIT, S_CLR_NEXT:         dbg_phase = 4'h7;
            S_READY:                                     dbg_phase = 4'hA;
            default:                                     dbg_phase = 4'hB;  // rendering
        endcase
    end

    always @(posedge clk) begin
        if (!rst_n) begin
            state        <= S_OFF;
            oled_cs      <= 1'b1;
            oled_dc      <= 1'b0;
            oled_res     <= 1'b0;
            oled_vccen   <= 1'b0;
            oled_pmoden  <= 1'b0;
            oled_mosi    <= 1'b0;
            oled_sck     <= 1'b1;
            delay        <= 0;
            init_i       <= 0;
            clr_i        <= 0;
            win_i        <= 0;
            char_col     <= 0;
            char_row     <= 0;
            pix_row      <= 0;
            pix_col      <= 0;
            bit_cnt      <= 0;
            sck_div      <= 0;
            shift_reg    <= 0;
            spi_busy     <= 1'b0;
            send_request <= 1'b0;
            font_char    <= 8'h20;
            pixel_byte   <= 0;
            buf_addr     <= 0;
            ready        <= 1'b0;
            refresh_pending <= 1'b0;
        end else begin
            send_request <= 1'b0;

            // Rejestruj refresh tylko gdy OLED gotowy
            if (refresh && ready) refresh_pending <= 1'b1;

            // ---------------------------------------------------------------
            // SPI sub-FSM: taktuje shift_reg przez 8 bitów, SCK 6.25 MHz
            // ---------------------------------------------------------------
            if (spi_busy) begin
                if (sck_div == SCK_HALF-1) begin
                    sck_div <= 0;
                    if (oled_sck == 1'b0) begin
                        oled_sck <= 1'b1;
                    end else begin
                        if (bit_cnt == 4'd1) begin
                            oled_sck <= 1'b1;
                            spi_busy <= 1'b0;
                        end else begin
                            oled_sck  <= 1'b0;
                            bit_cnt   <= bit_cnt - 1'b1;
                            shift_reg <= {shift_reg[6:0], 1'b0};
                            oled_mosi <= shift_reg[6];
                        end
                    end
                end else sck_div <= sck_div + 1'b1;
            end

            // Załaduj shift_reg i uruchom SPI gdy send_request i SPI wolny
            if (send_request && !spi_busy) begin
                bit_cnt   <= 4'd8;
                sck_div   <= 0;
                oled_mosi <= shift_reg[7];
                oled_sck  <= 1'b0;
                spi_busy  <= 1'b1;
            end

            // ---------------------------------------------------------------
            // Główna FSM
            // ---------------------------------------------------------------
            case (state)
                // Czekaj na enable; przy aktywacji włącz zasilanie PMODEN
                S_OFF: begin
                    oled_cs     <= 1'b1;
                    oled_dc     <= 1'b0;
                    oled_res    <= 1'b0;
                    oled_vccen  <= 1'b0;
                    oled_pmoden <= 1'b0;
                    ready       <= 1'b0;
                    if (enable) begin
                        oled_pmoden <= 1'b1;
                        delay       <= D_50MS;
                        state       <= S_PMODEN_DLY;
                    end
                end

                S_PMODEN_DLY: begin
                    if (delay == 0) begin
                        oled_res <= 1'b0;
                        delay    <= D_5MS;
                        state    <= S_RES_LO;
                    end else delay <= delay - 1'b1;
                end

                S_RES_LO: begin
                    if (delay == 0) begin
                        oled_res <= 1'b1;
                        delay    <= D_5MS;
                        state    <= S_RES_HI;
                    end else delay <= delay - 1'b1;
                end

                S_RES_HI: begin
                    if (delay == 0) begin
                        init_i <= 0;
                        state  <= S_INIT_START;
                    end else delay <= delay - 1'b1;
                end

                // Wysyłanie sekwencji init bajt po bajcie przez SPI (DC=0)
                S_INIT_START: begin
                    oled_cs      <= 1'b0;
                    oled_dc      <= 1'b0;
                    shift_reg    <= init_rom[init_i];
                    send_request <= 1'b1;
                    state        <= S_INIT_BYTE;
                end

                S_INIT_BYTE: begin
                    oled_cs <= 1'b0;
                    oled_dc <= 1'b0;
                    if (!spi_busy && !send_request) state <= S_INIT_NEXT;
                end

                S_INIT_NEXT: begin
                    if (init_i == INIT_LEN - 1) begin
                        oled_cs <= 1'b1;
                        delay   <= D_10MS;
                        state   <= S_POST_INIT;
                    end else begin
                        init_i <= init_i + 1'b1;
                        state  <= S_INIT_START;
                    end
                end

                S_POST_INIT: begin
                    if (delay == 0) begin
                        oled_vccen <= 1'b1;   // włącz VCC po zakończeniu init
                        delay      <= D_100MS;
                        state      <= S_VCCEN_DLY;
                    end else delay <= delay - 1'b1;
                end

                S_VCCEN_DLY: begin
                    if (delay == 0) state <= S_DISPON_START;
                    else delay <= delay - 1'b1;
                end

                // Wyślij komendę Display ON (0xAF), odczekaj 100 ms
                S_DISPON_START: begin
                    oled_cs      <= 1'b0;
                    oled_dc      <= 1'b0;
                    shift_reg    <= 8'hAF;
                    send_request <= 1'b1;
                    state        <= S_DISPON_WAIT;
                end

                S_DISPON_WAIT: begin
                    oled_cs <= 1'b0;
                    if (!spi_busy && !send_request) begin
                        oled_cs <= 1'b1;
                        delay   <= D_100MS;
                        state   <= S_DISP_DLY;
                    end
                end

                S_DISP_DLY: begin
                    if (delay == 0) begin
                        clr_i <= 0;
                        state <= S_CLR_START;
                    end else delay <= delay - 1'b1;
                end

                // Wyślij 5-bajtową komendę CLEAR WINDOW (0x25, x0, y0, x1, y1)
                S_CLR_START: begin
                    oled_cs      <= 1'b0;
                    oled_dc      <= 1'b0;
                    shift_reg    <= clr_rom[clr_i];
                    send_request <= 1'b1;
                    state        <= S_CLR_WAIT;
                end

                S_CLR_WAIT: begin
                    oled_cs <= 1'b0;
                    if (!spi_busy && !send_request) state <= S_CLR_NEXT;
                end

                S_CLR_NEXT: begin
                    if (clr_i == 3'd4) begin
                        oled_cs <= 1'b1;
                        ready   <= 1'b1;
                        refresh_pending <= 1'b1;   // natychmiast wyrenderuj po init
                        state   <= S_READY;
                    end else begin
                        clr_i <= clr_i + 1'b1;
                        state <= S_CLR_START;
                    end
                end

                // Gotowy: czeka na refresh lub wyłączenie
                S_READY: begin
                    oled_cs <= 1'b1;
                    ready   <= 1'b1;
                    if (!enable) begin
                        oled_vccen  <= 1'b0;
                        oled_pmoden <= 1'b0;
                        oled_res    <= 1'b0;
                        ready       <= 1'b0;
                        state       <= S_OFF;
                    end else if (refresh_pending) begin
                        refresh_pending <= 1'b0;
                        char_col <= 0;
                        char_row <= 0;
                        state    <= S_CHAR_ADDR;
                    end
                end

                // Ustaw buf_addr; odczekaj 3 cykle na propagację buf_data
                S_CHAR_ADDR: begin
                    buf_addr <= {3'b0, char_row} * 7'd12 + {3'b0, char_col};
                    delay    <= 28'd3;
                    state    <= S_CHAR_LATCH;
                end

                // Zatrzaśnij znak ASCII, przejdź do ustawiania okna SET COLUMN/ROW
                S_CHAR_LATCH: begin
                    if (delay == 0) begin
                        font_char <= buf_data;
                        win_i     <= 0;
                        state     <= S_WIN_START;
                    end else delay <= delay - 1'b1;
                end

                // Wyślij 6 bajtów SET COLUMN (0x15) i SET ROW (0x75) dla okna 8×8 px
                S_WIN_START: begin
                    oled_cs <= 1'b0;
                    oled_dc <= 1'b0;
                    case (win_i)
                        4'd0: shift_reg <= 8'h15;                                // SET COLUMN
                        4'd1: shift_reg <= {1'b0, char_col, 3'b000};             // col_start
                        4'd2: shift_reg <= {1'b0, char_col, 3'b000} + 8'd7;      // col_end
                        4'd3: shift_reg <= 8'h75;                                // SET ROW
                        4'd4: shift_reg <= {1'b0, char_row, 3'b000};             // row_start
                        default: shift_reg <= {1'b0, char_row, 3'b000} + 8'd7;   // row_end
                    endcase
                    send_request <= 1'b1;
                    state        <= S_WIN_WAIT;
                end

                S_WIN_WAIT: begin
                    oled_cs <= 1'b0;
                    oled_dc <= 1'b0;
                    if (!spi_busy && !send_request) state <= S_WIN_NEXT;
                end

                S_WIN_NEXT: begin
                    if (win_i == 4'd5) begin
                        pix_row <= 0;
                        pix_col <= 0;
                        state   <= S_PIX_PREP;
                    end else begin
                        win_i <= win_i + 1'b1;
                        state <= S_WIN_START;
                    end
                end

                // Zatrzaśnij wiersz pikseli z font_rom przed wysyłaniem (DC=1 = dane)
                S_PIX_PREP: begin
                    oled_cs    <= 1'b0;
                    oled_dc    <= 1'b1;
                    pixel_byte <= font_pixels;
                    state      <= S_PIX_HI;
                end

                // Wyślij bajt HI koloru RGB565; bit MSB glypha = bit7-pix_col
                S_PIX_HI: begin
                    oled_cs <= 1'b0;
                    oled_dc <= 1'b1;
                    if (pixel_byte[3'd7 - pix_col[2:0]])
                        shift_reg <= TXT_HI;
                    else
                        shift_reg <= BG_HI;
                    send_request <= 1'b1;
                    state        <= S_PIX_HI_WAIT;
                end

                S_PIX_HI_WAIT: begin
                    oled_cs <= 1'b0;
                    oled_dc <= 1'b1;
                    if (!spi_busy && !send_request) state <= S_PIX_LO;
                end

                // Wyślij bajt LO koloru RGB565 (ten sam piksel)
                S_PIX_LO: begin
                    oled_cs <= 1'b0;
                    oled_dc <= 1'b1;
                    if (pixel_byte[3'd7 - pix_col[2:0]])
                        shift_reg <= TXT_LO;
                    else
                        shift_reg <= BG_LO;
                    send_request <= 1'b1;
                    state        <= S_PIX_LO_WAIT;
                end

                S_PIX_LO_WAIT: begin
                    oled_cs <= 1'b0;
                    oled_dc <= 1'b1;
                    if (!spi_busy && !send_request) state <= S_PIX_NEXT;
                end

                // Przejdź do następnej kolumny; po col=7 przejdź do następnego wiersza
                S_PIX_NEXT: begin
                    if (pix_col == 4'd7) begin
                        pix_col <= 0;
                        if (pix_row == 3'd7)
                            state <= S_NEXT_CHAR;
                        else begin
                            pix_row <= pix_row + 1'b1;
                            state   <= S_PIX_PREP;
                        end
                    end else begin
                        pix_col <= pix_col + 1'b1;
                        state   <= S_PIX_HI;
                    end
                end

                // Przejdź do następnego znaku; po col=11 przejdź do następnego wiersza
                S_NEXT_CHAR: begin
                    oled_cs <= 1'b1;
                    if (char_col == 4'd11) begin
                        char_col <= 0;
                        if (char_row == 4'd7)
                            state <= S_READY;
                        else begin
                            char_row <= char_row + 1'b1;
                            state    <= S_CHAR_ADDR;
                        end
                    end else begin
                        char_col <= char_col + 1'b1;
                        state    <= S_CHAR_ADDR;
                    end
                end

                default: state <= S_OFF;
            endcase
        end
    end

endmodule