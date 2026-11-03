#include "viz_link.h"
#include <string.h>

/* USART2 is owned by this module; the generated HAL_UART_MspInit in usart.c has
 * no USART2 branch, so the pins, clock and DMA below are the only ones used. */
UART_HandleTypeDef huart2;
DMA_HandleTypeDef hdma_usart2_rx;

#define RING_MASK ((uint16_t)(VIZ_LINK_RING_SIZE - 1U))

static uint8_t rx_dma[VIZ_LINK_RX_DMA_SIZE];
static uint8_t ring[VIZ_LINK_RING_SIZE];
static volatile uint16_t ring_head;   /* written by the DMA interrupt */
static volatile uint16_t ring_tail;   /* written by the main loop */
static volatile uint16_t dma_pos;
static volatile uint8_t rx_fault;

static VizParser parser;
static VizFrame scratch;
static VizMailboxes mailboxes;
static VizStat latest_stat;
static uint8_t stat_valid;
static VizLinkStats stats;
static uint32_t restart_at;
static uint32_t last_rx_tick;

static void Push(const uint8_t *data, uint16_t length)
{
    uint16_t i;
    for (i = 0U; i < length; ++i) {
        uint16_t next = (uint16_t)((ring_head + 1U) & RING_MASK);
        if (next == ring_tail) {
            /* The main loop fell a whole ring behind; drop and let the parser
             * resynchronise on the next header instead of wedging the ISR. */
            stats.ring_overflow++;
            continue;
        }
        ring[ring_head] = data[i];
        ring_head = next;
    }
    stats.rx_bytes += length;
}

static void Capture(void)
{
    uint16_t pos = (uint16_t)(VIZ_LINK_RX_DMA_SIZE -
                              (uint16_t)__HAL_DMA_GET_COUNTER(huart2.hdmarx));
    uint16_t start = dma_pos;

    if (pos == start) return;
    if (pos > start) {
        Push(rx_dma + start, (uint16_t)(pos - start));
    } else {
        Push(rx_dma + start, (uint16_t)(VIZ_LINK_RX_DMA_SIZE - start));
        if (pos > 0U) Push(rx_dma, pos);
    }
    dma_pos = pos;
    last_rx_tick = HAL_GetTick();
}

/* Half/full transfer of the circular reception DMA.  NDTR is sampled here so a
 * delayed notification cannot replay bytes that a later one already took. */
void HAL_UART_RxHalfCpltCallback(UART_HandleTypeDef *handle)
{
    if (handle == &huart2) Capture();
}

void HAL_UART_RxCpltCallback(UART_HandleTypeDef *handle)
{
    if (handle == &huart2) Capture();
}

void VizLink_Error(void)
{
    stats.uart_errors++;
    stats.last_uart_error = huart2.ErrorCode;
    rx_fault = 1U;
}

int VizLink_Init(void)
{
    GPIO_InitTypeDef gpio;
    int started;

    memset(&stats, 0, sizeof(stats));
    memset(&gpio, 0, sizeof(gpio));
    VizParser_Init(&parser);
    VizMailboxes_Reset(&mailboxes);
    memset(&latest_stat, 0, sizeof(latest_stat));
    stat_valid = 0U;
    ring_head = 0U;
    ring_tail = 0U;
    dma_pos = 0U;
    rx_fault = 0U;
    restart_at = 0U;
    last_rx_tick = 0U;

    __HAL_RCC_GPIOA_CLK_ENABLE();
    __HAL_RCC_USART2_CLK_ENABLE();

    /* PA3 = USART2_RX.  The B board drives the line push-pull; the internal
     * pull-up only keeps an unplugged cable idle-high instead of floating. */
    gpio.Pin = GPIO_PIN_3;
    gpio.Mode = GPIO_MODE_AF_PP;
    gpio.Pull = GPIO_PULLUP;
    gpio.Speed = GPIO_SPEED_FREQ_VERY_HIGH;
    gpio.Alternate = GPIO_AF7_USART2;
    HAL_GPIO_Init(GPIOA, &gpio);

    /* USART2_RX = DMA1 Stream5, channel 4 (RM0090 DMA1 request mapping). */
    hdma_usart2_rx.Instance = DMA1_Stream5;
    hdma_usart2_rx.Init.Channel = DMA_CHANNEL_4;
    hdma_usart2_rx.Init.Direction = DMA_PERIPH_TO_MEMORY;
    hdma_usart2_rx.Init.PeriphInc = DMA_PINC_DISABLE;
    hdma_usart2_rx.Init.MemInc = DMA_MINC_ENABLE;
    hdma_usart2_rx.Init.PeriphDataAlignment = DMA_PDATAALIGN_BYTE;
    hdma_usart2_rx.Init.MemDataAlignment = DMA_MDATAALIGN_BYTE;
    hdma_usart2_rx.Init.Mode = DMA_CIRCULAR;
    hdma_usart2_rx.Init.Priority = DMA_PRIORITY_LOW;
    hdma_usart2_rx.Init.FIFOMode = DMA_FIFOMODE_DISABLE;
    if (HAL_DMA_Init(&hdma_usart2_rx) != HAL_OK) return 0;
    __HAL_LINKDMA(&huart2, hdmarx, hdma_usart2_rx);

    huart2.Instance = USART2;
    /* APB1 is 45 MHz: 45/2 = 22.5 clocks per bit -> USARTDIV = 1.40625, which
     * the 4-bit fraction cannot represent; BRR=22 gives 2.0455 Mbit/s (+2.3%),
     * inside the ~5% UART budget with a 10-bit frame.  See the notes in
     * docs/B板可视化_MCU接入说明.md before changing the clock tree. */
    huart2.Init.BaudRate = VIZ_LINK_BAUD;
    huart2.Init.WordLength = UART_WORDLENGTH_8B;
    huart2.Init.StopBits = UART_STOPBITS_1;
    huart2.Init.Parity = UART_PARITY_NONE;
    huart2.Init.Mode = UART_MODE_RX;
    huart2.Init.HwFlowCtl = UART_HWCONTROL_NONE;
    huart2.Init.OverSampling = UART_OVERSAMPLING_16;
    if (HAL_UART_Init(&huart2) != HAL_OK) return 0;

    HAL_NVIC_SetPriority(USART2_IRQn, VIZ_LINK_IRQ_PRIORITY, 0U);
    HAL_NVIC_EnableIRQ(USART2_IRQn);
    HAL_NVIC_SetPriority(DMA1_Stream5_IRQn, VIZ_LINK_IRQ_PRIORITY, 0U);
    HAL_NVIC_EnableIRQ(DMA1_Stream5_IRQn);

    started = (HAL_UART_Receive_DMA(&huart2, rx_dma, VIZ_LINK_RX_DMA_SIZE) == HAL_OK);
    if (!started) rx_fault = 1U;
    return started;
}

static void Commit(void)
{
    int index = VizMailboxes_Index(scratch.type);

    if (index < 0) return;
    VizMailbox_Commit(&mailboxes.slot[index], &scratch);
    stats.frames[index]++;
    stats.last_frame_tick = HAL_GetTick();
    stats.link_alive = 1U;
    if (scratch.type == VIZ_FRAME_STAT) {
        if (VizFrame_DecodeStat(&scratch, &latest_stat)) stat_valid = 1U;
    }
}

static void Pump(void)
{
    uint8_t chunk[64];

    for (;;) {
        uint16_t count = 0U;
        uint16_t offset = 0U;

        while (count < (uint16_t)sizeof(chunk) && ring_tail != ring_head) {
            chunk[count++] = ring[ring_tail];
            ring_tail = (uint16_t)((ring_tail + 1U) & RING_MASK);
        }
        for (;;) {
            uint16_t consumed = 0U;
            int got = VizParser_Feed(&parser, chunk + offset,
                                     (uint16_t)(count - offset), &scratch, &consumed);
            offset = (uint16_t)(offset + consumed);
            if (got) {
                Commit();
                continue;
            }
            if (offset >= count || consumed == 0U) break;
        }
        if (count == 0U) break;
    }
}

static void Restart(void)
{
    uint32_t now = HAL_GetTick();

    if ((uint32_t)(now - restart_at) < VIZ_LINK_RESTART_MS) return;
    restart_at = now;
    stats.restarts++;
    /* Abort/reset only from the main loop: HAL must not block an interrupt. */
    if (HAL_UART_Abort(&huart2) != HAL_OK) return;
    /* The bytes already copied into the ring stay valid; only the DMA window
     * restarts, and the parser resynchronises on the next AA 7C. */
    dma_pos = 0U;
    if (HAL_UART_Receive_DMA(&huart2, rx_dma, VIZ_LINK_RX_DMA_SIZE) != HAL_OK) return;
    rx_fault = 0U;
}

void VizLink_Service(void)
{
    uint32_t now = HAL_GetTick();

    /* Link and stall bookkeeping runs even while the port is being restarted,
     * otherwise the page would keep showing a stale "link alive". */
    if (stats.link_alive != 0U &&
        (uint32_t)(now - stats.last_frame_tick) > VIZ_LINK_TIMEOUT_MS) {
        stats.link_alive = 0U;
        stats.link_drops++;
    }
    if (parser.used > 0U &&
        (uint32_t)(now - last_rx_tick) > VIZ_LINK_STALL_MS) {
        stats.parked_requests += parser.used;
        VizParser_ResetCandidate(&parser);
    }

    if (rx_fault) {
        Restart();
        return;
    }

    Pump();

    stats.crc_errors = parser.crc_errors;
    stats.discarded = parser.discarded;
    stats.unknown_type = parser.unknown_type;
    {
        unsigned i;
        for (i = 0U; i < VIZ_MAILBOX_SLOTS; ++i) {
            stats.headers[i] = parser.header[i];
            stats.crc_bad[i] = parser.crc_bad[i];
        }
    }
}

int VizLink_TakeFrame(VizFrameType type, VizFrame *frame)
{
    int index = VizMailboxes_Index((uint8_t)type);
    int taken;

    if (index < 0 || frame == 0) return 0;
    taken = VizMailbox_Take(&mailboxes.slot[index], frame);
    frame->type = (uint8_t)type;
    return taken;
}

int VizLink_LinkAlive(void)
{
    return stats.link_alive != 0U;
}

int VizLink_GetStat(VizStat *stat)
{
    if (stat == 0 || !stat_valid) return 0;
    *stat = latest_stat;
    return 1;
}

const VizLinkStats *VizLink_GetStats(void)
{
    return &stats;
}
