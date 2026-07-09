#lang artifacts

;; Competitive multi-character bot.
;; Roles are bound to your live account characters in order.
;; Set ARTIFACTS_API_TOKEN (or ARTIFACTS_TOKEN), then:
;;   racket examples/apex-bot.rkt
;; Optional dry run:
;;   ARTIFACTS_DRY_RUN=1 racket examples/apex-bot.rkt

(bot apex
  (character fighter #:role 'combat
    (goal 'strongest-safe-farm
          (action 'fight)
          (action 'rest)
          (action 'bank-deposit-item)))
  (character miner #:role 'mining
    (goal 'ore-pipeline
          (action 'gather)
          (action 'bank-deposit-item)))
  (character woodcutter #:role 'woodcutting
    (goal 'wood-pipeline
          (action 'gather)
          (action 'bank-deposit-item)))
  (character fisher #:role 'fishing
    (goal 'fish-pipeline
          (action 'gather)
          (action 'bank-deposit-item)))
  (character trader #:role 'trader
    (goal 'market-edge
          (action 'grand-exchange-orders)
          (action 'active-events)
          (action 'raids)))
  (strategy maximize-account-value
    (action 'active-events)
    (action 'raids)
    (action 'grand-exchange-orders)))

(define dry-run?
  (let ([v (getenv "ARTIFACTS_DRY_RUN")])
    (and v (member v '("1" "true" "TRUE" "yes" "YES")) #t)))

(define iterations
  (let ([v (getenv "ARTIFACTS_ITERATIONS")])
    (if v (string->number v) +inf.0)))

(play apex
      #:iterations (or iterations +inf.0)
      #:sleep-seconds 2
      #:dry-run? dry-run?)
