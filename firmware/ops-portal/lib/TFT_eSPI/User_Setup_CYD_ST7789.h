// CYD-like TFT_eSPI setup (ST7789)
// Some 2.8" ESP32-2432S028 clones ship with ST7789 instead of ILI9341.
#define USER_SETUP_INFO "CYD 2.8 ST7789"

#define ST7789_DRIVER

#define TFT_MISO 19
#define TFT_MOSI 23
#define TFT_SCLK 18
#define TFT_CS   15
#define TFT_DC   2
#define TFT_RST  4
#define TFT_BL   21

#define TFT_WIDTH  240
#define TFT_HEIGHT 320

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

