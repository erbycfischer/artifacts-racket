#lang racket

;; Official Artifacts MMO — local 3D client bridge.
;; Talks only to the official Artifacts REST API (and optional realtime).
;; No bot process required. Godot connects for watch + manual play.
;;
;;   export ARTIFACTS_API_TOKEN=...   # or ARTIFACTS_TOKEN; optional Godot auth
;;   racket examples/artifacts-3d-bridge.rkt
;;   godot --path godot/client
;;
;; Alias: examples/visualizer-hub.rkt

(require "../artifacts/config.rkt"
         "../artifacts/session.rkt"
         "../artifacts/visualizer.rkt")

(define port
  (or (let ([v (getenv "ARTIFACTS_VISUALIZER_PORT")])
        (and v (string->number v)))
      8787))

(define poll
  (or (let ([v (getenv "ARTIFACTS_SESSION_POLL_SECONDS")])
        (and v (string->number v)))
      3))

(define (shutdown!)
  (printf "Shutting down official 3D bridge...\n")
  (flush-output)
  (stop-session-service!)
  (stop-visualizer-hub!)
  (printf "Bridge stopped.\n")
  (flush-output))

(unless (start-visualizer-hub! #:port port #:enabled? #t)
  (error 'artifacts-3d-bridge "failed to start bridge on port ~a" port))

;; Session owns official REST polling + optional realtime (ARTIFACTS_REALTIME=1).
(void (start-session-service! #:config (current-config) #:poll-seconds poll))

(printf "Official Artifacts 3D bridge ready on ws://127.0.0.1:~a\n" port)
(printf "Open Godot with: godot --path godot/client\n")
(printf "Auth via ARTIFACTS_API_TOKEN/ARTIFACTS_TOKEN or Godot session.auth panel.\n")
(printf "Bots are optional and unchanged — official character state is enough to watch them.\n")
(printf "Ctrl+C to stop.\n")
(flush-output)

(with-handlers ([exn:break?
                 (lambda (_exn)
                   (shutdown!)
                   (exit 0))])
  (let loop ()
    (sleep 3600)
    (loop)))
