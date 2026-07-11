#lang racket

;; Read/query layer for the Artifacts MMO. These forms are thin, keyword-based
;; wrappers over the HTTP functions in ../http.rkt. They mirror the API's read
;; surface so a bot author can pull world and account state with plain Racket
;; calls instead of threading `#:config` through raw `get-*` functions.
;;
;; Every form accepts `#:config` (defaulting to `(current-config)`) and returns
;; the decoded response body. The HTTP layer already strips the envelope and
;; raises a structured api-error on failure, so there is nothing to unwrap here.
;;
;; Pagination and `code` filters are passed straight through to the wrappers.
;; `map` keeps the positional (layer x y) signature of get-map because a tile is
;; naturally addressed by three coordinates rather than a keyword bag.

(require "../http.rkt"
         "../config.rkt")

(provide character
         my-characters
         account-details
         bank
         bank-items
         pending-items
         rate-limits
         item
         monster
         resource
         npc
         tasks
         achievements
         effects
         active-events
         raids
         character-leaderboard
         account-leaderboard
         server-details
         maps
         map)

;; A single character by name. Public endpoint, no token needed.
(define (character name #:config [config (current-config)])
  (get-character name #:config config))

;; The authenticated account's characters, paginated.
(define (my-characters #:page [page 1] #:size [size 50] #:config [config (current-config)])
  (get-my-characters #:page page #:size size #:config config))

;; The authenticated account's profile and totals.
(define (account-details #:config [config (current-config)])
  (get-account-details #:config config))

;; The authenticated account's bank capacity and gold.
(define (bank #:config [config (current-config)])
  (get-bank-details #:config config))

;; Bank item stacks, optionally filtered to one item code.
(define (bank-items #:code [code #f] #:page [page 1] #:size [size 50] #:config [config (current-config)])
  (get-bank-items #:item-code code #:page page #:size size #:config config))

;; Items the bank is still crafting or buying on your behalf.
(define (pending-items #:config [config (current-config)])
  (get-pending-items #:config config))

;; Current rate-limit budget for the authenticated account.
(define (rate-limits #:config [config (current-config)])
  (get-rate-limits #:config config))

;; Static item data by code.
(define (item code #:config [config (current-config)])
  (get-item code #:config config))

;; Static monster data by code.
(define (monster code #:config [config (current-config)])
  (get-monster code #:config config))

;; Static resource data by code.
(define (resource code #:config [config (current-config)])
  (get-resource code #:config config))

;; Static NPC data by code.
(define (npc code #:config [config (current-config)])
  (get-npc code #:config config))

;; The task list, paginated.
(define (tasks #:page [page 1] #:size [size 100] #:config [config (current-config)])
  (get-tasks #:page page #:size size #:config config))

;; Achievement definitions, paginated.
(define (achievements #:page [page 1] #:size [size 100] #:config [config (current-config)])
  (get-achievements #:page page #:size size #:config config))

;; Active account effects, paginated.
(define (effects #:page [page 1] #:size [size 100] #:config [config (current-config)])
  (get-effects #:page page #:size size #:config config))

;; Events currently running.
(define (active-events #:config [config (current-config)])
  (get-active-events #:config config))

;; Raid definitions, paginated.
(define (raids #:page [page 1] #:size [size 100] #:config [config (current-config)])
  (get-raids #:page page #:size size #:config config))

;; Character leaderboard, optionally sorted by a column name.
(define (character-leaderboard #:sort [sort #f] #:config [config (current-config)])
  (get-character-leaderboard #:sort sort #:config config))

;; Account leaderboard, optionally sorted by a column name.
(define (account-leaderboard #:sort [sort #f] #:config [config (current-config)])
  (get-account-leaderboard #:sort sort #:config config))

;; Server status and the announced next reset time.
(define (server-details #:config [config (current-config)])
  (get-server-details #:config config))

;; The map grid, optionally scoped to one layer and paginated.
(define (maps #:layer [layer #f] #:page [page 1] #:size [size 100] #:config [config (current-config)])
  (get-maps #:layer layer #:page page #:size size #:config config))

;; A single tile, addressed by its three coordinates (layer x y).
(define (map layer x y #:config [config (current-config)])
  (get-map layer x y #:config config))
