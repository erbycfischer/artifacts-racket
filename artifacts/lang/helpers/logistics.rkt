#lang racket

;; Shared-bank mailbox helpers. Characters deposit classified loot, pull
;; another role's recipe inputs, and haul bags to the vault. Each helper
;; returns a goal-spec / guard-spec so it drops into a character body.
;;
;; Bucket lists are keyword args (`#:soft` / `#:premium` / `#:rare`) so this
;; module does not depend on game-data exports a parallel worker may still
;; be adding. Example defaults below are enough to compose; pass live
;; encyclopedia lists from the bot when those exports land.
;;
;; Rare codes are deposited, never sold.

(require json
         "../../dsl-forms.rkt"
         "../../planner.rkt"
         "../actions.rkt"
         "market-logistics.rkt")

(provide bank-classified-loot
         log-rare-drops
         record-rare-drops!
         record-equipped-for-review!
         rare-drops-log-file
         supply-role
         fulfill-demand
         haul-to-bank
         mailbox-when-used
         clear-bag-except)

;; Example mailbox buckets. Empty rares: do not guess valuables; the bot
;; passes `#:rare` (or game-data `rare-loot-codes` later). Soft/premium
;; examples match common low-tier drops so `(bank-classified-loot)` banks
;; something useful out of the box.
(define example-soft-loot
  '(wolf_meat raw_chicken feather wool cowhide meat apple egg))
(define example-premium-loot
  '(topaz_stone emerald_stone ruby_stone sapphire_stone
    yellow_slimeball wolf_hide spider_silk))
(define example-rare-loot
  '())

(define (as-code-list codes)
  (cond
    [(list? codes) codes]
    [(false? codes) '()]
    [else (list codes)]))

(define (code-member? code codes)
  (for/or ([c codes]) (item-code=? c code)))

(define (unique-codes lists)
  (define seen (make-hash))
  (reverse
   (for*/fold ([acc '()]) ([lst lists] [c (as-code-list lst)])
     (define key (item-code c))
     (cond
       [(hash-ref seen key #f) acc]
       [else
        (hash-set! seen key #t)
        (cons c acc)]))))

;; Deposit a whole stack of `code` (keep 0) when the bag holds it. Same
;; deposit-surplus action as bank-loot; the planner walks to the bank.
(define (deposit-held code)
  (guard-spec (lambda (char) (when-has-item char code))
              (list (action-spec 'deposit-surplus
                                 (list (hasheq 'code (item-code code)
                                               'keep 0))))))

;; Deposit inventory items by soft / premium / rare buckets. Rares are
;; included in the deposit list (never sold). Duplicate codes across
;; buckets are deposited once; rares win the slot so a later `#:soft`
;; overlap cannot drop them from the bank path.
;;
;;   (bank-classified-loot)
;;   (bank-classified-loot #:soft '(wolf_meat) #:premium '(topaz_stone)
;;                         #:rare '(lich_crown))
;;
;; unique-codes keeps the first sighting: walk rare → premium → soft so a
;; code listed as both soft and rare stays on the rare (bank, never sell)
;; path. Reverse the list so expand-guards prefers rares first.
(define (bank-classified-loot #:soft [soft example-soft-loot]
                              #:premium [premium example-premium-loot]
                              #:rare [rare example-rare-loot])
  (define codes (reverse (unique-codes (list rare premium soft))))
  (goal-spec 'bank-classified-loot
             (map deposit-held codes)))

;; ---------------------------------------------------------------------------
;; Rare-drop NDJSON. Side effects run at tick time (guard predicates /
;; record-rare-drops!), never at expand time. logs/ is created on first
;; write, not at module load. Fields: code, qty, char, tick, monster.
;; No tokens, gold, inventory dumps, or other secrets.
;; ---------------------------------------------------------------------------

(define rare-drops-log-file (make-parameter #f))

;; Fingerprint of last logged qty per (char-name . code-string) so walking
;; to the bank does not append a line every planner scan. Qty 0 clears the
;; slot so the next pickup of the same stack size is a new drop.
(define rare-drop-fingerprint (make-hash))

(define (rare-drops-log-path)
  (or (rare-drops-log-file)
      (build-path (current-directory) "logs" "rare-drops.ndjson")))

(define (character-display-name char)
  (define raw (or (character-field char 'name #f)
                  (character-field char 'character #f)))
  (cond
    [(string? raw) raw]
    [(symbol? raw) (symbol->string raw)]
    [else "unknown"]))

;; Monster code if the character is standing on a monster tile, or if a
;; last-fight field is present on the hash. Otherwise json null.
(define (character-monster-code char)
  (define content (content-at-character char))
  (define from-tile
    (and (hash? content)
         (equal? (hash-ref content 'type #f) "monster")
         (hash-ref content 'code #f)))
  (define from-field
    (or (character-field char 'monster #f)
        (character-field char 'monster_code #f)
        (character-field char 'last_monster #f)))
  (define raw (or from-tile from-field))
  (cond
    [(string? raw) raw]
    [(symbol? raw) (symbol->string raw)]
    [else #f]))

(define (character-tick char)
  (define stamped (character-field char 'tick #f))
  (if (number? stamped) stamped (current-seconds)))

(define (append-rare-drop-ndjson! rec)
  (define path (rare-drops-log-path))
  (define dir (path-only (if (path? path) path (string->path (format "~a" path)))))
  (when dir (make-directory* dir))
  (call-with-output-file path
    (lambda (out)
      (write-json rec out)
      (newline out)
      (flush-output out))
    #:exists 'append))

;; Tick-time recorder. Call from a guard predicate (or tests). Safe to
;; invoke every scan: unchanged qty is a no-op; empty stacks reset state.
(define (record-rare-drops! char codes)
  (define name (character-display-name char))
  (define tick (character-tick char))
  (define monster (character-monster-code char))
  (for ([code (as-code-list codes)])
    (define qty (item-quantity char code))
    (define key (cons name (item-code code)))
    (cond
      [(not (positive? qty))
       (hash-remove! rare-drop-fingerprint key)]
      [(equal? (hash-ref rare-drop-fingerprint key #f) qty)
       (void)]
      [else
       (hash-set! rare-drop-fingerprint key qty)
       (with-handlers ([exn:fail?
                        (lambda (e)
                          (printf "  [log] rare-drops write failed: ~a\n"
                                  (exn-message e)))])
         (append-rare-drop-ndjson!
          (hasheq 'code (item-code code)
                  'qty qty
                  'char name
                  'tick tick
                  'kind "rare-drop"
                  'monster (or monster 'null))))])))

;; Fingerprint (char . slot . new-code) so walking to the bank does not
;; append equipped-for-review on every planner scan.
(define equipped-review-fingerprint (make-hash))

(define (record-equipped-for-review! char slot previous new-code)
  (define name (character-display-name char))
  (define tick (character-tick char))
  (define key (list name slot (item-code new-code)))
  (unless (hash-ref equipped-review-fingerprint key #f)
    (hash-set! equipped-review-fingerprint key #t)
    (with-handlers ([exn:fail?
                     (lambda (e)
                       (printf "  [log] equipped-for-review write failed: ~a\n"
                               (exn-message e)))])
      (append-rare-drop-ndjson!
       (hasheq 'kind "equipped-for-review"
               'code (item-code new-code)
               'slot (format "~a" slot)
               'previous (if previous (item-code previous) 'null)
               'char name
               'tick tick)))))

;; When the character holds any of `#:codes` (default: example rare list,
;; empty until the bot passes real rares), append NDJSON and bank them.
;; Logging lives in a predicate that always runs then returns false so it
;; never occupies preferred actions; deposit-surplus legs do the haul.
;;
;;   (log-rare-drops #:codes '(lich_crown dragon_egg))
(define (log-rare-drops #:codes [codes example-rare-loot])
  (define rares (as-code-list codes))
  (goal-spec 'log-rare-drops
             (cons
              (guard-spec (lambda (char)
                            (record-rare-drops! char rares)
                            #f)
                          '())
              (map deposit-held rares))))

;; Pull `#:codes` from the shared vault into the bag (`#:qty` each) so this
;; character can craft or deliver for another role. Each leg is `restock`,
;; which no-ops when the bag already holds enough or the vault is confirmed
;; empty (never 478s).
;;
;;   (fulfill-demand #:codes '(copper_ore ash_wood) #:qty 10)
(define (fulfill-demand #:codes codes #:qty [qty 1])
  (goal-spec 'fulfill-demand
             (for/list ([code (as-code-list codes)])
               (restock #:code code #:qty qty))))

;; Same mailbox withdraw, named from the supplier's side: restock the bag
;; with what another role's recipes need.
;;
;;   (supply-role #:codes '(raw_chicken sunflower) #:qty 5)
(define (supply-role #:codes codes #:qty [qty 1])
  (goal-spec 'supply-role
             (goal-spec-actions (fulfill-demand #:codes codes #:qty qty))))

;; Haul the current bag to the bank. With no `#:reserve`, any non-empty bag
;; is deposited (`deposit-all`); with `#:reserve`, only when the bag is
;; within that many slots of capacity (same trip as bank-when-full). Distinct
;; from `haul`, which gathers until full and then banks.
;;
;;   (haul-to-bank)
;;   (haul-to-bank #:reserve 1)
(define (haul-to-bank #:reserve [reserve #f])
  (goal-spec 'haul-to-bank
             (list (guard-spec
                    (lambda (char)
                      (if reserve
                          (when-inventory-full char #:reserve reserve)
                          (not (when-inventory-empty char))))
                    (list (deposit-all))))))

;; Shared-bank mailbox: dump the bag once it holds at least `#:qty` items
;; (default 10 = one copper_bar / ash_plank). Distinct from `banker`, which
;; only deposits at 99/100 and otherwise just buys vault expansions.
;; Put this *first* on gatherer bodies so gather cannot starve the haul.
;;
;;   (mailbox-when-used)
;;   (mailbox-when-used #:qty 10)
(define (mailbox-when-used #:qty [qty 10])
  (goal-spec 'mailbox-when-used
             (list (guard-spec
                    (lambda (char) (>= (inventory-used char) qty))
                    (list (deposit-all))))))

;; Deposit every held stack whose code is in `#:codes` and not in `#:keep`.
;; Action lists are fixed at expand time, so `#:codes` is the dumpable
;; universe (defaults to classified-loot examples). Codes not in that list
;; stay in the bag; keep codes are never deposited even if they overlap.
;;
;;   (clear-bag-except #:keep '(small_health_potion copper_dagger))
;;   (clear-bag-except #:keep '(cooked_chicken) #:codes '(wolf_meat copper_ore))
(define (clear-bag-except #:keep keep
                          #:codes [codes (append example-soft-loot
                                                 example-premium-loot
                                                 example-rare-loot)])
  (define keep* (as-code-list keep))
  (define dump
    (for/list ([code (unique-codes (list codes))]
               #:unless (code-member? code keep*))
      code))
  (goal-spec 'clear-bag-except
             (map deposit-held dump)))
