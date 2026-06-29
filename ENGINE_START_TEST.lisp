; Engine Start event-driven minimal debug script.
; Safe low-current starting point for no-load bench checks.

(defun es-set-defaults ()
  (engine-param-set 'align-current 5.0)
  (engine-param-set 'pull-current 12.0)
  (engine-param-set 'boost-current-1 20.0)
  (engine-param-set 'boost-current-2 30.0)
  (engine-param-set 'boost-current-3 40.0)
  (engine-param-set 'accel-current 15.0)
  (engine-param-set 'min-vin 24.0)
  (engine-param-set 'max-start-time-ms 3000.0)
  (engine-param-set 'event-confidence-threshold 0.65)
  (engine-param-set 'pull-event-timeout-ms 500.0)
  (engine-param-set 'pulse-event-timeout-ms 15.0)
  ; Optional reverse preload before ALIGN. Disable by setting preload-enable to 0.0.
  (engine-param-set 'preload-enable 1.0)
  (engine-param-set 'preload-current -12.0)
  (engine-param-set 'preload-time-ms 500.0))

(defun es-print-param (name)
  (print name)
  (print (engine-param-get name)))

(defun es-print-params ()
  (print "=== Engine Start Event Params ===")
  (es-print-param 'align-current)
  (es-print-param 'pull-current)
  (es-print-param 'boost-current-1)
  (es-print-param 'boost-current-2)
  (es-print-param 'boost-current-3)
  (es-print-param 'accel-current)
  (es-print-param 'min-vin)
  (es-print-param 'max-start-time-ms)
  (es-print-param 'event-confidence-threshold)
  (es-print-param 'pull-event-timeout-ms)
  (es-print-param 'pulse-event-timeout-ms)
  (es-print-param 'preload-enable)
  (es-print-param 'preload-current)
  (es-print-param 'preload-time-ms))

(defun es-monitor (n delay-ms)
  (if (> n 0)
      (progn
        (print "status=")
        ; Returns (state event-state event-confidence fault-reason active)
        ; State map: 0 IDLE, 1 ALIGN, 2 PULL, 3 LOAD_DETECT,
        ; 4 PULSE, 5 GAP, 6 BACKOFF, 7 ACCEL, 8 BLEND, 9 RUN,
        ; 10 FAULT, 11 PRELOAD.
        (print (engine-status))
        (sleep (/ delay-ms 1000.0))
        (es-monitor (- n 1) delay-ms))))

(defun es-run ()
  (print "=== Engine Start Event-Driven No-Load Debug ===")
  (es-set-defaults)
  (es-print-params)
  (print "initial-status=")
  (print (engine-status))
  (print "=== START ===")
  (engine-start)
  (es-monitor 40 100)
  (print "=== STOP ===")
  (engine-stop)
  (print "after-stop-status=")
  (print (engine-status)))

(es-run)
