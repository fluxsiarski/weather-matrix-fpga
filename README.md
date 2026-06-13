# 🌡️ Weather Matrix - Macierz Sensoryczna na FPGA

> Projekt semestralny z przedmiotu **Logika Układów Cyfrowych**  
> Akademia Wojsk Lądowych im. gen. Tadeusza Kościuszki we Wrocławiu · 2026  
> Prowadzący: mgr inż. Igor Mielczarek

---

## 📸 Demonstracja działania

![Stacja pogodowa na płytce Zybo Z7-20](media/system_overview.jpg)
*Widok ogólny układu: Zybo Z7-20 z podłączonymi sensorami BME680 i Pmod AQS oraz wyświetlaczem Pmod OLEDrgb.*

---

## 📋 Spis treści

### Wersja polska
- [O projekcie](#-o-projekcie)
- [Cele projektu](#-cele-projektu)
- [Sprzęt](#-sprzęt)
- [Architektura systemu](#-architektura-systemu)
- [Interfejsy i komunikacja](#-interfejsy-i-komunikacja)
- [Funkcjonalności](#-funkcjonalności)
- [Struktura modułów Verilog](#-struktura-modułów-verilog)
- [Opis działania modułów](#-opis-działania-modułów)
- [Obsługa użytkownika](#-obsługa-użytkownika)
- [Diagnostyka i napotkane problemy](#-diagnostyka-i-napotkane-problemy)
- [Wyniki pomiarów](#-wyniki-pomiarów)
- [Struktura repozytorium](#-struktura-repozytorium)
- [Szybki start](#-szybki-start)
- [Możliwe rozwinięcia](#-możliwe-rozwinięcia)
- [Autorzy](#-autorzy)
- [Licencja](#-licencja)

### ENG version
- [About the project](#-about-the-project)
- [Project goals](#-project-goals)
- [Hardware](#-hardware)
- [System architecture](#-system-architecture)
- [Interfaces and communication](#-interfaces-and-communication)
- [Features](#-features)
- [Verilog module structure](#-verilog-module-structure)
- [Module behavior](#-module-behavior)
- [User operation](#-user-operation)
- [Diagnostics and issues](#-diagnostics-and-issues)
- [Measurement results](#-measurement-results)
- [Repository structure](#-repository-structure)
- [Quick start](#-quick-start)
- [Possible extensions](#-possible-extensions)
- [Authors](#-authors)
- [License](#-license)

---

# 🇵🇱 Wersja polska

## 🔎 O projekcie

**Weather Matrix** to autonomiczna stacja monitoringu warunków środowiskowych zrealizowana jako projekt cyfrowy na platformie FPGA **Zybo Z7-20**. System akwizycji danych zbiera informacje z dwóch niezależnych sensorów środowiskowych, komunikuje się z nimi przez magistrale I²C i prezentuje wyniki w czasie rzeczywistym na kolorowym wyświetlaczu **Pmod OLEDrgb**.

Projekt został wykonany w języku **Verilog** z użyciem środowiska **Vivado 2025.2**. Jego głównym założeniem było pokazanie, że kompletna logika pomiarowa, komunikacyjna i prezentacyjna może zostać zaimplementowana sprzętowo, bez potrzeby uruchamiania systemu operacyjnego czy programu na klasycznym mikrokontrolerze.

W odróżnieniu od typowych rozwiązań opartych o MCU, architektura FPGA umożliwia deterministyczną i równoległą pracę wielu bloków sprzętowych. W tym projekcie dwie niezależne ścieżki I²C działają równolegle, a tor wyświetlania OLED pracuje asynchronicznie względem toru odczytu danych.

---

## 🎯 Cele projektu

Projekt miał spełnić następujące wymagania funkcjonalne i dydaktyczne:

- Odczyt temperatury, wilgotności i ciśnienia z sensora **BME680**.
- Odczyt parametrów jakości powietrza z modułu **Pmod AQS** opartego o układ **CCS811**.
- Prezentację wyników na kolorowym wyświetlaczu **OLED RGB 96×64**.
- Sterowanie wyborem trybu pracy za pomocą przełączników **SW0**, **SW1** i głównego włącznika **SW3**.
- Implementację logiki w pełni sprzętowo w języku **Verilog**.
- Opracowanie projektu w sposób nadający się do demonstracji laboratoryjnej i opisania w sprawozdaniu technicznym.

---

## 🛠️ Sprzęt

| Komponent | Opis | Interfejs | Parametry / adres | Port |
|-----------|------|-----------|-------------------|------|
| **Zybo Z7-20** | Płytka FPGA z układem Zynq-7000 | - | zegar zewnętrzny 125 MHz | - |
| **SparkFun BME680** | Sensor temperatury, wilgotności i ciśnienia | I²C | adres 0x77 | Pmod JC |
| **Digilent Pmod AQS** | Sensor jakości powietrza z układem CCS811 | I²C | adres 0x5B | Pmod JD |
| **Digilent Pmod OLEDrgb** | Wyświetlacz OLED RGB 96×64 | SPI | 16-bit RGB, sterownik SSD1331 | Pmod JE |

![Widok podłączeń sprzętowych](media/hardware_connections.jpg)
*Schemat podłączeń: BME680 → JC, Pmod AQS → JD, Pmod OLEDrgb → JE.*

---

## 🏗️ Architektura systemu

System został zbudowany jako hierarchiczna struktura modułów Verilog połączonych przez moduł nadrzędny `weathermatrix_top`. Całość można podzielić na trzy główne warstwy:

1. **Warstwa akwizycji danych**  
   Odpowiada za komunikację z sensorami BME680 i CCS811 poprzez dwa niezależne egzemplarze kontrolera I²C.

2. **Warstwa przetwarzania i formatowania**  
   Odpowiada za przeliczenie surowych danych na postać tekstową oraz zapis znaków do bufora ekranowego.

3. **Warstwa prezentacji**  
   Odpowiada za inicjalizację wyświetlacza OLED, generowanie grafiki znakowej 8×8 i transmisję danych po SPI.

### Schemat blokowy

```text
weathermatrix_top
├── i2cmaster        (instancja #1 dla BME680)
├── i2cmaster        (instancja #2 dla Pmod AQS / CCS811)
├── bme680driver
├── ccs811driver
├── displayformatter
├── fontrom
└── oledfinal
```

Dane w systemie przepływają w jednym kierunku: od sensorów, przez sterowniki i blok formatowania, aż do wyświetlacza. Taka architektura upraszcza sterowanie i ułatwia analizę działania całego układu.

---

## 🔌 Interfejsy i komunikacja

### Magistrala I²C

W projekcie zastosowano dwie niezależne magistrale I²C taktowane z częstotliwością **100 kHz**. Każdy sensor ma własny kontroler magistrali, dzięki czemu odczyty nie blokują się wzajemnie.

Najważniejszą cechą końcowej implementacji jest **monolityczna transakcja I²C**. Oznacza to, że cała sekwencja typu:

- START
- wysłanie adresu
- zapis wskaźnika rejestru
- opcjonalny RESTART
- odczyt danych
- STOP

jest realizowana jako jedna nieprzerwana operacja sprzętowa.

### Magistrala SPI

Wyświetlacz **Pmod OLEDrgb** wykorzystuje interfejs SPI. Sterownik `oledfinal` realizuje zarówno sekwencję inicjalizacji SSD1331, jak i późniejsze przesyłanie danych pikseli na ekran.

### Linie open-drain

Sygnały I²C zostały zrealizowane jako wyjścia trójstanowe z wymuszaniem stanu niskiego i stanem wysokiej impedancji dla logicznej jedynki. Pull-up dla linii SDA i SCL jest uwzględniony w constraints.

---

## ✅ Funkcjonalności

### Sterowanie przełącznikami

| Przełącznik | Funkcja |
|-------------|---------|
| **SW3 ↑** | Włączenie systemu i aktywacja logiki |
| **SW3 ↓** | Wyłączenie systemu i wygaszenie wyświetlacza |
| **SW1:SW0 = 00** | Temperatura z BME680 |
| **SW1:SW0 = 01** | Wilgotność z BME680 |
| **SW1:SW0 = 10** | Ciśnienie z BME680 |
| **SW1:SW0 = 11** | Dane z AQS / tryb diagnostyczny |

### Sygnalizacja LED

| Dioda | Znaczenie |
|-------|-----------|
| **LD0** | System aktywny |
| **LD1** | OLED zainicjalizowany |
| **LD2** | BME680 odpowiada na magistrali I²C |
| **LD3** | Pmod AQS odpowiada na magistrali I²C |

### Dodatkowe cechy

- Odświeżanie ekranu co około **500 ms**.
- Reset systemu przyciskiem **BTN0**.
- Równoległa praca dwóch torów I²C.
- Diagnostyka sprzętowa sensora CCS811.
- Prezentacja wartości w formacie tekstowym na ekranie 12×8 znaków.

---

## 📦 Struktura modułów Verilog

Projekt opiera się na kilku wyspecjalizowanych blokach sprzętowych.

### 1. `weathermatrix_top`
Moduł nadrzędny łączący wszystkie komponenty systemu. Odpowiada za:
- synchronizację wejść zewnętrznych,
- połączenie sterowników sensorów,
- routing linii I²C i SPI,
- sterowanie diodami LED.

### 2. `i2cmaster`
Uniwersalny kontroler magistrali I²C. Obsługuje:
- zapis,
- odczyt z rejestru,
- surowe transakcje write,
- ACK/NACK,
- repeated start.

### 3. `bme680driver`
Sterownik sensora pogodowego. Realizuje:
- konfigurację rejestrów pomiarowych,
- start pomiaru w forced mode,
- odczyt surowych danych,
- ich skalowanie do jednostek użytkowych.

### 4. `ccs811driver`
Sterownik układu CCS811 z modułu Pmod AQS. Zawiera:
- sekwencję wybudzenia,
- odczyt rejestru HWID,
- próbę wykonania APP_START,
- konfigurację trybu pomiarowego,
- diagnostykę STATUS i danych pomiarowych.

### 5. `displayformatter`
Moduł budujący zawartość tekstową ekranu. Odpowiada za:
- wybór trybu pracy,
- konwersję liczb do ASCII,
- zapis znaków do bufora 96 bajtów,
- generowanie sygnału odświeżenia.

### 6. `fontrom`
Pamięć ROM zawierająca czcionkę 8×8. Na podstawie kodu ASCII i numeru wiersza zwraca wzorzec pikseli dla pojedynczego znaku.

### 7. `oledfinal`
Sterownik wyświetlacza OLED. Odpowiada za:
- inicjalizację SSD1331,
- czyszczenie ekranu,
- ustawianie okna rysowania,
- renderowanie tekstu znak po znaku,
- transmisję RGB565 po SPI.

---

## ⚙️ Opis działania modułów

### BME680

Sterownik `bme680driver` wykonuje cykliczną sekwencję:

1. zapis `ctrl_hum`,
2. zapis `ctrl_meas`,
3. odczekanie czasu pomiaru,
4. odczyt 8 bajtów danych,
5. złożenie danych 20-bitowych i 16-bitowych,
6. skalowanie do temperatury, wilgotności i ciśnienia.

W obecnej wersji projektu zastosowano uproszczone, empiryczne wzory przeliczeniowe dopasowane do konkretnego egzemplarza sensora. Dzięki temu możliwe było uzyskanie czytelnych wyników bez implementacji pełnego algorytmu kompensacyjnego producenta.

### CCS811 / Pmod AQS

Sterownik `ccs811driver` realizuje rozbudowaną sekwencję inicjalizacji. Najpierw wybudza układ, następnie odczytuje rejestr **HWID**, sprawdza stan **STATUS**, próbuje uruchomić aplikację pomiarową komendą **APP_START**, a później konfiguruje rejestr **MEAS_MODE**.

W badanym egzemplarzu modułu AQS układ potwierdza transakcje I²C, ale zwraca niepoprawną wartość `0x00` z rejestru HWID zamiast oczekiwanego `0x81`. Z tego powodu tor AQS został pozostawiony w projekcie również jako narzędzie diagnostyczne.

### OLED

Sterownik `oledfinal` inicjalizuje wyświetlacz przez SPI, a następnie renderuje tekst z bufora znakowego 12×8. Każdy znak jest odwzorowywany przy użyciu czcionki 8×8, co pozwala pokryć cały ekran 96×64 bez dodatkowego skalowania.

---

## 🕹️ Obsługa użytkownika

```text
1. Podłącz moduły do odpowiednich portów Pmod:
   - BME680 → JC
   - Pmod AQS → JD
   - Pmod OLEDrgb → JE

2. Wgraj bitstream na płytkę Zybo Z7-20.

3. Ustaw SW3 w pozycję wysoką:
   - LD0 zapali się natychmiast,
   - po inicjalizacji OLED zapali się LD1,
   - LD2 i LD3 pokażą status komunikacji I²C.

4. Użyj SW1 i SW0 do wyboru wyświetlanego trybu.

5. W razie potrzeby użyj BTN0 do resetu systemu.
```

Układ został przygotowany tak, aby jego uruchomienie było możliwie proste podczas demonstracji laboratoryjnej. Wszystkie najważniejsze stany pracy są sygnalizowane bezpośrednio przez diody LED i ekran OLED.

---

## 🔬 Diagnostyka i napotkane problemy

Najważniejszym problemem napotkanym podczas realizacji projektu był błąd architektoniczny w pierwszej wersji kontrolera I²C. W pierwotnym podejściu transakcja była dzielona na osobne etapy START, WRITE, READ i STOP realizowane jak odrębne prymitywy. Pomiędzy nimi linie magistrali wracały do stanu spoczynkowego.

W protokole I²C takie zachowanie powoduje wygenerowanie niezamierzonego warunku STOP. W praktyce prowadziło to do sytuacji, w której sensory nie otrzymywały pełnej sekwencji adres + rejestr + dane, a odczyty zwracały `0xFF`.

Rozwiązaniem było przepisanie kontrolera jako **jednej monolitycznej maszyny stanów**. Po tej zmianie sensor BME680 zaczął odpowiadać poprawnie, a odczyty zaczęły reagować na realne warunki otoczenia.

Dodatkowo zdiagnozowano problem z modułem **Pmod AQS**. Układ CCS811:
- potwierdza transakcje na poziomie I²C,
- jednak zwraca `0x00` z rejestru HWID,
- nie przechodzi do poprawnego trybu aplikacyjnego.

Wniosek: badany egzemplarz modułu AQS jest prawdopodobnie uszkodzony sprzętowo, natomiast sam sterownik został zaimplementowany zgodnie z dokumentacją i jest gotowy do pracy ze sprawnym egzemplarzem.

---

## 📊 Wyniki pomiarów

![Odczyt temperatury z sensora BME680](media/demo_temperature.jpg)
*Tryb temperatury, np. `TEMP 22.1 C`.*

![Odczyt ciśnienia z sensora BME680](media/demo_pressure.jpg)
*Tryb ciśnienia, np. `CISN 1011 hPa`.*

![Odczyt wilgotności z sensora BME680](media/demo_humidity.jpg)
*Tryb wilgotności, np. `WILG 45.9 %`.*

Przykładowe wyniki uzyskiwane przez system obejmują:
- temperaturę w °C,
- wilgotność względną w %,
- ciśnienie atmosferyczne w hPa.

Wartości są prezentowane w formacie tekstowym i odświeżane okresowo, dzięki czemu użytkownik obserwuje zmiany środowiska w czasie rzeczywistym.

---

## 🗂️ Struktura repozytorium

```text
weather-matrix-fpga/
├── README.md
├── src/
│   ├── weathermatrix_top.v
│   ├── i2cmaster.v
│   ├── bme680driver.v
│   ├── ccs811driver.v
│   ├── displayformatter.v
│   ├── fontrom.v
│   └── oledfinal.v
├── constraints/
│   └── zybo_weather_matrix.xdc
├── vivado/
│   └── weather_matrix.xpr
├── docs/
│   └── sprawozdanie.pdf
└── media/
    ├── system_overview.jpg
    ├── hardware_connections.jpg
    ├── demo_temperature.jpg
    ├── demo_pressure.jpg
    └── demo_humidity.jpg
```

Struktura repozytorium może być oczywiście dostosowana do rzeczywistego układu katalogów. Powyższy układ jest czytelny, typowy dla projektów akademickich i wygodny przy publikacji na GitHubie.

---

## 🚀 Szybki start

### Wymagania

- **Vivado 2025.2**
- Digilent **Zybo Z7-20**
- Sensor **SparkFun BME680**
- Moduł **Digilent Pmod AQS**
- Wyświetlacz **Digilent Pmod OLEDrgb**
- Połączenia zgodne z plikiem constraints oraz dokumentacją sprzętu

### Kroki

```bash
# 1. Sklonuj repozytorium
git clone https://github.com/TWOJ_USERNAME/weather-matrix-fpga.git
cd weather-matrix-fpga

# 2. Otwórz projekt Vivado
# File -> Open Project -> wybierz plik .xpr

# 3. Uruchom syntezę i implementację
# Flow -> Run Synthesis
# Flow -> Run Implementation

# 4. Wygeneruj bitstream
# Flow -> Generate Bitstream

# 5. Zaprogramuj płytkę
# Open Hardware Manager -> Program Device
```

Po wgraniu bitstreamu system powinien uruchomić się po ustawieniu przełącznika **SW3** w stan wysoki.

---

## 🔭 Możliwe rozwinięcia

Projekt można rozbudować o wiele dodatkowych funkcji:

- implementację pełnego algorytmu kompensacyjnego **Bosch BME680**,
- zapis historii pomiarów do pamięci BRAM lub na kartę SD,
- prezentację wykresów zamiast wyłącznie tekstu,
- komunikację UART, USB lub Ethernet,
- alarm progowy dla eCO₂ / TVOC,
- integrację z procesorem ARM w układzie Zynq jako wersję hybrydową PL + PS.

Takie rozszerzenia pozwoliłyby rozwinąć projekt z demonstratora dydaktycznego do bardziej zaawansowanej platformy pomiarowej.

---

## 👥 Autorzy

| Imię i nazwisko | Nr albumu |
|-----------------|-----------|
| **Wiktor Zieliński** | 11854 |
| **Wiktor Dams** | 11864 |
| **Kamil Mańka** | 11137 |

**Prowadzący:** mgr inż. Igor Mielczarek  
**Uczelnia:** Akademia Wojsk Lądowych im. gen. Tadeusza Kościuszki we Wrocławiu  
**Rok akademicki:** 2025/2026

---

## 📄 Licencja

Projekt akademicki wykonany w ramach przedmiotu **Logika Układów Cyfrowych**.  
Materiały źródłowe i dokumentacja zostały przygotowane na potrzeby realizacji projektu semestralnego.

---

# 🇬🇧 ENG version

## 🔎 About the project

**Weather Matrix** is an FPGA-based environmental monitoring station implemented on the **Zybo Z7-20** platform. The system collects data from two independent environmental sensors, communicates with them over I²C buses, and displays the results in real time on a color **Pmod OLEDrgb** display.

The project was developed in **Verilog** using **Vivado 2025.2**. Its main objective was to prove that a complete sensor acquisition, processing, and display pipeline can be implemented directly in programmable logic without relying on a classical microcontroller firmware loop.

Compared with standard MCU-based solutions, the FPGA architecture offers deterministic timing and true hardware-level concurrency. In this project, two I²C paths operate independently, while the OLED rendering path works asynchronously with respect to the sensor acquisition path.

---

## 🎯 Project goals

The project was designed to achieve the following objectives:

- Read temperature, humidity, and pressure from the **BME680** sensor.
- Read air-quality-related parameters from the **Pmod AQS** module based on **CCS811**.
- Display results on a **96×64 RGB OLED** screen.
- Control operating modes using **SW0**, **SW1**, and the main enable switch **SW3**.
- Implement the full logic in **Verilog**.
- Prepare a demonstrable academic FPGA project suitable for lab presentation and written technical documentation.

---

## 🛠️ Hardware

| Component | Description | Interface | Parameters / address | Port |
|-----------|-------------|-----------|----------------------|------|
| **Zybo Z7-20** | Zynq-7000 FPGA development board | - | 125 MHz external clock | - |
| **SparkFun BME680** | Temperature, humidity, and pressure sensor | I²C | address 0x77 | Pmod JC |
| **Digilent Pmod AQS** | Air quality module with CCS811 | I²C | address 0x5B | Pmod JD |
| **Digilent Pmod OLEDrgb** | 96×64 RGB OLED display | SPI | 16-bit color, SSD1331 | Pmod JE |

---

## 🏗️ System architecture

The system is organized as a hierarchical set of Verilog modules connected by the top-level module `weathermatrix_top`.

### High-level structure

```text
weathermatrix_top
├── i2cmaster        (instance #1 for BME680)
├── i2cmaster        (instance #2 for Pmod AQS / CCS811)
├── bme680driver
├── ccs811driver
├── displayformatter
├── fontrom
└── oledfinal
```

The design can be divided into three layers:
- data acquisition,
- data formatting,
- visual presentation.

Sensor drivers produce numerical values, the formatter turns them into ASCII characters stored in a text buffer, and the OLED controller renders those characters on the screen.

---

## 🔌 Interfaces and communication

### I²C buses

The design uses two separate **100 kHz I²C buses**. Each sensor has its own master instance, which eliminates mutual blocking between transactions.

A key design decision was to implement I²C as a **monolithic transaction FSM**. This means the complete transaction sequence is handled as a single uninterrupted hardware process:
- START,
- address,
- register pointer write,
- optional repeated START,
- data read,
- STOP.

### SPI display link

The **Pmod OLEDrgb** is driven through SPI. The `oledfinal` module handles both SSD1331 initialization and pixel transmission.

### Open-drain signaling

I²C lines are implemented using tri-state control, where logic low is actively driven and logic high is represented by high impedance, with pull-ups defined in constraints.

---

## ✅ Features

### Switch behavior

| Switch | Function |
|--------|----------|
| **SW3 ↑** | Enable the system |
| **SW3 ↓** | Disable the system and blank the display |
| **SW1:SW0 = 00** | BME680 temperature |
| **SW1:SW0 = 01** | BME680 humidity |
| **SW1:SW0 = 10** | BME680 pressure |
| **SW1:SW0 = 11** | AQS data / diagnostic mode |

### LED indicators

| LED | Meaning |
|-----|---------|
| **LD0** | System enabled |
| **LD1** | OLED initialized |
| **LD2** | BME680 I²C response detected |
| **LD3** | Pmod AQS I²C response detected |

### Additional behavior

- Display refresh every **~500 ms**.
- Reset using **BTN0**.
- Parallel sensor communication paths.
- Hardware diagnostics for the CCS811-based module.
- Character-based rendering on a 12×8 text screen.

---

## 📦 Verilog module structure

### `weathermatrix_top`
Top-level integration module responsible for synchronization, routing, and status signaling.

### `i2cmaster`
Reusable monolithic I²C controller supporting write, register read, ACK/NACK handling, and repeated start.

### `bme680driver`
Environmental sensor driver handling sensor configuration, forced measurement, data readout, and scaling.

### `ccs811driver`
CCS811 driver with wake-up, HWID verification, APP_START sequence, measurement mode setup, and diagnostic handling.

### `displayformatter`
Text generation module converting numeric data into ASCII and writing it into the text buffer.

### `fontrom`
8×8 character ROM used by the OLED renderer.

### `oledfinal`
SSD1331 OLED driver with inline SPI transmitter and character rendering engine.

---

## ⚙️ Module behavior

### BME680 path

The BME680 driver cyclically:
1. writes configuration registers,
2. starts a forced measurement,
3. waits for conversion,
4. reads raw data,
5. combines the bytes into 20-bit and 16-bit values,
6. scales them to user-readable units.

The current implementation uses empirically tuned fixed-point formulas matched to the tested sensor instance. This approach keeps the design compact and sufficient for academic demonstration purposes.

### CCS811 / Pmod AQS path

The CCS811 driver performs wake-up, HWID read, STATUS inspection, APP_START, MEAS_MODE setup, and cyclic measurement polling. In the tested hardware configuration, the module acknowledges I²C traffic but returns `0x00` from the HWID register instead of the expected `0x81`.

As a result, this part of the project also serves as a practical example of embedded hardware diagnostics performed entirely in programmable logic.

### OLED path

The OLED controller initializes the SSD1331 and renders a 12×8 text buffer onto the 96×64 screen using an 8×8 bitmap font.

---

## 🕹️ User operation

```text
1. Connect the hardware modules:
   - BME680 -> JC
   - Pmod AQS -> JD
   - Pmod OLEDrgb -> JE

2. Program the Zybo Z7-20 board with the generated bitstream.

3. Set SW3 high:
   - LD0 turns on immediately,
   - LD1 lights up after OLED initialization,
   - LD2 and LD3 indicate I²C status.

4. Use SW1 and SW0 to select the displayed mode.

5. Use BTN0 to reset the system if needed.
```

The design is intended to be simple to demonstrate during laboratory evaluation. The current state of the system is visible directly through LEDs and the OLED display.

---

## 🔬 Diagnostics and issues

The most important issue encountered during development was a flawed early I²C controller architecture. The first version split transactions into separate START, WRITE, READ, and STOP primitives, allowing the bus lines to return to idle between stages.

In I²C, such behavior may unintentionally generate a STOP condition. In practice, this broke communication and caused readouts of `0xFF`.

The solution was to redesign the controller as a **single monolithic FSM** covering the entire transaction from START to STOP. After this fix, the BME680 started responding correctly and produced meaningful live data.

A separate issue was found in the tested **Pmod AQS** module. The CCS811 chip:
- acknowledges I²C transactions,
- but returns `0x00` from HWID,
- and does not enter valid application mode.

The most likely conclusion is a hardware fault in the tested module, while the driver itself is complete and ready for use with a functional sensor board.

---

## 📊 Measurement results

Example measurements displayed by the system include:
- temperature in °C,
- relative humidity in %,
- atmospheric pressure in hPa.

The screen is updated periodically, which gives the user the impression of a real-time weather station running entirely in FPGA logic.

---

## 🗂️ Repository structure

```text
weather-matrix-fpga/
├── README.md
├── src/
│   ├── weathermatrix_top.v
│   ├── i2cmaster.v
│   ├── bme680driver.v
│   ├── ccs811driver.v
│   ├── displayformatter.v
│   ├── fontrom.v
│   └── oledfinal.v
├── constraints/
│   └── zybo_weather_matrix.xdc
├── vivado/
│   └── weather_matrix.xpr
├── docs/
│   └── report.pdf
└── media/
    ├── system_overview.jpg
    ├── hardware_connections.jpg
    ├── demo_temperature.jpg
    ├── demo_pressure.jpg
    └── demo_humidity.jpg
```

This repository structure is recommended for clarity and clean project presentation on GitHub.

---

## 🚀 Quick start

### Requirements

- **Vivado 2025.2**
- Digilent **Zybo Z7-20**
- **SparkFun BME680**
- **Digilent Pmod AQS**
- **Digilent Pmod OLEDrgb**

### Steps

```bash
# 1. Clone the repository
git clone https://github.com/TWOJ_USERNAME/weather-matrix-fpga.git
cd weather-matrix-fpga

# 2. Open the Vivado project
# File -> Open Project -> select the .xpr file

# 3. Run synthesis and implementation
# Flow -> Run Synthesis
# Flow -> Run Implementation

# 4. Generate the bitstream
# Flow -> Generate Bitstream

# 5. Program the board
# Open Hardware Manager -> Program Device
```

---

## 🔭 Possible extensions

Potential improvements include:

- full Bosch BME680 compensation algorithm,
- historical data storage in BRAM or on SD card,
- chart-based display instead of plain text,
- UART, USB, or Ethernet export,
- threshold alarms for air quality,
- hybrid PL + PS architecture using the ARM cores inside Zynq.

---

## 👥 Authors

| Name | Student ID |
|------|------------|
| **Wiktor Zieliński** | 11854 |
| **Wiktor Dams** | 11864 |
| **Kamil Mańka** | 11137 |

**Supervisor:** mgr inż. Igor Mielczarek  
**University:** Akademia Wojsk Lądowych im. gen. Tadeusza Kościuszki we Wrocławiu  
**Academic year:** 2025/2026

---

## 📄 License

Academic project prepared for the course **Digital Logic Design** / **Logika Układów Cyfrowych**.
