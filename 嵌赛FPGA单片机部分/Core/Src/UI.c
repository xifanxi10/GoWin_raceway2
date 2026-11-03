#include "ui.h"
#include "touch_800x480.h"
#include "key.h"
#include <string.h>
#include <stdio.h>
#include "UI_Data.h"
/*------------------------------- 全局参数 --------------------------------*/
static UI_Page_t currentPage = PAGE_SPLASH;

typedef struct {
    uint16_t x, y, w, h;
    const char *label;
    UI_Page_t targetPage;
} UI_Button_t;

static UI_Button_t mainButtons[] = {
    { 110, 180, 160, 60, "1", PAGE_PAGE1 },
    { 320, 180, 160, 60, "2", PAGE_PAGE2 },
    { 530, 180, 160, 60, "3", PAGE_PAGE3 },
    { 110, 290, 160, 60, "4", PAGE_PAGE4 },
    { 320, 290, 160, 60, "5", PAGE_PAGE5 },
    { 530, 290, 160, 60, "6", PAGE_PAGE6 },
};
#define MAIN_BTN_NUM (sizeof(mainButtons) / sizeof(mainButtons[0]))

static UI_Button_t backButton = { 20, 420, 120, 50, "Back", PAGE_MAIN };

/*------------------------------- 通用页面绘制 ----------------------------*/

// 绘制页眉（标题 + 返回按钮）
static void DrawPageHeader(const char *title)
{
    LCD_SetBackColor(UI_DARK_GREY);
    LCD_ClearRect(0, 0, 800, 60);
    LCD_SetBackColor(UI_WHITE);
    LCD_ClearRect(0, 60, 800, 420);

    LCD_SetTextFont(&CH_Font32);
    LCD_SetColor(UI_BLACK);
    LCD_DisplayText(20, 10, (char *)title);

    // 返回按钮（仅在非主菜单页面绘制）
    if (currentPage != PAGE_MAIN) {
        LCD_SetColor(UI_LIGHT_GREY);
        LCD_FillRect(backButton.x, backButton.y, backButton.w, backButton.h);
        LCD_SetColor(UI_BLACK);
        LCD_DrawRect(backButton.x, backButton.y, backButton.w, backButton.h);
        LCD_SetTextFont(&CH_Font24);
        LCD_DisplayText(backButton.x + 30, backButton.y + 10, (char *)backButton.label);
    }
}

/*------------------------------- 各页面实现 ----------------------------*/

// 启动画面
void UI_SplashScreen(void)
{
    LCD_SetBackColor(UI_WHITE);
    LCD_Clear();

    LCD_SetTextFont(&CH_Font32);
    LCD_SetColor(UI_BLACK);
    LCD_DisplayText(100, 120, (char *)"2026电赛");

    LCD_SetTextFont(&CH_Font32);
    LCD_SetColor(UI_RED);
    LCD_DisplayText(130, 240, (char *)"组员:");

    LCD_SetTextFont(&CH_Font32);
    LCD_SetColor(UI_BLUE);
    LCD_DisplayText(220, 240, (char *)"1  2  3");

    HAL_Delay(2000);
}

// 加载画面
void UI_LoadingScreen(void)
{
    LCD_SetBackColor(UI_WHITE);
    LCD_Clear();
    LCD_SetTextFont(&CH_Font32);
    LCD_SetColor(UI_BLACK);
    LCD_DisplayString((LCD_Width - 9 * 16) / 2, 200, (char *)"Loading...");
    HAL_Delay(1000);
}

// 主菜单
void UI_MainMenu(void)
{
    LCD_SetBackColor(UI_WHITE);
    LCD_Clear();

    LCD_SetTextFont(&CH_Font32);
    LCD_SetColor(UI_BLUE);
    LCD_DisplayText(200, 20, (char *)"电赛UI");

    // 绘制6个数字按钮
    for (int i = 0; i < MAIN_BTN_NUM; i++) {
        UI_Button_t *btn = &mainButtons[i];
        LCD_SetColor(UI_LIGHT_GREY);
        LCD_FillRect(btn->x, btn->y, btn->w, btn->h);
        LCD_SetColor(UI_BLACK);
        LCD_DrawRect(btn->x, btn->y, btn->w, btn->h);
        LCD_SetTextFont(&CH_Font32);
        LCD_SetColor(UI_BLACK);
        LCD_DisplayText(btn->x + (btn->w - 12)/2, btn->y + 10, (char *)btn->label);
    }
}

//// 页面1：波形选择
//static void UI_Page1(void)
//{
//    DrawPageHeader("Waveform");


//}

//// 页面2：频谱图（曲线形式，标注坐标轴，显示各次谐波和THD）
//static void UI_Page2(void)
//{
//    DrawPageHeader("Spectrum");
//}



// 子页面模板（页面3~6）
void UI_PageTemplate(uint8_t pageNum)
{
    char title[16];
    sprintf(title, "Page %d", pageNum);
    DrawPageHeader(title);
    LCD_SetTextFont(&CH_Font32);
    LCD_SetColor(UI_BLACK);
}

/*------------------------------- 页面切换 ----------------------------*/
static void SwitchToPage(UI_Page_t page)
{
    currentPage = page;
    switch (page) {
        case PAGE_MAIN:   UI_MainMenu(); break;
//        case PAGE_PAGE1:  UI_Page1(); break;
//        case PAGE_PAGE2:  UI_Page2(); break;
        case PAGE_PAGE3:  UI_PageTemplate(3); break;
        case PAGE_PAGE4:  UI_PageTemplate(4); break;
        case PAGE_PAGE5:  UI_PageTemplate(5); break;
        case PAGE_PAGE6:  UI_PageTemplate(6); break;
        default: break;
    }
}

/*------------------------------- 触摸和按键处理 ------------------------*/
static void HandleTouch(void)
{
    Touch_Scan();
    if (touchInfo.flag && touchInfo.num > 0) {
        uint16_t x = touchInfo.x[0];
        uint16_t y = touchInfo.y[0];

        if (currentPage == PAGE_MAIN) {
            for (int i = 0; i < MAIN_BTN_NUM; i++) {
                UI_Button_t *btn = &mainButtons[i];
                if (x >= btn->x && x <= btn->x + btn->w &&
                    y >= btn->y && y <= btn->y + btn->h) {
                    SwitchToPage(btn->targetPage);
                    return;
                }
            }
        }
        // 公共返回按钮检测（所有非主菜单页面）
        if (currentPage != PAGE_MAIN) {
            if (x >= backButton.x && x <= backButton.x + backButton.w &&
                y >= backButton.y && y <= backButton.y + backButton.h) {
                SwitchToPage(PAGE_MAIN);
                return;
            }
        }
    }
}

/*------------------------------- UI 外部接口 ----------------------------*/
void UI_Init(void)
{
    LCD_DisplayDirection(Direction_H);
    LCD_SetBackColor(UI_WHITE);
    LCD_Clear();

    UI_SplashScreen();
    UI_LoadingScreen();

    currentPage = PAGE_MAIN;
    UI_MainMenu();
}

void UI_Task(void)
{
    HandleTouch();

    // 按键备用：任意子页面按物理按键返回主菜单
    if (KEY_Scan() == KEY_ON) {
        if (currentPage != PAGE_MAIN) {
            SwitchToPage(PAGE_MAIN);
        }
    }

//    UI_DataTask(currentPage);
    HAL_Delay(10);
}