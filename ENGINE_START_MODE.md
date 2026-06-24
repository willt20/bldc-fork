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
ENGINE_START_BOOST
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

目的：慢速开环拖动曲轴，检测是否遇到压缩阻力点。

动作：

- 输出 `pull-current`。
- 开环 ERPM 从 `pull-start-erpm` 按 `pull-ramp-erpm-s` 爬升。
- 最大到 `pull-target-erpm`。
- 如果压缩点检测成立，进入 BOOST。
- 如果转速达到 PULL 目标，进入 ACCEL。

### 4.4 BOOST

目的：短时大电流冲过压缩上止点。

动作：

- 输出 `boost-current`。
- 持续 `boost-time-ms`。
- 结束后如果实际 ERPM 仍低于 `stall-erpm`，进入 RETRY。
- 否则进入 ACCEL。

### 4.5 ACCEL

目的：过压缩点后继续开环加速，给曲轴/转子增加惯量，并等待 Observer 稳定。

动作：

- 输出 `accel-current`。
- 开环 ERPM 按 `accel-ramp-erpm-s` 爬升。
- 最大到 `accel-target-erpm`。
- 当实际 ERPM 高于 `obs-min-erpm` 并持续 `obs-stable-time-ms` 后进入 BLEND。

### 4.6 BLEND

目的：开环角度平滑融合到 observer 角度，避免硬切。

动作：

- 在 `blend-time-ms` 内将 `blend` 从 0 增加到 1。
- 读取 `mcpwm_foc_get_phase_observer()`。
- 用 `utils_angle_difference()` 计算开环角度到 observer 角度的差值。
- 调用 `mcpwm_foc_set_openloop_phase(accel-current, phase)` 做过渡。
- 完成后进入 RUN。

注意：BLEND 是第一版简化方案，实车如果 observer 接管抖动，需要后续增强。

### 4.7 RUN

目的：退出启动增强逻辑，交还正常 FOC 控制。

动作：

- `engine_start_active = false`
- `mcpwm_foc_set_current(0.0f)`

### 4.8 RETRY

目的：冲压缩失败后等待并重试。

动作：

- 输出电流设为 0。
- 等待 `retry-delay-ms`。
- `retry_count++`。
- 如果 `retry_count <= max-retry`，回到 ALIGN。
- 否则进入 FAULT。

### 4.9 FAULT

目的：停止输出并保持故障状态。

动作：

- 输出电流设为 0。
- `engine_start_active = false`。
- 等待 stop/reset。

## 5. 安全保护

每次 `engine_start_update()` 都会检查：

- 当前 VESC fault 是否为 `FAULT_CODE_NONE`。
- 输入电压是否低于当前配置的 `l_min_vin`。
- Engine Start 总时间是否超过 `max-start-time-ms`。

任一条件触发：

- 停止输出。
- `engine_start_active = false`。
- 进入 `ENGINE_START_FAULT`。

## 6. 压缩点检测逻辑

当前第一版压缩点检测函数为 `engine_start_detect_compression()`。

判断条件：

```text
abs(actual_erpm) < stall-erpm
abs_motor_current_filtered > stall-current
abs_duty_filtered > stall-duty
上述条件持续 compression-time-ms
```

如果任一条件不满足，会重置压缩检测计时器，避免瞬态误判。

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
| `pull-ramp-erpm-s` | `ENGINE_START_PARAM_PULL_RAMP_ERPM_S` | `1000.0` | eRPM/s | PULL 开环速度爬升率 |
| `boost-current` | `ENGINE_START_PARAM_BOOST_CURRENT` | `240.0` | A | BOOST 冲击电流 |
| `boost-time-ms` | `ENGINE_START_PARAM_BOOST_TIME_MS` | `120` | ms | BOOST 持续时间 |
| `accel-current` | `ENGINE_START_PARAM_ACCEL_CURRENT` | `180.0` | A | ACCEL 加速电流 |
| `accel-target-erpm` | `ENGINE_START_PARAM_ACCEL_TARGET_ERPM` | `1800.0` | eRPM | ACCEL 目标速度 |
| `accel-ramp-erpm-s` | `ENGINE_START_PARAM_ACCEL_RAMP_ERPM_S` | `2000.0` | eRPM/s | ACCEL 开环速度爬升率 |
| `obs-min-erpm` | `ENGINE_START_PARAM_OBS_MIN_ERPM` | `1200.0` | eRPM | Observer 接管最低速度 |
| `blend-time-ms` | `ENGINE_START_PARAM_BLEND_TIME_MS` | `200` | ms | 开环角度融合到 observer 的时间 |
| `retry-delay-ms` | `ENGINE_START_PARAM_RETRY_DELAY_MS` | `300` | ms | RETRY 停顿时间 |
| `max-retry` | `ENGINE_START_PARAM_MAX_RETRY` | `3` | 次 | 最大重试次数 |
| `max-start-time-ms` | `ENGINE_START_PARAM_MAX_START_TIME_MS` | `5000` | ms | 启动总超时 |
| `stall-erpm` | `ENGINE_START_PARAM_STALL_ERPM` | `150.0` | eRPM | 压缩/卡滞低速阈值 |
| `stall-current` | `ENGINE_START_PARAM_STALL_CURRENT` | `100.0` | A | 压缩/卡滞电流阈值 |
| `stall-duty` | `ENGINE_START_PARAM_STALL_DUTY` | `0.12` | duty | 压缩/卡滞 duty 阈值 |
| `compression-time-ms` | `ENGINE_START_PARAM_COMPRESSION_TIME_MS` | `50` | ms | 压缩点检测持续时间 |
| `obs-stable-time-ms` | `ENGINE_START_PARAM_OBS_STABLE_TIME_MS` | `100` | ms | Observer 稳定持续时间 |

## 10. 参数合法性检查

`mcpwm_foc_engine_start_set_param()` 会做基础检查：

- 所有参数必须是 finite number。
- `stall-duty` 必须在 `0.0 ~ 1.0`。
- `max-retry` 必须在 `0 ~ 20`。
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

Terminal 命令当前只做 start/stop/status，不负责改参数。调参数优先使用 Lisp。

## 12. Lisp 使用方法

### 启动/停止

```lisp
(engine-start)
(engine-stop)
(engine-start-active)
```

### 读取参数

```lisp
(engine-param-get 'boost-current)
(engine-param-get 'pull-current)
(engine-param-get 'stall-duty)
```

### 修改参数

```lisp
(engine-param-set 'boost-current 220.0)
(engine-param-set 'boost-time-ms 100)
(engine-param-set 'pull-current 110.0)
(engine-param-set 'stall-duty 0.10)
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
(engine-param-set 'boost-current 200.0)
(engine-param-set 'boost-time-ms 100)
(engine-param-set 'accel-current 150.0)
(engine-param-set 'stall-duty 0.10)

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
- `boost-current`
- `boost-time-ms`
- `stall-erpm`
- `stall-current`
- `stall-duty`
- `compression-time-ms`

建议：

- 如果慢拉拉不动，提高 `pull-current`。
- 如果遇到压缩点但冲不过，提高 `boost-current` 或 `boost-time-ms`。
- 如果误判压缩点，提高 `stall-current`、`stall-duty` 或 `compression-time-ms`。
- 如果明显卡住但不进 BOOST，降低 `stall-current`、`stall-duty` 或缩短 `compression-time-ms`。

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

1. 增加 `engine_status` 输出更多内部状态，例如当前 state、retry_count、openloop_erpm、blend、当前参数值。
2. 增加 Lisp 状态读取函数，例如 `(engine-state)`、`(engine-retry-count)`、`(engine-openloop-erpm)`。
3. 增强 BLEND，不再简单用 `mcpwm_foc_set_openloop_phase()`，而是更贴近 FOC 内部 observer 接管路径。
4. 增加压缩检测的低通/滞回逻辑，避免边界抖动。
5. 增加可选方向参数，但仍不要改 VESC Tool 协议。
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

