#lang artifacts

;; Copy-paste playbook: one character per helper family, each a single line.
;; This is the "best bot, easy for non-Lispers" roster — drop a helper into a
;; character body and the planner routes the rest. Five characters (the account
;; cap). Tags are local; #:as is env-overridable like the other examples.
;;
;;   ARTIFACTS_DRY_RUN=1 racket examples/everything-bot.rkt

(define (env-as-name tag)
  (let ([v (getenv (format "ARTIFACTS_AS_~a" (string-upcase (symbol->string tag))))])
    (and v (not (string=? v "")) v)))

(bot everything
  ;; Combat + bank soft loot + pull craftable kit from the shared vault.
  (character fighter #:role 'combat #:as (env-as-name 'fighter)
    (heal-when-low)
    (outfit-from-bank)
    (bank-loot #:codes soft-loot-codes)
    (combat-loop #:max-hp-ratio 0.5))
  ;; Production: gather a named resource until the bag is full, then bank.
  (character miner #:role 'mining #:as (env-as-name 'miner)
    (gather-specific #:resource 'copper_rocks #:reserve 75))
  ;; Production: forge bars + starter gear from the shared vault.
  (character smith #:role 'crafter #:as (env-as-name 'smith)
    (forge-loop #:batch 2))
  ;; Market: list refined goods + premium drops; ruthless watch in strategy.
  (character trader #:role 'trader #:as (env-as-name 'trader)
    (sell-products)
    (bank-gold #:threshold 500))
  ;; Gear / travel: walk to the nearest workshop tile.
  (character runner #:role 'crafter #:as (env-as-name 'runner)
    (travel-to #:type "workshop"))
  (strategy market-watch
    (ruthless-market)
    (scan-ge)))

(define dry-run?
  (let ([v (getenv "ARTIFACTS_DRY_RUN")])
    (and v (member v '("1" "true" "TRUE" "yes" "YES")) #t)))

(play everything
      #:ensure-characters? #t
      #:dry-run? dry-run?
      #:iterations (if dry-run? 2 +inf.0)
      #:sleep-seconds 2)
