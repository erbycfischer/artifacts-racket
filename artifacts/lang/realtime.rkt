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
;;
;; On top of the pure data model, this module also offers REST-polling helpers
;; that turn official character state into the same snapshot shape. Polling is
;; the bot-side "realtime parity": a bot may read character state over REST
;; without a WebSocket and without importing the 3D visualizer. The polling
;; helpers are plain REST and need no realtime flag; the flag only gates
;; automatic wiring (a future scheduler hook), not these functions.

(require "../config.rkt"
         "../http.rkt")

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
         snapshot-from-character
         poll-character-snapshot
         poll-account-snapshots
         make-snapshot-stream)

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

;; Pull one live character over REST and project it into a realtime snapshot.
;; The endpoint is public, so we gate on a usable token ourselves and raise the
;; structured 452 api-error (the same one the HTTP layer raises) before any
;; network call; the caller decides how to handle it. Returns #f when the
;; response carries no usable character data rather than fabricating a row.
(define (poll-character-snapshot name #:config [config (current-config)])
  (ensure-authenticated! config)
  (define response (get-character name #:config config))
  (define char (hash-ref/default response 'data #f))
  (and (hash? char) (snapshot-from-character char #:config config)))

;; Pull the whole account over REST and return one snapshot per live character.
;; Defensive on empty: a response with no data yields an empty list, never an
;; error, so a brand-new or token-less account doesn't crash the caller.
(define (poll-account-snapshots #:config [config (current-config)])
  (ensure-authenticated! config)
  (define response (get-my-characters #:config config))
  (define chars (hash-ref/default response 'data '()))
  (if (list? chars)
      (for/list ([char (in-list chars)] #:when (hash? char))
        (snapshot-from-character char #:config config))
      '()))

;; Build a polling closure over a fixed set of character names. Each call
;; returns a list of current snapshots, one per name, in the same order given.
;; It does NOT sleep or block: the runner owns timing and calls the closure on
;; its own schedule (its own loop/sleep). A failed fetch for a name yields #f
;; in that slot so one dead character never takes down the rest of the stream.
(define (make-snapshot-stream names
                              #:interval-seconds [interval-seconds 2]
                              #:config [config (current-config)])
  (define name-list (map character-name-string names))
  (lambda ()
    (for/list ([name (in-list name-list)])
      (with-handlers ([exn:fail? (lambda (_exn) #f)])
        (poll-character-snapshot name #:config config)))))
