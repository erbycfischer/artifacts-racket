#lang racket

;; High-level, Racket-y compositions of the low-level action builders. Each
;; helper returns a goal-spec (or nests guard-specs) so it drops straight into a
;; `character` body or a `pipeline`/`loop`/`routine` form. They read like the
;; intent a human would state for a bot: "mine until the bag is full, then bank"
;; or "fight, but rest when hurt and bank when loaded".
;;
;; The decision logic lives in the predicates from planner.rkt (when-low-hp,
;; when-inventory-full, when-on-content), which run against the live character
;; every tick. Helpers just wire those conditions around the action builders.

(require "../dsl-forms.rkt"
         "../planner.rkt"
         "./actions.rkt")

(provide mine-until-full
         combat-loop
         sell-surplus
         bank-when-full
         rest-when-low)

;; Gather the character's role resource, then bank everything the moment the
;; bag is within `reserve` slots of capacity. #:resource names the target for
;; readability; the planner still chooses the matching tile for the character's
;; gathering role (mining/woodcutting/fishing/alchemy).
(define (mine-until-full #:resource [code #f] #:reserve [reserve 1])
  (goal-spec 'mine-until-full
             (list (gather)
                   (guard-spec (lambda (char) (when-inventory-full char #:reserve reserve))
                               (list (deposit-all))))))

;; The same bank-when-full guard as a standalone, for goals that gather via a
;; different action (e.g. a craft loop that reclaims inventory space).
(define (bank-when-full #:reserve [reserve 1])
  (guard-spec (lambda (char) (when-inventory-full char #:reserve reserve))
              (list (deposit-all))))

;; Rest whenever HP drops to/under `ratio`, otherwise fight; bank when the bag
;; fills up. The rest guard sits first so a hurt character recovers before the
;; planner reaches the fight step.
(define (combat-loop #:max-hp-ratio [ratio 0.5])
  (goal-spec 'combat-loop
             (list (guard-spec (lambda (char) (when-low-hp char ratio))
                               (list (rest)))
                   (fight)
                   (bank-when-full))))

;; A rest-when-low guard alone, handy as a safety net inside any goal.
(define (rest-when-low #:max-hp-ratio [ratio 0.5])
  (guard-spec (lambda (char) (when-low-hp char ratio))
              (list (rest))))

;; Sell `code` (up to `qty`) to an NPC, but only while standing on the shop
;; tile. Pairing the sell with when-on-content keeps the bot from wandering to
;; an NPC just to offload; the planner routes there only when the goal asks.
(define (sell-surplus #:code code #:qty [qty 1])
  (goal-spec 'sell-surplus
             (list (guard-spec (lambda (char) (when-on-content char "npc"))
                               (list (sell #:code code #:qty qty))))))
