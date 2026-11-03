#ifndef __LED_H
#define __LED_H

/*------------------------------------------ LED配置宏 ----------------------------------*/

#define LED1_PIN            			 GPIO_PIN_7        				 	// LED1 引脚      
#define LED1_PORT           			 GPIOG                 			 	// LED1 GPIO端口     
#define __HAL_RCC_LED1_CLK_ENABLE    __HAL_RCC_GPIOD_CLK_ENABLE() 	// LED1 GPIO端口时钟
 
#define LED2_PIN            			 GPIO_PIN_12            			// LED2 引脚             
#define LED2_PORT          			 GPIOD                  			// LED2 GPIO端口          
#define __HAL_RCC_LED2_CLK_ENABLE    __HAL_RCC_GPIOG_CLK_ENABLE()    // LED2 GPIO端口时钟


  
/*----------------------------------------- LED控制宏 ----------------------------------*/
						
#define LED1_ON 	  HAL_GPIO_WritePin(LED1_PORT, LED1_PIN, GPIO_PIN_RESET)		// 输出低电平，点亮LED1	
#define LED1_OFF 	  HAL_GPIO_WritePin(LED1_PORT, LED1_PIN, GPIO_PIN_SET)		// 输出高电平，关闭LED1	

#define LED2_ON 	  HAL_GPIO_WritePin(LED2_PORT, LED2_PIN, GPIO_PIN_RESET)		// 输出低电平，点亮LED2
#define LED2_OFF 	  HAL_GPIO_WritePin(LED2_PORT, LED2_PIN, GPIO_PIN_SET)		// 输出高电平，关闭LED2

/*---------------------------------------- 函数声明 ------------------------------------*/

void LED_Init(void);

#endif //__LED_H


