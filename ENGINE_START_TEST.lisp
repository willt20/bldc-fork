; Engine Start Mode no-load low-current Lisp debug script.
; Target hardware used for defaults: KV ~= 65 rpm/V, Vin ~= 29.5 V, 42 poles / 21 pole pairs.
; Use this version for bench/no-load direction and status validation before connecting the engine.
;
; Safety:
; - Put the vehicle/engine in a safe state before running this script.
; - Keep a hard power cut-off ready.
; - This no-load script uses very low currents: align 5 A, pull 12 A, boost 10/12/15 A, accel 10 A.
; - Do not use these currents as final engine-cranking values; increase gradually only after logs are stable.
; - If state enters FAULT, run (engine-stop) before starting again.
;
; engine-status returns:
; (state active retry-count boost-pulse-count total-pulse-count
;  openloop-erpm openloop-phase blend iq-target
;  erpm-abs-filt current-abs-filt duty-abs-filt accel-filt load-score load-delta
;  compression-ms stall-ms obs-stable-ms last-stop-reason
;  stability-score learning-state learning-window-count consecutive-success
;  strategy knowledge-count avg-start-time-ms v6-confidence learning-gain policy-mode timing-mode timing-clamp-status
;  preload-enable preload-active preload-elapsed-ms pull-elapsed-ms pull-stall-ignored)
;
; State ids:
; 0 IDLE, 1 PRELOAD, 2 PRELOAD_SETTLE, 3 ALIGN, 4 PULL, 5 LOAD_DETECT,
; 6 PULSE, 7 GAP, 8 BACKOFF, 9 RECOVER, 10 ACCEL, 11 BLEND, 12 RUN, 13 RETRY, 14 FAULT
;
; Policy modes:
; 0 V5_ONLY, 1 V6_ONLY, 2 HYBRID_LOCKED
; v6-confidence is clamped to 0.30..0.95 before policy arbitration.
; Timing mode bitmask: bit0 pulse manual, bit1 gap manual, bit2 prewarn manual. 0 means all AUTO.
; Timing clamp bitmask: bit0 pulse clamped, bit1 gap clamped, bit2 prewarn clamped. 0 means no clamp.
;
; Stop reasons:
; 0 NONE, 1 USER, 2 TIMEOUT, 3 UNDERVOLTAGE, 4 FAULT,
; 5 MAX_RETRY, 6 MAX_PULSES, 7 STALL, 8 OVERCURRENT

(defun engine-print-params ()
    {
        (print "=== Engine Start Params ===")
        (print "direction=" (engine-param-get 'direction))
        (print "min-vin=" (engine-param-get 'min-vin))
        (print "align-current=" (engine-param-get 'align-current))
        (print "pull-current=" (engine-param-get 'pull-current))
        (print "boost-current-1=" (engine-param-get 'boost-current-1))
        (print "boost-current-2=" (engine-param-get 'boost-current-2))
        (print "boost-current-3=" (engine-param-get 'boost-current-3))
        (print "engine-period-ms=" (engine-param-get 'engine-period-ms))
        (print "pulse-ratio=" (engine-param-get 'pulse-ratio))
        (print "prewarn-ratio=" (engine-param-get 'prewarn-ratio))
        (print "gap-ratio=" (engine-param-get 'gap-ratio))
        (print "boost-pulse-ms=" (engine-param-get 'boost-pulse-ms))
        (print "boost-gap-ms=" (engine-param-get 'boost-gap-ms))
        (print "prewarn-hold-ms=" (engine-param-get 'prewarn-hold-ms))
        (print "boost-success-erpm=" (engine-param-get 'boost-success-erpm))
        (print "preload-enable=" (engine-param-get 'preload-enable))
        (print "preload-current=" (engine-param-get 'preload-current))
        (print "preload-time-ms=" (engine-param-get 'preload-time-ms))
        (print "preload-settle-ms=" (engine-param-get 'preload-settle-ms))
        (print "pull-stall-ignore-ms=" (engine-param-get 'pull-stall-ignore-ms))
        (print "accel-current=" (engine-param-get 'accel-current))
        (print "accel-target-erpm=" (engine-param-get 'accel-target-erpm))
        (print "obs-min-erpm=" (engine-param-get 'obs-min-erpm))
        (print "stall-erpm=" (engine-param-get 'stall-erpm))
        (print "stall-current=" (engine-param-get 'stall-current))
        (print "stall-duty=" (engine-param-get 'stall-duty))
        (print "max-total-pulses=" (engine-param-get 'max-total-pulses))
        (print "max-retry=" (engine-param-get 'max-retry))
        (print "max-start-time-ms=" (engine-param-get 'max-start-time-ms))
    }
)

(defun engine-monitor (n)
    (if (> n 0)
        {
            (print "status=" (engine-status))
            (sleep 0.05)
            (engine-monitor (- n 1))
        }
        {
            (print "=== Monitor Done ===")
            (print "final-status=" (engine-status))
        }
    )
)

(defun engine-apply-noload-low-current-defaults ()
    {
        ; Start from firmware defaults, then write conservative no-load test values explicitly
        ; so this script is self-documenting and repeatable even if firmware defaults change later.
        (engine-param-reset)

        ; Direction: change to -1.0 if crank direction is wrong.
        (engine-param-set 'direction 1.0)

        ; 29.5 V system: stop Engine Start if bus sags too far.
        (engine-param-set 'min-vin 24.0)

        ; No-load current limits. Keep these low for first bench validation.
        (engine-param-set 'align-current 5.0)
        (engine-param-set 'pull-current 12.0)
        (engine-param-set 'accel-current 10.0)

        ; No-load speeds for 21 pole pairs. 85 KV * 25 V is about 44k eRPM no-load,
        ; so these bench values are still conservative but high enough for smoother handoff.
        ; 500 eRPM ~= 23.8 mechanical rpm, 3000 eRPM ~= 142.9 mechanical rpm.
        (engine-param-set 'pull-start-erpm 500.0)
        (engine-param-set 'pull-target-erpm 3000.0)
        (engine-param-set 'pull-ramp-erpm-s 3000.0)

        ; Mechanical-period adaptive timing. With 34 ms, pulse/gap/prewarn are auto-derived
        ; as about 12 ms / 12 ms / 10 ms for the measured 2..14 ms compression window.
        ; Do not set pulse/gap/prewarn manually unless intentionally overriding auto timing.
        (engine-param-set 'engine-period-ms 34.0)
        ; Advanced timing ratios. Prefer engine-period-ms first; tune these only when necessary.
        (engine-param-set 'pulse-ratio 0.35)
        (engine-param-set 'prewarn-ratio 0.30)
        (engine-param-set 'gap-ratio 0.35)

        ; Very low no-load pulsed boost ladder. If PULSE is entered unexpectedly, keep it safe.
        (engine-param-set 'boost-current-1 10.0)
        (engine-param-set 'boost-current-2 12.0)
        (engine-param-set 'boost-current-3 15.0)
        (engine-param-set 'boost-max-pulses 1.0)
        (engine-param-set 'boost-success-erpm 3000.0)

        ; No-load accel target for smoother transition validation. Still far below ~44k eRPM no-load.
        (engine-param-set 'accel-target-erpm 8000.0)
        (engine-param-set 'accel-ramp-erpm-s 6000.0)

        ; Delay observer handoff until a higher no-load speed and blend more gently.
        (engine-param-set 'obs-min-erpm 5000.0)
        (engine-param-set 'obs-stable-time-ms 200.0)
        (engine-param-set 'blend-time-ms 400.0)

        ; Compression/stall detection. No-load should not false-trigger BACKOFF.
        (engine-param-set 'stall-erpm 80.0)
        (engine-param-set 'stall-current 60.0)
        (engine-param-set 'stall-duty 0.20)
        (engine-param-set 'compression-time-ms 50.0)
        (engine-param-set 'stall-confirm-ms 200.0)

        ; Global limits.
        (engine-param-set 'max-start-time-ms 5000.0)
        (engine-param-set 'max-total-pulses 2.0)
        (engine-param-set 'max-retry 1.0)

        ; PULL false-stall guard for no-load low-current bench starts.
        (engine-param-set 'pull-stall-ignore-ms 300.0)

        ; Optional reverse preload is disabled for default no-load validation.
        ; To verify it: set preload-enable=1, preload-current=-8, preload-time=500, settle=30.
        (engine-param-set 'preload-enable 0.0)
        (engine-param-set 'preload-current -8.0)
        (engine-param-set 'preload-time-ms 500.0)
        (engine-param-set 'preload-settle-ms 30.0)

        ; Default backoff only unloads. Do not enable reverse until mechanically validated.
        (engine-param-set 'backoff-ms 200.0)
        (engine-param-set 'backoff-reverse-enable 0.0)
        (engine-param-set 'backoff-current -40.0)
        (engine-param-set 'backoff-erpm -100.0)
    }
)

(defun engine-test-run ()
    {
        (print "=== Engine Start No-Load Low-Current Debug Test ===")
        (engine-stop)
        (engine-apply-noload-low-current-defaults)
        (engine-print-params)
        (print "initial-status=" (engine-status))
        (print "=== START ===")
        (engine-start)

        ; 120 samples * 0.05 s = 6 s. max-start-time-ms is 5 s, so this captures fast transitions.
        (engine-monitor 120)

        ; Always reset Engine Start after the scripted test window, even if it ended in FAULT.
        ; This releases the Engine Start FAULT state so normal VESC current/duty controls work again.
        (print "resetting engine-start state after monitor window")
        (engine-stop)
        (print "after-stop-status=" (engine-status))
    }
)

; Run the test.
(engine-test-run)
