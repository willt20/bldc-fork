# Engine Start Mode 修改记录与使用说明

本文档记录本分支为 VESC FOC 固件新增的 Engine Start Mode 的修改过程、参数含义、Lisp/Terminal 使用方法和后续修改注意事项，方便后续 Codex 或人工继续按需求迭代，避免遗忘上下文。

## 1. 需求背景

目标是在不修改 VESC Tool、不修改参数协议、不新增 `mc_configuration` 字段的前提下，在固件侧增加一个面向 A40 类低 KV 外转子电机直连四缸发动机曲轴启动的状态机。

使用场景特点：

- 电机：A40 类外转子，KV 约 50~85KV。
- 母线电压：约 29V。
- 启动相电流目标：约 100A~250A。
- 负载：四缸发动机曲轴直连。
- 负载特征：压缩上止点附近阻力突增，一圈内负载波动很大。
- 采样：低侧三电阻采样。
- 目标不是普通电机平滑启动，而是类似起动机：慢拉、检测压缩点、短时大电流冲击、过点后加速、Observer 延迟接管。

## 2. 已修改文件

### 必改文件

- `motor/mcpwm_foc.c`
- `motor/mcpwm_foc.h`
- `motor/mc_interface.c`
- `motor/mc_interface.h`

### 已额外修改文件

- `terminal.c`
- `lispBM/lispif_vesc_extensions.c`

### 未修改文件

保持以下文件未改动：

- VESC Tool 相关代码
- `datatypes.h`
- `conf_general.c`
- `commands.c`
- 参数协议相关代码

## 3. 当前实现概要

Engine Start Mode 当前实现为 FOC 层内的状态机，核心状态如下：

```text
ENGINE_START_IDLE
ENGINE_START_ALIGN
ENGINE_START_PULL
ENGINE_START_LOAD_DETECT
ENGINE_START_PULSE
ENGINE_START_GAP
ENGINE_START_BACKOFF
ENGINE_START_RECOVER
ENGINE_START_ACCEL
ENGINE_START_BLEND
ENGINE_START_RUN
ENGINE_START_RETRY
ENGINE_START_FAULT
```

状态机入口：

- `mcpwm_foc_engine_start()`
- `mc_interface_engine_start()`
- Terminal 命令 `engine_start`
- Lisp 命令 `(engine-start)`

状态机停止：

- `mcpwm_foc_engine_stop()`
- `mc_interface_engine_stop()`
- Terminal 命令 `engine_stop`
- Lisp 命令 `(engine-stop)`

状态机周期调用位置：

- `motor/mcpwm_foc.c` 的 `timer_thread`
- 在 `timer_update((motor_all_state_t*)&m_motor_1, dt)` 后调用 `engine_start_update(dt)`
- `dt = 0.001`，即约 1kHz 更新

## 4. 状态机逻辑

### 4.1 IDLE

默认状态，不输出额外启动电流。

收到 start 请求后进入 ALIGN。

### 4.2 ALIGN

目的：转子预定位，避免初始角度随机。

动作：

- 固定开环电角度 0 度。
- 输出 `align-current`。
- 持续 `align-time-ms`。
- 结束后进入 PULL。

### 4.3 PULL

目的：慢速开环拖动曲轴，同时给 `LOAD_DETECT` 提供稳定的负载趋势。

动作：

- 输出 `pull-current`。
- 开环 ERPM 从 `pull-start-erpm` 按 `pull-ramp-erpm-s` 爬升。
- 最大到 `pull-target-erpm`。
- 如果 compression 成立、HIGH_LOAD 已锁存，或速度达到 PULL 目标，进入 `LOAD_DETECT`。

### 4.4 LOAD_DETECT

目的：根据 `load_score` 和 `load_delta` 判断当前是压缩/高负载，还是可以继续加速。

动作：

- 如果 stall 成立，进入 `BACKOFF`。
- 如果 HIGH_LOAD 已锁存，进入 `PULSE`。
- 如果 LOW_LOAD 且速度达到 `boost-success-erpm`，进入 `ACCEL`。
- 如果速度达到 `pull-target-erpm`，进入 `ACCEL`。
- 否则回到 `PULL` 继续慢拉。

HIGH_LOAD 使用滞回，避免 `load_score` / `load_delta` 在压缩边缘抖动；`load_score` 是主判据，`load_delta` 只作为提前触发辅助：

```text
进入：load_score > ENGINE_LOAD_HIGH_SCORE
   或 load_score > (ENGINE_LOAD_HIGH_SCORE + ENGINE_LOAD_LOW_SCORE) / 2
      且 load_delta > ENGINE_LOAD_RISE_SCORE
   或 compression 已确认
      持续 ENGINE_HIGH_LOAD_ENTER_MS
退出：load_score < ENGINE_LOAD_LOW_SCORE
      且 load_delta < ENGINE_LOAD_FALL_SCORE
      且无 compression
      持续 ENGINE_HIGH_LOAD_EXIT_MS
```

### 4.5 PULSE

目的：用短脉冲冲过压缩上止点，不再长时间顶住压缩点。

动作：

- 每次进入 PULSE 都增加 `boost_pulse_count` 和 `total_pulse_count`。
- 第 1 / 2 / 3 个脉冲分别使用 `boost-current-1`、`boost-current-2`、`boost-current-3`。
- 默认单个脉冲最大 `boost-pulse-ms = 50ms`。
- `ENGINE_PULSE_MIN_MS = 50ms` 内禁止提前退出，保证最小能量窗口。
- 50ms 后如果 rpm 不上升、load 不下降且电流仍高，则提前进入 `GAP`，避免硬顶压缩峰。
- PULSE 以时间为主导逻辑：所有普通退出条件都必须等到 `ENGINE_PULSE_MIN_MS` 之后才允许执行。
- 如果滤波 ERPM 超过 `boost-success-erpm`，也要在最小能量窗口之后才进入 `GAP`，由 GAP 决定是否转入 `ACCEL`。

### 4.6 GAP

目的：PULSE 之间释放压缩阻力，避免连续高电流冲击。

动作：

- 输出 0A。
- 等待 `boost-gap-ms`。
- 如果 stall 成立，进入 `BACKOFF`。
- 如果 LOW_LOAD 且速度超过 `boost-success-erpm`，进入 `ACCEL`。
- 如果本轮脉冲次数未超过 `boost-max-pulses` 且总脉冲数未超过 `max-total-pulses`，回到 `LOAD_DETECT`。
- 否则进入 `BACKOFF`。

### 4.7 BACKOFF

目的：卡在压缩点时卸力/退让，保护电机、MOS 和电池。

动作：

- 立即输出 0A，并清除当前 PULSE 电流。
- 等待 `backoff-ms`，且 `state_hold_timer` 至少达到 `ENGINE_BACKOFF_RECOVER_HOLD_MS`。
- `retry_count++`。
- 如果 `retry_count <= max-retry`，进入 `RECOVER`。
- 否则进入 `FAULT`。

### 4.8 RECOVER

目的：从 BACKOFF 后恢复，避免 BACKOFF / RECOVER 之间抖动。状态优先级为 `BACKOFF > RECOVER > PULSE`：PULSE/GAP/ACCEL 遇到确认 stall 会立即转 BACKOFF；RECOVER 保留 200ms 保持时间，若保持后仍 stall 才允许重新转 BACKOFF。

动作：

- 默认输出 0A。
- 如果 `backoff-reverse-enable = 1`，允许小电流、小速度反向卸力；默认关闭。
- 必须满足 `ENGINE_BACKOFF_RECOVER_HOLD_MS` 后才允许回到 `ALIGN`。

### 4.9 ACCEL

目的：过压缩点后继续开环加速，给曲轴/转子增加惯量，并等待 Observer 稳定。

动作：

- 输出 `accel-current`。
- 开环 ERPM 按 `accel-ramp-erpm-s` 爬升。
- 最大到 `accel-target-erpm`。
- 当滤波 ERPM 高于 `obs-min-erpm`、没有 compression/stall、LOW_LOAD 成立并持续 `obs-stable-time-ms` 后进入 BLEND。
- 如果 ACCEL 中再次检测到 compression/stall，回到 `LOAD_DETECT`。

### 4.10 BLEND

目的：开环角度平滑融合到 observer 角度，避免硬切。

动作：

- 在 `blend-time-ms` 内将 `blend` 从 0 增加到 1。
- 读取 `mcpwm_foc_get_phase_observer()`。
- 用 `utils_angle_difference()` 计算开环角度到 observer 角度的差值。
- 调用 `mcpwm_foc_set_openloop_phase(accel-current, phase)` 做过渡。
- 完成后进入 RUN。
- 如果 BLEND 期间再次检测到 compression/stall，退出 BLEND 并回到 `LOAD_DETECT`。

注意：BLEND 是简化交接方案，实车如果 observer 接管抖动，需要继续提高 `obs-min-erpm` 或延长 `blend-time-ms`。

### 4.11 RUN

目的：退出启动增强逻辑，交还正常 FOC 控制。

动作：

- `engine_start_active = false`
- `mcpwm_foc_set_current(0.0f)`

### 4.12 RETRY

目的：冲压缩失败后等待并重试。

动作：

- 输出电流设为 0。
- 等待 `retry-delay-ms`。
- `retry_count++`。
- 如果 `retry_count <= max-retry`，回到 ALIGN。
- 否则进入 FAULT。

### 4.13 FAULT

目的：停止输出并保持故障状态。

动作：

- 输出电流设为 0。
- `engine_start_active = false`。
- 等待 stop/reset。

## 5. 安全保护

每次 `engine_start_update()` 都会检查：

- 当前 VESC fault 是否为 `FAULT_CODE_NONE`。
- 输入电压是否低于 Engine Start 专用 `min-vin`。
- Engine Start 总时间是否超过 `max-start-time-ms`。
- PULSE 总脉冲次数是否超过 `max-total-pulses`。
- 滤波电流是否超过内部 `ENGINE_OVERCURRENT_CURRENT`。

任一条件触发：

- 停止输出。
- `engine_start_active = false`。
- 进入 `ENGINE_START_FAULT`。

## 6. 负载、压缩和稳定性检测逻辑

当前检测由 `engine_start_update_filters()` 先更新低通滤波值，再由 `engine_start_detect_compression()`、`engine_start_high_load()`、`engine_start_low_load()` 判断。

### 6.1 load_score / load_delta

```text
load_score =
    ENGINE_LOAD_K_CURRENT * current_abs_filt
  + ENGINE_LOAD_K_DUTY    * duty_abs_filt
  - ENGINE_LOAD_K_ACCEL   * accel_filt

load_delta = load_score - last_load_score
```

其中 `erpm_abs_filt/current_abs_filt/duty_abs_filt` 使用 `ENGINE_LOAD_LP = 0.1` 的 EMA，一阶滤波，保持 MCU 负担很低。`load_delta` 不再单独二次 EMA，而是每次更新后直接取 `load_score` 的差分，减少对 10~30ms 压缩冲击的相位延迟。

为了避免无滤波微分信号过敏，`load_delta` 会先经过 `ENGINE_LOAD_DELTA_DEADBAND` 死区，小尖峰直接归零，再通过 `ENGINE_LOAD_DELTA_MAX` 限幅。`load_score` 是主判据；`load_delta` 只用于捕捉压缩负载的快速上升，作为提前触发辅助，避免把两个信号等权叠加导致响应变慢。

### 6.2 压缩点检测

判断条件：

```text
erpm_abs_filt < stall-erpm
current_abs_filt > stall-current
duty_abs_filt > stall-duty
上述条件持续 compression-time-ms
```

此外还会结合加速度低通值：如果 `accel_filt` 明显为负，同时电流和 duty 较高，也会累计 compression_ms。这比瞬时 rpm/current/duty 判断更不容易误判。

如果任一条件不满足，会重置压缩检测计时器，避免瞬态误判。

### 6.3 HIGH_LOAD 滞回

HIGH_LOAD 不是瞬时值，而是锁存状态：

```text
进入：load_score > ENGINE_LOAD_HIGH_SCORE
   或 load_score > (ENGINE_LOAD_HIGH_SCORE + ENGINE_LOAD_LOW_SCORE) / 2
      且 load_delta > ENGINE_LOAD_RISE_SCORE
   或 compression 已确认
      持续 ENGINE_HIGH_LOAD_ENTER_MS

退出：load_score < ENGINE_LOAD_LOW_SCORE
      且 load_delta < ENGINE_LOAD_FALL_SCORE
      且无 compression
      持续 ENGINE_HIGH_LOAD_EXIT_MS
```

目的：进入快、退出慢，防止压缩边缘抖动。

## 7. Observer 稳定判断逻辑

当前第一版 Observer 稳定函数为 `engine_start_observer_stable()`。

判断条件：

```text
abs(actual_erpm) >= obs-min-erpm
持续 obs-stable-time-ms
```

如果速度掉到阈值以下，会重置 observer 稳定计时器。

## 8. 参数实现方式

最初版本全部用宏写死。后续为了实车调试方便，已改为：

```text
宏默认值 + 运行时参数表 engine_start_params
```

宏仍在 `motor/mcpwm_foc.c` 顶部，作为默认值来源；状态机实际读取 `engine_start_params`。这样 Lisp 可以运行时覆盖参数，而不必每次重新编译刷写。

运行时参数表为 `engine_start_params_t`，对应参数 ID 枚举为 `engine_start_param_id_t`。

重要规则：

- 断电/重启后恢复宏默认值。
- `(engine-param-reset)` 会恢复宏默认值。
- Lisp 覆盖值不写入 flash。
- 不改 `mc_configuration`。
- 不改 VESC Tool 参数协议。

## 9. 当前参数表

| Lisp 参数名 | C enum | 默认值 | 单位 | 说明 |
|---|---|---:|---|---|
| `align-current` | `ENGINE_START_PARAM_ALIGN_CURRENT` | `60.0` | A | ALIGN 预定位电流 |
| `align-time-ms` | `ENGINE_START_PARAM_ALIGN_TIME_MS` | `500` | ms | ALIGN 持续时间 |
| `pull-current` | `ENGINE_START_PARAM_PULL_CURRENT` | `120.0` | A | PULL 慢拉电流 |
| `pull-start-erpm` | `ENGINE_START_PARAM_PULL_START_ERPM` | `100.0` | eRPM | PULL 起始开环速度 |
| `pull-target-erpm` | `ENGINE_START_PARAM_PULL_TARGET_ERPM` | `800.0` | eRPM | PULL 目标速度 |
| `pull-ramp-erpm-s` | `ENGINE_START_PARAM_PULL_RAMP_ERPM_S` | `800.0` | eRPM/s | PULL 开环速度爬升率 |
| `boost-current` | `ENGINE_START_PARAM_BOOST_CURRENT` | `160.0` | A | 兼容旧 Lisp 名称；设置时同步到第 1 个 PULSE 电流 |
| `boost-time-ms` | `ENGINE_START_PARAM_BOOST_TIME_MS` | `50` | ms | 兼容旧 Lisp 名称；设置时同步到 PULSE 脉冲宽度 |
| `boost-current-1` | `ENGINE_START_PARAM_BOOST_CURRENT_1` | `160.0` | A | 第 1 个 PULSE 脉冲电流 |
| `boost-current-2` | `ENGINE_START_PARAM_BOOST_CURRENT_2` | `190.0` | A | 第 2 个 PULSE 脉冲电流 |
| `boost-current-3` | `ENGINE_START_PARAM_BOOST_CURRENT_3` | `220.0` | A | 第 3 个 PULSE 脉冲电流；实车必须从低值验证 |
| `boost-pulse-ms` | `ENGINE_START_PARAM_BOOST_PULSE_MS` | `50` | ms | 单个 PULSE 最大脉冲宽度；内部还有 `ENGINE_PULSE_MIN_MS` 最小能量窗口 |
| `boost-gap-ms` | `ENGINE_START_PARAM_BOOST_GAP_MS` | `100` | ms | PULSE 之间的 0A 释放间隔 |
| `boost-max-pulses` | `ENGINE_START_PARAM_BOOST_MAX_PULSES` | `3` | 次 | 单轮压缩点最多 PULSE 次数 |
| `boost-success-erpm` | `ENGINE_START_PARAM_BOOST_SUCCESS_ERPM` | `800.0` | eRPM | PULSE/GAP 后允许进入 ACCEL 的最低速度 |
| `accel-current` | `ENGINE_START_PARAM_ACCEL_CURRENT` | `180.0` | A | ACCEL 加速电流 |
| `accel-target-erpm` | `ENGINE_START_PARAM_ACCEL_TARGET_ERPM` | `3000.0` | eRPM | ACCEL 目标速度 |
| `accel-ramp-erpm-s` | `ENGINE_START_PARAM_ACCEL_RAMP_ERPM_S` | `1800.0` | eRPM/s | ACCEL 开环速度爬升率 |
| `obs-min-erpm` | `ENGINE_START_PARAM_OBS_MIN_ERPM` | `2500.0` | eRPM | Observer 接管最低速度 |
| `blend-time-ms` | `ENGINE_START_PARAM_BLEND_TIME_MS` | `300` | ms | 开环角度融合到 observer 的时间 |
| `retry-delay-ms` | `ENGINE_START_PARAM_RETRY_DELAY_MS` | `300` | ms | RETRY 停顿时间 |
| `max-retry` | `ENGINE_START_PARAM_MAX_RETRY` | `3` | 次 | 最大重试次数 |
| `max-start-time-ms` | `ENGINE_START_PARAM_MAX_START_TIME_MS` | `5000` | ms | 启动总超时 |
| `stall-erpm` | `ENGINE_START_PARAM_STALL_ERPM` | `300.0` | eRPM | 压缩/卡滞低速阈值 |
| `stall-current` | `ENGINE_START_PARAM_STALL_CURRENT` | `100.0` | A | 压缩/卡滞电流阈值 |
| `stall-duty` | `ENGINE_START_PARAM_STALL_DUTY` | `0.12` | duty | 压缩/卡滞 duty 阈值 |
| `compression-time-ms` | `ENGINE_START_PARAM_COMPRESSION_TIME_MS` | `50` | ms | 压缩点检测持续时间 |
| `obs-stable-time-ms` | `ENGINE_START_PARAM_OBS_STABLE_TIME_MS` | `200` | ms | Observer 稳定持续时间 |
| `direction` | `ENGINE_START_PARAM_DIRECTION` | `1.0` | sign | 开环启动方向，正数为正向，负数为反向 |
| `stall-confirm-ms` | `ENGINE_START_PARAM_STALL_CONFIRM_MS` | `120` | ms | 卡死保护确认时间 |
| `max-total-pulses` | `ENGINE_START_PARAM_MAX_TOTAL_PULSES` | `9` | 次 | 整个启动过程最多 PULSE 脉冲数 |
| `min-vin` | `ENGINE_START_PARAM_MIN_VIN` | `24.0` | V | Engine Start 最低母线电压 |
| `backoff-ms` | `ENGINE_START_PARAM_BACKOFF_MS` | `200` | ms | BACKOFF 卸力等待时间 |
| `backoff-reverse-enable` | `ENGINE_START_PARAM_BACKOFF_REVERSE_ENABLE` | `0` | bool | 是否启用小电流反向卸力；默认关闭 |
| `backoff-current` | `ENGINE_START_PARAM_BACKOFF_CURRENT` | `-40.0` | A | 反向卸力电流，仅启用 backoff reverse 时使用 |
| `backoff-erpm` | `ENGINE_START_PARAM_BACKOFF_ERPM` | `-100.0` | eRPM | 反向卸力速度，仅启用 backoff reverse 时使用 |

### 9.1 内部稳定性宏参数

以下参数不是 Lisp 运行时参数，主要用于状态机稳定性和保护。修改它们需要重新编译固件。

| C 宏 | 默认值 | 单位 | 作用 |
|---|---:|---|---|
| `ENGINE_LOAD_LP` | `0.1` | ratio | `erpm/current/duty` 的 EMA 系数；`load_delta` 直接由 `load_score` 差分得到，避免二次 EMA 延迟 |
| `ENGINE_LOAD_K_CURRENT` | `1.0` | score/A | `load_score` 中电流权重 |
| `ENGINE_LOAD_K_DUTY` | `300.0` | score/duty | `load_score` 中 duty 权重 |
| `ENGINE_LOAD_K_ACCEL` | `0.02` | score/(eRPM/s) | `load_score` 中加速度权重；减速会提高 load_score |
| `ENGINE_LOAD_HIGH_SCORE` | `120.0` | score | HIGH_LOAD 进入分数阈值 |
| `ENGINE_LOAD_LOW_SCORE` | `70.0` | score | HIGH_LOAD 退出/LOW_LOAD 分数阈值 |
| `ENGINE_LOAD_RISE_SCORE` | `15.0` | score/update | HIGH_LOAD 进入时的 load_delta 上升阈值 |
| `ENGINE_LOAD_FALL_SCORE` | `0.0` | score/update | HIGH_LOAD 退出/LOW_LOAD 时的 load_delta 阈值 |
| `ENGINE_LOAD_DELTA_DEADBAND` | `5.0` | score/update | load_delta 死区，小于该值的噪声尖峰归零 |
| `ENGINE_LOAD_DELTA_MAX` | `60.0` | score/update | load_delta 限幅，防止高频尖峰直接抢占 HIGH_LOAD |
| `ENGINE_HIGH_LOAD_ENTER_MS` | `20` | ms | HIGH_LOAD 进入确认时间 |
| `ENGINE_HIGH_LOAD_EXIT_MS` | `50` | ms | HIGH_LOAD 退出确认时间 |
| `ENGINE_PULSE_MIN_MS` | `50` | ms | PULSE 最小能量窗口；小于该时间禁止提前退出 |
| `ENGINE_STATE_DEBOUNCE_MS` | `10` | ms | 普通状态切换 debounce |
| `ENGINE_BACKOFF_RECOVER_HOLD_MS` | `200` | ms | BACKOFF / RECOVER 互斥保持时间 |
| `ENGINE_OVERCURRENT_CURRENT` | `260.0` | A | Engine Start 过流停止阈值 |
| `ENGINE_RECOVER_MS` | `150` | ms | RECOVER 基础等待时间；实际还受 200ms hold 限制 |

## 10. 参数合法性检查

`mcpwm_foc_engine_start_set_param()` 会做基础检查：

- 所有参数必须是 finite number。
- `stall-duty` 必须在 `0.0 ~ 1.0`。
- `max-retry`、`boost-max-pulses`、`max-total-pulses` 必须在 `0 ~ 20`。
- `direction` 的绝对值必须在 `0.5 ~ 1.0`，实际使用时会归一为正向或反向。
- `backoff-reverse-enable` 必须在 `0.0 ~ 1.0`。
- 时间类参数必须大于 0，避免除零或无意义状态。
- 其他参数必须大于等于 0。

## 11. Terminal 使用方法

### 启动

```text
engine_start
```

### 停止

```text
engine_stop
```

### 查看是否 active

```text
engine_status
```

`engine_status` 会输出 active、state、retry_count、boost_pulse_count、total_pulse_count、openloop_erpm、openloop_phase、blend、iq_target、滤波后的 erpm/current/duty、accel、load_score、load_delta、compression_ms、stall_ms、obs_stable_ms 和 last_stop_reason，便于实车判断卡在哪个阶段。

Terminal 命令当前只做 start/stop/status，不负责改参数。调参数优先使用 Lisp。

## 12. Lisp 使用方法

根目录提供了完整测试脚本：

```text
ENGINE_START_TEST.lisp
```

该脚本会显式写入 A40 / 29.5V / 21 对极的建议初始值，启动 Engine Start，并以 0.1s 间隔打印 `(engine-status)`，用于记录 `state`、脉冲计数、滤波转速/电流/duty、`load-score`、`load-delta`、compression/stall/observer 稳定时间和停止原因。

### 启动/停止

```lisp
(engine-start)
(engine-stop)
(engine-start-active)
(engine-status) ; 返回 (state active retry-count boost-pulse-count total-pulse-count openloop-erpm openloop-phase blend iq-target erpm-abs-filt current-abs-filt duty-abs-filt accel-filt load-score load-delta compression-ms stall-ms obs-stable-ms last-stop-reason)
```

### 读取参数

```lisp
(engine-param-get 'boost-current)
(engine-param-get 'pull-current)
(engine-param-get 'stall-duty)
```

### 修改参数

```lisp
(engine-param-set 'boost-current-1 120.0)
(engine-param-set 'boost-current-2 150.0)
(engine-param-set 'boost-current-3 180.0)
(engine-param-set 'boost-pulse-ms 50)
(engine-param-set 'boost-gap-ms 100)
(engine-param-set 'pull-current 110.0)
(engine-param-set 'stall-duty 0.10)
(engine-param-set 'direction 1.0) ; 如电机方向相反可改为 -1.0
```

### 恢复默认值

```lisp
(engine-param-reset)
```

### 一段典型调试脚本

```lisp
; 恢复默认值
(engine-param-reset)

; 温和一点的首轮参数
(engine-param-set 'pull-current 100.0)
(engine-param-set 'boost-current-1 120.0)
(engine-param-set 'boost-current-2 150.0)
(engine-param-set 'boost-current-3 180.0)
(engine-param-set 'boost-pulse-ms 50)
(engine-param-set 'boost-gap-ms 100)
(engine-param-set 'accel-current 150.0)
(engine-param-set 'stall-duty 0.10)
(engine-param-set 'direction 1.0) ; 如电机方向相反可改为 -1.0

; 启动
(engine-start)
```

也可以用数字 ID 调参数，例如：

```lisp
(engine-param-set 6 220.0) ; 6 = boost-current
(engine-param-get 6)
```

但建议优先使用符号名，避免 ID 顺序记错。

## 13. 实车调参建议

### 优先级 1：是否能拉动和冲过压缩点

重点调：

- `pull-current`
- `boost-current-1`
- `boost-current-2`
- `boost-current-3`
- `boost-pulse-ms`
- `boost-gap-ms`
- `stall-erpm`
- `stall-current`
- `stall-duty`
- `compression-time-ms`

建议：

- 如果慢拉拉不动，提高 `pull-current`。
- 如果遇到压缩点但冲不过，逐步提高 `boost-current-1/2/3` 或 `boost-pulse-ms`，不要直接上 250A。
- 如果 PULSE 连续撞击太硬，适当增大 `boost-gap-ms`。
- 如果误判压缩点，提高 `stall-current`、`stall-duty` 或 `compression-time-ms`。
- 如果明显卡住但不进 PULSE，降低 `stall-current`、`stall-duty` 或缩短 `compression-time-ms`，同时检查 `load_score/load_delta` 是否达到 HIGH_LOAD。

### 优先级 2：过点后是否能稳定加速

重点调：

- `accel-current`
- `accel-target-erpm`
- `accel-ramp-erpm-s`

建议：

- 过压缩点后掉速，提高 `accel-current`。
- 机械冲击太大，降低 `accel-ramp-erpm-s`。

### 优先级 3：Observer 接管是否平顺

重点调：

- `obs-min-erpm`
- `obs-stable-time-ms`
- `blend-time-ms`

建议：

- 接管抖动，提高 `obs-min-erpm` 或 `blend-time-ms`。
- 接管太晚，降低 `obs-min-erpm`。

## 14. 后续修改注意事项

### 不建议修改的内容

除非明确需求变化，否则不要改：

- VESC Tool
- `datatypes.h`
- `conf_general.c`
- `commands.c`
- 参数协议
- ADC 采样
- HFI
- Observer 核心算法

### 如果继续增强，建议优先做

1. 根据实车结果继续扩展 `engine_status`，例如增加当前参数快照、电压、电流、duty、fault。
2. 如 Lisp 自动调参需要更清晰的字段名，可在 `(engine-status)` 之外增加 `(engine-state)`、`(engine-retry-count)` 等单项读取函数。
3. 增强 BLEND，不再简单用 `mcpwm_foc_set_openloop_phase()`，而是更贴近 FOC 内部 observer 接管路径。
4. 增加压缩检测的低通/滞回逻辑，避免边界抖动。
5. 如果需要正反方向更严格区分，可将 `direction` 从 sign 扩展为带方向状态显示和安全确认的参数，但仍不要改 VESC Tool 协议。
6. 如果最终需要持久化参数，再考虑独立 flash storage 或已有 Lisp storage，不要直接改 `mc_configuration`，除非明确要改协议。

### 如果发现普通控制模式被影响

重点检查：

- `engine_start_active` 是否正确退出。
- `engine_start_update()` 是否只在 active 或 fault 处理时执行。
- 外部普通 `set_current/set_rpm/set_duty` 是否在 Engine Start active 时被状态机覆盖。

当前设计是：Engine Start 未 active 时，状态机立即 return，不影响普通控制。

## 15. 已验证命令

当前已用推荐 ARM GCC 7-2018-q2 工具链通过以下命令验证：

```bash
git diff --check
make 60_clean
make 60 -j2
```

`make 60 -j2` 已成功生成：

```text
build/60/60.elf
build/60/60.hex
build/60/60.bin
build/60/60.dmp
build/60/60.list
```
