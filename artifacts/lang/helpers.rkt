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
         gather-loop
         auto-level
         trader-loop
         banker
         ruthless-market
         sell-loot
         upgrade-gear
         grind
         haul
         market-maker
         has-loot?
         equipped?)

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

;; Grind toward `target` level using the character's role skill, banking when
;; the bag fills so a long run never stalls. The whole goal is gated behind
;; when-below-level, so once the character reaches `target` the goal goes
;; dormant (the planner falls through to the role default or another goal).
;; It composes the existing gather/role helpers with a level guard instead of
;; inventing new dispatch:
;;
;;   (auto-level 'mining #:target 10)
;;   (auto-level 'combat #:target 15 #:max-hp-ratio 0.5)
;;
;; A gatherer gathers + banks; a combatant rests when hurt, fights, and banks.
(define (auto-level role #:target target #:max-hp-ratio [ratio 0.5] #:reserve [reserve 1])
  (define role-goal
    (case role
      [(mining woodcutting fishing alchemy) (gather-loop #:reserve reserve)]
      [(combat fighter) (combat-loop #:max-hp-ratio ratio)]
      [else (gather-loop #:reserve reserve)]))
  (guard-spec (lambda (char) (when-below-level char target))
              (list role-goal)))

;; Run a market character: watch the Grand Exchange, fill a known buy order,
;; list a standing sell order, and bank the moment the bag fills. Every leg
;; nests an existing helper, and each helper only acts while on the right tile
;; (the planner routes there), so the loop reads as "trade, but only the parts
;; the world lets me do right now". `#:code`/`#:price` set the sell leg; pass
;; `#:fill-order-id` to also fill a specific open buy order:
;;
;;   (trader-loop #:code 'copper_ore #:qty 5 #:price 10)
;;   (trader-loop #:code 'coal #:qty 5 #:price 8 #:fill-order-id 42)
;;
;; The scan leg runs unconditionally (a plain action), so the bot always sees
;; its open orders; the buy/sell legs are tile-gated like ge-trade. The fill
;; leg only appears when you supply an order id — without one the loop stays a
;; scan+list+bank flow, which is the common beginner shape.
(define (trader-loop #:code code
                     #:qty [qty 1]
                     #:price price
                     #:fill-order-id [fill-order-id #f]
                     #:reserve [reserve 1])
  (define fill-leg
    (if fill-order-id
        (list (guard-spec (lambda (char) (when-on-content char "grand_exchange"))
                          (list (fill-order #:order-id fill-order-id #:qty qty))))
        '()))
  (goal-spec 'trader-loop
             (append (list (scan-ge)
                           (ge-trade #:code code #:qty qty #:price price)
                           (bank-when-full #:reserve reserve))
                     fill-leg)))

;; Manage bank capacity: deposit everything when the bag is full, and buy a new
;; bank slot when the bank itself is near capacity. `#:bank-threshold` is the
;; free-slot count below which an expansion is warranted (read from the
;; character's bank_max_items vs bank_items_used when present). Both legs are
;; guards over existing builders, so the helper drops into any character body:
;;
;;   (banker #:bank-threshold 5)
;;
;; A gatherer can pair it with mine-until-full so hauled loot is banked and the
;; bank is grown before it overflows.
(define (banker #:bank-threshold [bank-threshold 5])
  (define (bank-near-full? char)
    (define max-items (character-field char 'bank_max_items 0))
    (define used (character-field char 'bank_items_used 0))
    (and (> max-items 0)
         (>= used (- max-items bank-threshold))))
  (goal-spec 'banker
             (list (bank-when-full #:reserve 1)
                   (guard-spec (lambda (char) (bank-near-full? char))
                               (list (buy-expansion))))))

;; The ruthless market brain. Returns a goal-spec that does nothing until the
;; character is standing on the grand_exchange tile, then dispatches the
;; `market-tick` action (see artifacts/dispatch.rkt) which scans live event/raid
;; demand signals and the public GE book, pre-emptively buys the items a new
;; event/raid will spike, takes delivery of matched buys, and relists open sells
;; at the higher bid. Drop it into a `strategy` so the bot never stops watching:
;;
;;   (strategy market-watch (ruthless-market))
;;
;; The character must be pinned to the GE tile; the bot's routing moves them
;; there because the guarded action names the "grand_exchange" content type.
(define (ruthless-market)
  (goal-spec 'ruthless-market
             (list (guard-spec (lambda (char) (when-on-content char "grand_exchange"))
                               (list (action-spec 'market-tick #f))))))

;; True when the character's inventory holds at least one stack of `code` with a
;; positive quantity. Mirrors the grinder-bot's local check so it can live in the
;; shared layer.
(define (has-loot? char code)
  (define inv (character-field char 'inventory '()))
  (and (list? inv)
       (for/or ([slot (in-list inv)])
         (and (hash? slot)
              (equal? (hash-ref slot 'code #f) code)
              (> (hash-ref slot 'quantity 0) 0)))))

;; True when an item with `code` is equipped in any slot. Tolerant of ring1/ring2
;; style slot keys, so a re-buy is avoided even if the API names the slot
;; differently from the upgrade table.
(define (equipped? char code)
  (define eq (character-field char 'equipment #hasheq()))
  (and (hash? eq)
       (for/or ([(_ item) (in-hash eq)])
         (and (hash? item) (equal? (hash-ref item 'code #f) code)))))

;; Liquidate the whole held quantity of each given loot code to the NPC. Fires
;; only while standing on the items shop tile (the planner routes there when the
;; guard is the chosen action), exactly like sell-surplus but across a list of
;; codes. A `when-on-content` guard keeps the bot from detouring to the shop just
;; to offload. Each code is gated behind has-loot? so an empty stack emits
;; nothing:
;;
;;   (sell-loot #:codes '(wolf_hide wolf_meat iron_ore))
(define (sell-loot #:codes codes)
  (define guards
    (for/list ([code codes])
      (guard-spec (lambda (char) (has-loot? char code))
                  (list (sell #:code code #:qty 1000)))))
  (goal-spec 'sell-loot
             (list (guard-spec (lambda (char) (when-on-content char "items"))
                               guards))))

;; Buy and equip the best gear the character's level bucket unlocks, but only
;; while standing on the items tile and only for slots it isn't already wearing.
;; `table` maps a level bucket (e.g. 1/5/10/15/20/25) to a hash of
;; slot -> item-code. Gold is respected by the API, so a purchase the character
;; can't afford fails gracefully and the goal falls through to the next tick.
;; The equipped-check lives in the per-slot guard (which receives the live char),
;; so upgrades never double-buy an item already worn:
;;
;;   (upgrade-gear #:by-level gear-by-level)
(define (upgrade-gear #:by-level table)
  (define buckets (sort (hash-keys table) <))
  (define slots '(weapon shield helmet body_armor leg_armor boots ring amulet))
  (define (bucket-for level)
    ;; Highest bucket at or below the character's level.
    (for/fold ([best #f]) ([b buckets] #:when (<= b level))
      (if (or (not best) (> b best)) b best)))
  (define guards
    (for*/list ([bucket buckets]
                [slot slots]
                #:do [(define code (hash-ref (hash-ref table bucket) slot #f))]
                #:when code)
      (guard-spec
       (lambda (char)
         (define lvl (character-field char 'level 1))
         (and (equal? bucket (bucket-for lvl))
              (not (equipped? char code))))
       (list (buy #:code code #:qty 1)
             (equip code)))))
  (goal-spec 'upgrade-gear
             (list (guard-spec (lambda (char) (when-on-content char "items"))
                               guards))))

;; The canonical "fight the best safe monster, sell the loot, buy better gear,
;; repeat" loop as a single composable goal. It reads as intent: rest when hurt
;; and fight the best monster, then sell held loot and upgrade toward the next
;; gear tier — all gated by their own tile/level/inventory guards. `#:loot-codes`
;; names the drops to liquidate; `#:gear-table` is the level-bucketed gear hash.
;; Because expand-guards reverses body order when resolving, listing combat-loop
;; last puts `fight` first in the preferred list so the bot grinds first and
;; falls through to selling/buying when nothing is fightable:
;;
;;   (grind #:target 25 #:max-hp-ratio 0.5
;;          #:loot-codes '(wolf_hide wolf_meat ...)
;;          #:gear-table gear-by-level)
(define (grind #:target [target +inf.0]
               #:max-hp-ratio [ratio 0.5]
               #:loot-codes [loot-codes '()]
               #:gear-table [gear-table #hasheq()])
  ;; Flatten nested goal-specs into one goal body so grind reads as a single
  ;; goal (each part is itself a goal-spec). When-on-content / level / equipped
  ;; guards inside each part still resolve against the live character per tick.
  (define loot (if (pair? loot-codes)
                   (goal-spec-actions (sell-loot #:codes loot-codes))
                   '()))
  (define gear (if (and (hash? gear-table) (not (hash-empty? gear-table)))
                   (goal-spec-actions (upgrade-gear #:by-level gear-table))
                   '()))
  (define combat (goal-spec-actions (combat-loop #:max-hp-ratio ratio)))
  (goal-spec 'grind (append loot gear combat)))

;; Gatherers' haul loop: mine (or gather via the character's role) until the bag
;; is full, then bank everything. Composition of mine-until-full + banker, both
;; already network-friendly (tile-gated, gold-respecting), so a dedicated
;; standalone body isn't needed — this just names the intent:
;;
;;   (haul #:resource 'copper_ore #:reserve 1)
(define (haul #:resource [code #f] #:reserve [reserve 1])
  (goal-spec 'haul
             (list (mine-until-full #:resource code #:reserve reserve)
                   (banker))))

;; A thin, strategy-ready market helper: returns the list of high-level helpers
;; a market-watcher runs, so a bot can simply say
;;
;;   (strategy market-watch (market-maker))
;;
;; without naming each leg. The ruthless brain does the live analysis; scan-ge
;; keeps the open-order book visible. Both are tile-gated at the GE tile.
(define (market-maker)
  (list (ruthless-market) (scan-ge)))

