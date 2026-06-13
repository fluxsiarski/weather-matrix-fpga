// i2c_master.v
// Monolityczny I2C master: cały cykl START → adres → dane → STOP wykonywany
// jako jedna nieprzerwana transakcja (linie nie wracają do IDLE w środku).

module i2c_master #(
    parameter integer SYS_CLK_HZ = 125_000_000,
    parameter integer I2C_CLK_HZ = 100_000
)(
    input  wire        clk,
    input  wire        rst_n,

    // Sterowanie transakcją
    input  wire [6:0]  dev_addr,      // 7-bitowy adres slave
    input  wire [1:0]  mode,          // 0=WRITE, 1=READ, 2=WRITE_RAW
    input  wire [3:0]  wr_len,        // liczba bajtów do zapisu (1..8)
    input  wire [3:0]  rd_len,        // liczba bajtów do odczytu (1..8, tylko READ)
    input  wire        start,         // impuls 1-cyklowy: rozpocznij transakcję

    // Bufory danych
    input  wire [7:0]  wr_data0, wr_data1, wr_data2, wr_data3,
    input  wire [7:0]  wr_data4, wr_data5, wr_data6, wr_data7,
    output reg  [7:0]  rd_data0, rd_data1, rd_data2, rd_data3,
    output reg  [7:0]  rd_data4, rd_data5, rd_data6, rd_data7,

    output reg         busy,
    output reg         done,          // impuls 1-cyklowy po zakończeniu transakcji
    output reg         ack_error,     // 1 = slave nie ACK-ował

    // Linie fizyczne I2C (open-drain)
    output reg         scl_oe,        // 1 = wymusz SCL LOW, 0 = HiZ (pull-up trzyma HIGH)
    output reg         sda_oe,        // 1 = wymusz SDA LOW, 0 = HiZ
    input  wire        sda_in         // odczyt stanu linii SDA
);

    localparam [1:0] MODE_WRITE     = 2'd0;
    localparam [1:0] MODE_READ      = 2'd1;
    localparam [1:0] MODE_WRITE_RAW = 2'd2;

    // -------------------------------------------------------------------------
    // Generator ćwiartek SCL
    // Każdy bit SCL dzielony na 4 ćwiartki (q=0..3):
    //   q=0: SCL LOW  - master ustawia SDA
    //   q=1: SCL HIGH - slave próbkuje dane
    //   q=2: SCL HIGH - środek stanu HIGH
    //   q=3: SCL LOW  - faza trzymania
    // -------------------------------------------------------------------------
    localparam integer QUARTER = (SYS_CLK_HZ / I2C_CLK_HZ) / 4;  // ~312
    localparam integer QBITS   = 12;

    reg [QBITS-1:0] q_cnt;
    reg [1:0]       q;          // numer ćwiartki 0..3
    reg             q_tick;     // impuls 1-cyklowy przy każdym przejściu ćwiartki
    reg             run;        // włącza generator podczas transakcji

    always @(posedge clk) begin
        if (!rst_n) begin
            q_cnt  <= 0;
            q      <= 2'd0;
            q_tick <= 1'b0;
        end else if (run) begin
            if (q_cnt == QUARTER-1) begin
                q_cnt  <= 0;
                q      <= q + 2'd1;
                q_tick <= 1'b1;
            end else begin
                q_cnt  <= q_cnt + 1'b1;
                q_tick <= 1'b0;
            end
        end else begin
            q_cnt  <= 0;
            q      <= 2'd0;
            q_tick <= 1'b0;
        end
    end

    // -------------------------------------------------------------------------
    // Główna maszyna stanów
    // -------------------------------------------------------------------------
    localparam [4:0]
        ST_IDLE      = 5'd0,
        ST_START     = 5'd1,    // generowanie warunku START
        ST_ADDR_W    = 5'd2,    // wysyłanie adresu + bit W
        ST_ADDR_ACK  = 5'd3,    // odczyt ACK po adresie
        ST_WR_BYTE   = 5'd4,    // wysyłanie bajtu z bufora wr_data
        ST_WR_ACK    = 5'd5,    // odczyt ACK po bajcie
        ST_WR_LOAD   = 5'd13,   // ładowanie kolejnego bajtu (byte_idx już zaktualizowany)
        ST_RESTART   = 5'd6,    // generowanie warunku RESTART (dla READ)
        ST_ADDR_R    = 5'd7,    // wysyłanie adresu + bit R
        ST_ADDR_R_ACK= 5'd8,    // odczyt ACK po adresie+R
        ST_RD_BYTE   = 5'd9,    // odczyt bajtu (slave steruje SDA)
        ST_RD_ACK    = 5'd10,   // master wysyła ACK lub NACK
        ST_STOP      = 5'd11,   // generowanie warunku STOP
        ST_DONE      = 5'd12;

    reg [4:0] state;
    reg [3:0] bit_cnt;        // licznik bitów w bieżącym bajcie (7..0)
    reg [3:0] byte_idx;       // indeks aktualnie przetwarzanego bajtu
    reg [7:0] shift;          // rejestr przesuwny (TX i RX)
    reg       restart_done;   // flaga: RESTART już wykonany (faza READ)

    // Multiplekser wyboru bajtu do zapisu na podstawie byte_idx
    reg [7:0] wr_sel;
    always @* begin
        case (byte_idx)
            4'd0: wr_sel = wr_data0;
            4'd1: wr_sel = wr_data1;
            4'd2: wr_sel = wr_data2;
            4'd3: wr_sel = wr_data3;
            4'd4: wr_sel = wr_data4;
            4'd5: wr_sel = wr_data5;
            4'd6: wr_sel = wr_data6;
            default: wr_sel = wr_data7;
        endcase
    end

    always @(posedge clk) begin
        if (!rst_n) begin
            state        <= ST_IDLE;
            scl_oe       <= 1'b0;
            sda_oe       <= 1'b0;
            busy         <= 1'b0;
            done         <= 1'b0;
            ack_error    <= 1'b0;
            run          <= 1'b0;
            bit_cnt      <= 4'd7;
            byte_idx     <= 4'd0;
            shift        <= 8'h00;
            restart_done <= 1'b0;
            rd_data0 <= 0; rd_data1 <= 0; rd_data2 <= 0; rd_data3 <= 0;
            rd_data4 <= 0; rd_data5 <= 0; rd_data6 <= 0; rd_data7 <= 0;
        end else begin
            done <= 1'b0;

            case (state)

                ST_IDLE: begin
                    scl_oe <= 1'b0;
                    sda_oe <= 1'b0;
                    busy   <= 1'b0;
                    run    <= 1'b0;
                    if (start) begin
                        busy         <= 1'b1;
                        ack_error    <= 1'b0;
                        restart_done <= 1'b0;
                        byte_idx     <= 4'd0;
                        run          <= 1'b1;
                        state        <= ST_START;
                    end
                end

                // START: SDA opada gdy SCL HIGH
                //   q0: SDA=HiZ, SCL=HiZ  (oba HIGH)
                //   q1: SDA=LOW, SCL=HiZ  ← warunek START
                //   q2: SDA=LOW, SCL=LOW
                //   q3: SDA=LOW, SCL=LOW
                ST_START: begin
                    case (q)
                        2'd0: begin sda_oe<=1'b0; scl_oe<=1'b0; end
                        2'd1: begin sda_oe<=1'b1; scl_oe<=1'b0; end
                        2'd2: begin sda_oe<=1'b1; scl_oe<=1'b1; end
                        2'd3: begin sda_oe<=1'b1; scl_oe<=1'b1; end
                    endcase
                    if (q_tick && q == 2'd3) begin
                        shift   <= {dev_addr, 1'b0};   // adres + bit W
                        bit_cnt <= 4'd7;
                        state   <= ST_ADDR_W;
                    end
                end

                // Wysyłanie 8 bitów adresu+W (MSB first)
                // q0: SCL LOW, ustaw SDA; q1-q2: SCL HIGH; q3: SCL LOW
                ST_ADDR_W: begin
                    sda_oe <= ~shift[7];
                    case (q)
                        2'd0: scl_oe <= 1'b1;
                        2'd1: scl_oe <= 1'b0;
                        2'd2: scl_oe <= 1'b0;
                        2'd3: scl_oe <= 1'b1;
                    endcase
                    if (q_tick && q == 2'd3) begin
                        if (bit_cnt == 0) begin
                            state <= ST_ADDR_ACK;
                        end else begin
                            shift   <= {shift[6:0], 1'b0};
                            bit_cnt <= bit_cnt - 1'b1;
                        end
                    end
                end

                // Odczyt ACK od slave po adresie; próbkowanie w q=2 (SCL HIGH)
                ST_ADDR_ACK: begin
                    sda_oe <= 1'b0;
                    case (q)
                        2'd0: scl_oe <= 1'b1;
                        2'd1: scl_oe <= 1'b0;
                        2'd2: scl_oe <= 1'b0;
                        2'd3: scl_oe <= 1'b1;
                    endcase
                    if (q_tick && q == 2'd2) begin
                        if (sda_in) ack_error <= 1'b1;   // SDA=1 → NACK
                    end
                    if (q_tick && q == 2'd3) begin
                        shift    <= wr_sel;
                        bit_cnt  <= 4'd7;
                        byte_idx <= 4'd0;
                        state    <= ST_WR_BYTE;
                    end
                end

                // Wysyłanie bajtu wr_data[byte_idx], bit po bicie
                ST_WR_BYTE: begin
                    sda_oe <= ~shift[7];
                    case (q)
                        2'd0: scl_oe <= 1'b1;
                        2'd1: scl_oe <= 1'b0;
                        2'd2: scl_oe <= 1'b0;
                        2'd3: scl_oe <= 1'b1;
                    endcase
                    if (q_tick && q == 2'd3) begin
                        if (bit_cnt == 0) begin
                            state <= ST_WR_ACK;
                        end else begin
                            shift   <= {shift[6:0], 1'b0};
                            bit_cnt <= bit_cnt - 1'b1;
                        end
                    end
                end

                // Odczyt ACK po bajcie; decyzja: kolejny bajt, RESTART lub STOP
                ST_WR_ACK: begin
                    sda_oe <= 1'b0;
                    case (q)
                        2'd0: scl_oe <= 1'b1;
                        2'd1: scl_oe <= 1'b0;
                        2'd2: scl_oe <= 1'b0;
                        2'd3: scl_oe <= 1'b1;
                    endcase
                    if (q_tick && q == 2'd2) begin
                        if (sda_in) ack_error <= 1'b1;
                    end
                    if (q_tick && q == 2'd3) begin
                        if (byte_idx == wr_len - 1) begin
                            if (mode == MODE_READ && !restart_done)
                                state <= ST_RESTART;
                            else
                                state <= ST_STOP;
                        end else begin
                            byte_idx <= byte_idx + 1'b1;
                            state    <= ST_WR_LOAD;
                        end
                    end
                end

                // Jeden cykl przerwy - byte_idx zaktualizowany, ładujemy shift
                ST_WR_LOAD: begin
                    shift   <= wr_sel;
                    bit_cnt <= 4'd7;
                    state   <= ST_WR_BYTE;
                end

                // RESTART: SCL wraca HIGH, następnie SDA opada = powtórny START
                //   q0: SCL LOW,  SDA=HiZ
                //   q1: SCL HIGH, SDA=HiZ  (oba HIGH)
                //   q2: SCL HIGH, SDA=LOW  ← warunek START
                //   q3: SCL LOW,  SDA=LOW
                ST_RESTART: begin
                    case (q)
                        2'd0: begin sda_oe<=1'b0; scl_oe<=1'b1; end
                        2'd1: begin sda_oe<=1'b0; scl_oe<=1'b0; end
                        2'd2: begin sda_oe<=1'b1; scl_oe<=1'b0; end
                        2'd3: begin sda_oe<=1'b1; scl_oe<=1'b1; end
                    endcase
                    if (q_tick && q == 2'd3) begin
                        restart_done <= 1'b1;
                        shift   <= {dev_addr, 1'b1};   // adres + bit R
                        bit_cnt <= 4'd7;
                        state   <= ST_ADDR_R;
                    end
                end

                // Wysyłanie adresu+R (identyczna sekwencja jak ADDR_W)
                ST_ADDR_R: begin
                    sda_oe <= ~shift[7];
                    case (q)
                        2'd0: scl_oe <= 1'b1;
                        2'd1: scl_oe <= 1'b0;
                        2'd2: scl_oe <= 1'b0;
                        2'd3: scl_oe <= 1'b1;
                    endcase
                    if (q_tick && q == 2'd3) begin
                        if (bit_cnt == 0) begin
                            state <= ST_ADDR_R_ACK;
                        end else begin
                            shift   <= {shift[6:0], 1'b0};
                            bit_cnt <= bit_cnt - 1'b1;
                        end
                    end
                end

                // Odczyt ACK po adresie+R
                ST_ADDR_R_ACK: begin
                    sda_oe <= 1'b0;
                    case (q)
                        2'd0: scl_oe <= 1'b1;
                        2'd1: scl_oe <= 1'b0;
                        2'd2: scl_oe <= 1'b0;
                        2'd3: scl_oe <= 1'b1;
                    endcase
                    if (q_tick && q == 2'd2) begin
                        if (sda_in) ack_error <= 1'b1;
                    end
                    if (q_tick && q == 2'd3) begin
                        shift    <= 8'h00;
                        bit_cnt  <= 4'd7;
                        byte_idx <= 4'd0;
                        state    <= ST_RD_BYTE;
                    end
                end

                // Odczyt bajtu: master puszcza SDA, slave wystawia bity.
                // Próbkowanie w q=1 (SCL HIGH, dane stabilne).
                ST_RD_BYTE: begin
                    sda_oe <= 1'b0;
                    case (q)
                        2'd0: scl_oe <= 1'b1;
                        2'd1: scl_oe <= 1'b0;
                        2'd2: scl_oe <= 1'b0;
                        2'd3: scl_oe <= 1'b1;
                    endcase
                    if (q_tick && q == 2'd1) begin
                        shift <= {shift[6:0], sda_in};
                    end
                    if (q_tick && q == 2'd3) begin
                        if (bit_cnt == 0) begin
                            case (byte_idx)
                                4'd0: rd_data0 <= shift;
                                4'd1: rd_data1 <= shift;
                                4'd2: rd_data2 <= shift;
                                4'd3: rd_data3 <= shift;
                                4'd4: rd_data4 <= shift;
                                4'd5: rd_data5 <= shift;
                                4'd6: rd_data6 <= shift;
                                4'd7: rd_data7 <= shift;
                            endcase
                            state <= ST_RD_ACK;
                        end else begin
                            bit_cnt <= bit_cnt - 1'b1;
                        end
                    end
                end

                // Master wysyła ACK (SDA LOW) dla kolejnych bajtów,
                // NACK (SDA HiZ) dla ostatniego bajtu przed STOP.
                ST_RD_ACK: begin
                    if (byte_idx == rd_len - 1)
                        sda_oe <= 1'b0;     // NACK - ostatni bajt
                    else
                        sda_oe <= 1'b1;     // ACK  - więcej bajtów do odebrania
                    case (q)
                        2'd0: scl_oe <= 1'b1;
                        2'd1: scl_oe <= 1'b0;
                        2'd2: scl_oe <= 1'b0;
                        2'd3: scl_oe <= 1'b1;
                    endcase
                    if (q_tick && q == 2'd3) begin
                        if (byte_idx == rd_len - 1) begin
                            state <= ST_STOP;
                        end else begin
                            byte_idx <= byte_idx + 1'b1;
                            shift    <= 8'h00;
                            bit_cnt  <= 4'd7;
                            state    <= ST_RD_BYTE;
                        end
                    end
                end

                // STOP: SCL idzie HIGH, następnie SDA idzie HIGH
                //   q0: SDA=LOW, SCL=LOW
                //   q1: SDA=LOW, SCL=HIGH
                //   q2: SDA=HiZ, SCL=HIGH ← warunek STOP
                //   q3: oba HiZ (bus wolny)
                ST_STOP: begin
                    case (q)
                        2'd0: begin sda_oe<=1'b1; scl_oe<=1'b1; end
                        2'd1: begin sda_oe<=1'b1; scl_oe<=1'b0; end
                        2'd2: begin sda_oe<=1'b0; scl_oe<=1'b0; end
                        2'd3: begin sda_oe<=1'b0; scl_oe<=1'b0; end
                    endcase
                    if (q_tick && q == 2'd3) state <= ST_DONE;
                end

                // Transakcja zakończona: puls done=1, zwolnienie linii i bus
                ST_DONE: begin
                    scl_oe <= 1'b0;
                    sda_oe <= 1'b0;
                    run    <= 1'b0;
                    busy   <= 1'b0;
                    done   <= 1'b1;
                    state  <= ST_IDLE;
                end

                default: state <= ST_IDLE;
            endcase
        end
    end

endmodule