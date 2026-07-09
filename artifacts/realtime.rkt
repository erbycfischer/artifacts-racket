#lang racket

;; Optional Artifacts realtime WebSocket ingest (future).
;; REST session polling is the supported live path today.

(require "config.rkt")

(provide realtime-enabled?
         realtime-url
         start-realtime-ingest!
         stop-realtime-ingest!)

(define ingest-thread #f)

(define (realtime-enabled?)
  (define v (getenv "ARTIFACTS_REALTIME"))
  (and v (member v '("1" "true" "TRUE" "yes" "YES")) #t))

(define (realtime-url #:config [config (current-config)])
  (artifacts-config-realtime-url config))

(define (start-realtime-ingest! #:config [config (current-config)]
                                #:on-message [on-message #f])
  (cond
    [(not (realtime-enabled?))
     (printf "Realtime ingest disabled (set ARTIFACTS_REALTIME=1 to enable later).~n")
     (flush-output)
     #f]
    [ingest-thread
     #t]
    [else
     (printf "Realtime ingest stub ready for ~a (not connected yet).~n"
             (realtime-url #:config config))
     (flush-output)
     (set! ingest-thread #t)
     #t]))

(define (stop-realtime-ingest!)
  (set! ingest-thread #f)
  (void))
