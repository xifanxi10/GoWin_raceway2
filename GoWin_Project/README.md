# Tang Primer 25K 双 UART、压力音频与控制

基于 Gowin GW5A-25A（Tang Primer 25K）的压力感应钢琴 FPGA 工程。板级顶层为 `tang_primer_25k_audio_top`，内部保留 `mcu_link_top`，并通过参数化 mailbox 接入四声部 KS/I²S 音频核心。STM32F429 侧的压力协议、两路 UART 与 22 步静音同步保持固定。原加密 UART IP 保留在工程中但未启用。

## 1. 输入链路

| 链路 | MCU 引脚 | 速率 | 内容 |
|---|---|---|---|
| 压力 / 十二键 | PB10 / USART3_TX | 1 Mbps | `AA 55` 八路压力帧、`AA 56` 34 字节十二键快照 |
| 控制 | PB6 / USART1_TX | 115200 | 配置命令 |
| 回复 | PB7 / USART1_RX | 115200 | 配置回复 |

PB10 的 1 Mbps 接收器同时解析两类帧：只有 CRC 与字段全部合法的帧才会原子提交；首个合法的新类型帧切换输入源，ADC 通道使用 20 ms 看门狗、钢琴快照使用 75 ms 看门狗分别释音。钢琴快照经 166 位 bundled-data mailbox 跨到音频域，12 路使用轻量 DDS 声部，旧的四路压力 KS 路径保留。

压力基线为 0、430、710、0；补偿后 ≤200 判松开、≥300 连续两帧判按下。K5～K8 随整帧接收，当前未接入声部。N60/N32 均在音源支持范围内。

慢按力度的处理：ADC 实测 0→301→310→2500，原实现按 1/255 锁存力度，混音峰值仅 18/32767；集成层新增 `MIN_PRESSURE_VELOCITY=64`，只抬高非零触发力度的下限，同一仿真条件下峰值为 1178。KS 为弹拨衰减音，力度在触发时锁存，按住后继续加力不会重新拨弦，松开再按才重新触发。

## 2. 双板可视化

A 板新增三个只读扇出脚 `i2s_mon_bclk/lrclk/sd`（J6-9/10/11，0 LUT），把 I2S 流送给第二片同型号 FPGA 做可视化协处理器（波形 / 频谱 / 李萨如），B 板再用 2 Mbps UART 把绘图包发给 MCU。B 板接收机位于 `src/viz/i2s_rx.sv`。

## 3. 引脚与音频输出

| MCU | Dock J3 排针编号 | FPGA 封装脚 | 用途 |
|---|---:|---|---|
| PB10 / USART3_TX | 13 | C2 | 压力输入 1 Mbps |
| PB6 / USART1_TX | 14 | B2 | 控制输入 115200 |
| PB7 / USART1_RX | 17 | A1 | 控制回复 115200 |
| GND | 12 | GND | 共地 |

音频输出：**J6-8（H7）→ BCLK，J6-7（H8）→ LRC，J5-5（L5）→ DIN**，接 MAX98357A 的数字 I²S 输入；功放另需供电、共地与使能，输出接扬声器。

排针编号与 BGA 封装脚号是两套编号，J3 的 11 脚是 +5 V，不要与相邻的 12 脚 GND 混淆。S1 为复位键，释放稳定约 10 ms 后恢复；50 MHz 板载晶振已接 E2，无需外接时钟。重新下载后需要 Resync，并手动解除静音至 Mute 0/0。

## 4. 构建

```text
Gowin IDE → 打开 UART_project.gprj → Synthesize → Place & Route → Program Device
```

- A 板工程：`UART_project.gprj`，下载文件 `impl/pnr/UART_project.fs`，约束为 `constraints/tang_primer_25k_audio.cst` / `.sdc`
- B 板可视化工程：`B板工程/board_b.gprj`，下载文件 `B板工程/impl/pnr/board_b.fs`

压力/配置总线在板内接入压力按键门控、跨域 mailbox、四个 KS 声部与 I²S 发射器。

## 5. 目录结构

```
src/audio/          自适应混音、音频声部核心、长笛音色
src/audio_teammate/ 四声部 KS/I²S 音频源码（i2s_tx、max98357、按键滤波、力度桥接等）
src/board/          板级顶层与音频顶层
src/mcu_link/       UART 链路、帧解析、控制执行与回复
src/viz/            B 板可视化：I2S 接收、缓冲、FFT、频带映射、帧发送
src/uart_master*/   原 Gowin UART IP 生成产物（工程中禁用）
constraints/        板级引脚与时序约束
impl/               A 板综合与布局布线结果
B板工程/            B 板可视化独立工程
```
