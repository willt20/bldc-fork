# Engine Start Event Robust System

This document records the final Engine Start architecture used in this fork.

## Architecture

Engine Start is now a minimal event-driven controller. It does not use the old pulse/gap/prewarn timing system, stall-based PULL decisions, or the V3/V4/V5/V6 learning and policy layers for control. It can optionally run a short reverse preload before ALIGN.

The active layers are:

1. **Event Detection**
   * `ENTER_COMPRESSION`
   * `PEAK_REACHED`
   * `RELEASE`

   Events are inferred from filtered `load_delta`, Iq/current level, and ERPM slope.

2. **Event Robustifier**
   * `event_confidence` in the range `0.0..1.0`
   * two-sample debounce
   * state locking through the existing Engine Start state machine
   * separate watchdogs through `pull-event-timeout-ms` and `pulse-event-timeout-ms`

3. **State Machine Execution**
   * optional `PRELOAD` before alignment
   * `ALIGN`
   * `PULL` as event wait mode
   * `LOAD_DETECT` compatibility routing
   * `PULSE`
   * `GAP`
   * `ACCEL`
   * `BLEND`
   * `RUN`
   * `BACKOFF`
   * `FAULT`

## State number map

Use this table when reading `(engine-status)` or `engine_status` output. `PRELOAD` is assigned number 11 so the existing 0..10 state numbers remain unchanged:

| Number | State |
|---:|---|
| 0 | `IDLE` |
| 1 | `ALIGN` |
| 2 | `PULL` |
| 3 | `LOAD_DETECT` |
| 4 | `PULSE` |
| 5 | `GAP` |
| 6 | `BACKOFF` |
| 7 | `ACCEL` |
| 8 | `BLEND` |
| 9 | `RUN` |
| 10 | `FAULT` |
| 11 | `PRELOAD` |

## PULL event wait mode

`PULL` no longer uses stall ERPM/current/duty to enter `BACKOFF`. It waits for robust events:

* `ENTER_COMPRESSION` with confidence above threshold enters `PULSE`.
* `PEAK_REACHED` enters `ACCEL`.
* `RELEASE` enters `ACCEL` or `BLEND` if the observer is already stable.
* No event for longer than `pull-event-timeout-ms` enters `BACKOFF`, which faults with timeout. PULSE/GAP use the much shorter `pulse-event-timeout-ms` safety watchdog.

## Runtime parameters

Only the minimal runtime parameter set is exposed to Lisp/terminal parameter APIs:

| Lisp name | Meaning |
|---|---|
| `align-current` | ALIGN current. |
| `pull-current` | PULL event-wait current. |
| `boost-current-1` | First event-driven boost pulse current. |
| `boost-current-2` | Second event-driven boost pulse current. |
| `boost-current-3` | Third and later event-driven boost pulse current. |
| `accel-current` | ACCEL/BLEND current. |
| `min-vin` | Minimum input voltage for Engine Start. |
| `max-start-time-ms` | Safety watchdog for the full start attempt. |
| `event-confidence-threshold` | Default `0.65`; event confidence needed to accept an event. |
| `pull-event-timeout-ms` | Default `500`; PULL/LOAD_DETECT no-event watchdog. |
| `pulse-event-timeout-ms` | Default `15`; PULSE/GAP safety watchdog. |
| `preload-enable` | Enable optional reverse preload before ALIGN. Default `1.0`; set `0.0` to skip. |
| `preload-current` | Reverse preload current. Default `-12A`; valid `-20A..20A`. |
| `preload-time-ms` | Reverse preload duration. Default `500ms`; set `0` or disable preload to skip. |

## Lisp usage

```lisp
(engine-param-set 'preload-enable 1.0)
(engine-param-set 'preload-current -12.0)
(engine-param-set 'preload-time-ms 500.0)
(engine-param-set 'align-current 5.0)
(engine-param-set 'pull-current 12.0)
(engine-param-set 'boost-current-1 20.0)
(engine-param-set 'boost-current-2 30.0)
(engine-param-set 'boost-current-3 40.0)
(engine-param-set 'accel-current 15.0)
(engine-param-set 'event-confidence-threshold 0.65)
(engine-param-set 'pull-event-timeout-ms 500)
(engine-param-set 'pulse-event-timeout-ms 15)
(engine-start)
(engine-status)
(engine-stop)
```

`(engine-status)` returns:

```lisp
(state event-state event-confidence fault-reason active)
```

## Removed / disabled systems

The following old systems are no longer part of control:

* pulse/gap/prewarn timing and ratios
* `engine-period-ms`
* stall-based PULL backoff logic
* pull stall ignore window
* V3/V4 learning control
* V5 policy selection
* V6 knowledge preload/save
* timing mode and timing clamp status output

They are intentionally not exposed in `(engine-status)` or Lisp parameter names. Reverse preload is not part of those removed systems; it is an optional pre-ALIGN positioning step controlled by `preload-enable`, `preload-current`, and `preload-time-ms`.

## Non-goals

This change does not modify FOC, PWM, ADC, Observer, VESC Tool protocol, EEPROM, Flash layout, `mc_configuration`, or `app_configuration`.
