#lang racket

;; Standalone visualizer hub: no bot required.
;; Godot connects to ws://127.0.0.1:8787 for watch + manual play.
;;
;;   export ARTIFACTS_API_TOKEN=...  # or ARTIFACTS_TOKEN; optional Godot auth
;;   racket examples/visualizer-hub.rkt
;;   godot --path godot/client

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

(unless (start-visualizer-hub! #:port port #:enabled? #t)
  (error 'visualizer-hub "failed to start hub on port ~a" port))

(start-session-service! #:config (current-config) #:poll-seconds poll)

(printf "Visualizer hub ready. Open Godot with: godot --path godot/client\n")
(printf "Auth via ARTIFACTS_API_TOKEN/ARTIFACTS_TOKEN or Godot session.auth panel.\n")
(flush-output)

;; Keep process alive until interrupted.
(let loop ()
  (sleep 3600)
  (loop))
