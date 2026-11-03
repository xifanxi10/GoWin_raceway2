#include "protocol_crc.h"

uint16_t Protocol_Crc16CcittFalse(const uint8_t *data, size_t length)
{
    uint16_t crc = 0xFFFFU;
    size_t i;

    if (data == NULL)
    {
        return crc;
    }

    for (i = 0U; i < length; ++i)
    {
        uint8_t bit;
        crc ^= (uint16_t)data[i] << 8;
        for (bit = 0U; bit < 8U; ++bit)
        {
            if ((crc & 0x8000U) != 0U)
            {
                crc = (uint16_t)((crc << 1) ^ 0x1021U);
            }
            else
            {
                crc <<= 1;
            }
        }
    }
    return crc;
}
