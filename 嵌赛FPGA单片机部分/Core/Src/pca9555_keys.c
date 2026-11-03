#include "pca9555_keys.h"
#include "instrument_config.h"
#include "pca9555_bus.h"
#include "rtt_log.h"

#define PCA9555_REG_INPUT_0       0x00U
#define PCA9555_REG_POLARITY_0    0x04U
#define PCA9555_REG_CONFIG_0      0x06U
#define PCA9555_KEY_MASK          0x0FFFU
#define PCA9555_OFFLINE_ERRORS    3U

static const uint8_t pca_addresses[PCA9555_DEVICE_COUNT] = {
    PCA9555_I2C_ADDRESS_0_7BIT, PCA9555_I2C_ADDRESS_1_7BIT,
    PCA9555_I2C_ADDRESS_2_7BIT, PCA9555_I2C_ADDRESS_3_7BIT
};
static volatile uint16_t raw_groups[PCA9555_DEVICE_COUNT];
static volatile uint8_t online_mask;
static volatile uint32_t read_count;
static volatile uint32_t error_count;
static uint8_t consecutive_errors[PCA9555_DEVICE_COUNT];
static uint32_t last_poll;
static uint32_t last_retry;

static uint8_t ConfigureDevice(uint8_t address)
{
    const uint8_t polarity[2] = {0x00U, 0x00U};
    const uint8_t direction[2] = {0xFFU, 0xFFU};
    if (!PCA9555Bus_Write(address, PCA9555_REG_POLARITY_0,
                          polarity, (uint8_t)sizeof(polarity))) {
        RTT_LogPrintf("[I2C][ERR] addr=0x%02X write POLARITY(0x04) NACK\r\n",
                      (unsigned)address);
        return 0U;
    }
    
    /* Configuration write is kept separate so the failing register is visible
       in RTT instead of being hidden behind a generic offline counter. */
    
    if (!PCA9555Bus_Write(address, PCA9555_REG_CONFIG_0,
                          direction, (uint8_t)sizeof(direction))) {
        RTT_LogPrintf("[I2C][ERR] addr=0x%02X write CONFIG(0x06) NACK\r\n",
                      (unsigned)address);
        return 0U;
    }
    return 1U;
}

uint8_t PCA9555Keys_Init(void)
{
    uint8_t i;
    for (i = 0U; i < PCA9555_DEVICE_COUNT; ++i) {
        raw_groups[i] = 0U;
        consecutive_errors[i] = 0U;
    }
    online_mask = 0U; read_count = 0U; error_count = 0U;
    last_poll = 0U; last_retry = 0U;
    PCA9555Bus_Init();
    for (i = 0U; i < PCA9555_DEVICE_COUNT; ++i) {
        if (ConfigureDevice(pca_addresses[i])) {
            online_mask |= (uint8_t)(1U << i);
            RTT_LogPrintf("[I2C] PCA9555 init group=%u addr=0x%02X OK\r\n",
                          (unsigned)i, (unsigned)pca_addresses[i]);
        } else {
            error_count++;
            RTT_LogPrintf("[I2C][ERR] PCA9555 init group=%u addr=0x%02X failed\r\n",
                          (unsigned)i, (unsigned)pca_addresses[i]);
        }
    }
    return online_mask;
}

void PCA9555Keys_Service(uint32_t now_ms)
{
    uint8_t i, input[2];
    if ((uint32_t)(now_ms - last_poll) < PCA9555_POLL_PERIOD_MS &&
        online_mask != 0U) return;
    last_poll = now_ms;
    if ((uint32_t)(now_ms - last_retry) >= PCA9555_RETRY_PERIOD_MS) {
        last_retry = now_ms;
        for (i = 0U; i < PCA9555_DEVICE_COUNT; ++i) {
            uint8_t bit = (uint8_t)(1U << i);
            if ((online_mask & bit) == 0U && ConfigureDevice(pca_addresses[i])) {
                online_mask |= bit; consecutive_errors[i] = 0U;
                RTT_LogPrintf("[I2C] PCA9555 recovered group=%u addr=0x%02X online=0x%02X\r\n",
                              (unsigned)i, (unsigned)pca_addresses[i],
                              (unsigned)online_mask);
            } else if ((online_mask & bit) == 0U) {
                RTT_LogPrintf("[I2C][ERR] PCA9555 retry failed group=%u addr=0x%02X online=0x%02X\r\n",
                              (unsigned)i, (unsigned)pca_addresses[i],
                              (unsigned)online_mask);
            }
        }
    }
    for (i = 0U; i < PCA9555_DEVICE_COUNT; ++i) {
        uint8_t bit = (uint8_t)(1U << i);
        uint16_t value;
        if ((online_mask & bit) == 0U) { raw_groups[i] = 0U; continue; }
        if (!PCA9555Bus_Read(pca_addresses[i], PCA9555_REG_INPUT_0,
                             input, (uint8_t)sizeof(input))) {
            error_count++; raw_groups[i] = 0U;
            ++consecutive_errors[i];
            if (consecutive_errors[i] == 1U) {
                RTT_LogPrintf("[I2C][ERR] PCA9555 read failed group=%u addr=0x%02X\r\n",
                              (unsigned)i, (unsigned)pca_addresses[i]);
            }
            if (consecutive_errors[i] >= PCA9555_OFFLINE_ERRORS) {
                online_mask = (uint8_t)(online_mask & (uint8_t)~bit);
                RTT_LogPrintf("[I2C][ERR] PCA9555 OFFLINE group=%u addr=0x%02X after=%u errors online=0x%02X\r\n",
                              (unsigned)i, (unsigned)pca_addresses[i],
                              (unsigned)consecutive_errors[i],
                              (unsigned)online_mask);
            }
            continue;
        }
        consecutive_errors[i] = 0U;
        value = (uint16_t)(input[0] | ((uint16_t)input[1] << 8U));
#if PCA9555_KEYS_ACTIVE_LOW
        value = (uint16_t)~value;
#endif
        raw_groups[i] = value & PCA9555_KEY_MASK; read_count++;
    }
}

uint16_t PCA9555Keys_GetRawMask(void) { return raw_groups[0]; }

void PCA9555Keys_GetGroups(uint16_t groups[PCA9555_DEVICE_COUNT])
{
    uint8_t i;
    if (groups == 0) return;
    for (i = 0U; i < PCA9555_DEVICE_COUNT; ++i) groups[i] = raw_groups[i];
}

uint8_t PCA9555Keys_GetOnlineMask(void) { return online_mask; }
uint8_t PCA9555Keys_IsOnline(void) { return (uint8_t)(online_mask != 0U); }
uint32_t PCA9555Keys_GetReadCount(void) { return read_count; }
uint32_t PCA9555Keys_GetErrorCount(void) { return error_count; }
