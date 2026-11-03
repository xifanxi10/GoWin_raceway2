#include "pca9555_bus.h"

static void BusDelay(void)
{
    volatile uint32_t i;
    for (i = 0U; i < PCA9555_BUS_DELAY_CYCLES; ++i)
    {
        __NOP();
    }
}

static void Scl(uint8_t high)
{
    HAL_GPIO_WritePin(PCA9555_BUS_SCL_PORT, PCA9555_BUS_SCL_PIN,
                      high ? GPIO_PIN_SET : GPIO_PIN_RESET);
}

static void Sda(uint8_t high)
{
    HAL_GPIO_WritePin(PCA9555_BUS_SDA_PORT, PCA9555_BUS_SDA_PIN,
                      high ? GPIO_PIN_SET : GPIO_PIN_RESET);
}

static void Start(void)
{
    Sda(1U);
    Scl(1U);
    BusDelay();
    Sda(0U);
    BusDelay();
    Scl(0U);
}

static void Stop(void)
{
    Sda(0U);
    BusDelay();
    Scl(1U);
    BusDelay();
    Sda(1U);
    BusDelay();
}

static uint8_t WriteByte(uint8_t value)
{
    uint8_t i;
    for (i = 0U; i < 8U; ++i)
    {
        Sda((uint8_t)((value & 0x80U) != 0U));
        BusDelay();
        Scl(1U);
        BusDelay();
        Scl(0U);
        value <<= 1U;
    }
    Sda(1U);
    BusDelay();
    Scl(1U);
    BusDelay();
    i = (uint8_t)(HAL_GPIO_ReadPin(PCA9555_BUS_SDA_PORT,
                                  PCA9555_BUS_SDA_PIN) == GPIO_PIN_RESET);
    Scl(0U);
    BusDelay();
    return i;
}

static uint8_t ReadByte(uint8_t acknowledge)
{
    uint8_t i;
    uint8_t value = 0U;
    Sda(1U);
    for (i = 0U; i < 8U; ++i)
    {
        value <<= 1U;
        Scl(1U);
        BusDelay();
        if (HAL_GPIO_ReadPin(PCA9555_BUS_SDA_PORT,
                            PCA9555_BUS_SDA_PIN) == GPIO_PIN_SET)
        {
            value |= 1U;
        }
        Scl(0U);
        BusDelay();
    }
    Sda((uint8_t)!acknowledge);
    BusDelay();
    Scl(1U);
    BusDelay();
    Scl(0U);
    Sda(1U);
    return value;
}

void PCA9555Bus_Init(void)
{
    GPIO_InitTypeDef GPIO_InitStruct = {0};
    uint8_t i;

    PCA9555_BUS_GPIO_CLOCK_ENABLE();
    GPIO_InitStruct.Mode = GPIO_MODE_OUTPUT_OD;
    GPIO_InitStruct.Pull = GPIO_NOPULL;
    GPIO_InitStruct.Speed = GPIO_SPEED_FREQ_HIGH;
    GPIO_InitStruct.Pin = PCA9555_BUS_SCL_PIN;
    HAL_GPIO_Init(PCA9555_BUS_SCL_PORT, &GPIO_InitStruct);
    GPIO_InitStruct.Pin = PCA9555_BUS_SDA_PIN;
    HAL_GPIO_Init(PCA9555_BUS_SDA_PORT, &GPIO_InitStruct);
    Sda(1U);
    for (i = 0U; i < 9U; ++i)
    {
        Scl(0U);
        BusDelay();
        Scl(1U);
        BusDelay();
    }
    Stop();
}

uint8_t PCA9555Bus_Write(uint8_t address_7bit, uint8_t reg,
                         const uint8_t *data, uint8_t length)
{
    uint8_t i;
    if ((data == 0) || (length == 0U) || (address_7bit > 0x7FU))
    {
        return 0U;
    }
    Start();
    if (!WriteByte((uint8_t)(address_7bit << 1U)) || !WriteByte(reg))
    {
        Stop();
        return 0U;
    }
    for (i = 0U; i < length; ++i)
    {
        if (!WriteByte(data[i]))
        {
            Stop();
            return 0U;
        }
    }
    Stop();
    return 1U;
}

uint8_t PCA9555Bus_Read(uint8_t address_7bit, uint8_t reg,
                        uint8_t *data, uint8_t length)
{
    uint8_t i;
    if ((data == 0) || (length == 0U) || (address_7bit > 0x7FU))
    {
        return 0U;
    }
    Start();
    if (!WriteByte((uint8_t)(address_7bit << 1U)) || !WriteByte(reg))
    {
        Stop();
        return 0U;
    }
    Start();
    if (!WriteByte((uint8_t)((address_7bit << 1U) | 1U)))
    {
        Stop();
        return 0U;
    }
    for (i = 0U; i < length; ++i)
    {
        data[i] = ReadByte((uint8_t)(i + 1U < length));
    }
    Stop();
    return 1U;
}
