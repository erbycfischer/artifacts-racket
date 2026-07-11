#lang artifacts

;; Flagship multi-character bot. Every character leans on a high-level helper,
;; so the roster reads as intent rather than bookkeeping: gather, fight, craft,
;; trade. Tags are local descriptors; #:as pins a character to a live Artifacts
;; name (env-overridable). Set ARTIFACTS_API_TOKEN (or ARTIFACTS_TOKEN), then:
;;   racket examples/apex-bot.rkt
;; Create missing characters from #:as names (or tags when omitted):
;;   (play apex #:ensure-characters? #t)
;; Optional dry run (no token, no real actions):
;;   ARTIFACTS_DRY_RUN=1 racket examples/apex-bot.rkt

(define (env-as-name tag)
  (let ([v (getenv (format "ARTIFACTS_AS_~a" (string-upcase (symbol->string tag))))])
    (and v (not (string=? v "")) v)))

(bot apex
  ;; Front-line fighter: rests when hurt, fights, and banks when the bag fills.
  (character fighter #:role 'combat #:as (env-as-name 'fighter)
    (combat-loop #:max-hp-ratio 0.5))
  ;; Gatherer: mines its role resource, banks the moment the bag nears capacity.
  (character miner #:role 'mining #:as (env-as-name 'miner)
    (mine-until-full #:resource 'copper_rocks))
  ;; Second gatherer: a different role resource, same helper shape.
  (character woodcutter #:role 'woodcutting #:as (env-as-name 'woodcutter)
    (mine-until-full #:resource 'apple_tree))
  ;; Fisher: gather-loop helper, role-keyed to fishing.
  (character fisher #:role 'fishing #:as (env-as-name 'fisher)
    (mine-until-full #:resource 'shrimp_spot))
  ;; Crafter: refine copper, banking when a long run fills the bag.
  (character smith #:role 'crafter #:as (env-as-name 'smith)
    (craft-loop #:code 'copper_bar #:qty 1))
  ;; Trader: a single pipeline that pulls together the standalone guards and
  ;; goal helpers. sell-surplus and ge-trade stay dormant until the character
  ;; stands on the shop / Grand Exchange tile; bank-when-full keeps the bag
  ;; clear. Nesting helpers inside pipeline is what the ergonomic surface is
  ;; for — each helper contributes its actions to the same named goal.
  (character trader #:role 'trader #:as (env-as-name 'trader)
    (pipeline 'market-edge
      (rest-when-low #:max-hp-ratio 0.5)
      (sell-surplus #:code 'copper_ore #:qty 5)
      (ge-trade #:code 'copper_ore #:qty 5 #:price 10)
      (bank-when-full #:reserve 1)))
  ;; Buy one more bank slot so the whole roster has room to haul.
  (character quartermaster #:role 'tasker #:as (env-as-name 'quartermaster)
    (pipeline 'logistics
      (buy-expansion)))
  ;; Account strategy: a trader-driven watch over the market and the map. The
  ;; strategy mixes plain actions (check-events, check-raids) with a high-level
  ;; helper goal-spec (ge-trade), all run through the same flatten+resolve path
  ;; as a character pipeline. The actor is whoever plays the market.
  (strategy maximize-account-value
    (scan-ge)
    (ge-trade #:code 'copper_ore #:qty 5 #:price 10)
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
