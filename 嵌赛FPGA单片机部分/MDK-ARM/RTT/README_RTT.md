# SEGGER RTT / UART 日志集成说明

本工程直接使用根目录 `SEGGER_RTT_V782b` 里的官方 SEGGER RTT 源码，不在 `MDK-ARM/RTT` 里复制官方文件。

`MDK-ARM/RTT` 目录只放本工程自己的封装：

- `rtt_log_config.h`：日志输出后端配置，平时主要改这个文件。
- `rtt_log.h`
- `rtt_log.c`

## 先说清楚：RTT 不是串口

事实：

- SEGGER RTT 通过 J-Link/J-Trace 的 SWD/JTAG 调试链路读写 MCU 内存缓冲区。
- RTT 不接 J-Link 的 RX/TX，也不占用 USART1 引脚。
- J-Link 上的 RX/TX 如果存在，那是 USB 转串口功能，和 RTT 是两条不同通道。

判断：

- MCU 端通常不能可靠判断“电脑有没有打开 RTT Viewer”。
- 所以本工程不做运行时自动判断，而是用 `rtt_log_config.h` 里的编译期宏切换输出后端。

## 怎么切换 J-Link RTT / 串口

打开：

```text
MDK-ARM/RTT/rtt_log_config.h
```

改这一行：

```c
#define RTT_LOG_BACKEND RTT_LOG_BACKEND_BOTH
```

可选值：

```c
#define RTT_LOG_BACKEND RTT_LOG_BACKEND_RTT   // 只走 J-Link RTT
#define RTT_LOG_BACKEND RTT_LOG_BACKEND_UART  // 只走 USART1 串口
#define RTT_LOG_BACKEND RTT_LOG_BACKEND_BOTH  // RTT 和 USART1 同时输出
#define RTT_LOG_BACKEND RTT_LOG_BACKEND_NONE  // 不输出
```

当前默认是 `RTT_LOG_BACKEND_BOTH`，原因是模板工程要兼顾两类人：

- 有 J-Link：打开 J-Link RTT Viewer 看 Terminal 0。
- 没有 J-Link：接 USART1 串口，也能看到 `printf()` 和 `RTT_LOGI()` 这些日志。

如果你确定只用 J-Link 调试，建议改成：

```c
#define RTT_LOG_BACKEND RTT_LOG_BACKEND_RTT
```

这样不会被串口 115200 波特率拖慢。

如果你没有 J-Link，只接 USB-TTL 串口，改成：

```c
#define RTT_LOG_BACKEND RTT_LOG_BACKEND_UART
```

## 串口怎么接

当前工程使用 `USART1`，配置在 `Core/Src/usart.c`：

- 波特率：`115200`
- 数据位：`8`
- 校验：无
- 停止位：`1`
- 模式：收发

接 USB-TTL 或 J-Link 自带 UART 时，按串口交叉接：

```text
USB-TTL/J-Link TX  ->  MCU USART1 RX
USB-TTL/J-Link RX  ->  MCU USART1 TX
GND                ->  GND
```

注意：不要把 5V 串口电平直接接到 3.3V MCU 引脚。

## J-Link RTT 怎么看

硬件不是 RX/TX，而是调试口：

```text
J-Link GND   -> 板子 GND
J-Link VTref -> 板子 3.3V
J-Link SWDIO -> MCU SWDIO
J-Link SWCLK -> MCU SWCLK
J-Link NRST  -> MCU NRST，可选但建议接
```

电脑端打开 J-Link RTT Viewer / RTT Client：

- Interface 选 `SWD`
- Device 选你的 STM32F429 型号或相近 F429 型号
- Terminal 选 `0`

## 代码里怎么发数据

这些接口都会走 `RTT_LOG_BACKEND` 选定的后端：

```c
#include "rtt_log.h"

RTT_LogInit();

RTT_LOGI("BOOT", "system start");
RTT_LOGD("ADC", "raw=%u voltage=%.3f", raw, voltage);
RTT_LOG_EVERY_MS(1000u, "LOOP", "alive=%lu", counter);

printf("hello log backend\r\n");
```

也就是说：

- `RTT_LOG_BACKEND_RTT`：上面输出只在 RTT Viewer 里看。
- `RTT_LOG_BACKEND_UART`：上面输出只在串口助手里看。
- `RTT_LOG_BACKEND_BOTH`：RTT Viewer 和串口助手都能看。

## 从电脑往 MCU 发命令

RTT 下行输入只对 RTT 有效：

```c
if (RTT_LogHasKey())
{
    int ch = RTT_LogGetKey();
    if (ch == '1')
    {
        RTT_LOGI("CMD", "key 1 received");
    }
}
```

如果你走 USART1 串口输入，应该使用 HAL UART 接收、中断接收或 DMA 接收；这不是 RTT 的下行缓冲区。

## Keil 工程已包含

当前 `MDK-ARM/STM32F429BIT6.uvprojx` 已经加入：

- `.\RTT\rtt_log.c`
- `.\RTT\rtt_log.h`
- `.\RTT\rtt_log_config.h`
- `..\SEGGER_RTT_V782b\RTT\SEGGER_RTT.c`
- `..\SEGGER_RTT_V782b\RTT\SEGGER_RTT_printf.c`

Include Path 已加入：

- `.\RTT`
- `..\SEGGER_RTT_V782b\RTT`
- `..\SEGGER_RTT_V782b\Config`

Define 已加入：

- `RTT_USE_ASM=0`

这里故意走纯 C 版本，没有加入 `SEGGER_RTT_ASM_ARMv7M.S`。原因是 Keil/ARMCLANG 对 `.S` 文件类型和预处理配置更容易踩坑；日志输出场景下纯 C 版本已经够用。

## 如果新工程也想让 printf() 走 RTT/串口统一后端，还要在它原来的 fputc() 里改成：
#include "rtt_log.h"

int fputc(int ch, FILE *f)
{
    (void)f;
    RTT_LogPutChar(ch);
    return ch;
}
## 然后在 main() 初始化外设后调用一次：
RTT_LogInit();
RTT_LOGI("BOOT", "system start");

## 使用注意

- 串口输出比 RTT 慢很多，循环里不要疯狂 `printf()`。
- 循环日志建议用 `RTT_LOG_EVERY_MS()` 限流。
- `RTT_LOG_ENABLE = 0` 只会关闭 `RTT_LOGI/RTT_LOGD` 这些宏；`printf()` 仍然按 `RTT_LOG_BACKEND` 输出。
- 如果 `%.3f` 这类浮点格式打印异常，需要在 Keil 的 C 库/链接选项里启用浮点 printf；不想折腾的话，把浮点数放大成整数打印。

