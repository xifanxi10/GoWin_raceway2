#include "rtt_log.h"

#if RTT_LOG_USE_RTT
#include "SEGGER_RTT.h"
#endif

#if RTT_LOG_USE_UART
#include "usart.h"
#endif

#include <stdarg.h>
#include <stdio.h>

#if RTT_LOG_USE_RTT
static char s_rtt_up_buffer[RTT_LOG_UP_BUFFER_SIZE];
static char s_rtt_down_buffer[RTT_LOG_DOWN_BUFFER_SIZE];
static uint8_t s_rtt_inited = 0u;

static void RTT_LogEnsureInit(void)
{
  if (s_rtt_inited == 0u)
  {
    SEGGER_RTT_Init();
    (void)SEGGER_RTT_ConfigUpBuffer(0u,
                                    "Terminal",
                                    s_rtt_up_buffer,
                                    (unsigned)sizeof(s_rtt_up_buffer),
                                    SEGGER_RTT_MODE_NO_BLOCK_TRIM);
    (void)SEGGER_RTT_ConfigDownBuffer(0u,
                                      "Terminal",
                                      s_rtt_down_buffer,
                                      (unsigned)sizeof(s_rtt_down_buffer),
                                      SEGGER_RTT_MODE_NO_BLOCK_SKIP);
    s_rtt_inited = 1u;
  }
}
#else
static void RTT_LogEnsureInit(void)
{
}
#endif

#if RTT_LOG_USE_UART
static void RTT_LogWriteUart(const char *data, uint32_t len)
{
  const uint8_t *bytes = (const uint8_t *)data;

  while (len > 0u)
  {
    uint16_t chunk = (len > 0xFFFFu) ? 0xFFFFu : (uint16_t)len;
    (void)HAL_UART_Transmit(&RTT_LOG_UART_HANDLE,
                            (uint8_t *)bytes,
                            chunk,
                            RTT_LOG_UART_TIMEOUT_MS);
    bytes += chunk;
    len -= chunk;
  }
}
#endif

static void RTT_LogBackendWrite(const char *data, uint32_t len)
{
  if ((data == NULL) || (len == 0u))
  {
    return;
  }

#if RTT_LOG_USE_RTT
  RTT_LogEnsureInit();
  (void)SEGGER_RTT_Write(0u, data, (unsigned)len);
#endif

#if RTT_LOG_USE_UART
  RTT_LogWriteUart(data, len);
#endif
}

static void RTT_LogBackendWriteString(const char *text)
{
  const char *p = text;

  if (text == NULL)
  {
    return;
  }

  while (*p != '\0')
  {
    p++;
  }

  RTT_LogBackendWrite(text, (uint32_t)(p - text));
}

static const char *RTT_LogBackendName(void)
{
#if RTT_LOG_BACKEND == RTT_LOG_BACKEND_RTT
  return "RTT";
#elif RTT_LOG_BACKEND == RTT_LOG_BACKEND_UART
  return "UART1";
#elif RTT_LOG_BACKEND == RTT_LOG_BACKEND_BOTH
  return "RTT+UART1";
#else
  return "NONE";
#endif
}

static void RTT_LogVPrintf(const char *fmt, va_list args)
{
  char buffer[192];
  int len;

  if (fmt == NULL)
  {
    return;
  }

  RTT_LogEnsureInit();
  len = vsnprintf(buffer, sizeof(buffer), fmt, args);

  if (len <= 0)
  {
    return;
  }

  if ((uint32_t)len >= sizeof(buffer))
  {
    RTT_LogBackendWrite(buffer, (uint32_t)(sizeof(buffer) - 1u));
    RTT_LogBackendWriteString("...[trim]\r\n");
  }
  else
  {
    RTT_LogBackendWrite(buffer, (uint32_t)len);
  }
}

void RTT_LogInit(void)
{
  RTT_LogEnsureInit();
  RTT_LogPrintf("\r\n[LOG] backend=%s ready\r\n", RTT_LogBackendName());
}

void RTT_LogWriteString(const char *text)
{
  RTT_LogBackendWriteString(text);
}

int RTT_LogPutChar(int ch)
{
  char c = (char)ch;

  RTT_LogBackendWrite(&c, 1u);
  return ch;
}

int RTT_LogPrintf(const char *fmt, ...)
{
  va_list args;

  va_start(args, fmt);
  RTT_LogVPrintf(fmt, args);
  va_end(args);

  return 0;
}

void RTT_LogMessage(const char *level, const char *tag, const char *fmt, ...)
{
  va_list args;

  RTT_LogPrintf("[%s][%lu][%s] ",
                (level != NULL) ? level : "?",
                (unsigned long)HAL_GetTick(),
                (tag != NULL) ? tag : "-");

  va_start(args, fmt);
  RTT_LogVPrintf(fmt, args);
  va_end(args);

  RTT_LogBackendWriteString("\r\n");
}

void RTT_LogHexDump(const char *tag, const void *data, uint32_t len)
{
  const uint8_t *bytes = (const uint8_t *)data;
  uint32_t i;

  if (bytes == NULL)
  {
    RTT_LOGW(tag, "HexDump data is NULL");
    return;
  }

  RTT_LogPrintf("[D][%lu][%s] len=%lu",
                (unsigned long)HAL_GetTick(),
                (tag != NULL) ? tag : "HEX",
                (unsigned long)len);

  for (i = 0u; i < len; i++)
  {
    if ((i & 0x0Fu) == 0u)
    {
      RTT_LogPrintf("\r\n  %04lX:", (unsigned long)i);
    }
    RTT_LogPrintf(" %02X", (unsigned)bytes[i]);
  }

  RTT_LogBackendWriteString("\r\n");
}

void RTT_LogU16Array(const char *tag, const uint16_t *data, uint32_t len, uint32_t max_count)
{
  uint32_t i;
  uint32_t count = len;

  if (data == NULL)
  {
    RTT_LOGW(tag, "U16 data is NULL");
    return;
  }

  if ((max_count != 0u) && (count > max_count))
  {
    count = max_count;
  }

  RTT_LogPrintf("[D][%lu][%s] u16[%lu], show=%lu:",
                (unsigned long)HAL_GetTick(),
                (tag != NULL) ? tag : "U16",
                (unsigned long)len,
                (unsigned long)count);

  for (i = 0u; i < count; i++)
  {
    if ((i & 0x0Fu) == 0u)
    {
      RTT_LogBackendWriteString("\r\n  ");
    }
    RTT_LogPrintf("%5u ", (unsigned)data[i]);
  }

  if (count < len)
  {
    RTT_LogBackendWriteString("\r\n  ...");
  }

  RTT_LogBackendWriteString("\r\n");
}

void RTT_LogXYPoints(const char *tag, const uint16_t *x, const uint16_t *y, uint8_t count)
{
  uint8_t i;

  if ((x == NULL) || (y == NULL))
  {
    RTT_LOGW(tag, "XY data is NULL");
    return;
  }

  RTT_LogPrintf("[D][%lu][%s] points=%u:",
                (unsigned long)HAL_GetTick(),
                (tag != NULL) ? tag : "XY",
                (unsigned)count);

  for (i = 0u; i < count; i++)
  {
    RTT_LogPrintf(" (%u,%u)", (unsigned)x[i], (unsigned)y[i]);
  }

  RTT_LogBackendWriteString("\r\n");
}

int RTT_LogHasKey(void)
{
#if RTT_LOG_USE_RTT
  RTT_LogEnsureInit();
  return SEGGER_RTT_HasKey();
#else
  return 0;
#endif
}

int RTT_LogGetKey(void)
{
#if RTT_LOG_USE_RTT
  RTT_LogEnsureInit();
  return SEGGER_RTT_GetKey();
#else
  return -1;
#endif
}

void RTT_LogAssertFailed(const char *expr, const char *file, uint32_t line)
{
  RTT_LOGE("ASSERT", "%s at %s:%lu",
           (expr != NULL) ? expr : "?",
           (file != NULL) ? file : "?",
           (unsigned long)line);

  __disable_irq();
  while (1)
  {
  }
}
