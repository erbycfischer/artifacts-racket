#lang racket

;; Real-time readiness layer (prep only).
;;
;; This module models the shape of a live character update from the official
;; Artifacts MMO realtime WebSocket and offers pure, read-only helpers to read
;; the configured realtime URL and decide whether realtime consumption is on.
;;
;; It deliberately opens NO WebSocket and imports NO client/visualizer code.
;; The actual WS ingest belongs to the separate 3D visualizer bridge. A bot may
;; poll or prepare realtime data; only the visual client does the networking.
;; Building the data model here now means future ingestion can drop in without
;; touching the framework core.

(require "../config.rkt")

(define (hash-ref/default value key default)
  (if (hash? value) (hash-ref value key default) default))

(provide realtime-url
         realtime-enabled?
         realtime-snapshot
         realtime-snapshot?
         realtime-snapshot-character-name
         realtime-snapshot-hp
         realtime-snapshot-max-hp
         realtime-snapshot-x
         realtime-snapshot-y
         realtime-snapshot-cooldown-expiration
         snapshot-from-character)

;; Live character snapshot drawn from a realtime update. Read-only data shape
;; only; nothing here reaches the network.
(struct realtime-snapshot (character-name hp max-hp x y cooldown-expiration)
  #:transparent)

;; Configured realtime URL, or #f when none is set (e.g. a config with no WS).
(define (realtime-url [config (current-config)])
  (artifacts-config-realtime-url config))

;; Realtime is "enabled" only when both a URL is configured and the operator has
;; flipped the ARTIFACTS_REALTIME env flag to a truthy value. Kept pure and
;; read-only: we read the process env but change nothing.
(define (realtime-enabled? [config (current-config)])
  (and (realtime-url config)
       (let ([flag (getenv "ARTIFACTS_REALTIME")])
         (and flag
              (regexp-match? #px"^(1|true|yes|on)$" (string-downcase flag))))))

;; Convert an API character hash into a realtime snapshot, projecting the fields
;; a realtime consumer cares about. Tolerates missing keys by defaulting to #f
;; so a partial update still yields a usable snapshot.
(define (snapshot-from-character char
                                 #:config [config (current-config)])
  (define get (lambda (key) (hash-ref/default char key #f)))
  (realtime-snapshot (get 'name)
                     (get 'hp)
                     (get 'max_hp)
                     (get 'x)
                     (get 'y)
                     (get 'cooldown_expiration)))
