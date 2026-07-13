#lang artifacts

;; A ruthless Grand Exchange market-maker. It sits at the GE and never stops
;; analyzing: it watches for new events, raids, and bosses, pre-emptively buys
;; up everything the player base will suddenly need (before the crowd bids the
;; price up), takes delivery of its matched buy orders, and relists its open
;; sells at the higher bid the moment demand arrives. Buy low, sell high, and
;; front-run supply-and-demand spikes — that's the whole loop.
;;
;; Auth: bridge-first. The token is resolved via the 3D Visualizer bridge
;; (http://127.0.0.1:7878/token) first, then the ~/.artifacts/token dotfile,
;; then ARTIFACTS_API_TOKEN / ARTIFACTS_TOKEN. No token is hardcoded; start the
;; visualizer and log in (or run tools/gen-token.rkt login) and this bot picks
;; it up. Set ARTIFACTS_DRY_RUN=1 to prove it compiles and ticks with synthetic
;; characters (no real orders).
;;
;; Optional env overrides:
;;   ARTIFACTS_AS_TRADER   pin to a live character name
;;   ARTIFACTS_DRY_RUN=1   dry run (no real orders)
;;   ARTIFACTS_ITERATIONS  tick count (default: forever)

(require artifacts/auth)

;; Bridge-first token resolution: bridge (HTTP -> file) -> ~/.artifacts/token
;; -> env. Resolved on every request, so a mid-run visualizer login just works.
(current-config (make-bridge-config))

(define (env-as-name tag)
  (let ([v (getenv (format "ARTIFACTS_AS_~a" (string-upcase (symbol->string tag))))])
    (and v (not (string=? v "")) v)))

(bot trader-bot
  (character trader #:role 'trader #:as (env-as-name 'trader)
    ;; Keep the bag empty enough to take delivery of bought stock, and grow the
    ;; bank before it overflows. The ruthless brain lives in the strategy below
    ;; so it keeps watching even while this character idles.
    (banker #:bank-threshold 5))
  ;; The market-watch strategy runs the ruthless analysis every tick, but only
  ;; acts while the character is standing on the grand_exchange tile (the bot
  ;; routes them there automatically).
  (strategy market-watch
    (ruthless-market)
    (scan-ge)))

(define dry-run?
  (let ([v (getenv "ARTIFACTS_DRY_RUN")])
    (and v (member v '("1" "true" "TRUE" "yes" "YES")) #t)))

(define iterations
  (let ([v (getenv "ARTIFACTS_ITERATIONS")])
    (if v (string->number v) (if dry-run? 2 +inf.0))))

(play trader-bot
      #:ensure-characters? #t
      #:iterations iterations
      #:sleep-seconds 3
      #:dry-run? dry-run?)
