// CYD (ESP32-2432S028) TFT_eSPI setup (ILI9341, alternate reset wiring)
// Some clones have TFT reset tied to EN (no GPIO reset line). Use TFT_RST=-1.
#define USER_SETUP_INFO "CYD 2.8 ILI9341 (RST=-1)"

#define ILI9341_DRIVER

#define TFT_MISO 19
#define TFT_MOSI 23
#define TFT_SCLK 18
#define TFT_CS   15
#define TFT_DC   2
#define TFT_RST  -1
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

