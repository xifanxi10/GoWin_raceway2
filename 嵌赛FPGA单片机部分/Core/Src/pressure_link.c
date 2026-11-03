#include "pressure_link.h"
#include "instrument_protocol.h"
#include "usart.h"
#include <string.h>
static uint8_t frames[2][TOUCH_PIANO_FRAME_SIZE];
static uint8_t frame_length[2];
static volatile uint8_t busy, pending, active, fault;
static volatile PressureLinkMode mode;
static volatile uint32_t dropped, errors, sent, started_at;
/* Caller holds PRIMASK. HAL never waits here. */
static HAL_StatusTypeDef Start(void)
{
    HAL_StatusTypeDef result;
    busy=1; started_at=HAL_GetTick();
    result=HAL_UART_Transmit_DMA(&huart3,frames[active],frame_length[active]);
    if(result!=HAL_OK) { busy=0; fault=1; errors++; dropped++; }
    return result;
}
void PressureLink_Init(void)
{ busy=pending=active=fault=0; mode=PRESSURE_LINK_MODE_ADC; dropped=errors=sent=0; }

static HAL_StatusTypeDef SubmitFrame(const uint8_t *frame,uint8_t length,
                                     PressureLinkMode required_mode)
{
    uint32_t mask; HAL_StatusTypeDef result=HAL_OK;
    mask=__get_PRIMASK(); __disable_irq();
    if(mode!=required_mode) result=HAL_BUSY;
    else if(fault) { dropped++; result=HAL_ERROR; }
    else if(!busy) {
        memcpy(frames[active],frame,length); frame_length[active]=length;
        result=Start();
    } else {
        uint8_t next=(uint8_t)(active^1U);
        if(pending) dropped++;
        memcpy(frames[next],frame,length); frame_length[next]=length; pending=1;
    }
    __set_PRIMASK(mask); return result;
}

HAL_StatusTypeDef PressureLink_Submit(const uint16_t v[8],uint16_t seq)
{
    uint8_t frame[PRESSURE_FRAME_SIZE];
    if(!v) return HAL_ERROR;
    Protocol_Pressure(frame,v,seq);
    return SubmitFrame(frame,PRESSURE_FRAME_SIZE,PRESSURE_LINK_MODE_ADC);
}
HAL_StatusTypeDef PressureLink_SubmitTouchPiano(const uint16_t force[12],
                                                uint16_t seq,
                                                uint8_t base_note,
                                                uint16_t pressed_mask)
{
    uint8_t frame[TOUCH_PIANO_FRAME_SIZE];
    if(!force || base_note>116U) return HAL_ERROR;
    Protocol_TouchPiano(frame,force,seq,base_note,pressed_mask);
    return SubmitFrame(frame,TOUCH_PIANO_FRAME_SIZE,
                       PRESSURE_LINK_MODE_TOUCH_PIANO);
}
HAL_StatusTypeDef PressureLink_SubmitPiano48(
    const uint16_t groups[PIANO48_GROUP_COUNT], uint16_t seq)
{
    uint8_t frame[PIANO48_FRAME_SIZE];
    Protocol_Piano48(frame, groups, seq);
    return SubmitFrame(frame, PIANO48_FRAME_SIZE,
                       PRESSURE_LINK_MODE_TOUCH_PIANO);
}
void PressureLink_SetMode(PressureLinkMode new_mode)
{
    uint32_t mask=__get_PRIMASK();
    __disable_irq();
    if(mode!=new_mode) {
        mode=new_mode;
        if(pending) { pending=0; dropped++; }
    }
    __set_PRIMASK(mask);
}
PressureLinkMode PressureLink_GetMode(void)
{
    return mode;
}
void PressureLink_TxComplete(void)
{
    uint32_t mask=__get_PRIMASK(); __disable_irq();
    sent++; busy=0;
    if(pending && !fault) { active^=1U; pending=0; (void)Start(); }
    __set_PRIMASK(mask);
}
void PressureLink_Error(void) { errors++; fault=1; }
void PressureLink_Service(void)
{
    uint32_t mask=__get_PRIMASK(); uint8_t recover;
    __disable_irq();
    if(busy && (uint32_t)(HAL_GetTick()-started_at)>5 && !fault) { fault=1; errors++; }
    recover=fault; __set_PRIMASK(mask);
    if(recover) {
        /* fault gates ADC submissions while HAL releases the failed transfer. */
        if(HAL_UART_AbortTransmit(&huart3)==HAL_OK) {
            mask=__get_PRIMASK(); __disable_irq();
            dropped+=busy+pending; busy=pending=fault=0; __set_PRIMASK(mask);
        }
    }
}
uint32_t PressureLink_GetDroppedFrameCount(void) { return dropped; }
uint32_t PressureLink_GetErrorCount(void) { return errors; }
uint32_t PressureLink_GetSentCount(void) { return sent; }
