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
         rest-when-low
         craft-loop
         ge-trade
         gather-loop)

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

;; Craft `qty` of `code`, banking the moment the bag fills so a long craft run
;; never stalls on a full inventory. The craft itself waits for a workshop tile
;; (the planner routes there), and the bank guard waits for a full bag.
(define (craft-loop #:code code #:qty [qty 1] #:reserve [reserve 1])
  (goal-spec 'craft-loop
             (list (craft #:code code #:qty qty)
                   (bank-when-full #:reserve reserve))))

;; List `qty` of `code` on the Grand Exchange at `price` per unit. Like
;; sell-surplus, it only acts while standing on the exchange tile, so the bot
;; won't detour to the GE just to post an order. Pair it with scan-ge in a
;; strategy to watch for fills.
(define (ge-trade #:code code #:qty [qty 1] #:price price)
  (goal-spec 'ge-trade
             (list (guard-spec (lambda (char) (when-on-content char "grand_exchange"))
                               (list (sell-on-ge #:code code #:qty qty #:price price))))))

;; Gather the character's role resource, banking the moment the bag nears
;; capacity (within `reserve` slots). Unlike mine-until-full, which hard-codes
;; the mining role, gather-loop works for any gatherer role — the planner
;; derives the skill (mining/woodcutting/fishing/alchemy) from the character's
;; role, so a woodcutter or fisher drops straight in with just `(gather-loop)`.
(define (gather-loop #:skill [skill #f] #:reserve [reserve 1])
  (goal-spec 'gather-loop
             (list (gather)
                   (bank-when-full #:reserve reserve))))
