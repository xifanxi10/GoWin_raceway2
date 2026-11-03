#include "pressure_acq.h"
#include "adc.h"
#include "tim.h"

/* DMA must access ordinary SRAM; this buffer is intentionally not in CCM. */
static uint16_t adc_dma_buffer[PRESSURE_ADC_DMA_LENGTH] __attribute__((aligned(4)));
static uint16_t snapshot_buffer[2][PRESSURE_CHANNEL_COUNT];
static volatile uint8_t published_buffer;
static volatile uint8_t snapshot_pending;
static volatile uint16_t snapshot_sequence;
static volatile uint32_t dma_error_count;
volatile uint32_t pressure_adc_overruns, pressure_adc_errors, pressure_samples;
volatile uint8_t pressure_adc_running;

static void PressureAcq_Publish(const uint16_t *source)
{
    uint8_t write_buffer = (uint8_t)(published_buffer ^ 1U);
    uint8_t i;

    if(!pressure_adc_running) return;
    for (i = 0U; i < PRESSURE_CHANNEL_COUNT; ++i)
    {
        snapshot_buffer[write_buffer][i] = source[i] & 0x0FFFU;
    }
    snapshot_sequence++;
    published_buffer = write_buffer;
    snapshot_pending = 1U;
    pressure_samples++;
}

HAL_StatusTypeDef PressureAcq_Start(void)
{
    HAL_StatusTypeDef status;

    published_buffer = 0U;
    snapshot_pending = 0U;
    snapshot_sequence = 0U;
    dma_error_count = 0U;

    status = HAL_ADC_Start_DMA(&hadc1, (uint32_t *)adc_dma_buffer,
                               PRESSURE_ADC_DMA_LENGTH);
    if (status != HAL_OK)
    {
        return status;
    }

    status = HAL_TIM_Base_Start(&htim3);
    if (status != HAL_OK)
    {
        (void)HAL_ADC_Stop_DMA(&hadc1);
    }
    pressure_adc_running = (status == HAL_OK);
    return status;
}

uint8_t PressureAcq_TakeSnapshot(uint16_t values[PRESSURE_CHANNEL_COUNT],
                                 uint16_t *sequence)
{
    uint8_t i;
    uint8_t buffer;
    uint16_t seq;
    uint32_t mask;

    if ((values == NULL) || (sequence == NULL))
    {
        return 0U;
    }

    mask = __get_PRIMASK();
    __disable_irq();
    if (snapshot_pending == 0U)
    {
        __set_PRIMASK(mask);
        return 0U;
    }
    buffer = published_buffer;
    seq = snapshot_sequence;
    for (i = 0U; i < PRESSURE_CHANNEL_COUNT; ++i)
    {
        values[i] = snapshot_buffer[buffer][i];
    }
    snapshot_pending = 0U;
    __set_PRIMASK(mask);

    *sequence = seq;
    return 1U;
}

uint32_t PressureAcq_GetDmaErrorCount(void)
{
    return dma_error_count;
}

void HAL_ADC_ConvHalfCpltCallback(ADC_HandleTypeDef *hadc)
{
    if ((hadc != NULL) && (hadc->Instance == ADC1))
    {
        PressureAcq_Publish(&adc_dma_buffer[0]);
    }
}

void HAL_ADC_ConvCpltCallback(ADC_HandleTypeDef *hadc)
{
    if ((hadc != NULL) && (hadc->Instance == ADC1))
    {
        PressureAcq_Publish(&adc_dma_buffer[PRESSURE_CHANNEL_COUNT]);
    }
}

void HAL_ADC_ErrorCallback(ADC_HandleTypeDef *hadc)
{
    if ((hadc != NULL) && (hadc->Instance == ADC1))
    {
        if(hadc->ErrorCode & HAL_ADC_ERROR_DMA) dma_error_count++;
        if(hadc->ErrorCode & HAL_ADC_ERROR_OVR) pressure_adc_overruns++;
        pressure_adc_errors++;
        pressure_adc_running=0;
        __HAL_TIM_DISABLE(&htim3);
    }
}
