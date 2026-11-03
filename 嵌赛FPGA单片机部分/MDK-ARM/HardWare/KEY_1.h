#ifndef __KEY_1_H
#define __KEY_1_H

#include "main.h"

/* 按键状态返回值宏定义 */
#define KEY_NONE        0  // 无按键按下
#define KEY1_PRESSED    1  // PD3 按下
#define KEY2_PRESSED    2  // PD4 按下
#define KEY3_PRESSED    3  // PD5 按下
#define KEY4_PRESSED    4  // PD6 按下
#define KEY5_PRESSED    5  // PI8 按下（如果有第五个按键的话）

/* * 读取引脚状态的宏定义 
 * 内部带有上拉电阻，按下为低电平 (RESET)
 */
 
 /*************张丽***************/
//#define READ_KEY1   HAL_GPIO_ReadPin(GPIOC, GPIO_PIN_1)
//#define READ_KEY2   HAL_GPIO_ReadPin(GPIOC, GPIO_PIN_2)
//#define READ_KEY3   HAL_GPIO_ReadPin(GPIOC, GPIO_PIN_3)
//#define READ_KEY4   HAL_GPIO_ReadPin(GPIOC, GPIO_PIN_4)
//#define READ_KEY5  HAL_GPIO_ReadPin(GPIOI, GPIO_PIN_8)

/*************席宝森****************/
#define READ_KEY1   HAL_GPIO_ReadPin(GPIOD, GPIO_PIN_3)
#define READ_KEY2   HAL_GPIO_ReadPin(GPIOD, GPIO_PIN_4)
#define READ_KEY3   HAL_GPIO_ReadPin(GPIOD, GPIO_PIN_5)
#define READ_KEY4   HAL_GPIO_ReadPin(GPIOD, GPIO_PIN_6)
#define READ_KEY5  HAL_GPIO_ReadPin(GPIOI, GPIO_PIN_8)


/* 函数声明 */
uint8_t Key_Scan(uint8_t mode);

#endif /* __KEY_H */

