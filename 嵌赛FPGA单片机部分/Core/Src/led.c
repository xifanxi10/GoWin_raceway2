/***
	************************************************************************************************
	*	@file  	led.c
	*	@version V1.0
	*  @date    2019-12-25
	*	@author  反客科技
	*	@brief   LED接口相关函数	
   ************************************************************************************************
   *  @description
	*
	*	实验平台：反客STM32F429BIT6核心板 （型号：FK429M1）
	*	淘宝地址：https://shop212360197.taobao.com
	*	QQ交流群：536665479
	*
>>>>> 文件说明：
	*
	*	初始化LED的IO口，配置为推挽输出、上拉、速度等级2M。
	*
	************************************************************************************************
***/

#include "stm32f4xx_hal.h"
#include "led.h"  


void LED_Init(void)
{
	GPIO_InitTypeDef GPIO_InitStruct = {0};

	__HAL_RCC_LED1_CLK_ENABLE;		// 初始化LED1 GPIO时钟	
	__HAL_RCC_LED2_CLK_ENABLE;		// 初始化LED2 GPIO时钟

	HAL_GPIO_WritePin(LED1_PORT, LED1_PIN, GPIO_PIN_RESET);		// LED1引脚输出低，即点亮LED1
	HAL_GPIO_WritePin(LED2_PORT, LED2_PIN, GPIO_PIN_RESET);		// LED2引脚输出低，即点亮LED2

	GPIO_InitStruct.Pin 		= LED1_PIN;					// LED1引脚
	GPIO_InitStruct.Mode 	= GPIO_MODE_OUTPUT_PP;	// 推挽输出模式
	GPIO_InitStruct.Pull 	= GPIO_NOPULL;				// 不上下拉
	GPIO_InitStruct.Speed 	= GPIO_SPEED_FREQ_LOW;	// 低速模式
	HAL_GPIO_Init(LED1_PORT, &GPIO_InitStruct);

	GPIO_InitStruct.Pin = LED2_PIN;						// LED2引脚
	HAL_GPIO_Init(LED2_PORT, &GPIO_InitStruct);

}

