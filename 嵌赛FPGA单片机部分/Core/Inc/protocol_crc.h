#ifndef PROTOCOL_CRC_H
#define PROTOCOL_CRC_H

#include <stdint.h>
#include <stddef.h>

/* CRC-16/CCITT-FALSE: poly 0x1021, init 0xFFFF, no reflection. */
uint16_t Protocol_Crc16CcittFalse(const uint8_t *data, size_t length);

#endif
