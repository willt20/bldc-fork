; Engine Start Mode full Lisp bench/vehicle test script.
; Target hardware used for defaults: KV ~= 65 rpm/V, Vin ~= 29.5 V, 42 poles / 21 pole pairs.
;
; Safety:
; - Put the vehicle/engine in a safe state before running this script.
; - Keep a hard power cut-off ready.
; - The default boost pulses are 160/190/220 A; reduce these first if MOS/battery margin is unknown.
; - If state enters FAULT, run (engine-stop) before starting again.
;
; engine-status returns:
; (state active retry-count boost-pulse-count total-pulse-count
;  openloop-erpm openloop-phase blend iq-target
;  erpm-abs-filt current-abs-filt duty-abs-filt accel-filt load-score load-delta
;  compression-ms stall-ms obs-stable-ms last-stop-reason
;  stability-score learning-state learning-window-count consecutive-success
;  strategy knowledge-count avg-start-time-ms)
;
; State ids:
; 0 IDLE, 1 ALIGN, 2 PULL, 3 LOAD_DETECT, 4 PULSE, 5 GAP,
; 6 BACKOFF, 7 RECOVER, 8 ACCEL, 9 BLEND, 10 RUN, 11 RETRY, 12 FAULT
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
        (print "boost-pulse-ms=" (engine-param-get 'boost-pulse-ms))
        (print "boost-gap-ms=" (engine-param-get 'boost-gap-ms))
        (print "boost-success-erpm=" (engine-param-get 'boost-success-erpm))
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
            (sleep 0.1)
            (engine-monitor (- n 1))
        }
        {
            (print "=== Monitor Done ===")
            (print "final-status=" (engine-status))
        }
    )
)

(defun engine-apply-a40-29v5-defaults ()
    {
        ; Start from firmware defaults, then write the recommended test values explicitly
        ; so this script is self-documenting and repeatable even if firmware defaults change later.
        (engine-param-reset)

        ; Direction: change to -1.0 if crank direction is wrong.
        (engine-param-set 'direction 1.0)

        ; 29.5 V system: stop Engine Start if bus sags too far.
        (engine-param-set 'min-vin 24.0)

        ; Slow pull / compression detection speeds for 21 pole pairs.
        ; 100 eRPM ~= 4.8 mechanical rpm, 800 eRPM ~= 38.1 mechanical rpm.
        (engine-param-set 'pull-start-erpm 100.0)
        (engine-param-set 'pull-target-erpm 800.0)
        (engine-param-set 'pull-ramp-erpm-s 800.0)

        ; Pulsed boost: short 50 ms pulses with a 100 ms release gap.
        ; Start lower than these values during first hardware shakedown if MOS/battery margin is unknown.
        (engine-param-set 'boost-current-1 160.0)
        (engine-param-set 'boost-current-2 190.0)
        (engine-param-set 'boost-current-3 220.0)
        (engine-param-set 'boost-pulse-ms 50.0)
        (engine-param-set 'boost-gap-ms 100.0)
        (engine-param-set 'boost-max-pulses 3.0)
        (engine-param-set 'boost-success-erpm 800.0)

        ; Accel target for 21 pole pairs: 3000 eRPM ~= 143 mechanical rpm.
        (engine-param-set 'accel-target-erpm 3000.0)
        (engine-param-set 'accel-ramp-erpm-s 1800.0)

        ; Delay observer handoff: 2500 eRPM ~= 119 mechanical rpm.
        (engine-param-set 'obs-min-erpm 2500.0)
        (engine-param-set 'obs-stable-time-ms 200.0)
        (engine-param-set 'blend-time-ms 300.0)

        ; Compression/stall detection.
        (engine-param-set 'stall-erpm 300.0)
        (engine-param-set 'stall-current 100.0)
        (engine-param-set 'stall-duty 0.12)
        (engine-param-set 'compression-time-ms 50.0)
        (engine-param-set 'stall-confirm-ms 120.0)

        ; Global limits.
        (engine-param-set 'max-start-time-ms 5000.0)
        (engine-param-set 'max-total-pulses 9.0)
        (engine-param-set 'max-retry 3.0)

        ; Default backoff only unloads. Do not enable reverse until mechanically validated.
        (engine-param-set 'backoff-ms 200.0)
        (engine-param-set 'backoff-reverse-enable 0.0)
        (engine-param-set 'backoff-current -40.0)
        (engine-param-set 'backoff-erpm -100.0)
    }
)

(defun engine-test-run ()
    {
        (print "=== Engine Start A40 29.5V / 21-pole-pair Test ===")
        (engine-stop)
        (engine-apply-a40-29v5-defaults)
        (engine-print-params)
        (print "initial-status=" (engine-status))
        (print "=== START ===")
        (engine-start)

        ; 60 samples * 0.1 s = 6 s. max-start-time-ms is 5 s, so this captures timeout/final state.
        (engine-monitor 60)

        ; Ensure output is stopped after the scripted test window.
        (if (engine-start-active)
            {
                (print "engine still active after monitor window, stopping")
                (engine-stop)
            }
            ()
        )
        (print "after-stop-status=" (engine-status))
    }
)

; Run the test.
(engine-test-run)
