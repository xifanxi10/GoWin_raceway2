#ifndef PCA9555_KEYS_H
#define PCA9555_KEYS_H

#include <stdint.h>

#define PCA9555_DEVICE_COUNT 4U
#define PCA9555_KEYS_PER_DEVICE 12U

uint8_t PCA9555Keys_Init(void);
void PCA9555Keys_Service(uint32_t now_ms);
uint16_t PCA9555Keys_GetRawMask(void);
void PCA9555Keys_GetGroups(uint16_t groups[PCA9555_DEVICE_COUNT]);
uint8_t PCA9555Keys_GetOnlineMask(void);
uint8_t PCA9555Keys_IsOnline(void);
uint32_t PCA9555Keys_GetReadCount(void);
uint32_t PCA9555Keys_GetErrorCount(void);

#endif
