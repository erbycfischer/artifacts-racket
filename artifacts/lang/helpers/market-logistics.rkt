#lang racket

;; Market and bank logistics. Tile-gated GE/bank helpers, plus the
;; cross-account actions (deposit-surplus, restock, snap-up) whose handlers
;; live in artifacts/dispatch.rkt because they have to read bank items or
;; the public GE book.

(require json
         racket/file
         "../../dsl-forms.rkt"
         "../../planner.rkt"
         "../../game-data.rkt"
         "../actions.rkt")

(provide sell-all-on-ge
         withdraw-then-sell
         sell-products
         bank-gold
         keep-gold
         stockpile
         deposit-surplus
         restock
         snap-up
         bank-loot
         default-spend-policy
         current-spend-policy
         spend-max-price
         spend-policy
         procure-needs
         flip-spread
         snipe-valuables
         sell-excess
         relist-stale-orders
         snipe-log-path
         default-snipe-codes
         bargain-consumables
         snipe-disposition
         current-snipe-hold
         current-snipe-fills
         flip-relist-price)

;; List every given code on the Grand Exchange at `price`, qty 1000 so a
;; whole stack dumps in one order. Only fires while standing on the GE tile.
(define (sell-all-on-ge #:codes codes #:price price)
  (define per-code
    (for/list ([code codes])
      (sell-on-ge #:code code #:qty 1000 #:price price)))
  (goal-spec 'sell-all-on-ge
             (list (guard-spec (lambda (char) (when-on-content char "grand_exchange"))
                               per-code))))

;; Pull `qty` of `code` out of the bank (via restock, which no-ops when the
;; vault is empty — never 478s), then list on the GE once the bag holds the
;; code. Do not require already-on-GE in the guard — that left gems stuck at
;; the bank while snipe deposit put them right back. plan-preferred walks to
;; the exchange for grand-exchange-create-sell-order.
(define (withdraw-then-sell #:code code #:qty n #:price p)
  (goal-spec 'withdraw-then-sell
             (list (restock #:code code #:qty n)
                   (guard-spec (lambda (char) (when-has-item char code))
                               (list (sell-on-ge #:code code #:qty n #:price p))))))

;; Deposit carried gold down to `#:keep` (default 0 = all of it). Fighters
;; should use `#:keep 0` so loot gold funds the trader; the trader uses
;; `keep-gold` to pull a spending float. Legacy `#:threshold` is an alias
;; for `#:keep`.
;;
;;   (bank-gold)                 ; deposit everything
;;   (bank-gold #:keep 0)
;;   (bank-gold #:threshold 40)  ; leave 40 in the pocket
(define (bank-gold #:keep [keep #f] #:threshold [threshold #f])
  (define pocket (or keep threshold 0))
  (guard-spec (lambda (char) (when-gold-above char pocket))
              (list (action-spec 'deposit-gold-surplus
                                 (list (hasheq 'keep pocket))))))

;; Withdraw until carried gold reaches `#:floor`. No-ops when the vault is
;; empty so an empty bank does not spam failed withdraws every tick.
;; Default matches `default-spend-policy` gold-floor so a bare `(keep-gold)`
;; is a valid overnight call.
(define (keep-gold #:floor [amount 100])
  (guard-spec (lambda (char) (when-gold-below char amount))
              (list (action-spec 'top-up-gold
                                 (list (hasheq 'floor amount))))))

;; Deposit all of `code` above `keep`. Dispatches deposit-surplus, which
;; reads the live inventory and banks max(0, qty - keep).
(define (deposit-surplus #:code code #:keep n)
  (goal-spec 'deposit-surplus
             (list (action-spec 'deposit-surplus
                                (list (hasheq 'code (item-code code)
                                              'keep n))))))

;; Keep `n` of `code` in the bag; deposit the rest. Same action as
;; deposit-surplus, named for the "stockpile in the bank" reading.
(define (stockpile #:code code #:keep n)
  (deposit-surplus #:code code #:keep n))

;; Withdraw from the bank until the bag holds `n` of `code`. The handler
;; reads bank items because the character hash has no bank state. Do NOT
;; tile-gate here — the planner's `plan-on-content` walks to the bank.
;; Guard on live bank qty so a confirmed-empty vault does not put a dead
;; restock into preferred actions (which would shadow fight/gather forever).
;; Dormant when the bag is full so we never plan a 497 inventory-full withdraw.
(define (restock #:code code #:qty n)
  (guard-spec
   (lambda (char)
     (define have (item-quantity char code))
     (define bank-have (bank-item-quantity code))
     (and (not (inventory-full? char))
          (< have n)
          (or (not (number? bank-have)) (> bank-have 0))))
   (list (action-spec 'restock
                      (list (hasheq 'code (item-code code)
                                    'qty n))))))

;; Buy `code` on the GE when the best public ask is at or below `max-price`.
;; The handler reads the live order book (same best-ask as ruthless-market).
(define (snap-up #:code code #:max-price p)
  (goal-spec 'snap-up
             (list (action-spec 'snap-up
                                (list (hasheq 'code (item-code code)
                                              'max_price p))))))


;; List every crafted product on the GE: withdraw from the bank, then post a
;; sell order. `#:listings` is `((code qty price) ...)` — when omitted, every
;; key in `default-sell-prices` is listed at qty `default-qty` and that price.
;;
;;   (sell-products)
;;   (sell-products #:listings '((copper_bar 5 40) (ash_plank 5 35)))
(define (sell-products #:listings [listings #f] #:default-qty [default-qty 5])
  (define rows
    (cond
      [(pair? listings) listings]
      [else
       (for/list ([(code price) (in-hash default-sell-prices)])
         (list code default-qty price))]))
  (goal-spec 'sell-products
             (apply append
                    (for/list ([row rows])
                      (goal-spec-actions
                       (withdraw-then-sell #:code (car row)
                                           #:qty (cadr row)
                                           #:price (caddr row)))))))

;; Deposit each listed loot code when held, without dumping potions or kit.
;; deposit-surplus walks to the bank via the planner (same as restock). Harmony
;; fighters use this so soft/premium drops land in the shared vault for the
;; trader instead of NPC pennies.
;;
;;   (bank-loot #:codes soft-loot-codes)
(define (bank-loot #:codes codes)
  (goal-spec 'bank-loot
             (for/list ([code codes])
               (guard-spec (lambda (char) (when-has-item char code))
                           (list (action-spec 'deposit-surplus
                                              (list (hasheq 'code (item-code code)
                                                            'keep 0))))))))

;; ---------------------------------------------------------------------------
;; Spend policy: per-situation GE buy ceilings + gold floor
;;
;; Trader auto-spends gold when the book shows a deal. Thresholds are
;; aggressive (pay up for roster deficits; flip on a modest spread; snipe
;; when fair ≫ ask). Gold banking must not starve this: spend-policy is
;; keep-gold at the floor so carried gold stays spendable; do not pair with
;; a high bank-gold threshold. snap-up still reads the live ask.
;;
;;   (spend-policy)
;;   (spend-policy #:gold-floor 250 #:max-spend-per-item 600)
;;   (spend-policy #:need (hasheq 'max-ask-premium 1.8))
;; ---------------------------------------------------------------------------

;; Default ceilings. `max-ask-premium` is a multiplier on fair value (1.5 =
;; pay 50% over). Flip uses the *strictest* of min-spread, min-roi, and
;; max-ask-premium so a thin margin cannot sneak through. Snipe requires
;; fair ≥ min-fair-multiple × ask (1.75× = ask at most ~57% of fair).
(define default-spend-policy
  (hasheq 'need (hasheq 'max-ask-premium 1.5)
          'flip (hasheq 'min-spread 3
                        'min-roi 0.12
                        'max-ask-premium 0.88)
          'snipe (hasheq 'min-fair-multiple 1.75)
          'bargain (hasheq 'max-ask-premium 0.7)
          'upgrade (hasheq 'max-ask-premium 1.2)
          'gold-floor 100
          'max-spend-per-tick 800
          'max-spend-per-item 400))

(define current-spend-policy (make-parameter default-spend-policy))

;; Local fair-value hints for codes game-data does not price yet. default-sell-prices
;; wins on overlap; the encyclopedia worker can replace these via #:fair-values.
(define extra-fair-values
  (hasheq 'sunflower 6
          'gudgeon 8
          'raw_chicken 8
          'cooked_gudgeon 12
          'medium_health_potion 50
          'apple 4
          'topaz_stone 80
          'emerald_stone 120
          'ruby_stone 180
          'sapphire_stone 180
          'iron_sword 200
          'iron_armor 220
          'iron_shield 180
          'gold_bar 250
          'mithril_bar 400
          'dragon_scale 500
          'dragon_bone 400
          'demon_horn 350
          'giant_heart 400
          'lich_crown 4000
          'highwayman_dagger 250
          'death_knight_sword 3500
          'goblin_guard_shield 800
          'forest_staff 200
          'copper_pickaxe 80
          'copper_axe 80))

(define default-fair-values
  (for/fold ([h extra-fair-values])
            ([(k v) (in-hash default-sell-prices)])
    (hash-set h k v)))

;; High-value catalog the trader will snipe when absurdly cheap. Craftable
;; kit/tools are excluded — the smith forges those. Commodities may flip;
;; unique gear is hold / equip-review.
(define default-snipe-codes
  '(topaz_stone emerald_stone ruby_stone sapphire_stone
    gold_bar mithril_bar
    dragon_scale dragon_bone demon_horn giant_heart
    lich_crown highwayman_dagger death_knight_sword
    goblin_guard_shield forest_staff))

(define current-snipe-hold (make-parameter '()))
(define current-snipe-fills (make-parameter (hasheq)))
(define current-snipe-dispositions (make-parameter (hasheq)))

(define (snipe-disposition code)
  (cond
    [(craftable-gear? code) #f]
    [(and (equipment-slot-of code) (or (rare-loot? code) #t)
          (not (gather-tool? code)))
     (if (rare-loot? code) 'equip-review 'hold)]
    [(rare-loot? code) 'hold]
    [(or (premium-loot? code)
         (memq (code-key code)
               '(topaz_stone emerald_stone ruby_stone sapphire_stone
                 gold_bar mithril_bar dragon_scale dragon_bone
                 demon_horn giant_heart)))
     'flip]
    [else 'hold]))

(define (snipe-hold-code? code)
  (define d (or (hash-ref (current-snipe-dispositions) (code-key code) #f)
                (snipe-disposition code)))
  (memq d '(hold equip-review)))

(define (held-snipe-codes [codes (current-snipe-hold)])
  (for/list ([c codes] #:when (snipe-hold-code? c))
    c))

;; Relist a sniped commodity strictly above fill and at least
;; max(fair, cost × (1 + min-roi), cost + min-spread). Missing cost uses fair.
(define (flip-relist-price code
                           #:cost [cost #f]
                           #:policy [policy (current-spend-policy)]
                           #:fair-values [fairs default-fair-values])
  (define fair (fair-value code fairs))
  (define paid (or cost
                   (hash-ref (current-snipe-fills) (code-key code) #f)
                   fair))
  (and fair paid
       (let* ([min-spread (situation-field policy 'flip 'min-spread 3)]
              [min-roi (situation-field policy 'flip 'min-roi 0.12)]
              [raw (max fair
                        (* paid (+ 1 min-roi))
                        (+ paid min-spread))])
         (gold-int (max raw (add1 paid))))))

;; Sibling of logs/rare-drops.ndjson. Bind in tests to a temp path.
(define snipe-log-path (make-parameter (build-path "logs" "ge-snipes.ndjson")))

(define snipe-log-seen (make-hash))

(define (code-key code)
  (string->symbol (item-code code)))

(define (same-code? a b)
  (equal? (item-code a) (item-code b)))

(define (in-codes? code codes)
  (for/or ([c codes])
    (same-code? code c)))

(define (codes-minus codes excluded)
  (for/list ([c codes] #:unless (in-codes? c excluded))
    c))

(define (codes-union . lists)
  (define seen (make-hash))
  (define acc '())
  (for ([lst lists])
    (for ([c (if (list? lst) lst '())])
      (define k (item-code c))
      (unless (hash-ref seen k #f)
        (hash-set! seen k #t)
        (set! acc (cons c acc)))))
  (reverse acc))

(define (fair-value code table)
  (define key (code-key code))
  (or (hash-ref table key #f)
      (hash-ref table (item-code code) #f)))

(define (gold-int n)
  (inexact->exact (floor n)))

(define (hash-overlay base overlay)
  (cond
    [(not overlay) base]
    [(hash? overlay)
     (for/fold ([h base]) ([(k v) (in-hash overlay)])
       (hash-set h k v))]
    [else base]))

(define (situation-field policy situation key [default #f])
  (define sit (hash-ref policy situation #f))
  (if (hash? sit) (hash-ref sit key default) default))

(define (flip-buy-ceiling fair policy)
  (define min-spread (situation-field policy 'flip 'min-spread 3))
  (define min-roi (situation-field policy 'flip 'min-roi 0.12))
  (define premium (situation-field policy 'flip 'max-ask-premium 0.88))
  (min (- fair min-spread)
       (/ fair (+ 1 min-roi))
       (* fair premium)))

;; Max gold the trader will pay for `code` in `situation` (`need`, `flip`,
;; `snipe`, `upgrade`). Applies per-item / per-tick caps. #f means skip —
;; no fair value, or the ceiling collapsed to nothing.
(define (spend-max-price situation code
                         #:policy [policy (current-spend-policy)]
                         #:fair-values [fairs default-fair-values])
  (define fair (fair-value code fairs))
  (define per-item (hash-ref policy 'max-spend-per-item +inf.0))
  (define per-tick (hash-ref policy 'max-spend-per-tick +inf.0))
  (define cap (min per-item per-tick))
  (define raw
    (and fair
         (case situation
           [(need)
            (* fair (situation-field policy 'need 'max-ask-premium 1.5))]
           [(flip) (flip-buy-ceiling fair policy)]
           [(snipe)
            (/ fair (situation-field policy 'snipe 'min-fair-multiple 1.75))]
           [(bargain)
            (* fair (situation-field policy 'bargain 'max-ask-premium 0.7))]
           [(upgrade)
            (* fair (situation-field policy 'upgrade 'max-ask-premium 1.2))]
           [else #f])))
  (and raw (> raw 0) (gold-int (min raw cap))))

(define (make-spend-policy-table #:policy [base default-spend-policy]
                                 #:need [need #f]
                                 #:flip [flip #f]
                                 #:snipe [snipe #f]
                                 #:bargain [bargain #f]
                                 #:upgrade [upgrade #f]
                                 #:gold-floor [gold-floor #f]
                                 #:max-spend-per-tick [max-spend-per-tick #f]
                                 #:max-spend-per-item [max-spend-per-item #f])
  (define table0 (if (hash? base) base default-spend-policy))
  (define table1
    (for/fold ([h table0])
              ([pair (list (cons 'need need)
                           (cons 'flip flip)
                           (cons 'snipe snipe)
                           (cons 'bargain bargain)
                           (cons 'upgrade upgrade))]
               #:when (hash? (cdr pair)))
      (hash-set h (car pair)
                (hash-overlay (hash-ref h (car pair) (hasheq)) (cdr pair)))))
  (define table2 (if gold-floor (hash-set table1 'gold-floor gold-floor) table1))
  (define table3 (if max-spend-per-tick
                     (hash-set table2 'max-spend-per-tick max-spend-per-tick)
                     table2))
  (if max-spend-per-item
      (hash-set table3 'max-spend-per-item max-spend-per-item)
      table3))

;; Pipeline helper: install the threshold table and keep carried gold at the
;; floor so snap-up / procure / snipe always have a purse. Spend the rest.
(define (spend-policy #:policy [base default-spend-policy]
                      #:need [need #f]
                      #:flip [flip #f]
                      #:snipe [snipe #f]
                      #:bargain [bargain #f]
                      #:upgrade [upgrade #f]
                      #:gold-floor [gold-floor #f]
                      #:max-spend-per-tick [max-spend-per-tick #f]
                      #:max-spend-per-item [max-spend-per-item #f])
  (define table
    (make-spend-policy-table #:policy base
                             #:need need
                             #:flip flip
                             #:snipe snipe
                             #:bargain bargain
                             #:upgrade upgrade
                             #:gold-floor gold-floor
                             #:max-spend-per-tick max-spend-per-tick
                             #:max-spend-per-item max-spend-per-item))
  (current-spend-policy table)
  (goal-spec 'spend-policy
             (list (keep-gold #:floor (hash-ref table 'gold-floor 100)))))

(define (gold-above-floor? char policy)
  (when-gold-above char (hash-ref policy 'gold-floor 0)))

(define (snap-under-policy situation code
                           #:policy policy
                           #:fair-values fairs)
  (define max-price
    (spend-max-price situation code #:policy policy #:fair-values fairs))
  (and max-price
       (guard-spec (lambda (char) (gold-above-floor? char policy))
                   (list (action-spec 'snap-up
                                      (list (hasheq 'code (item-code code)
                                                    'max_price max-price)))))))

(define (deposit-when-held code)
  (guard-spec (lambda (char) (when-has-item char code))
              (list (action-spec 'deposit-surplus
                                 (list (hasheq 'code (item-code code)
                                               'keep 0))))))

;; Recipe inputs that are not themselves crafted products (ores, woods, raw
;; food, plants). Intermediate bars/planks stay sellable as excess.
(define (leaf-recipe-inputs)
  (define products
    (for/hash ([k (hash-keys default-recipes)])
      (values (item-code k) #t)))
  (define seen (make-hash))
  (define acc '())
  (for ([prod (hash-keys default-recipes)])
    (define mats (recipe-materials prod))
    (when mats
      (for ([m mats])
        (define mat (car m))
        (define k (item-code mat))
        (unless (or (hash-ref products k #f)
                    (hash-ref seen k #f))
          (hash-set! seen k #t)
          (set! acc (cons mat acc))))))
  (reverse acc))

(define (gear-codes-up-to [level #f])
  (define buckets (sort (hash-keys default-gear-table) <))
  (define chosen
    (if level (filter (lambda (b) (<= b level)) buckets) buckets))
  (define from-table
    (apply append
           (for/list ([b chosen])
             (define slots (hash-ref default-gear-table b))
             (for/list ([(k code) (in-hash slots)] #:when code)
               (void k)
               code))))
  (codes-union fighter-kit-codes from-table))

(define (default-need-codes #:level [level #f])
  (void level)
  (codes-union default-consumables (leaf-recipe-inputs)))

(define (vault-held-kit-codes)
  (define all (apply append
                     (map kit-table-codes
                          (list default-gear-table
                                miner-kit-table
                                woodcutter-kit-table
                                crafter-kit-table))))
  (for/list ([c all]
             #:when (let ([q (bank-item-quantity c)])
                      (and (number? q) (positive? q))))
    c))

(define (default-sell-reserve [held #f])
  (define held* (or held (vault-held-kit-codes)))
  (codes-union (codes-minus (leaf-recipe-inputs) premium-loot-codes)
               (reserved-upgrade-codes held*)
               '(cooked_chicken cooked_gudgeon cooked_beef
                 small_health_potion
                 copper_bar ash_plank iron_bar spruce_plank
                 steel_bar hardwood_plank)))

;; Auto-buy underpriced roster inputs (food, pots, forge mats) and
;; deposit them for smith/fighter. Does not GE-buy craftable kit — the
;; smith forges those. Pass `#:kit` only for a non-harmony bot that
;; still wants an upgrade snap.
;;
;;   (procure-needs)
;;   (procure-needs #:codes '(sunflower copper_ore) #:rare rare-loot-codes)
(define (procure-needs #:codes [codes #f]
                       #:kit [kit #f]
                       #:level [level #f]
                       #:rare [rare '()]
                       #:policy [policy (current-spend-policy)]
                       #:fair-values [fairs default-fair-values]
                       #:deposit? [deposit? #t])
  (void level)
  (define kit-codes
    (codes-minus (filter (lambda (c) (not (craftable-gear? c)))
                         (or kit '()))
                 rare))
  (define need-codes
    (codes-minus (if codes codes (default-need-codes))
                 (codes-union rare kit-codes
                              (filter craftable-gear?
                                      (or codes '())))))
  (define snaps
    (filter values
            (for/list ([code need-codes])
              (snap-under-policy 'need code #:policy policy #:fair-values fairs))))
  (define deposits
    (if deposit?
        (for/list ([code (codes-union need-codes kit-codes)])
          (deposit-when-held code))
        '()))
  (goal-spec 'procure-needs (append snaps deposits)))

;; Auto-buy routine undervalued trade goods, then relist higher when the
;; spread clears the #:flip thresholds. Complements ruthless-market /
;; market-maker (event demand + stale-sell relist) without replacing them.
;; Never flips #:rare or sniped valuables.
;;
;;   (flip-spread)
;;   (flip-spread #:codes '(copper_bar ash_plank) #:rare rare-loot-codes)
(define (flip-spread #:codes [codes #f]
                     #:rare [rare '()]
                     #:sniped [sniped (current-snipe-hold)]
                     #:policy [policy (current-spend-policy)]
                     #:fair-values [fairs default-fair-values]
                     #:relist? [relist? #t]
                     #:relist-qty [relist-qty 1000])
  (define hold (codes-union rare (held-snipe-codes sniped)))
  (define trade
    (codes-minus
     (if codes
         codes
         (codes-union premium-loot-codes (hash-keys default-sell-prices)))
     (codes-union hold default-consumables
                  (reserved-upgrade-codes (vault-held-kit-codes)))))
  (define snaps
    (filter values
            (for/list ([code trade] #:unless (craftable-gear? code))
              (snap-under-policy 'flip code #:policy policy #:fair-values fairs))))
  (define relists
    (if relist?
        (filter values
                (for/list ([code trade] #:unless (craftable-gear? code))
                  (define price (flip-relist-price code #:fair-values fairs
                                                   #:policy policy))
                  (and price
                       (guard-spec
                        (lambda (char)
                          (and (when-has-item char code)
                               (when-on-content char "grand_exchange")))
                        (list (sell-on-ge #:code code
                                          #:qty relist-qty
                                          #:price price))))))
        '()))
  (goal-spec 'flip-spread (append snaps relists)))

(define (character-name-for-log char)
  (format "~a" (or (character-field char 'name #f)
                   (character-field char 'character #f)
                   "unknown")))

(define (character-tick char)
  (or (character-field char 'tick #f)
      (current-seconds)))

(define (append-snipe-log! record)
  (with-handlers ([exn:fail?
                   (lambda (e)
                     (printf "  [snipe] log failed: ~a\n" (exn-message e))
                     (flush-output))])
    (define path (snipe-log-path))
    (define as-path (cond
                      [(path? path) path]
                      [(string? path) (string->path path)]
                      [else (build-path "logs" "ge-snipes.ndjson")]))
    (define dir (path-only as-path))
    (when dir (make-directory* dir))
    (call-with-output-file as-path
      (lambda (out)
        (write-json record out)
        (newline out))
      #:exists 'append)))

;; Log once per (character, code) acquisition cycle. Cleared when the stack
;; leaves the bag so a later snipe of the same code logs again.
(define (maybe-log-snipe! char code qty price [disposition 'hold])
  (define key (cons (character-name-for-log char) (item-code code)))
  (cond
    [(and (number? qty) (> qty 0))
     (unless (hash-ref snipe-log-seen key #f)
       (append-snipe-log!
        (hasheq 'code (item-code code)
                'qty qty
                'char (character-name-for-log char)
                'tick (character-tick char)
                'price price
                'kind "ge-snipe"
                'disposition (format "~a" disposition)))
       (hash-set! snipe-log-seen key #t))
     #t]
    [else
     (hash-remove! snipe-log-seen key)
     #f]))

(define (hold-snipe-for-player code max-price disposition)
  (guard-spec
   (lambda (char)
     (maybe-log-snipe! char code (item-quantity char code) max-price disposition))
   (list (action-spec 'deposit-surplus
                      (list (hasheq 'code (item-code code)
                                    'keep 0))))))

(define (flip-snipe-for-player code max-price)
  ;; Flip stays in the bag and walks to the GE — depositing keep-0 first
  ;; made sell unreachable and fought sell-excess restock every tick.
  (define ask (flip-relist-price code #:cost max-price))
  (list (guard-spec
         (lambda (char)
           (maybe-log-snipe! char code (item-quantity char code) max-price 'flip)
           (and ask (when-has-item char code)))
         (list (sell-on-ge #:code code #:qty 1000 #:price ask)))))

;; If a high-value / rare catalog item is listed absurdly cheap (fair ≫ ask),
;; buy immediately within spend thresholds. Craftable kit is never sniped.
;; Uniques hold or wait for fighter outfit; commodities relist above fill.
;;
;;   (snipe-valuables)
;;   (snipe-valuables #:rare rare-loot-codes #:codes '(ruby_stone))
(define (snipe-valuables #:codes [codes #f]
                         #:rare [rare '()]
                         #:policy [policy (current-spend-policy)]
                         #:fair-values [fairs default-fair-values])
  ;; `#:codes` replaces the default catalog when given; rare is always
  ;; unioned so hold/equip-review uniques stay in the snipe set.
  (define catalog
    (filter (lambda (c) (not (craftable-gear? c)))
            (codes-union (or codes default-snipe-codes) rare)))
  (define hold-codes
    (for/list ([c catalog] #:when (snipe-hold-code? c))
      c))
  (current-snipe-hold (codes-union (current-snipe-hold) hold-codes))
  (current-snipe-dispositions
   (for/fold ([h (current-snipe-dispositions)]) ([c catalog])
     (define d (snipe-disposition c))
     (if d (hash-set h (code-key c) d) h)))
  (define snaps-and-holds
    (apply append
           (for/list ([code catalog])
             (define max-price
               (spend-max-price 'snipe code #:policy policy #:fair-values fairs))
             (define disp (snipe-disposition code))
             (when (and max-price (eq? disp 'flip))
               (current-snipe-fills
                (hash-set (current-snipe-fills) (code-key code) max-price)))
             (define after
               (cond
                 [(eq? disp 'flip) (flip-snipe-for-player code (or max-price 0))]
                 [else (list (hold-snipe-for-player code (or max-price 0)
                                                   (or disp 'hold)))]))
             (if max-price
                 (cons (guard-spec
                        (lambda (char) (gold-above-floor? char policy))
                        (list (action-spec 'snap-up
                                           (list (hasheq 'code (item-code code)
                                                         'max_price max-price)))))
                       after)
                 after))))
  (goal-spec 'snipe-valuables snaps-and-holds))

(define (fair-ask-or-floor code [fairs default-fair-values])
  (define fair (fair-value code fairs))
  (define floor (hash-ref default-sell-prices (code-key code) #f))
  (and fair (gold-int (max fair (or floor 0)))))

;; List anything not reserved for recipes / current-best kit / food / rare
;; on the GE. Dominated leftover starter kit lists at fair. Combat rares,
;; upgrade gear, and hold/equip-review snipes are never auto-sold.
;;
;;   (sell-excess)
;;   (sell-excess #:rare rare-loot-codes #:reserve '(cooked_chicken))
;;   (sell-excess #:listings '((copper_bar 5 40)))
(define (sell-excess #:listings [listings #f]
                     #:default-qty [default-qty 5]
                     #:rare [rare '()]
                     #:reserve [reserve #f]
                     #:held [held #f]
                     #:sniped [sniped (current-snipe-hold)])
  (define held* (or held (vault-held-kit-codes)))
  ;; Hold / equip-review snipes stay forbidden. Flip dispositions are
  ;; intentionally sellable (that is the flip), so they are not reserved.
  (define forbidden
    (codes-union rare
                 (held-snipe-codes sniped)
                 (if reserve reserve (default-sell-reserve held*))))
  (define dominated
    (codes-minus (dominated-spare-codes held*) forbidden))
  (define rows
    (cond
      [(pair? listings)
       (for/list ([row listings]
                  #:unless (or (in-codes? (car row) forbidden)
                               (rare-loot? (car row))))
         (define code (car row))
         (define asked (caddr row))
         (define floor (fair-ask-or-floor code))
         (list code (cadr row) (if floor (max asked floor) asked)))]
      [else
       (define candidates
         (codes-union (codes-minus (codes-union premium-loot-codes
                                                (hash-keys default-sell-prices))
                                   forbidden)
                      dominated))
       (filter values
               (for/list ([code candidates]
                          #:unless (or (rare-loot? code)
                                       (craftable-gear? code)
                                       (in-codes? code forbidden)))
                 (define price (fair-ask-or-floor code))
                 (and price (list code default-qty price))))]))
  ;; Dominated extras of craftable kit still list at fair when they
  ;; survived the forbidden filter (strictly below the held bucket).
  (define dominated-rows
    (if (pair? listings)
        '()
        (filter values
                (for/list ([code dominated]
                           #:unless (or (rare-loot? code)
                                        (in-codes? code forbidden)))
                  (define price (fair-ask-or-floor code))
                  (and price (list code default-qty price))))))
  (define all-rows
    (if (pair? listings) rows (codes-union-rows rows dominated-rows)))
  (goal-spec 'sell-excess
             (apply append
                    (for/list ([row all-rows])
                      (goal-spec-actions
                       (withdraw-then-sell #:code (car row)
                                           #:qty (cadr row)
                                           #:price (caddr row)))))))

(define (codes-union-rows . lists)
  (define seen (make-hash))
  (define acc '())
  (for ([lst lists])
    (for ([row lst])
      (define k (item-code (car row)))
      (unless (hash-ref seen k #f)
        (hash-set! seen k #t)
        (set! acc (cons row acc)))))
  (reverse acc))

;; Buy food/pots at #:need when the vault is below target; buy more only
;; when the ask is a #:bargain, up to a stockpile cap. Gold floor stays 100.
;;
;;   (bargain-consumables)
;;   (bargain-consumables #:food-target 10 #:pot-target 5 #:pot-cap 30)
(define (bargain-consumables #:food [food 'cooked_chicken]
                             #:potion [potion 'small_health_potion]
                             #:food-target [food-target 10]
                             #:pot-target [pot-target 5]
                             #:food-cap [food-cap 30]
                             #:pot-cap [pot-cap 30]
                             #:policy [policy (current-spend-policy)]
                             #:fair-values [fairs default-fair-values])
  (define (vault-qty code)
    (define q (bank-item-quantity code))
    (if (number? q) q 0))
  (define (snap-when situation code cap)
    (define max-price
      (spend-max-price situation code #:policy policy #:fair-values fairs))
    (and max-price
         (guard-spec
          (lambda (char)
            (and (gold-above-floor? char policy)
                 (< (vault-qty code) cap)))
          (list (action-spec 'snap-up
                             (list (hasheq 'code (item-code code)
                                           'max_price max-price)))))))
  (goal-spec 'bargain-consumables
             (filter values
                     (list (snap-when 'need food food-target)
                           (snap-when 'need potion pot-target)
                           (snap-when 'bargain food food-cap)
                           (snap-when 'bargain potion pot-cap)
                           (deposit-when-held food)
                           (deposit-when-held potion)))))

;; Thin alias over existing GE cancel + relist. With `#:order-id`, cancel
;; that order and optionally post a new sell. With no id, dispatch the same
;; `market-tick` brain ruthless-market uses (cancel-and-relist stale sells
;; at the higher bid).
;;
;;   (relist-stale-orders)
;;   (relist-stale-orders #:order-id 42 #:code 'copper_bar #:qty 5 #:price 45)
(define (relist-stale-orders #:order-id [order-id #f]
                             #:code [code #f]
                             #:qty [qty 1]
                             #:price [price #f])
  (define body
    (cond
      [order-id
       (append (list (cancel-order #:order-id order-id))
               (if (and code price)
                   (list (sell-on-ge #:code code #:qty qty #:price price))
                   '()))]
      [else (list (action-spec 'market-tick #f))]))
  (goal-spec 'relist-stale-orders
             (list (guard-spec (lambda (char) (when-on-content char "grand_exchange"))
                               body))))
