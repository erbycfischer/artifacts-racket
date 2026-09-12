#lang racket

;; Gear and travel helpers. auto-gear equips whatever suggest-equipment
;; finds in the bag; buy-kit purchases a named loadout at the items tile;
;; travel-to names a content type so a non-Lisper can write "go to the
;; workshop" without coordinates; outfit-from-bank (alias: equip-best-from-bank)
;; pulls craftable kit from the shared vault for the fighter.

(require "../../dsl-forms.rkt"
         "../../planner.rkt"
         "../../game-data.rkt"
         "../../combat.rkt"
         "../actions.rkt"
         "market-logistics.rkt"
         "logistics.rkt")

(provide auto-gear
         buy-kit
         travel-to
         outfit-from-bank
         equip-best-from-bank
         equip-utility
         worn-in-slot
         wearing?)

;; True when `code` is already worn. Live API uses `weapon_slot` etc.;
;; tests may use an `equipment` hash. Local copy of helpers.rkt equipped?
;; so this module stays free of a circular require.
(define character-equipment-slot-keys
  '(weapon_slot shield_slot helmet_slot body_armor_slot leg_armor_slot
    boots_slot ring1_slot ring2_slot amulet_slot
    artifact1_slot artifact2_slot artifact3_slot
    utility1_slot utility2_slot bag_slot rune_slot))

(define slot-field
  (hasheq 'weapon 'weapon_slot
          'shield 'shield_slot
          'helmet 'helmet_slot
          'body_armor 'body_armor_slot
          'leg_armor 'leg_armor_slot
          'boots 'boots_slot
          'ring 'ring1_slot
          'amulet 'amulet_slot
          'bag 'bag_slot
          'utility 'utility1_slot))

(define (wearing? char code)
  (define eq (character-field char 'equipment #hasheq()))
  (or (and (hash? eq)
           (for/or ([(_ item) (in-hash eq)])
             (cond
               [(hash? item) (item-code=? (hash-ref item 'code #f) code)]
               [else (item-code=? item code)])))
      (for/or ([key character-equipment-slot-keys])
        (item-code=? (character-field char key #f) code))))

(define (slot-value item)
  (cond
    [(hash? item) (hash-ref item 'code #f)]
    [else item]))

(define (worn-in-slot char slot)
  (define eq (character-field char 'equipment #hasheq()))
  (define from-eq
    (and (hash? eq)
         (or (slot-value (hash-ref eq slot #f))
             (slot-value (hash-ref eq (string->symbol
                                       (format "~a_slot" slot))
                                      #f)))))
  (define field (hash-ref slot-field slot #f))
  (or from-eq
      (and field (character-field char field #f))
      (and (eq? slot 'ring) (character-field char 'ring2_slot #f))
      (and (eq? slot 'utility) (character-field char 'utility2_slot #f))))

(define (outfit-level char table)
  (cond
    [(eq? table miner-kit-table)
     (or (character-field char 'mining_level #f)
         (character-field char 'level 1))]
    [(eq? table woodcutter-kit-table)
     (or (character-field char 'woodcutting_level #f)
         (character-field char 'level 1))]
    [else (character-field char 'level 1)]))

(define (candidate-available? char code)
  (or (when-has-item char code)
      (let ([bank-have (bank-item-quantity code)])
        (or (not (number? bank-have)) (positive? bank-have)))))

(define (slot-candidates slot table)
  (define from-table
    (filter values
            (for/list ([b (hash-keys table)])
              (define h (hash-ref table b #f))
              (and (hash? h) (hash-ref h slot #f)))))
  (define rares
    (if (eq? table default-gear-table)
        (filter (lambda (c)
                  (and (rare-loot? c)
                       (eq? (equipment-slot-of c) slot)
                       (not (gather-tool? c))))
                (hash-ref equipment-rank-table slot '()))
        '()))
  (define seen (make-hash))
  (reverse
   (for/fold ([acc '()]) ([c (append from-table rares)])
     (define k (item-code c))
     (cond
       [(hash-ref seen k #f) acc]
       [else
        (hash-set! seen k #t)
        (cons c acc)]))))

(define (maybe-log-equip-review! char slot previous code)
  (when (rare-loot? code)
    (record-equipped-for-review! char slot previous code)))

(define (upgrade-leg char-slot code table)
  (guard-spec
   (lambda (char)
     (define worn (worn-in-slot char char-slot))
     (define lvl (outfit-level char table))
     (and (<= (item-level code) lvl)
          (better-gear? code worn)
          (candidate-available? char code)))
   (list (restock #:code code #:qty 1)
         (guard-spec
          (lambda (char)
            (and (when-has-item char code)
                 (let ([worn (worn-in-slot char char-slot)])
                   (and (better-gear? code worn)
                        (begin
                          (maybe-log-equip-review! char char-slot worn code)
                          #t)))))
          (list (equip code))))))

;; Equip the best weapon/armor currently in inventory. Dormant when the bag
;; has nothing suggest-equipment recognizes, so a bare auto-gear cannot occupy
;; preferred actions and block fight/gather.
(define (auto-gear)
  (guard-spec (lambda (char) (suggest-equipment char #hasheq()))
              (list (action-spec 'auto-gear '()))))

;; Buy and equip each slot in `slots` (a hash of slot -> item-code), but
;; only at the items tile and only for pieces not already worn.
(define (buy-kit #:slots slots)
  (define guards
    (for/list ([(slot code) (in-hash slots)])
      (guard-spec (lambda (char) (not (wearing? char code)))
                  (list (buy #:code code #:qty 1)
                        (equip code)))))
  (goal-spec 'buy-kit
             (list (guard-spec (lambda (char) (when-on-content char "items"))
                               guards))))

;; Walk to the nearest tile of `type` ("workshop", "bank", "grand_exchange",
;; "npc", …). The guard stays off once the character is already there, and
;; the planner's nearest-typed-content supplies the destination.
(define (travel-to #:type type)
  (goal-spec 'travel-to
             (list (guard-spec (lambda (char) (not (when-on-content char type)))
                               (list (action-spec 'move (list (hasheq 'type type))))))))

;; Pull the best vault/bag piece per slot and equip it. Restock+equip only
;; when the candidate ranks strictly above what is worn and the character
;; meets the item level. Lowest rank first in the body so expand-guards
;; prefers the highest-rank live upgrade. Rare combat drops that beat
;; current kit log `kind: equipped-for-review` and are still never auto-sold.
;;
;;   (outfit-from-bank)
;;   (outfit-from-bank #:gear-table miner-kit-table)
;;   (outfit-from-bank #:codes '(copper_dagger copper_helmet))
(define (outfit-from-bank #:codes [codes #f]
                         #:gear-table [table default-gear-table])
  (define pulls
    (cond
      [(pair? codes)
       (for/list ([code codes])
         (define slot (or (equipment-slot-of code) 'weapon))
         (upgrade-leg slot code table))]
      [else
       (define slots '(weapon shield helmet body_armor leg_armor boots ring amulet bag))
       (apply append
              (for/list ([slot slots])
                (define candidates
                  (sort (slot-candidates slot table)
                        <
                        #:key (lambda (c) (equipment-rank c slot))))
                (for/list ([code candidates])
                  (upgrade-leg slot code table))))]))
  (goal-spec 'outfit-from-bank
             (append pulls (list (auto-gear)))))

;; Thin alias of outfit-from-bank: best vault/bag piece per slot, then
;; auto-gear. Same keywords; named for the mailbox reading "equip the best
;; the bank already holds". Do not also call outfit-from-bank on the same body.
;;
;;   (equip-best-from-bank)
;;   (equip-best-from-bank #:gear-table miner-kit-table)
(define (equip-best-from-bank #:codes [codes #f]
                              #:gear-table [table default-gear-table])
  (goal-spec 'equip-best-from-bank
             (goal-spec-actions
              (outfit-from-bank #:codes codes #:gear-table table))))

;; Restock a potion into a combat utility slot (auto-triggers in fights).
;; Distinct from bag `heal-when-low`, which still drinks from inventory.
;;
;;   (equip-utility)
;;   (equip-utility #:code 'small_health_potion #:qty 10 #:slot "utility1")
(define (equip-utility #:code [code 'small_health_potion]
                       #:qty [qty 10]
                       #:slot [slot "utility1"])
  (define slot-key
    (if (or (eq? slot 'utility2) (equal? slot "utility2"))
        'utility2_slot
        'utility1_slot))
  (define slot-name
    (if (eq? slot-key 'utility2_slot) "utility2" "utility1"))
  (goal-spec 'equip-utility
             (list
              (guard-spec
               (lambda (char)
                 (define worn (character-field char slot-key #f))
                 (and (not (item-code=? worn code))
                      (candidate-available? char code)))
               (list (restock #:code code #:qty qty)
                     (guard-spec
                      (lambda (char) (when-has-item char code))
                      (list (action-spec 'equip
                                         (list (hasheq 'code (item-code code)
                                                       'slot slot-name
                                                       'quantity qty))))))))))
