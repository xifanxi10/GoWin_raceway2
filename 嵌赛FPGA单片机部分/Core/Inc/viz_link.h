#ifndef VIZ_LINK_H
#define VIZ_LINK_H

/* Down-link from the B board (visualizer) into USART2 / PA3.
 *
 * The hand-over pins this link down as 2 Mbit/s 8N1, one way, fixed 518/134/
 * 518/22 byte frames (see viz_frame.h for the frame layout).  The receiver is
 * a circular DMA with half/full transfer interrupts feeding an 8 KiB software
 * ring; the main loop turns that byte stream into frames and keeps only the
 * newest frame of each type in a double-buffered mailbox.  Nothing is drawn
 * from an interrupt.
 *
 * USART2 is configured here rather than in usart.c on purpose: the peripheral
 * is only needed by this module, and keeping it out of the CubeMX generated
 * file means a regeneration of usart.c cannot silently drop it (the generated
 * HAL_UART_MspInit has no USART2 branch and simply does nothing for it).
 */

#include "main.h"
#include "viz_frame.h"
#include <stdint.h>

#define VIZ_LINK_BAUD              2000000U
#define VIZ_LINK_RX_DMA_SIZE       1024U
#define VIZ_LINK_RING_SIZE         16384U
#define VIZ_LINK_TIMEOUT_MS        300U   /* no valid frame: link is down */
#define VIZ_LINK_STALL_MS          100U   /* half frame then silence: drop it */
/* HAL stops the reception on the first framing/noise/overrun error, so the port
 * has to be re-armed.  A long back-off here silently costs whole blocks: at
 * 47 fps, 100 ms is five frames. */
#define VIZ_LINK_RESTART_MS        2U
#define VIZ_LINK_IRQ_PRIORITY      5U     /* below USART3 (2) and USART1 (4) */

/* Owned by viz_link.c; the interrupt handlers and the HAL error callback in
 * control_transport.c switch on these handles. */
extern UART_HandleTypeDef huart2;
extern DMA_HandleTypeDef hdma_usart2_rx;

typedef struct {
    uint32_t rx_bytes;
    uint32_t frames[VIZ_MAILBOX_SLOTS];
    uint32_t headers[VIZ_MAILBOX_SLOTS];
    uint32_t crc_bad[VIZ_MAILBOX_SLOTS];
    uint32_t crc_errors;
    uint32_t discarded;
    uint32_t unknown_type;
    uint32_t ring_overflow;
    uint32_t uart_errors;
    uint32_t last_uart_error;
    uint32_t restarts;
    uint32_t link_drops;
    uint32_t parked_requests;   /* bytes left in a failed candidate when it stalled */
    uint32_t last_frame_tick;
    uint8_t  link_alive;
} VizLinkStats;

/* 1 when USART2/DMA came up; 0 when the link stays parked (stats show why). */
int VizLink_Init(void);
void VizLink_Service(void);

/* Main context only.  Copies the newest frame of `type` into `frame`.
 * Returns 1 when a frame was waiting, 0 when nothing new arrived. */
int VizLink_TakeFrame(VizFrameType type, VizFrame *frame);

/* 1 while valid frames keep arriving (see VIZ_LINK_TIMEOUT_MS). */
int VizLink_LinkAlive(void);

/* 1 once at least one STAT frame was decoded. */
int VizLink_GetStat(VizStat *stat);
const VizLinkStats *VizLink_GetStats(void);

/* Called from HAL_UART_ErrorCallback for the viz UART. */
void VizLink_Error(void);

#endif
