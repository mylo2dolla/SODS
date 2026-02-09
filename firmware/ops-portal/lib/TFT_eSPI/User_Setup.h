// SODS Ops Portal CYD TFT_eSPI setup dispatcher.
// Select a variant via PlatformIO build flag:
//   -D PORTAL_TFT_CYD_ILI9341_RST_MINUS1
//   -D PORTAL_TFT_CYD_ST7789
//
// Default is ILI9341 with TFT_RST=4 (common CYD).

#if defined(PORTAL_TFT_CYD_ST7789)
  #include "User_Setup_CYD_ST7789.h"
#elif defined(PORTAL_TFT_CYD_SUNTON_HSPI)
  #include "User_Setup_CYD_SUNTON_HSPI.h"
#elif defined(PORTAL_TFT_CYD_ILI9341_RST_MINUS1)
  #include "User_Setup_CYD_ILI9341_RST_MINUS1.h"
#else
  #include "User_Setup_CYD_ILI9341.h"
#endif
