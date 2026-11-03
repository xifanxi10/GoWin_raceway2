#include "key_1.h"

/**
 * @brief  按键扫描函数 (带软件去抖)
 * @param  mode: 0-不支持连续按压 (按住只算一次) 
 * 1-支持连续按压 (按住不放会持续返回键值)
 * @retval 按下的按键值 (KEY_NONE / KEY1_PRESSED / KEY2_PRESSED / KEY3_PRESSED / KEY4_PRESSED)
 */
uint8_t Key_Scan(uint8_t mode)
{
    // 静态变量，记录按键是否处于松开状态
    static uint8_t key_up = 1; 

    // 如果模式为1，强制认为是松开状态，从而支持连续触发
    if (mode == 1) 
		{
        key_up = 1; 
    }

    // 判断是否有任意一个按键被按下（上拉输入，按下为 RESET）
    if (key_up && (READ_KEY1 == GPIO_PIN_RESET || READ_KEY2 == GPIO_PIN_RESET || 
                   READ_KEY3 == GPIO_PIN_RESET || READ_KEY4 == GPIO_PIN_RESET || READ_KEY5 == GPIO_PIN_RESET))
    {
        HAL_Delay(10);  // 延时 10ms 消抖

        key_up = 0;     // 标记按键已被按下

        // 再次确认哪个按键被按下，并返回对应键值
        if (READ_KEY1 == GPIO_PIN_RESET) 
				{
            return KEY1_PRESSED;
        } 
  			else if (READ_KEY2 == GPIO_PIN_RESET)
				{
            return KEY2_PRESSED;
        }
				else if (READ_KEY3 == GPIO_PIN_RESET) 
				{
            return KEY3_PRESSED;
        }
				else if (READ_KEY4 == GPIO_PIN_RESET) 
				{
            return KEY4_PRESSED;
        }
				else if (READ_KEY5 == GPIO_PIN_RESET) 
				{
            return KEY5_PRESSED;
        }
    }
		
    else if (READ_KEY1 == GPIO_PIN_SET && READ_KEY2 == GPIO_PIN_SET && 
             READ_KEY3 == GPIO_PIN_SET && READ_KEY4 == GPIO_PIN_SET && READ_KEY5 == GPIO_PIN_SET)
    {
        key_up = 1;     // 重置按键松开标志
    }

    return KEY_NONE;    // 无按键按下，返回0
}

