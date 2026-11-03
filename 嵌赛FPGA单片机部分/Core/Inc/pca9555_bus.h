#ifndef PCA9555_BUS_H
#define PCA9555_BUS_H

#include "main.h"
#include <stdint.h>

/* Change only these board definitions if the PCA9555 is wired elsewhere. */
#define PCA9555_BUS_SCL_PORT GPIOB
#define PCA9555_BUS_SCL_PIN  GPIO_PIN_8
#define PCA9555_BUS_SDA_PORT GPIOB
#define PCA9555_BUS_SDA_PIN  GPIO_PIN_9
#define PCA9555_BUS_GPIO_CLOCK_ENABLE() __HAL_RCC_GPIOB_CLK_ENABLE()

/* Conservative software-I2C delay. Four devices are on one shared bus;
 * keep this >= the value validated with the board pull-ups. */
#ifndef PCA9555_BUS_DELAY_CYCLES
#define PCA9555_BUS_DELAY_CYCLES 180U
#endif

void PCA9555Bus_Init(void);
uint8_t PCA9555Bus_Write(uint8_t address_7bit, uint8_t reg,
                         const uint8_t *data, uint8_t length);
uint8_t PCA9555Bus_Read(uint8_t address_7bit, uint8_t reg,
                        uint8_t *data, uint8_t length);

#endif
