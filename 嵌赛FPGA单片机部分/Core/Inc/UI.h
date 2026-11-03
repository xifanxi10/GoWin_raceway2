#ifndef __UI_H
#define __UI_H

#include <stdint.h>
#include "stm32f4xx_hal.h"
#include "lcd_fonts.h"
#include "ltdc.h"

/*------------------------------- 颜色定义 --------------------------------*/
#define UI_BLUE         0xff0000FF
#define UI_RED          0xffFF0000
#define UI_PINK         0xffFF69B4
#define UI_YELLOW       0xffffff00
#define UI_CYAN         0xff00FFFF
#define UI_GREEN        0xff00FF00
#define UI_WHITE        0xffffffff
#define UI_BLACK        0xff000000
#define UI_LIGHT_GREY   0xffD3D3D3
#define UI_DARK_GREY    0xff808080

/*------------------------------- 页面枚举 --------------------------------*/
typedef enum {
    PAGE_SPLASH,
    PAGE_MAIN,
    PAGE_PAGE1,
    PAGE_PAGE2,
    PAGE_PAGE3,
    PAGE_PAGE4,
    PAGE_PAGE5,
    PAGE_PAGE6,
    PAGE_MAX
} UI_Page_t;

/*------------------------------- 界面函数声明 ----------------------------*/
void UI_SplashScreen(void);
void UI_LoadingScreen(void);
void UI_MainMenu(void);
void UI_PageTemplate(uint8_t pageNum);

void UI_Init(void);
void UI_Task(void);
void UI_DataReady(void);

#endif