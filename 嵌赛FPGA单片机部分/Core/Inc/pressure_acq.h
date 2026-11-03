#ifndef PRESSURE_ACQ_H
#define PRESSURE_ACQ_H

#include "main.h"
#include <stdint.h>

#define PRESSURE_CHANNEL_COUNT 12U
#define PRESSURE_ADC_DMA_LENGTH (PRESSURE_CHANNEL_COUNT * 2U)

HAL_StatusTypeDef PressureAcq_Start(void);
/* Copy the newest complete twelve-channel snapshot. Returns 1 if new data exists. */
uint8_t PressureAcq_TakeSnapshot(uint16_t values[PRESSURE_CHANNEL_COUNT],
                                 uint16_t *sequence);
uint32_t PressureAcq_GetDmaErrorCount(void);
extern volatile uint32_t pressure_adc_overruns, pressure_adc_errors, pressure_samples;
extern volatile uint8_t pressure_adc_running;

#endif
