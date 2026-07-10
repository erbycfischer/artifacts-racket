#lang artifacts

;; Crafter + tasker showcase for workshop, NPC, and bank flows.
;; Set ARTIFACTS_API_TOKEN and optional ARTIFACTS_AS_* env names.

(define (env-as-name tag)
  (let ([v (getenv (format "ARTIFACTS_AS_~a" (string-upcase (symbol->string tag))))])
    (and v (not (string=? v "")) v)))

(bot workshop
  (character smith #:role 'crafter #:as (env-as-name 'smith)
    (pipeline 'refine-loop
      (craft 'copper_bar 1)
      (deposit-all)
      (rest)))
  (character quartermaster #:role 'tasker #:as (env-as-name 'quartermaster)
    (pipeline 'task-loop
      (task-complete)
      (task-start)
      (deposit-all)))
  (character buyer #:role 'trader #:as (env-as-name 'buyer)
    (pipeline 'supply-run
      (buy 'small_health_potion 3)
      (sell 'copper_ore 5)
      (deposit-all)))
  (strategy market-watch
    (scan-ge)
    (check-events)))

(define dry-run?
  (let ([v (getenv "ARTIFACTS_DRY_RUN")])
    (and v (member v '("1" "true" "TRUE" "yes" "YES")) #t)))

(play workshop
      #:ensure-characters? #t
      #:dry-run? dry-run?
      #:iterations (if dry-run? 2 +inf.0)
      #:sleep-seconds 2)
