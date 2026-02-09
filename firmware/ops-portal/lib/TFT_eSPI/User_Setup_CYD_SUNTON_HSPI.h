// ESP32-2432S028R (Sunton / many Nerdminer boards) TFT_eSPI setup (ILI9341 over HSPI)
// Common pinout:
//   TFT_SCK=14, TFT_SDO=12, TFT_SDI=13, TFT_CS=15, TFT_DC=2, TFT_RST=EN (use -1), TFT_BL=21
#define USER_SETUP_INFO "ESP32-2432S028R ILI9341 (HSPI 14/12/13/15)"

#define ILI9341_DRIVER

// Use HSPI port instead of VSPI.
#define USE_HSPI_PORT

#define TFT_MISO 12
#define TFT_MOSI 13
#define TFT_SCLK 14
#define TFT_CS   15
#define TFT_DC   2
#define TFT_RST  -1
#define TFT_BL   21

#define TFT_WIDTH  240
#define TFT_HEIGHT 320

// Touch CS/IRQ are still handled in firmware (XPT2046), pins vary by board.
#define TOUCH_CS 33

#define SPI_FREQUENCY  40000000
#define SPI_READ_FREQUENCY  20000000
#define SPI_TOUCH_FREQUENCY  2500000

#define LOAD_GLCD
#define LOAD_FONT2
#define LOAD_FONT4
#define LOAD_FONT6
#define LOAD_FONT7
#define LOAD_FONT8
#define LOAD_GFXFF
#define SMOOTH_FONT

#ifndef TFT_BACKLIGHT_ON
  #define TFT_BACKLIGHT_ON HIGH
#endif

