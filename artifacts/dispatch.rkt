#lang racket

(require "config.rkt"
         "http.rkt"
         "combat.rkt"
         "game-data.rkt")

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
    [(equip) (action-equip character-name (normalize-equip-items payload) #:config config)]
    [(unequip) (action-unequip character-name (normalize-unequip-items payload) #:config config)]
    [(use) (action-use character-name payload #:config config)]
    [(fight) (action-fight character-name #:participants (if (list? payload) payload '()) #:config config)]
    [(gather) (action-gather character-name #:config config)]
    [(craft) (action-craft character-name payload #:config config)]
    [(recycle) (action-recycle character-name payload #:config config)]
    [(bank-deposit-item) (action-bank-deposit-item character-name (if (list? payload) payload '()) #:config config)]
    [(bank-deposit-gold) (action-bank-deposit-gold character-name (if (number? payload) payload 0) #:config config)]
    [(bank-withdraw-item) (action-bank-withdraw-item character-name (if (list? payload) payload '()) #:config config)]
    [(bank-withdraw-gold) (action-bank-withdraw-gold character-name (if (number? payload) payload 0) #:config config)]
    [(deposit-gold-surplus) (run-deposit-gold-surplus character-name payload #:config config)]
    [(top-up-gold) (run-top-up-gold character-name payload #:config config)]
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
    [(deposit-surplus) (run-deposit-surplus character-name payload #:config config)]
    [(restock) (run-restock character-name payload #:config config)]
    [(snap-up) (run-snap-up character-name payload #:config config)]
    [(auto-gear) (run-auto-gear character-name #:config config)]
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

;; ---------------------------------------------------------------------------
;; Cross-account helpers
;;
;; These read bank items or the public GE book, which the character hash does
;; not carry. They follow the market-tick precedent: a named action whose
;; handler does the extra GETs, then issues the matching character action.
;; ---------------------------------------------------------------------------

(define (unwrap-data response)
  (cond
    [(and (hash? response) (hash-has-key? response 'data)) (hash-ref response 'data)]
    [else response]))

(define (code-string v)
  (cond
    [(symbol? v) (symbol->string v)]
    [(string? v) v]
    [else (format "~a" v)]))

(define (inventory-qty char code)
  (define want (code-string code))
  (define inv (if (hash? char) (hash-ref char 'inventory '()) '()))
  (for/sum ([slot (if (list? inv) inv '())])
    (if (and (hash? slot)
             (equal? (code-string (hash-ref slot 'code "")) want))
        (hash-ref slot 'quantity 0)
        0)))

(define (load-character character-name #:config config)
  (unwrap-data (get-character character-name #:config config)))

;; Deposit max(0, in-bag qty - keep) of `code`. A keep of 0 dumps the stack.
(define (run-deposit-surplus character-name payload #:config [config (current-config)])
  (define code (code-string (if (hash? payload) (hash-ref payload 'code "") "")))
  (define keep (if (hash? payload) (hash-ref payload 'keep 0) 0))
  (define char (load-character character-name #:config config))
  (define surplus (max 0 (- (inventory-qty char code) keep)))
  (cond
    [(zero? surplus)
     (printf "  [bank] deposit-surplus ~a: nothing above keep ~a\n" code keep)
     (flush-output)]
    [else
     (printf "  [bank] deposit-surplus ~a x~a (keep ~a)\n" code surplus keep)
     (flush-output)
     (action-bank-deposit-item character-name
                               (list (hasheq 'code code 'quantity surplus))
                               #:config config)]))

;; Deposit carried gold down to `keep`. One trip clears a fat pocket so the
;; trader's keep-gold / procure loop can spend it.
(define (run-deposit-gold-surplus character-name payload #:config [config (current-config)])
  (define keep (if (hash? payload) (hash-ref payload 'keep 0) 0))
  (define char (load-character character-name #:config config))
  (define have (if (hash? char) (hash-ref char 'gold 0) 0))
  (define surplus (max 0 (- (if (number? have) have 0) keep)))
  (cond
    [(zero? surplus)
     (printf "  [bank] ~a deposit-gold: nothing above keep ~a\n" character-name keep)
     (flush-output)]
    [else
     (printf "  [bank] ~a deposit-gold ~a (keep ~a)\n" character-name surplus keep)
     (flush-output)
     (action-bank-deposit-gold character-name surplus #:config config)]))

;; Withdraw until carried gold reaches `floor`, but never more than the vault
;; holds — empty vault → quiet no-op instead of a failed withdraw every tick.
(define (run-top-up-gold character-name payload #:config [config (current-config)])
  (define floor (if (hash? payload) (hash-ref payload 'floor 100) 100))
  (define char (load-character character-name #:config config))
  (define have (if (hash? char) (hash-ref char 'gold 0) 0))
  (define need (max 0 (- floor (if (number? have) have 0))))
  (define bank-gold
    (with-handlers ([exn:fail? (lambda (_) 0)])
      (define raw (get-bank-details #:config config))
      (define data (cond
                     [(and (hash? raw) (hash-has-key? raw 'data)) (hash-ref raw 'data)]
                     [(hash? raw) raw]
                     [else #hasheq()]))
      (define g (hash-ref data 'gold 0))
      (if (number? g) g 0)))
  (define take (min need bank-gold))
  (cond
    [(zero? take)
     (printf "  [bank] ~a top-up-gold: have ~a/~a, vault ~a\n"
             character-name have floor bank-gold)
     (flush-output)]
    [else
     (printf "  [bank] ~a top-up-gold +~a (have ~a -> ~a)\n"
             character-name take have (+ have take))
     (flush-output)
     (action-bank-withdraw-gold character-name take #:config config)]))

;; Withdraw from the bank until the bag holds `qty` of `code`. Reads bank
;; items so we never request more than the vault actually has.
(define (run-restock character-name payload #:config [config (current-config)])
  (define code (code-string (if (hash? payload) (hash-ref payload 'code "") "")))
  (define want (if (hash? payload) (hash-ref payload 'qty 0) 0))
  (define char (load-character character-name #:config config))
  (define have (inventory-qty char code))
  (define need (max 0 (- want have)))
  (define bank-items
    (unwrap-data (get-bank-items #:item-code code #:config config)))
  (define bank-have
    (for/sum ([it (if (list? bank-items) bank-items '())])
      (if (hash? it) (hash-ref it 'quantity 0) 0)))
  (define take (min need bank-have))
  (cond
    [(zero? take)
     (printf "  [bank] restock ~a: bag ~a/~a, bank ~a\n" code have want bank-have)
     (flush-output)]
    [else
     (printf "  [bank] restock ~a x~a (bag ~a -> ~a)\n" code take have want)
     (flush-output)
     (action-bank-withdraw-item character-name
                                (list (hasheq 'code code 'quantity take))
                                #:config config)]))

;; Buy `code` on the GE when the best public ask is at or below `max_price`.
;; Places a buy order at the ask, same as ruthless-market's pre-emptive buy.
(define (run-snap-up character-name payload #:config [config (current-config)])
  (define code (if (hash? payload) (hash-ref payload 'code #f) #f))
  (define max-price (if (hash? payload) (hash-ref payload 'max_price 0) 0))
  (define sym (if (symbol? code) code (and code (string->symbol (code-string code)))))
  (define ask (and sym (best-ask sym #:config config)))
  (cond
    [(not ask)
     (printf "  [market] snap-up ~a: no public ask\n" sym)
     (flush-output)]
    [(> ask max-price)
     (printf "  [market] snap-up ~a: ask ~a > max ~a\n" sym ask max-price)
     (flush-output)]
    [else
     (printf "  [market] snap-up BUY ~a @ ~a (max ~a)\n" sym ask max-price)
     (flush-output)
     (action-grand-exchange-create-buy-order
      character-name
      (hasheq 'code sym 'quantity 1 'price ask)
      #:config config)]))

;; Equip whatever suggest-equipment finds in the live inventory. No-ops when
;; the bag has no weapon/armor fragment the scorer recognizes.
(define (json-slot slot)
  (cond [(symbol? slot) (symbol->string slot)]
        [(string? slot) slot]
        [else #f]))

;; Map logical rank-table slots onto Artifacts equip API slots. The API
;; rejects bare "ring" / "utility" / "artifact" (wants ring1, utility1, …)
;; and answers 422 invalid payload.
(define (api-equip-slot slot)
  (define s (json-slot slot))
  (cond
    [(not s) #f]
    [(member s '("ring" "ring1" "ring2"))
     (if (equal? s "ring2") "ring2" "ring1")]
    [(member s '("utility" "utility1" "utility2"))
     (if (equal? s "utility2") "utility2" "utility1")]
    [(member s '("artifact" "artifact1" "artifact2" "artifact3"))
     (cond [(equal? s "artifact2") "artifact2"]
           [(equal? s "artifact3") "artifact3"]
           [else "artifact1"])]
    [else s]))

(define (json-code code)
  (cond [(symbol? code) (symbol->string code)]
        [(string? code) code]
        [else #f]))

;; Turn equip action payloads into API JSON: a list of {code, slot}
;; hashes with string fields. Accepts bare item codes, nested lists,
;; and already-formed hashes.
(define (normalize-equip-items payload)
  (define raw
    (cond
      [(not payload) '()]
      [(and (list? payload) (pair? payload)
            (list? (car payload)) (not (hash? (car payload))))
       (car payload)]
      [(list? payload) payload]
      [(hash? payload) (list payload)]
      [(or (symbol? payload) (string? payload)) (list payload)]
      [else '()]))
  (filter values
          (for/list ([it raw])
            (cond
              [(hash? it)
               (define code (json-code (hash-ref it 'code #f)))
               (define slot (or (api-equip-slot (hash-ref it 'slot #f))
                                (and code (api-equip-slot (or (equipment-slot-of code) 'weapon)))))
               (and code slot
                    (let* ([qty (hash-ref it 'quantity #f)]
                           [base (hasheq 'code code 'slot slot)])
                      (if qty (hash-set base 'quantity qty) base)))]
              [(or (symbol? it) (string? it))
               (define code (json-code it))
               (define slot (api-equip-slot (or (equipment-slot-of code) 'weapon)))
               (and code slot (hasheq 'code code 'slot slot))]
              [else #f]))))

;; Unequip bodies are slot-focused: `{slot}` or bare slot name/symbol.
(define (normalize-unequip-items payload)
  (define raw
    (cond
      [(not payload) '()]
      [(and (list? payload) (pair? payload)
            (list? (car payload)) (not (hash? (car payload))))
       (car payload)]
      [(list? payload) payload]
      [(hash? payload) (list payload)]
      [(or (symbol? payload) (string? payload)) (list payload)]
      [else '()]))
  (filter values
          (for/list ([it raw])
            (cond
              [(hash? it)
               (define slot (or (api-equip-slot (hash-ref it 'slot #f))
                                (let ([code (json-code (hash-ref it 'code #f))])
                                  (and code (api-equip-slot (equipment-slot-of code))))))
               (and slot (hasheq 'slot slot))]
              [(or (symbol? it) (string? it))
               (define slot (api-equip-slot it))
               (and slot (hasheq 'slot slot))]
              [else #f]))))

(define (run-auto-gear character-name #:config [config (current-config)])
  (define char (load-character character-name #:config config))
  (define suggestion (suggest-equipment char #hasheq()))
  (cond
    [(not suggestion)
     (printf "  [gear] auto-gear: nothing to equip\n")
     (flush-output)]
    [else
     (define items
       (normalize-equip-items
        (for/list ([(slot code) (in-hash suggestion)])
          (hasheq 'slot slot 'code code))))
     (cond
       [(null? items)
        (printf "  [gear] auto-gear: nothing to equip\n")
        (flush-output)]
       [else
        (printf "  [gear] auto-gear ~a\n" items)
        (flush-output)
        (action-equip character-name items #:config config)])]))

