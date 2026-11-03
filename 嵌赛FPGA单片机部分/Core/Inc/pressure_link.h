#ifndef PRESSURE_LINK_H
#define PRESSURE_LINK_H

#include "main.h"
#include "instrument_protocol.h"
#include <stdint.h>

typedef enum {
    PRESSURE_LINK_MODE_ADC=0,
    PRESSURE_LINK_MODE_TOUCH_PIANO=1
} PressureLinkMode;

void PressureLink_Init(void);
/* Enqueue only the newest snapshot. The caller may reuse values after return. */
HAL_StatusTypeDef PressureLink_Submit(const uint16_t values[8], uint16_t sequence);
HAL_StatusTypeDef PressureLink_SubmitTouchPiano(const uint16_t force[12],
                                                uint16_t sequence,
                                                uint8_t base_note,
                                                uint16_t pressed_mask);
HAL_StatusTypeDef PressureLink_SubmitPiano48(
    const uint16_t groups[PIANO48_GROUP_COUNT], uint16_t sequence);
void PressureLink_SetMode(PressureLinkMode mode);
PressureLinkMode PressureLink_GetMode(void);
uint32_t PressureLink_GetDroppedFrameCount(void);
uint32_t PressureLink_GetErrorCount(void);
uint32_t PressureLink_GetSentCount(void);
void PressureLink_Service(void);
void PressureLink_TxComplete(void);
void PressureLink_Error(void);

#endif
