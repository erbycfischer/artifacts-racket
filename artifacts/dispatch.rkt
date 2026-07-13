#lang racket

(require "config.rkt"
         "http.rkt")

(provide dispatch-action-name)

(define (dispatch-action-name character-name action-name payload #:config [config (current-config)])
  (define pretend? (artifacts-pretend?))
  (case action-name
    [(move)
     (cond
       [(and (hash? payload) (hash-has-key? payload 'map_id))
        (action-move character-name #:map-id (hash-ref payload 'map_id) #:config config)]
       [(and (hash? payload) (hash-has-key? payload 'x) (hash-has-key? payload 'y))
        (action-move character-name
                     #:x (hash-ref payload 'x)
                     #:y (hash-ref payload 'y)
                     #:config config)]
       [else (error 'dispatch-action-name "move payload needs map_id or x/y, got ~v" payload)])]
    [(transition) (action-transition character-name #:config config)]
    [(rest) (action-rest character-name #:config config)]
    [(equip) (action-equip character-name (if (list? payload) payload '()) #:config config)]
    [(unequip) (action-unequip character-name (if (list? payload) payload '()) #:config config)]
    [(use) (action-use character-name payload #:config config)]
    [(fight) (action-fight character-name #:participants (if (list? payload) payload '()) #:config config)]
    [(gather) (action-gather character-name #:config config)]
    [(craft) (action-craft character-name payload #:config config)]
    [(recycle) (action-recycle character-name payload #:config config)]
    [(bank-deposit-item) (action-bank-deposit-item character-name (if (list? payload) payload '()) #:config config)]
    [(bank-deposit-gold) (action-bank-deposit-gold character-name (if (number? payload) payload 0) #:config config)]
    [(bank-withdraw-item) (action-bank-withdraw-item character-name (if (list? payload) payload '()) #:config config)]
    [(bank-withdraw-gold) (action-bank-withdraw-gold character-name (if (number? payload) payload 0) #:config config)]
    [(bank-buy-expansion) (action-bank-buy-expansion character-name #:config config)]
    [(npc-buy) (action-npc-buy character-name payload #:config config)]
    [(npc-sell) (action-npc-sell character-name payload #:config config)]
    [(grand-exchange-buy) (action-grand-exchange-buy character-name payload #:config config)]
    [(grand-exchange-create-sell-order)
     (if pretend?
         (printf "  [pretend] would CREATE SELL ORDER ~a\n" payload)
         (action-grand-exchange-create-sell-order character-name payload #:config config))]
    [(grand-exchange-create-buy-order)
     (if pretend?
         (printf "  [pretend] would CREATE BUY ORDER ~a\n" payload)
         (action-grand-exchange-create-buy-order character-name payload #:config config))]
    [(grand-exchange-cancel)
     (if pretend?
         (printf "  [pretend] would CANCEL ORDER ~a\n" payload)
         (action-grand-exchange-cancel character-name payload #:config config))]
    [(grand-exchange-fill)
     (if pretend?
         (printf "  [pretend] would FILL ORDER ~a\n" payload)
         (action-grand-exchange-fill character-name payload #:config config))]
    [(task-new) (action-task-new character-name #:config config)]
    [(task-complete) (action-task-complete character-name #:config config)]
    [(task-cancel) (action-task-cancel character-name #:config config)]
    [(task-exchange) (action-task-exchange character-name #:config config)]
    [(task-trade) (action-task-trade character-name payload #:config config)]
    [(give-gold) (action-give-gold character-name payload #:config config)]
    [(give-item) (action-give-item character-name payload #:config config)]
    [(claim-item) (action-claim-item character-name payload #:config config)]
    [(delete-item) (action-delete-item character-name payload #:config config)]
    [(change-skin) (action-change-skin character-name payload #:config config)]
    [(grand-exchange-orders) (get-grand-exchange-orders #:config config)]
    [(active-events) (get-active-events #:config config)]
    [(raids) (get-raids #:config config)]
    ;; The ruthless market analysis step. When a strategy dispatches this action
    ;; the character is standing on the grand_exchange tile, so we scan live
    ;; demand signals (active events + raids) and the public GE order book, then
    ;; act: buy up items a new event/raid will need, fill any of our own buy
    ;; orders that have been matched, and relist our sells at the higher bid.
    ;; Real network calls happen only here, under live play; dry-run skips it.
    [(market-tick) (run-market-tick character-name #:config config)]
    [else (error 'dispatch-action-name "unsupported action ~v" action-name)]))

;; ---------------------------------------------------------------------------
;; Ruthless market analysis
;;
;; Demand model: when an event or raid goes live, certain item codes spike.
;; We keep a curated map from event/raid "kind" hints to the item codes the
;; player base suddenly needs, and we pre-emptively buy those on the GE before
;; the crowd bids the price up. We then sell our existing stock into the highest
;; available bid. All decisions are driven by the live GE order book so the bot
;; never guesses a price — it reads the market.
;; ---------------------------------------------------------------------------

;; Event/raid -> item codes the market will want. Keys are matched as
;; case-insensitive substrings against the event/raid name + description so a
;; new "Goblin Invasion" event still triggers the goblin-loot buys. Add codes as
;; you learn the meta; missing codes simply mean we don't pre-buy that event.
(define event-demand-map
  (list (cons "goblin" '(goblin_ear goblin_standard wolf_meat))
        (cons "wolf"   '(wolf_hide wolf_meat))
        (cons "bandit" '(bandit_helmet bandit_cloth))
        (cons "demon"  '(demon_horn demon_skin))
        (cons "dragon" '(dragon_scale dragon_bone))
        (cons "giant"  '(giant_heart giant_tooth))
        (cons "undead" '(bone essence_of_death))
        (cons "ice"    '(ice_crystal))
        (cons "fire"   '(fire_essence sulfur))
        (cons "mining" '(copper_ore iron_ore coal))
        (cons "wood"   '(wood birch_wood))
        (cons "alchemy" '(wheat honey))
        (cons "combat" '(small_health_potion medium_health_potion))
        (cons "boss"   '(small_health_potion medium_health_potion fire_essence))
        (cons "raid"   '(small_health_potion medium_health_potion dragon_scale))))

;; Pull the active event + raid text and return the set of item codes we should
;; be hoarding right now. Returns a list of symbols.
(define (demand-codes #:config [config (current-config)])
  (define (haystacks)
    (define events
      (with-handlers ([exn:fail? (lambda (_) '())])
        (let ([r (get-active-events #:config config)])
          (if (and (hash? r) (hash-has-key? r 'data)) (hash-ref r 'data) r))))
    (define raids
      (with-handlers ([exn:fail? (lambda (_) '())])
        (let ([r (get-raids #:config config)])
          (if (and (hash? r) (hash-has-key? r 'data)) (hash-ref r 'data) r))))
    (append
     (map (lambda (e) (format "~a ~a" (hash-ref e 'name "") (hash-ref e 'description ""))) events)
     (map (lambda (e) (format "~a ~a" (hash-ref e 'name "") (hash-ref e 'description ""))) raids)))
  (define texts (haystacks))
  (define hits
    (for*/list ([text texts]
                [entry event-demand-map]
                #:when (string-contains? (string-downcase text) (car entry)))
      (cdr entry)))
  (remove-duplicates (apply append hits)))

;; Best public bid (buy order) price for a code, or #f if none listed.
(define (best-bid code #:config [config (current-config)])
  (with-handlers ([exn:fail? (lambda (_) #f)])
    (define r (get-grand-exchange-orders #:code code #:type "buy" #:config config))
    (define orders (if (and (hash? r) (hash-has-key? r 'data)) (hash-ref r 'data) r))
    (define prices
      (for/list ([o orders] #:when (hash? o))
        (hash-ref o 'price 0)))
    (and (not (null? prices)) (apply max prices))))

;; Best public ask (sell order) price for a code, or #f if none listed.
(define (best-ask code #:config [config (current-config)])
  (with-handlers ([exn:fail? (lambda (_) #f)])
    (define r (get-grand-exchange-orders #:code code #:type "sell" #:config config))
    (define orders (if (and (hash? r) (hash-has-key? r 'data)) (hash-ref r 'data) r))
    (define prices
      (for/list ([o orders] #:when (hash? o))
        (hash-ref o 'price 0)))
    (and (not (null? prices)) (apply min prices))))

;; Our own open buy orders, as a list of hashes with id/code/price/quantity.
(define (my-open-buy-orders character-name #:config [config (current-config)])
  (with-handlers ([exn:fail? (lambda (_) '())])
    (define r (get-my-grand-exchange-orders #:type "buy" #:config config))
    (define orders (if (and (hash? r) (hash-has-key? r 'data)) (hash-ref r 'data) r))
    (filter (lambda (o) (eq? (hash-ref o 'type 'buy) 'buy)) orders)))

;; Our own open sell orders, as a list of hashes with id/code/price/quantity.
(define (my-open-sell-orders character-name #:config [config (current-config)])
  (with-handlers ([exn:fail? (lambda (_) '())])
    (define r (get-my-grand-exchange-orders #:type "sell" #:config config))
    (define orders (if (and (hash? r) (hash-has-key? r 'data)) (hash-ref r 'data) r))
    (filter (lambda (o) (eq? (hash-ref o 'type 'sell) 'sell)) orders)))

;; Run one ruthless market pass. Steps:
;;  1. Read demand signals -> codes to hoard.
;;  2. For each demanded code with a public ask, place a buy order at the ask
;;     (buy low / buy before the spike). Skip if we already hold one open.
;;  3. Fill any of our own buy orders that have been matched (take delivery so
;;     we can re-list higher).
;;  4. For our open sell orders, if the market bid has risen above our list
;;     price, cancel-and-relist at the higher bid (sell high). Otherwise leave.
(define (run-market-tick character-name #:config [config (current-config)])
  (define demand (demand-codes #:config config))
  (printf "  [market] demand signals -> ~a\n" demand)
  (flush-output)
  ;; Step 2+3: pre-emptive buys + take delivery of filled buys.
  (for ([code demand])
    (define sym (if (symbol? code) code (string->symbol code)))
    (define ask (best-ask sym #:config config))
    (when ask
      (define open (my-open-buy-orders character-name #:config config))
      (define already?
        (findf (lambda (o) (eq? (hash-ref o 'code #f) sym)) open))
      (unless already?
        (printf "  [market] BUY ~a @ ~a (pre-emptive)\n" sym ask)
        (flush-output)
        (with-handlers ([exn:fail? (lambda (e) (printf "  [market] buy failed: ~a\n" (exn-message e)) (flush-output))])
          (action-grand-exchange-create-buy-order
           character-name
           (hasheq 'code sym 'quantity 10 'price ask) #:config config))))
    ;; Take delivery of any matched buy order so we can re-list it.
    (for ([o (my-open-buy-orders character-name #:config config)])
      (define remaining (hash-ref o 'quantity 0))
      (when (> remaining 0)
        (with-handlers ([exn:fail? (lambda (e)
                              (printf "  [market] fill failed: ~a\n" (exn-message e))
                              (flush-output))])
          (action-grand-exchange-fill character-name
                                      (hasheq 'id (hash-ref o 'id 0) 'quantity remaining)
                                      #:config config))))
  ;; Step 3: sell high / relist open sells at the higher bid.
  (for ([o (my-open-sell-orders character-name #:config config)])
    (define sym (hash-ref o 'code #f))
    (define list-price (hash-ref o 'price 0))
    (define bid (and sym (best-bid sym #:config config)))
    (when (and bid (> bid list-price))
      (printf "  [market] RELIST ~a @ ~a (was ~a)\n" sym bid list-price)
      (flush-output)
      (with-handlers ([exn:fail? (lambda (e)
                            (printf "  [market] relist failed: ~a\n" (exn-message e))
                            (flush-output))])
        (action-grand-exchange-cancel character-name (hasheq 'id (hash-ref o 'id 0)) #:config config)
        (action-grand-exchange-create-sell-order
         character-name (hasheq 'code sym 'quantity (hash-ref o 'quantity 0) 'price bid) #:config config))))))
