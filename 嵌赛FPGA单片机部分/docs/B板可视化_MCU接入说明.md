# B 板可视化：F429 端（单片机）接入说明

更新：2026-10-31。对应 FPGA 仓库 `Touch_Paino2.3_48/UART_project/docs/BOARD_B_VISUALIZER_HANDOVER.md` 第 6 节，以及 `BOARD_B_IMPLEMENTATION.md` 的实际实现。

本文记录**已经写进本工程固件**的部分：2 Mbps 下行链路、帧解析、mailbox、第三个显示页与四种绘图、编译与主机测试结果。第 9 节明确列出**尚未上板验证**的项目，请不要把"编译通过 / 主机测试通过"当成联调结果。

---

## 1. 本次交付范围

| 文件 | 内容 | 验证状态 |
|---|---|---|
| `Core/Inc/viz_frame.h`、`Core/Src/viz_frame.c` | `AA 7C` 帧长度表、字节流解析与重同步、CRC 校验、STAT 解码、四路双缓冲 mailbox | 主机单测通过 |
| `Core/Inc/viz_link.h`、`Core/Src/viz_link.c` | USART2/PA3 初始化、1 KB 循环 DMA、8 KB 环形缓冲、中断搬运、主循环解析、失联/重启看门狗、统计 | ARMClang 编译链接通过；未上板 |
| `Core/Inc/viz_view.h`、`Core/Src/viz_view.c` | 可视化页：WAVE / SPEC / XY / STAT 四种视图，脏几何擦除，30 fps 节流 | ARMClang 编译链接通过；未上板 |
| `Core/Src/instrument_ui.c` | 增加第三页 `UI_PAGE_VIZ`，两页原有顶栏各加 `Viz >` 入口，返回按钮回 ADC 页 | 编译通过；触摸未上板 |
| `Core/Src/main.c` | `VizLink_Init()` / `VizLink_Service()` 接入 | 编译通过 |
| `Core/Src/stm32f4xx_it.c`、`Core/Src/control_transport.c` | `USART2_IRQHandler`、`DMA1_Stream5_IRQHandler`、UART 错误回调转发 | 编译通过 |
| `MDK-ARM/STM32F429BIT6.uvprojx` | Instrument 组新增 6 个文件 | 已加入 |
| `tests/test_viz_frame.c`、`tools/run_tests.py` | 解析器/邮箱主机测试（8 项） | 通过 |
| `tools/build_firmware.py` | 不打开 Keil 界面、用 ARMCLang 6.22 复现工程编译链接 | 通过 |

**没有做的事**：没有任何音频、绘图或通信行为被"假装"验证；B 板与 MCU 之间的实体连线、2 Mbps 误码率、屏幕实际帧率都还没有实测。

---

## 2. 接线

| 方向 | B 板 | 排针 | F429 | 说明 |
|---|---|---|---|---|
| B → MCU | `viz_tx`（G5） | **J6-12** | **PA3（USART2_RX）** | 2 Mbit/s 8N1，单向 |
| 共地 | GND | J3-12 | GND | 与信号线同走向，星型汇到 A 板 J3-12 附近 |

- PA2 不接（固件把 USART2 配成只收，`UART_MODE_RX`，PA2 保持复位状态）。
- **不要把 `viz_tx` 接到 A 板**：A 板同一位置是推挽输出。
- 线长 ≤ 20 cm，远离功放与屏排线，超过 15 cm 在发送端串 33 Ω。
- B 板三个 I2S 输入不开内部上拉；MCU 侧 PA3 开了内部上拉，只用于"拔线时保持空闲高电平"，不会与 B 板的推挽输出冲突。

`.ioc` 里 PA2/PA3 标的是 `ADCx_IN2/IN3`，但 `main()` 从不调用 `MX_ADC1_Init()`（48 键方案已停用 ADC），所以这两个脚是空闲的。`VizLink_Init()` 在 `MX_GPIO_Init()` 之后执行并重新把 PA3 配成 `AF7_USART2`，即使以后 CubeMX 把 PA3 生成成模拟输入也会被覆盖。

---

## 3. 串口参数与波特率误差（**与交接文档 6.1 的结论不同，请以本节为准**）

| 项目 | 取值 |
|---|---|
| 外设 | USART2（PA3，只开 RX） |
| 波特率 | 2 Mbit/s，8N1，无流控 |
| 时钟 | APB1 = 45 MHz（HCLK 180 MHz ÷ 4） |
| DMA | USART2_RX = **DMA1 Stream5 / Channel 4**（RM0090 DMA1 请求映射），循环模式 1 KB |
| 中断 | USART2_IRQn、DMA1_Stream5_IRQn，抢占优先级均为 **5**（低于压力 USART3 的 2、控制 USART1 的 4） |

**实际误差不是 0。** 45 MHz ÷ 2 Mbit/s = 22.5 个 PCLK/位，这是"每比特的 PCLK 数"，不是 BRR。16 倍过采样下：

```
USARTDIV = 45e6 / (16 × 2e6) = 1.40625
BRR     = 1.40625 × 16 = 22.5  → 只能取整 22（HAL 计算得 MANT=1, FRAQ=6）
实际波特率 = 45e6 / (16 × 1.375) = 2.0455 Mbit/s
误差 = +2.27%
```

交接文档写的"BRR = 22 + 0.5×16，误差为 0"把这个数当成了可表示的 BRR 值，实际 4 位小数位无法表示 0.5/16。**+2.27% 在 UART 的容限内**（10 位帧到停止位累计偏移约 0.23 位，接收端每位有 3 个采样点），10 位帧可以正常收发，但这是余量而不是零误差。

如果上板后 `VizLinkStats.uart_errors` 持续增长、`crc_errors` 大量增加，优先怀疑这里，改用 **USART6**（APB2 = 90 MHz，90 ÷ 2 = 45 整除，误差为 0，可选 PC7 或 PG9，DMA2 Stream1 / Channel 5）。换口只需要改 `viz_link.c` 里的 GPIO 复用、`huart2.Instance`、`DMA1_Stream5/CH4` 与两个 NVIC 项，协议和上层完全不用动。

---

## 4. 帧格式（B 板实际发送的）

```
偏移  0     1     2      3      4 ...                    末尾 2 字节
      AA    7C    type   seq    payload ...              CRC16（低字节先发）
```

CRC 为 CRC-16/CCITT-FALSE（0x1021，初值 0xFFFF，不反转），覆盖 **type 到 payload 末字节**，即偏移 2 起 `len-4` 字节。多字节字段一律低字节先发。

| type | 名称 | payload | 帧长 | B 板实测帧率 |
|---|---|---:|---:|---:|
| 0x01 | WAVE | 512 = 256 × {min,max} | **518** | ≈46.9 fps |
| 0x02 | SPEC | 128 = 64 柱 + 64 峰值 | **134** | ≈46.9 fps |
| 0x03 | XY | 512 = 256 × {x,y} | **518** | ≈46.9 fps |
| 0x04 | STAT | 16 | **22** | ≈11.7 fps |

各字段语义见 `BOARD_B_VISUALIZER_HANDOVER.md` 第 4 节；STAT 的第 4～5 字节按键掩码 **恒为 0**（B 板拿不到按键信息），页面上的按键状态应取本地 `PianoInput`。

---

## 5. 接收链路

```
PA3 ──► USART2 RX ──► DMA1_Stream5（1 KB 循环）
                              │  HT/TC 中断：按 NDTR 算出新增字节，拷进 8 KB 环形缓冲
                              ▼
                    主循环 VizLink_Service()
                              │  一次取 64 B → VizParser_Feed()
                              │  校验通过 → 按 type 提交到对应 mailbox（双缓冲）
                              ▼
                     VizView_Service() 取最新一帧 → 画

上报：VizLinkStats（字节数、四类帧数、CRC 错、垃圾字节、环溢出、UART 错、重启、失联次数）
```

设计要点：

- **中断里只搬运不解析**。518 字节的有效帧做一次逐位 CRC 约 90 µs，放在中断里会挤压 1 Mbps 压力链路。中断只按 `NDTR` 计算已接收字节并复制。
- **环形缓冲写回绕**：`NDTR` 在 TC 边界可能读到 0 或满值，两种都按"`pos < dma_pos` 即已回绕"处理；8 KB ≈ 2 Mbps 下的 32 ms，主循环落后一整个环才丢弃（`ring_overflow` 计数），不会卡死中断。
- **解析器保留候选**：`AA 7C` 可以先收进候选再校验；负载里出现 `AA 7C`（例如静音波形 `min=0xAA,max=0x7C`）不会把帧截断。CRC 错、未知 type、垃圾字节一律**丢 1 字节后重新搜索**，可以恢复插字节、丢字节、截断帧。
- **喂字节必须处理"只吃掉一部分"**：`VizParser_Feed` 在候选缓冲将满时只复制一部分就先返回（并给出本次消费的字节数），调用方必须把剩下的字节重新喂进去。早期 `Pump` 只调用一次、把剩余字节当已消费丢掉，结果每组装一个 518 字节帧就丢 56 字节，紧接着的那一帧必然损坏——这就是"`rx` 满速 53 KB/s、`in` 却只有个位数"的根因。`tests/test_viz_frame.c` 的整块流用例（20 个 WAVE+SPEC+XY+STAT 块、64 字节分片）现在覆盖这条路径。
- **半帧停滞**：缓冲区里有候选但 100 ms 没有新字节（B 板复位/拔线），丢弃候选并计入 `parked_requests`。
- **失联**：连续 300 ms 没有合法帧 → `link_alive = 0`，页面显示"waiting for B board frames"；恢复后自动继续画，不需要复位。
- **UART 错误**：`HAL_UART_ErrorCallback` 转发到 `VizLink_Error()`。HAL 在收到**任何**帧错/噪声/溢出错误时都会停掉 DMA，所以必须在主循环里重新武装；退避只有 **2 ms**（早期版本照抄控制链路的 100 ms，等于每错一次白丢 5 帧，实测会把 47 fps 打到 6 fps）。重武装保留环形缓冲里已收的字节，只把 DMA 窗口归零，解析器会在下一个 `AA 7C` 重新对齐。
- **延迟提交**：每类帧单独 mailbox，写指针切换后 `dirty` 才置位；显示端只会拿到完整帧，不会撕裂。可视化允许丢帧，不允许卡顿——`seq` 跳变不作为错误。

RAM 占用：环形 8 KB + DMA 1 KB + mailbox 4 KB + 解析器/mailbox 结构 ≈ 17 KB（ZI 由 5.3 KB 增至 26.4 KB，F429 共 192 KB + 64 KB CCM）。

---

## 6. 显示页

第三个页面：`ADC 诊断` → `48 键钢琴` → **`Viz`**。三个页面顶栏都留了入口（`Piano >` / `< ADC` / `Viz >`），Viz 页的 `< ADC` 返回第一页。

布局（800×480）：

```
y 8    标题
y 34   [< ADC][Wave][Spec][XY][Stat][Gain x1]     2M OK  I2S ON
y 80   ┌──────────────────────┬──────────────────────┐
       │  WAVE / SPEC：760×352 │  XY：312×312 正方形   │
y 432  └──────────────────────┴──────────────────────┘
y 440  WAVE Gain x1  in 47  out 30  draw   3ms  loop   3ms  [UART ERR]
y 460  rx 55 KB/s  frames / crc / junk / ovf / err / rst
```

映射（都是整除关系，避免逐列除法）：

| 视图 | 横向 | 纵向 |
|---|---|---|
| WAVE | 256 列原始数据 `x = 20 + (i×95 >> 5)`，**在列间线性插值成 760 个 1 px 竖条** | `y = 80 + ((255-v)×352 >> 8)` |
| SPEC | 64 柱，`x = 20 + (i×190 >> 4)`，柱宽 11 px 留 1 px 间隔 | 柱高 `v×352 >> 8`，峰值另画 2 px 标记 |
| XY | 正方形 312×312（x 244..555，y 100..411），`x = 244 + v×311/255` | `y = 100 + (255-v)×311/255`，**与横向同比例**；左侧 Y 刻度、下方 X 刻度 |
| STAT | 文本 6 行 | — |

- 波形/频谱都是**偏移二进制**：0x80 = 静音 = 绘图区正中。
- **WAVE 的插值**：B 板一列只代表 8 个采样点的 min/max，直接按 3 px 一列画会有明显台阶。现在把相邻列的 min/max 线性插值到 760 个屏幕列，每列画成 1 px 竖条（min/max 跨度大于 2 px 时用暗青色包络 + 中间 2 px 亮色迹线）。链路带宽不变，台阶从 3 px 降到 1 px。
- **直接写帧缓冲**：一帧 WAVE 有 760 条竖条，如果每条都调一次 `LCD_FillRect`（DMA2D R2M，每次都有启动/停止开销），实测只能跑到个位数帧率。现在 WAVE/XY 的热路径直接按 `LTDC_Layer1->CFBAR` 取到帧缓冲基址、按 RGB565 写入像素（`PutRun`/`Plot`/`PutLine`），每帧只有页面级清屏还走 DMA2D。若画布不是 RGB565 单图层或帧缓冲地址不在 SDRAM 范围，自动退回 `LCD_FillRect`/`LCD_DrawPoint`，功能不变只是慢。
- **诊断行**：`in` = 该类型每秒收到并提交的帧数（源端真实速率），`out` = 本页每秒实际画出的帧数，`draw` = 上一次绘制耗时，`loop` = 两次页面服务之间的间隔，方括号里是自动判断：`NO LINK` / `SRC SLOW`（链路字节率 < 20 KB/s）/ `UART ERR`（有 UART 错误在发生）/ `RING OVF`（主循环跟不上）/ `CRC ERR`（帧校验失败）/ `DRAW SLOW`（画得慢）。第二行是 `rx KB/s`、累计帧数、`crc`、`junk`、`ovf`、`err`、`rst`。
- **环形缓冲 16 KB**：约 65 ms 的 2 Mbps 流量，主循环偶发卡顿不会立刻丢帧。
- **增益 x1 / x2 / x4**（顶栏左侧按钮循环）：8 位偏移二进制是按 16 位全量程换算的，正常演奏电平只用到几十个码值，所以画面偏小；增益在 MCU 端放大，超过 ±127 码就削顶并在地面状态行显示 `CLIP!`。
- **XY 用正方形**：原来 760×352 会把圆压成 2.16:1 的扁椭圆；现在 312×312 等比，圆就是圆。
- **XY 的轴与刻度**：B 板 `xy_scope.sv` 的定义是 **X = x[n]**、**Y = x[n − T/4]**（T 为触发扫描测出的相邻上升过零间隔；比例取自 STAT 第 6、7 字节 a:b，B 板固定 1:4）。两端来自**同一个单声道（左声道）**，所以这是相位肖像而不是两路不同信号：纯音画圆/椭圆，噪声画乱线。页面顶部用两种颜色标出 `X = x[n]` 与 `Y = x[n − T/4]`；方框内画 1/4 网格与中心轴，左侧和下方各 5 个刻度（`+1.00 / +0.50 / 0 / −0.50 / −1.00`，按增益折算），刻度单位是**相对 16 位满量程**：`1.00 = ±32768`，一个码 = `sample>>8` 的 1 LSB = 256。增益 x2 时框边变成 ±0.50，x4 时 ±0.25。
- **不整屏擦除**：WAVE 只重画值变化的 1 px 竖条（先按背景色擦旧，再画新；一帧最多约 1520 次 1 px 填充）；SPEC 只在柱值或峰值变化时重画那一列；XY 把上一帧折线用背景色再画一遍。稳定单音时几乎不写像素。
- 节流：绘图 33 ms（30 fps，源端 47 fps 只取最新），统计文字 200 ms，速率 500 ms。
- 画布是 **RGB565 单图层**（`ltdc.h` 的 `ColorMode_0 = LTDC_PIXEL_FORMAT_RGB565`），不是交接文档 6.4 假设的 ARGB8888；一次整屏填充是 768 KB 而不是 1.5 MB。虽然代价更小，仍然按几何擦除，没有退化成整屏刷新。
- 绘图统一走 `LCD_FillRect` / `LCD_DrawLine`，与现有两页使用同一套 LTDC 封装（内部 DMA2D R2M），不直接写帧缓冲地址。

---

## 7. 接口与主循环接入

```c
/* main.c, USER CODE BEGIN 2 */
PressureLink_Init();
PianoInput_Init();
(void)VizLink_Init();        /* USART2 / PA3，失败只置统计，不阻塞启动 */
Instrument_Init();

/* main.c, while (1) */
PressureLink_Service();
PianoInput_Service(HAL_GetTick());
VizLink_Service();           /* 取字节、组帧、提交 mailbox，不画图 */
Instrument_Service();
#if INSTRUMENT_DISPLAY_ENABLE
if (board_sdram_ready) InstrumentUI_Service();   /* 第三页时内部调用 VizView_Service */
#endif
```

`viz_link.h`：

| 接口 | 说明 |
|---|---|
| `int VizLink_Init(void)` | 配置 PA3/USART2/DMA/NVIC 并启动循环接收；成功返回 1 |
| `void VizLink_Service(void)` | 主循环调用，非阻塞；内部完成解析、提交、超时与重启 |
| `int VizLink_TakeFrame(VizFrameType, VizFrame *)` | 取该类最新整帧；有未读帧返回 1。**只允许主循环调用** |
| `int VizLink_LinkAlive(void)` | 300 ms 内收到过合法帧返回 1 |
| `int VizLink_GetStat(VizStat *)` | 最近一帧 STAT 的解码结果 |
| `const VizLinkStats *VizLink_GetStats(void)` | 诊断计数（可直接在调试器里看） |
| `void VizLink_Error(void)` | 供 `HAL_UART_ErrorCallback` 调用 |

`viz_view.h`：`VizView_Enter(now)` / `VizView_Service(now)` / `VizView_Touch(down,x,y)`，由 `instrument_ui.c` 在第三页调用，`VizView_Touch` 返回 1 表示用户按了 `< ADC`。

---

## 8. 编译与测试

### 8.1 命令行编译（不需要打开 Keil 界面）

```powershell
python tools/build_firmware.py
```

脚本从 `MDK-ARM/STM32F429BIT6.uvprojx` 读出文件表、include 路径、宏与内存布局，用 ARMCLang 6.22 逐个编译 70 个对象并 `armlink` 链接，产物在 `MDK-ARM/build_armclang/`。

本次结果：

```
OK: 70 objects linked into MDK-ARM\build_armclang\STM32F429BIT6.axf
Total RO  Size (Code + RO Data)                48864 (  47.72kB)
Total RW  Size (RW Data + ZI Data)             27048 (  26.41kB)
Total ROM Size (Code + RO Data + RW Data)      48900 (  47.75kB)
```

`0 Error`。仅有的两个 warning 来自既有文件（`UI.c`、`KEY_1.c` 的 include 大小写），与本次改动无关。

### 8.2 主机测试

```powershell
python tools/run_tests.py
```

新增 `tests/test_viz_frame.c`（8 组断言，真实生产源码 + GCC `-Wall -Wextra -Werror`）：

| 用例 | 检查点 |
|---|---|
| 长度表 | 518 / 134 / 518 / 22，未知 type 为 0 |
| STAT 参考向量 | 用独立 Python 算出的 22 字节整帧逐字节解析：peak/rms/voices/flags/mask/ratio/sample_count/fft |
| 逐字节喂入 | 每字节一次 `Feed`，只在最后一字节返回 1 |
| 负载内出现 `AA 7C` | 不截断，512 字节负载完整 |
| 坏 CRC 后恢复 | CRC 错不产生帧，紧跟的合法帧仍被接受 |
| 垃圾字节 / 未知 type | 计数正确，后续合法帧可恢复 |
| 连续两帧 | 第二次调用（`size=0`）能排空缓冲，帧恰好交付一次 |
| 半帧停滞 + mailbox | 丢弃候选；双缓冲最新值语义，其它类型 mailbox 不受影响 |

`tools/viz_frame_feeder.py --selftest` 也在同一脚本里运行：它用独立实现重建 `AA 7C` 帧，并和 STAT 参考向量逐字节比对。

全部用例（含既有 7 个套件）通过。

### 8.3 还没有验证的

- 实体 B 板 → PA3 的 2 Mbps 通信、误码率、CRC 错计数；
- 屏幕第三页的实际观感、触摸命中、帧率与 CPU 占用；
- 与压力链路（USART3 1 Mbps）+ 控制链路（USART1）同时满载时的抖动；
- 2.27% 波特率误差在真实线缆上的表现。

---

## 9. 上板联调顺序

0. **没有 B 板时先调界面**：3.3 V USB-TTL 的 TX 接 MCU PA3、GND 共地，用
   `python tools/viz_frame_feeder.py --port COMx --view all` 灌假帧（`--selftest` 不需要 pyserial）。
   能正常出图说明 PA3/USART2/DMA/解析/绘制整条路是通的，后面的问题就只剩 B 板与接线。
1. **只接 B → MCU**（`viz_tx` + 地），进第三页看 STAT：应显示 `2M LINK OK  B I2S ON`，`frames` 每秒增加约 47+47+47+12。若 `NO LINK`，先量 PA3 有无波形、查波特率与地线。
2. **旁路抓包**：USB-TTL 接 B 板 G5，用 FPGA 仓库的 `scripts/viz_frame_monitor.py --port COMx --view spec`，确认 CRC 全对、序号连续。这一步排除 B 板问题。
3. **WAVE**：A 板放 `diagnostics/audio_tone` 单音，屏幕应是一条**不左右滚动**的稳定正弦；滚动说明触发没对准（B 板 `trigger_minmax`）。
4. **SPEC**：谱峰落在测试音的频带（±1 带）。偏一个倍频程说明 B 板窗长/采样率不对，与 MCU 无关。
5. **XY**：单音应稳定椭圆/圆，不应是乱线。
6. **回归**：回到钢琴页弹奏，确认 1 Mbps 压力链路与屏幕刷新没有变慢；`PressureLink_GetDroppedFrameCount()` 不应因开图而增长。

常见现象：

| 现象 | 先查什么 |
|---|---|
| `NO LINK`，`rx_bytes` 不动 | PA3 接线、B 板是否配置成功（`status_beat` 慢闪） |
| `rx_bytes` 增长但 `crc_errors` 暴涨 | 波特率误差（换 USART6）、地线、线长 |
| CRC 偶尔错、`junk` 小幅增长 | 属于正常垃圾字节，只要帧率稳定即可 |
| `ring_overflow` 增长 | 主循环单次阻塞过久（触摸 I²C 重试、SDRAM 刷新），可增大 `VIZ_LINK_RING_SIZE` |
| LINK OK 但画面不动 | `frames` 有增长而某类为 0 → 该 type 帧没发出；或停在同一视图未取到新帧 |
| `out` 远低于 `in`，`draw` 也很大 | 绘制慢：确认走的是直接写帧缓冲的分支（画布必须是 RGB565、`Direction_H`） |
| `out` 远低于 `in`，但 `draw` 很小 | 主循环被其它任务占住，看 `loop`；再查触摸 I²C、PCA9555 读取耗时 |
| `in` 明显低于 47 | 源端或链路：先看 `crc`/`junk`/`ovf` 是否增长，再用 USB-TTL 抓 G5 |
| 方括号显示 `[UART ERR]` 且 `err`/`rst` 在涨 | 线路上有误码（地线、线长、无串阻）。2 Mbps 下 MCU 端本身有 +2.27% 误差，若误码持续，可把两边都降到 **1 Mbps**：FPGA 50 MHz ÷ 1 MHz = 50 整除，MCU 45 MHz 下 BRR = 2\|13 也是零误差 |
| 方括号显示 `[SRC SLOW]` 且 `rx` 只有 7 KB/s 左右 | B 板确实只发 6 帧/秒：看 STAT 页 `samples` 每秒增量（正常 96 000），以及 B 板 `status_alive` 灯 |
| 画面撕裂 | 不应出现：mailbox 是整帧提交，若出现请查是否有人绕过 `VizLink_TakeFrame` 直接读缓冲 |

---

## 10. 已知限制

1. **2.27% 波特率误差**（第 3 节），可用但不理想；USART6 可做到 0 误差。
2. **按键掩码恒 0**：B 板只有 I2S 单向音频，拿不到按键；页面如需显示按键，用本地 `PianoInput_GetPressedMask()`。
3. **UI 30 fps vs 源 47 fps**：会丢帧，但只丢旧帧，画面永远是最新的。
4. **单图层 RGB565**：没有用 LTDC 第二图层做硬件混合，全部靠 CPU 按几何擦除；如果之后 FFT 页叠加更多文字导致掉帧，再考虑 `pLayerCfg1`。
5. **`VizLink_TakeFrame` 只允许主循环调用**；中断里只做 `Push`/`Capture`。
6. **USART2 不在 `.ioc` 里**：故意由 `viz_link.c` 自己配置，CubeMX 重新生成 `usart.c` 不会把它删掉；代价是 `.ioc` 的引脚图上看不到 USART2。
