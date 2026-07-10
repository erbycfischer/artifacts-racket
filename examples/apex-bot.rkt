#lang artifacts

;; Competitive multi-character bot.
;; Tags are local descriptors; #:as sets the live Artifacts name.
;; Optional env overrides: ARTIFACTS_AS_FIGHTER, ARTIFACTS_AS_MINER, etc.
;; Set ARTIFACTS_API_TOKEN (or ARTIFACTS_TOKEN), then:
;;   racket examples/apex-bot.rkt
;; Create missing characters from #:as names (or tags when omitted):
;;   (play apex #:ensure-characters? #t)
;; Optional dry run:
;;   ARTIFACTS_DRY_RUN=1 racket examples/apex-bot.rkt

(define (env-as-name tag)
  (let ([v (getenv (format "ARTIFACTS_AS_~a" (string-upcase (symbol->string tag))))])
    (and v (not (string=? v "")) v)))

(bot apex
  (character fighter #:role 'combat #:as (env-as-name 'fighter)
    (pipeline 'strongest-safe-farm
      (fight)
      (rest)
      (deposit-all)))
  (character miner #:role 'mining #:as (env-as-name 'miner)
    (pipeline 'ore-pipeline
      (gather)
      (deposit-all)))
  (character woodcutter #:role 'woodcutting #:as (env-as-name 'woodcutter)
    (pipeline 'wood-pipeline
      (gather)
      (deposit-all)))
  (character fisher #:role 'fishing #:as (env-as-name 'fisher)
    (pipeline 'fish-pipeline
      (gather)
      (deposit-all)))
  (character trader #:role 'trader #:as (env-as-name 'trader)
    (pipeline 'market-edge
      (scan-ge)
      (check-events)
      (deposit-all)))
  (strategy maximize-account-value
    (scan-ge)
    (check-events)
    (check-raids)))

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
