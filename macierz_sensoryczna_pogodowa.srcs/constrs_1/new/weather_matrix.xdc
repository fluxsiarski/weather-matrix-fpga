## weather_matrix.xdc
## Constraints dla projektu Weather Matrix na Zybo Z7-20.
## VCCEN i PMODEN mają PULLDOWN - chronią OLED przed przypadkowym zasileniem
## podczas ładowania bitstreamu.

## Piny nieużywane w stanie HIGH-Z z pull-down przez cały czas konfiguracji
set_property BITSTREAM.GENERAL.UNUSEDPIN PULLDOWN [current_design]
set_property BITSTREAM.CONFIG.UNUSEDPIN  PULLDOWN [current_design]

## Zegar systemowy 125 MHz (K17)
set_property -dict { PACKAGE_PIN K17  IOSTANDARD LVCMOS33 } [get_ports { sysclk }];
create_clock -add -name sys_clk_pin -period 8.00 -waveform {0 4} [get_ports { sysclk }];

## Przełączniki SW0..SW3
set_property -dict { PACKAGE_PIN G15  IOSTANDARD LVCMOS33 } [get_ports { sw[0] }];
set_property -dict { PACKAGE_PIN P15  IOSTANDARD LVCMOS33 } [get_ports { sw[1] }];
set_property -dict { PACKAGE_PIN W13  IOSTANDARD LVCMOS33 } [get_ports { sw[2] }];
set_property -dict { PACKAGE_PIN T16  IOSTANDARD LVCMOS33 } [get_ports { sw[3] }];

## Przyciski BTN0..BTN3 (BTN0 = reset aktywny niski)
set_property -dict { PACKAGE_PIN K18  IOSTANDARD LVCMOS33 } [get_ports { btn[0] }];
set_property -dict { PACKAGE_PIN P16  IOSTANDARD LVCMOS33 } [get_ports { btn[1] }];
set_property -dict { PACKAGE_PIN K19  IOSTANDARD LVCMOS33 } [get_ports { btn[2] }];
set_property -dict { PACKAGE_PIN Y16  IOSTANDARD LVCMOS33 } [get_ports { btn[3] }];

## LED LD0..LD3
set_property -dict { PACKAGE_PIN M14  IOSTANDARD LVCMOS33 } [get_ports { led[0] }];
set_property -dict { PACKAGE_PIN M15  IOSTANDARD LVCMOS33 } [get_ports { led[1] }];
set_property -dict { PACKAGE_PIN G14  IOSTANDARD LVCMOS33 } [get_ports { led[2] }];
set_property -dict { PACKAGE_PIN D18  IOSTANDARD LVCMOS33 } [get_ports { led[3] }];

## Pmod JC - BME680 I2C (PULLUP: wymagane przez magistralę I2C)
set_property -dict { PACKAGE_PIN V15  IOSTANDARD LVCMOS33 PULLUP true } [get_ports { bme_sda }];
set_property -dict { PACKAGE_PIN W15  IOSTANDARD LVCMOS33 PULLUP true } [get_ports { bme_scl }];

## Pmod JD - Pmod AQS / CCS811 I2C
set_property -dict { PACKAGE_PIN T14  IOSTANDARD LVCMOS33 }             [get_ports { aqs_int  }];
set_property -dict { PACKAGE_PIN T15  IOSTANDARD LVCMOS33 }             [get_ports { aqs_wake }];
set_property -dict { PACKAGE_PIN P14  IOSTANDARD LVCMOS33 PULLUP true } [get_ports { aqs_scl  }];
set_property -dict { PACKAGE_PIN R14  IOSTANDARD LVCMOS33 PULLUP true } [get_ports { aqs_sda  }];

## Pmod JE - Pmod OLEDrgb SPI
## oled_vccen i oled_pmoden: PULLDOWN zapobiega zasileniu OLED przed uruchomieniem logiki
set_property -dict { PACKAGE_PIN V12  IOSTANDARD LVCMOS33             } [get_ports { oled_cs     }];
set_property -dict { PACKAGE_PIN W16  IOSTANDARD LVCMOS33             } [get_ports { oled_mosi   }];
set_property -dict { PACKAGE_PIN H15  IOSTANDARD LVCMOS33             } [get_ports { oled_sck    }];
set_property -dict { PACKAGE_PIN V13  IOSTANDARD LVCMOS33             } [get_ports { oled_dc     }];
set_property -dict { PACKAGE_PIN U17  IOSTANDARD LVCMOS33             } [get_ports { oled_res    }];
set_property -dict { PACKAGE_PIN T17  IOSTANDARD LVCMOS33 PULLDOWN true } [get_ports { oled_vccen  }];
set_property -dict { PACKAGE_PIN Y17  IOSTANDARD LVCMOS33 PULLDOWN true } [get_ports { oled_pmoden }];

## Pin JE-3 (J15) nie jest używany przez OLEDrgb - obsłużony przez globalny PULLDOWN

## Napięcie konfiguracji FPGA
set_property CFGBVS VCCO        [current_design]
set_property CONFIG_VOLTAGE 3.3 [current_design]