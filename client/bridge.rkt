#lang racket

;; Official Artifacts MMO — local 3D visual client bridge.
;; Visual-only: polls the official REST API and serves Godot over local WS.
;; No bot process required. Run bots separately; watch them via official state.
;;
;;   export ARTIFACTS_API_TOKEN=...
;;   racket client/bridge.rkt
;;   godot --path client/godot

(require "../artifacts/config.rkt"
         "bridge/session.rkt"
         "bridge/visualizer.rkt")

(define port
  (or (let ([v (getenv "ARTIFACTS_BRIDGE_PORT")])
        (and v (string->number v)))
      (let ([v (getenv "ARTIFACTS_VISUALIZER_PORT")])
        (and v (string->number v)))
      8787))

(define poll
  (or (let ([v (getenv "ARTIFACTS_SESSION_POLL_SECONDS")])
        (and v (string->number v)))
      3))

(define (shutdown!)
  (printf "Shutting down official 3D visual bridge...\n")
  (flush-output)
  (stop-session-service!)
  (stop-visualizer-hub!)
  (printf "Bridge stopped.\n")
  (flush-output))

(unless (start-visualizer-hub! #:port port #:enabled? #t)
  (error 'artifacts-3d-bridge "failed to start bridge on port ~a" port))

(void (start-session-service! #:config (current-config) #:poll-seconds poll))

(printf "Official Artifacts 3D visual bridge ready on ws://127.0.0.1:~a\n" port)
(printf "Open Godot with: godot --path client/godot\n")
(printf "Auth via ARTIFACTS_API_TOKEN/ARTIFACTS_TOKEN or the in-client auth panel.\n")
(printf "Bots run separately — character motion comes from official API polling.\n")
(printf "Ctrl+C to stop.\n")
(flush-output)

(with-handlers ([exn:break?
                 (lambda (_exn)
                   (shutdown!)
                   (exit 0))])
  (let loop ()
    (sleep 3600)
    (loop)))
