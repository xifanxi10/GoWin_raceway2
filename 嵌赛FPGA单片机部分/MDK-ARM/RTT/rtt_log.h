#ifndef __RTT_LOG_H__
#define __RTT_LOG_H__

#ifdef __cplusplus
extern "C" {
#endif

#include "main.h"
#include <stdint.h>
#include <stddef.h>
#include "rtt_log_config.h"

/*
 * SEGGER RTT logging wrapper for this STM32/Keil project.
 *
 * Facts:
 * - RTT output is transferred through the debug probe, not through USART pins.
 * - Output backend is selected in rtt_log_config.h: RTT / UART / BOTH / NONE.
 * - printf redirection is handled in Core/Src/usart.c by calling RTT_LogPutChar().
 *   printf and RTT_LOGI/RTT_LOGD use the same backend.
 * - SEGGER_RTT_printf() is small, but it does not support floating point formats.
 *
 * Common use:
 * - RTT_LOGI("SYS", "boot");
 * - RTT_LOGD("ADC", "ch1=%u ch2=%u", adc1, adc2);
 * - RTT_LOG_EVERY_MS(200, "LOOP", "alive=%lu", counter);
 * - RTT_LogHexDump("RX", buf, len);
 */

#if (RTT_LOG_BACKEND != RTT_LOG_BACKEND_NONE) && \
    (RTT_LOG_BACKEND != RTT_LOG_BACKEND_RTT) && \
    (RTT_LOG_BACKEND != RTT_LOG_BACKEND_UART) && \
    (RTT_LOG_BACKEND != RTT_LOG_BACKEND_BOTH)
#error "RTT_LOG_BACKEND must be RTT_LOG_BACKEND_NONE, RTT_LOG_BACKEND_RTT, RTT_LOG_BACKEND_UART, or RTT_LOG_BACKEND_BOTH"
#endif

#define RTT_LOG_USE_RTT                 ((RTT_LOG_BACKEND == RTT_LOG_BACKEND_RTT) || \
                                         (RTT_LOG_BACKEND == RTT_LOG_BACKEND_BOTH))
#define RTT_LOG_USE_UART                ((RTT_LOG_BACKEND == RTT_LOG_BACKEND_UART) || \
                                         (RTT_LOG_BACKEND == RTT_LOG_BACKEND_BOTH))

#define RTT_LOG_CONCAT_INNER(a, b)      a##b
#define RTT_LOG_CONCAT(a, b)            RTT_LOG_CONCAT_INNER(a, b)

void RTT_LogInit(void);
void RTT_LogWriteString(const char *text);
int  RTT_LogPutChar(int ch);
int  RTT_LogPrintf(const char *fmt, ...);
void RTT_LogMessage(const char *level, const char *tag, const char *fmt, ...);
void RTT_LogHexDump(const char *tag, const void *data, uint32_t len);
void RTT_LogU16Array(const char *tag, const uint16_t *data, uint32_t len, uint32_t max_count);
void RTT_LogXYPoints(const char *tag, const uint16_t *x, const uint16_t *y, uint8_t count);
int  RTT_LogHasKey(void);
int  RTT_LogGetKey(void);
void RTT_LogAssertFailed(const char *expr, const char *file, uint32_t line);

#if RTT_LOG_ENABLE && (RTT_LOG_LEVEL >= RTT_LOG_LEVEL_ERROR)
#define RTT_LOGE(tag, ...)              RTT_LogMessage("E", (tag), __VA_ARGS__)
#else
#define RTT_LOGE(tag, ...)              do { } while (0)
#endif

#if RTT_LOG_ENABLE && (RTT_LOG_LEVEL >= RTT_LOG_LEVEL_WARN)
#define RTT_LOGW(tag, ...)              RTT_LogMessage("W", (tag), __VA_ARGS__)
#else
#define RTT_LOGW(tag, ...)              do { } while (0)
#endif

#if RTT_LOG_ENABLE && (RTT_LOG_LEVEL >= RTT_LOG_LEVEL_INFO)
#define RTT_LOGI(tag, ...)              RTT_LogMessage("I", (tag), __VA_ARGS__)
#else
#define RTT_LOGI(tag, ...)              do { } while (0)
#endif

#if RTT_LOG_ENABLE && (RTT_LOG_LEVEL >= RTT_LOG_LEVEL_DEBUG)
#define RTT_LOGD(tag, ...)              RTT_LogMessage("D", (tag), __VA_ARGS__)
#else
#define RTT_LOGD(tag, ...)              do { } while (0)
#endif

#if RTT_LOG_ENABLE
#define RTT_LOG_EVERY_MS(period_ms, tag, ...)                                      \
        RTT_LOG_EVERY_MS_IMPL(__LINE__, (period_ms), (tag), __VA_ARGS__)

#define RTT_LOG_EVERY_MS_IMPL(line, period_ms, tag, ...)                           \
  do {                                                                             \
    static uint32_t RTT_LOG_CONCAT(_rtt_log_last_ms_, line);                       \
    uint32_t _rtt_log_now_ms = HAL_GetTick();                                      \
    if ((_rtt_log_now_ms - RTT_LOG_CONCAT(_rtt_log_last_ms_, line)) >=             \
        (uint32_t)(period_ms)) {                                                   \
      RTT_LOG_CONCAT(_rtt_log_last_ms_, line) = _rtt_log_now_ms;                   \
      RTT_LogMessage("D", (tag), __VA_ARGS__);                                    \
    }                                                                              \
  } while (0)

#define RTT_ASSERT(expr)                                                           \
  do {                                                                             \
    if (!(expr)) {                                                                 \
      RTT_LogAssertFailed(#expr, __FILE__, (uint32_t)__LINE__);                    \
    }                                                                              \
  } while (0)
#else
#define RTT_LOG_EVERY_MS(period_ms, tag, ...)  do { } while (0)
#define RTT_ASSERT(expr)                       do { (void)sizeof(expr); } while (0)
#endif

#ifdef __cplusplus
}
#endif

#endif /* __RTT_LOG_H__ */
