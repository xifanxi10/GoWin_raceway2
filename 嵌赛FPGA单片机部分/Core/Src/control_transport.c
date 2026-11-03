#include "control_transport.h"
#include "pressure_link.h"
#include "viz_link.h"
#include "usart.h"
#include <string.h>
#define RX_DMA_SIZE 128U
#define RX_RING_SIZE 1024U
static uint8_t rx_dma[RX_DMA_SIZE],ring[RX_RING_SIZE],tx_dma[16];
static volatile uint16_t head,tail;
static uint16_t dma_pos;
static volatile uint8_t tx_done,rx_fault;
static volatile uint32_t tx_tick;
static uint32_t restart_at;
static ControlClient *client;
ControlParser control_parser;
volatile uint32_t control_uart_errors,control_rx_dropped,control_start_errors;
int ControlTransport_Init(ControlClient *c)
{
    client=c; head=tail=dma_pos=0; tx_done=rx_fault=0;
    if(HAL_UARTEx_ReceiveToIdle_DMA(&huart1,rx_dma,RX_DMA_SIZE)!=HAL_OK) {
        rx_fault=1; control_start_errors++; return 0;
    }
    return 1;
}
int ControlTransport_Send(const uint8_t *frame,void *context)
{
    uint32_t mask=__get_PRIMASK(); HAL_StatusTypeDef result;
    (void)context;
    __disable_irq();
    tx_done=0;
    result=HAL_ERROR;
    if(!rx_fault && huart1.gState==HAL_UART_STATE_READY) {
        memcpy(tx_dma,frame,16); result=HAL_UART_Transmit_DMA(&huart1,tx_dma,16);
    }
    __set_PRIMASK(mask);
    return result==HAL_OK;
}
void HAL_UARTEx_RxEventCallback(UART_HandleTypeDef *h,uint16_t size)
{
    uint16_t pos;
    if(h!=&huart1 || rx_fault || size>RX_DMA_SIZE) return;
    /* IDLE and DMA HT/TC share preemption priority 4: this producer cannot nest. */
    /* Sample live NDTR: a delayed HT notification must not replay older bytes after IDLE. */
    size=(uint16_t)(RX_DMA_SIZE-__HAL_DMA_GET_COUNTER(huart1.hdmarx));
    if(size==RX_DMA_SIZE) size=0;
    pos=dma_pos;
    while(pos!=size) {
        uint16_t next;
        if(pos==RX_DMA_SIZE) { pos=0; if(pos==size) break; }
        next=(uint16_t)((head+1U)%RX_RING_SIZE);
        if(next==tail) { control_rx_dropped++; rx_fault=1; return; }
        ring[head]=rx_dma[pos++]; __DMB(); head=next;
        if(pos==RX_DMA_SIZE) pos=0;
    }
    dma_pos=size;
}
void HAL_UART_TxCpltCallback(UART_HandleTypeDef *h)
{
    if(h==&huart3) PressureLink_TxComplete();
    else if(h==&huart1) { tx_tick=HAL_GetTick(); __DMB(); tx_done=1; }
}
void HAL_UART_ErrorCallback(UART_HandleTypeDef *h)
{
    if(h==&huart3) PressureLink_Error();
    else if(h==&huart1) { control_uart_errors++; rx_fault=1; }
    else if(h==&huart2) VizLink_Error();
}
void ControlTransport_Service(void)
{
    uint32_t mask,tick; uint8_t done; ControlMessage m;
    if(rx_fault) {
        if((uint32_t)(HAL_GetTick()-restart_at)<20) return;
        restart_at=HAL_GetTick();
        Control_FailIO(client);
        /* Abort/reset only in main context, never block an interrupt. */
        if(HAL_UART_Abort(&huart1)!=HAL_OK) { control_start_errors++; return; }
        mask=__get_PRIMASK(); __disable_irq();
        head=tail=dma_pos=0; control_parser.used=0; tx_done=0; rx_fault=0;
        if(HAL_UARTEx_ReceiveToIdle_DMA(&huart1,rx_dma,RX_DMA_SIZE)!=HAL_OK) {
            rx_fault=1; control_start_errors++;
        }
        __set_PRIMASK(mask); return;
    }
    mask=__get_PRIMASK(); __disable_irq(); done=tx_done; tick=tx_tick; tx_done=0; __set_PRIMASK(mask);
    if(done) Control_TxComplete(client,tick);
    while(tail!=head) {
        uint8_t b=ring[tail]; __DMB(); tail=(uint16_t)((tail+1U)%RX_RING_SIZE);
        if(Protocol_Feed(&control_parser,b,&m)) Control_Receive(client,&m,HAL_GetTick());
    }
}

void ControlTransport_Recover(void) { rx_fault=1; }
