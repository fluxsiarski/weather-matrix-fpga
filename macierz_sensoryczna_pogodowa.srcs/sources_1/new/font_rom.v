// font_rom.v
// ROM czcionki 8×8 pikseli. Dla zadanego kodu ASCII i numeru wiersza (0..7)
// zwraca 8-bitowy wzorzec pikseli (MSB = lewy piksel).
// Zaimplementowane: spacja, 0-9, A-Z (wybrane), małe litery h/a/c/o/m/p
// wymagane przez napisy projektu. Pozostałe kody zwracają 0x00 (pusty znak).

module font_rom (
    input  wire [7:0] char_code,   // kod ASCII znaku
    input  wire [2:0] row,         // wiersz glypha 0..7 (0 = górny)
    output reg  [7:0] pixels       // maska pikseli wiersza (bit7 = lewy piksel)
);

    // 64-bitowy glyph: 8 bajtów, każdy = jeden wiersz pikseli (row 0..7)
    reg [63:0] glyph;

    always @* begin
        case (char_code)
            8'h20: glyph = 64'h00_00_00_00_00_00_00_00; // spacja
            8'h21: glyph = 64'h18_18_18_18_18_00_18_00; // !
            8'h25: glyph = 64'h62_64_08_10_20_46_86_00; // %
            8'h2E: glyph = 64'h00_00_00_00_00_18_18_00; // .
            8'h2F: glyph = 64'h02_04_08_10_20_40_80_00; // /
            8'h30: glyph = 64'h3C_66_6E_76_66_66_3C_00; // 0
            8'h31: glyph = 64'h18_38_18_18_18_18_3C_00; // 1
            8'h32: glyph = 64'h3C_66_06_0C_18_30_7E_00; // 2
            8'h33: glyph = 64'h3C_66_06_1C_06_66_3C_00; // 3
            8'h34: glyph = 64'h0C_1C_3C_6C_7E_0C_0C_00; // 4
            8'h35: glyph = 64'h7E_60_7C_06_06_66_3C_00; // 5
            8'h36: glyph = 64'h1C_30_60_7C_66_66_3C_00; // 6
            8'h37: glyph = 64'h7E_06_0C_18_30_30_30_00; // 7
            8'h38: glyph = 64'h3C_66_66_3C_66_66_3C_00; // 8
            8'h39: glyph = 64'h3C_66_66_3E_06_0C_38_00; // 9
            8'h3A: glyph = 64'h00_18_18_00_18_18_00_00; // :
            8'h41: glyph = 64'h18_3C_66_66_7E_66_66_00; // A
            8'h42: glyph = 64'h7C_66_66_7C_66_66_7C_00; // B
            8'h43: glyph = 64'h3C_66_60_60_60_66_3C_00; // C
            8'h44: glyph = 64'h78_6C_66_66_66_6C_78_00; // D
            8'h45: glyph = 64'h7E_60_60_78_60_60_7E_00; // E
            8'h46: glyph = 64'h7E_60_60_78_60_60_60_00; // F
            8'h47: glyph = 64'h3C_66_60_6E_66_66_3C_00; // G
            8'h48: glyph = 64'h66_66_66_7E_66_66_66_00; // H
            8'h49: glyph = 64'h3C_18_18_18_18_18_3C_00; // I
            8'h4A: glyph = 64'h1E_0C_0C_0C_0C_6C_38_00; // J
            8'h4B: glyph = 64'h66_6C_78_70_78_6C_66_00; // K
            8'h4C: glyph = 64'h60_60_60_60_60_60_7E_00; // L
            8'h4D: glyph = 64'h63_77_7F_6B_63_63_63_00; // M
            8'h4E: glyph = 64'h66_76_7E_7E_6E_66_66_00; // N
            8'h4F: glyph = 64'h3C_66_66_66_66_66_3C_00; // O
            8'h50: glyph = 64'h7C_66_66_7C_60_60_60_00; // P
            8'h51: glyph = 64'h3C_66_66_66_6A_6C_36_00; // Q
            8'h52: glyph = 64'h7C_66_66_7C_78_6C_66_00; // R
            8'h53: glyph = 64'h3C_66_60_3C_06_66_3C_00; // S
            8'h54: glyph = 64'h7E_18_18_18_18_18_18_00; // T
            8'h55: glyph = 64'h66_66_66_66_66_66_3C_00; // U
            8'h56: glyph = 64'h66_66_66_66_66_3C_18_00; // V
            8'h57: glyph = 64'h63_63_63_6B_7F_77_63_00; // W
            8'h58: glyph = 64'h66_66_3C_18_3C_66_66_00; // X
            8'h59: glyph = 64'h66_66_66_3C_18_18_18_00; // Y
            8'h5A: glyph = 64'h7E_06_0C_18_30_60_7E_00; // Z
            8'h61: glyph = 64'h00_00_3C_06_3E_66_3E_00; // a
            8'h63: glyph = 64'h00_00_3C_66_60_66_3C_00; // c
            8'h68: glyph = 64'h60_60_7C_66_66_66_66_00; // h  (używane w "hPa")
            8'h6D: glyph = 64'h00_00_66_7F_7F_6B_63_00; // m
            8'h6F: glyph = 64'h00_00_3C_66_66_66_3C_00; // o
            8'h70: glyph = 64'h00_00_7C_66_7C_60_60_00; // p
            8'h70+8'h01: glyph = 64'h00_00_7C_66_66_7C_60_60; // p (z descenderem)
            default:     glyph = 64'h00_00_00_00_00_00_00_00; // nieznany znak → pusty
        endcase
    end

    // Wybierz właściwy bajt z glypha na podstawie numeru wiersza
    always @* begin
        case (row)
            3'd0: pixels = glyph[63:56];
            3'd1: pixels = glyph[55:48];
            3'd2: pixels = glyph[47:40];
            3'd3: pixels = glyph[39:32];
            3'd4: pixels = glyph[31:24];
            3'd5: pixels = glyph[23:16];
            3'd6: pixels = glyph[15: 8];
            3'd7: pixels = glyph[ 7: 0];
        endcase
    end

endmodule