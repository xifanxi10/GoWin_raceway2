#ifndef __RTT_LOG_CONFIG_H__
#define __RTT_LOG_CONFIG_H__

/*
 * 日志输出后端选择。
 *
 * 事实：SEGGER RTT 走 SWD/JTAG 调试链路，不走串口 RX/TX。
 * 判断：MCU 端通常不能可靠判断电脑是否正在使用 J-Link RTT Viewer，
 *       所以这里用“编译期宏”切换，而不是运行时自动判断。
 */
#define RTT_LOG_BACKEND_NONE            0
#define RTT_LOG_BACKEND_RTT             1
#define RTT_LOG_BACKEND_UART            2
#define RTT_LOG_BACKEND_BOTH            3

/*
 * 默认用 BOTH：有 J-Link 的人能看 RTT；没有 J-Link 但接了串口的人也能看 USART1。
 *
 * 只想用 J-Link RTT：
 *   #define RTT_LOG_BACKEND RTT_LOG_BACKEND_RTT
 *
 * 只想用串口 USART1：
 *   #define RTT_LOG_BACKEND RTT_LOG_BACKEND_UART
 *
 * 两边同时输出：
 *   #define RTT_LOG_BACKEND RTT_LOG_BACKEND_BOTH
 */
#ifndef RTT_LOG_BACKEND
#define RTT_LOG_BACKEND                 RTT_LOG_BACKEND_BOTH                       // RTT + USART1
#endif

/* 1：打开 RTT_LOGI/RTT_LOGD 等宏；0：这些宏编译为空。printf 不受它控制。 */
#ifndef RTT_LOG_ENABLE
#define RTT_LOG_ENABLE                  1
#endif

/* UART 输出使用的 HAL 句柄。当前工程是 USART1，对应 Core/Src/usart.c 里的 huart1。 */
#ifndef RTT_LOG_UART_HANDLE
#define RTT_LOG_UART_HANDLE             huart1
#endif

#ifndef RTT_LOG_UART_TIMEOUT_MS
#define RTT_LOG_UART_TIMEOUT_MS         100u
#endif

#ifndef RTT_LOG_UP_BUFFER_SIZE
#define RTT_LOG_UP_BUFFER_SIZE          2048u
#endif

#ifndef RTT_LOG_DOWN_BUFFER_SIZE
#define RTT_LOG_DOWN_BUFFER_SIZE        32u
#endif

#define RTT_LOG_LEVEL_NONE              0
#define RTT_LOG_LEVEL_ERROR             1
#define RTT_LOG_LEVEL_WARN              2
#define RTT_LOG_LEVEL_INFO              3
#define RTT_LOG_LEVEL_DEBUG             4

#ifndef RTT_LOG_LEVEL
#define RTT_LOG_LEVEL                   RTT_LOG_LEVEL_DEBUG
#endif

#endif /* __RTT_LOG_CONFIG_H__ */
