#lang racket

;; Gathering, recycling, and crafting compositions. Each helper returns a
;; goal-spec or guard-spec that flattens into a character / pipeline body.

(require "../../dsl-forms.rkt"
         "../../planner.rkt"
         "../../game-data.rkt"
         "../actions.rkt"
         "market-logistics.rkt")

(provide gather-specific
         gather-until
         recycle-junk
         production-chain
         craft-if-materials
         forge-loop
         bank-craft
         workshop-loop
         cook-for-roster
         forge-kit-for
         forge-progression
         bank-crafted-products
         adaptive-gather
         default-workshop-by-skill)

(define (bank-when-full-guard #:reserve [reserve 1])
  (guard-spec (lambda (char) (when-inventory-full char #:reserve reserve))
              (list (deposit-all))))

;; Like gather-loop, but the planner is pinned to `code` instead of the
;; role's highest-level node. Still banks when the bag is within `reserve`
;; slots of capacity.
(define (gather-specific #:resource code #:reserve [reserve 1])
  (goal-spec 'gather-specific
             (list (action-spec 'gather (list (hasheq 'code (item-code code))))
                   (bank-when-full-guard #:reserve reserve))))

;; Gather `code` until the bag holds at least `n` of it, banking when full
;; along the way. Once the quantity is reached the guard goes dormant so the
;; planner can fall through to the next goal (typically a craft step).
(define (gather-until #:resource code #:qty n #:reserve [reserve 1])
  (guard-spec (lambda (char) (not (when-has-qty char code n)))
              (goal-spec-actions (gather-specific #:resource code #:reserve reserve))))

;; Recycle each listed junk code, but only at a workshop and only when that
;; code is actually in the bag. Qty 1000 dumps a whole stack the way sell-loot
;; dumps drops.
(define (recycle-junk #:codes codes)
  (define per-code
    (for/list ([code codes])
      (guard-spec (lambda (char) (when-has-item char code))
                  (list (recycle #:code code #:qty 1000)))))
  (goal-spec 'recycle-junk
             (list (guard-spec (lambda (char) (when-on-content char "workshop"))
                               per-code))))

(define (recipe-chain code qty)
  (define mats (recipe-materials code))
  (if mats
      (for/list ([m mats])
        (list (car m) (* (cadr m) qty)))
      '()))

;; Sequence: gather-until each ingredient (bank between), then craft the
;; final product. `#:chain` is a list of `(code qty)` pairs; when omitted,
;; `default-recipes` supplies the ingredients for `#:craft`.
(define (production-chain #:chain [chain #f] #:craft code #:qty [qty 1])
  (define steps (if (pair? chain) chain (recipe-chain code qty)))
  (goal-spec 'production-chain
             (append (for/list ([step steps])
                       (gather-until #:resource (car step) #:qty (cadr step)))
                     (list (craft #:code code #:qty qty)
                           (bank-when-full-guard)))))

(define (can-craft-item? char code)
  (define skill (craft-workshop-skill code))
  (define need (item-craft-level code))
  (and skill (<= need (or (skill-level char skill) 1))))

;; Kit / tools / bags: forge one, then stop. Lower-tier slots go dormant
;; once the vault or bag already holds a strictly better piece.
(define (one-shot-kit? code)
  (define slot (equipment-slot-of code))
  (and slot (not (eq? slot 'utility))))

(define (held-qty char code)
  (+ (item-quantity char code)
     (let ([q (bank-item-quantity code)])
       (if (number? q) q 0))))

;; Gather tools and fighter weapons share the 'weapon rank ladder but must
;; not one-shot each other: a vault pickaxe must not block forging a dagger,
;; and a worn dagger must not starve tools.
(define (same-weapon-family? a b)
  (eq? (and (gather-tool? a) #t) (and (gather-tool? b) #t)))

(define (slot-already-covered? char code)
  (define slot (equipment-slot-of code))
  (or (>= (held-qty char code) 1)
      (and slot
           (for/or ([other (hash-ref equipment-rank-table slot '())])
             (and (better-gear? other code)
                  (or (not (eq? slot 'weapon))
                      (same-weapon-family? other code))
                  (>= (held-qty char other) 1))))))

(define (should-forge-kit? char code)
  (or (not (one-shot-kit? code))
      (not (slot-already-covered? char code))))

;; Craft `qty` of `code`, but only once every listed material is in the bag
;; at the required quantity and this character's workshop skill can make it.
(define (craft-if-materials #:code code #:qty [qty 1] #:materials materials)
  (guard-spec (lambda (char)
                (and (can-craft-item? char code)
                     (should-forge-kit? char code)
                     (for/and ([m materials])
                       (when-has-qty char (car m) (cadr m)))))
              (list (craft #:code code #:qty qty))))


;; Expand a recipe entry into `(product ((mat qty) ...))`. Accepts a product
;; symbol (looked up in default-recipes) or an explicit
;; `(product ((mat qty) ...))` list.
(define (normalize-forge-recipe entry)
  (cond
    [(symbol? entry)
     (define mats (recipe-materials entry))
     (and mats (list entry mats))]
    [(and (list? entry) (>= (length entry) 2) (symbol? (car entry)) (list? (cadr entry)))
     (list (car entry) (cadr entry))]
    [else #f]))

;; Bank-backed crafting for a shared vault: restock every recipe ingredient,
;; craft when the bag holds the mats, recycle junk at the workshop, then bank.
;; `#:recipes` defaults to `default-forge-recipes`. `#:batch` multiplies the
;; per-craft ingredient qty so the smith pulls a workable stack in one trip:
;;
;;   (forge-loop)
;;   (forge-loop #:recipes '(copper_bar ash_plank) #:batch 5)
;;
;; Bank expansion is left to a sibling `(banker)` in the character body so this
;; module stays free of a circular require on helpers.rkt.
(define (forge-loop #:recipes [recipes default-forge-recipes]
                    #:batch [batch 5]
                    #:junk [junk '(wooden_stick ash)])
  (define normalized
    (filter values (map normalize-forge-recipe recipes)))
  (define restock-legs
    (apply append
           (for/list ([recipe normalized])
             (for/list ([m (cadr recipe)])
               (guard-spec
                (lambda (char)
                  (and (can-craft-item? char (car recipe))
                       (should-forge-kit? char (car recipe))))
                (list (restock #:code (car m) #:qty (* (cadr m) batch))))))))
  (define craft-legs
    (for/list ([recipe normalized])
      (craft-if-materials #:code (car recipe)
                          #:qty 1
                          #:materials (cadr recipe))))
  (define junk-legs
    (if (pair? junk)
        (goal-spec-actions (recycle-junk #:codes junk))
        '()))
  ;; Restocks before crafts in the pre-reverse list → after expand-guards
  ;; reverse, live crafts beat restocks (forge from bars in hand before
  ;; pulling more ore into a tight bag).
  (goal-spec 'forge-loop
             (append restock-legs craft-legs junk-legs
                     (list (bank-when-full-guard)))))

;; One-shot bank-backed craft: pull `materials`, craft `qty` of `code`, bank.
;; Use when a bot wants a single product without the full forge roster.
(define (bank-craft #:code code #:qty [qty 1] #:materials materials)
  (goal-spec 'bank-craft
             (append (for/list ([m materials])
                       (restock #:code (car m) #:qty (* (cadr m) qty)))
                     (list (craft-if-materials #:code code #:qty qty #:materials materials)
                           (bank-when-full-guard)))))


;; ---------------------------------------------------------------------------
;; WAVE 1: intent-level production (smith multi-workshop + adaptive gather)
;;
;; Priority forge queue (semantic; expand-guards reverses a goal body, so
;; workshop-loop emits groups in reverse and cooking/food wins first):
;;   1. food for fighter
;;   2. potions
;;   3. bars / planks
;;   4. current-tier kit
;;   5. next-tier kit
;;
;; Craft routing is not a separate action: `craft` payloads go through
;; `plan-craft` → `craft-workshop-skill`, so each product walks to its
;; mining / cooking / weaponcrafting / … workshop instead of the nearest
;; cooking tile.
;; ---------------------------------------------------------------------------

;; Human-readable workshop order. workshop-loop walks this list, reversing
;; before splice so expand-guards puts cooking first in preferred actions.
(define default-workshop-skill-order
  '(cooking alchemy mining woodcutting
    weaponcrafting gearcrafting jewelrycrafting))

;; Per-skill products, low-priority first / last preferred after reverse.
;; Current-tier copper/wood kit sits after next-tier iron so the live
;; restock+craft for copper_dagger wins ties against iron_sword.
(define default-workshop-by-skill
  (hasheq 'cooking '(cooked_wolf_meat mushroom_soup fried_eggs cooked_shrimp
                     cooked_beef cooked_gudgeon cooked_chicken)
          'alchemy '(minor_health_potion
                     air_boost_potion fire_boost_potion water_boost_potion earth_boost_potion
                     small_health_potion)
          'mining '(adamantite_bar mithril_bar gold_bar steel_bar iron_bar copper_bar)
          'woodcutting '(palm_plank maple_plank dead_wood_plank hardwood_plank spruce_plank ash_plank)
          'weaponcrafting '(steel_axe steel_pickaxe steel_battleaxe
                          king_slime_sword
                          leather_gloves iron_axe iron_pickaxe iron_sword
                          sticky_sword apprentice_gloves
                          copper_axe copper_pickaxe copper_dagger)
          'gearcrafting '(steel_armor steel_legs_armor steel_boots steel_helm slime_shield
                          mushmush_jacket mushmush_wizard_hat adventurer_pants adventurer_boots
                          satchel
                          iron_armor iron_shield iron_legs_armor iron_boots iron_helm
                          copper_legs_armor copper_armor
                          copper_boots copper_helmet wooden_shield)
          'jewelrycrafting '(skull_amulet life_ring wisdom_amulet steel_ring
                             fire_and_earth_amulet life_amulet iron_ring copper_ring)))

(define (as-item-symbol code)
  (cond
    [(symbol? code) code]
    [(string? code) (string->symbol code)]
    [else code]))

(define (recipe-product-key entry)
  (cond
    [(or (symbol? entry) (string? entry)) (as-item-symbol entry)]
    [(and (list? entry) (pair? entry) (or (symbol? (car entry)) (string? (car entry))))
     (as-item-symbol (car entry))]
    [else #f]))

(define (helper-forms spec)
  (cond
    [(goal-spec? spec) (goal-spec-actions spec)]
    [(guard-spec? spec) (list spec)]
    [else (list spec)]))

;; Group a recipe list by `craft-workshop-skill`. Unknown products (no
;; workshop mapping) are dropped — those would otherwise walk to the
;; nearest untyped cooking tile.
(define (group-recipes-by-skill recipes)
  (define grouped (make-hasheq))
  (for ([entry recipes])
    (define key (recipe-product-key entry))
    (define skill (and key (craft-workshop-skill key)))
    (when skill
      (hash-set! grouped skill
                 (append (hash-ref grouped skill '()) (list entry)))))
  grouped)

(define (default-recipes-for-skill skill)
  (hash-ref default-workshop-by-skill skill '()))

(define (workshop-recipe-groups recipes order)
  (define grouped
    (if (pair? recipes)
        (group-recipes-by-skill recipes)
        (for/fold ([h (hasheq)]) ([skill order])
          (hash-set h skill (default-recipes-for-skill skill)))))
  (for/list ([skill order]
             #:do [(define recs (hash-ref grouped skill '()))]
             #:when (pair? recs))
    (cons skill recs)))

;; Ordered multi-skill craft loop. Each skill group is a `forge-loop`
;; (live crafts beat restocks after reverse; then junk → bank-when-full).
;; `#:order` overrides the cooking→…→jewelry sequence. `#:batch` is the
;; default restock multiplier; `#:batches` is an optional skill→batch hash.
;;
;;   (workshop-loop)
;;   (workshop-loop #:batch 3 #:order '(cooking mining weaponcrafting))
;;   (workshop-loop #:batches (hasheq 'cooking 10 'mining 5) #:junk '())
(define (workshop-loop #:order [order default-workshop-skill-order]
                       #:batch [batch 5]
                       #:batches [batches #hasheq()]
                       #:recipes [recipes #f]
                       #:junk [junk '(wooden_stick ash)])
  (define groups (workshop-recipe-groups recipes order))
  (define skills (map car groups))
  (define legs
    (apply append
           (for/list ([group (reverse groups)])
             (define skill (car group))
             (define recs (cdr group))
             (define b (hash-ref batches skill batch))
             ;; Junk + bank-when-full live on the last-emitted (highest
             ;; priority) group, same as a single forge-loop body.
             (define j (if (and (pair? skills) (eq? skill (car skills)))
                           junk
                           '()))
             (helper-forms
              (forge-loop #:recipes recs #:batch b #:junk j)))))
  ;; Deposit finished goods first in the source body so expand-guards ranks
  ;; craft/restock above haul — otherwise copper_bar restock↔deposit forever
  ;; and the smith never reaches craft-if-materials.
  (goal-spec 'workshop-loop
             (append (helper-forms (bank-crafted-products))
                     (if (pair? legs) legs (list (bank-when-full-guard))))))

;; Bars/planks are craft inputs for kit — depositing them keep-0 before forge
;; runs is the restock↔deposit thrash seen on live harmony. Default haul is
;; finished food / pots / kit / tools only. Pass `#:codes` to also bank bars.
(define forge-intermediate-codes
  '(copper_bar iron_bar steel_bar gold_bar mithril_bar adamantite_bar
    ash_plank spruce_plank hardwood_plank dead_wood_plank
    maple_plank palm_plank))

(define (forge-intermediate? code)
  (define key (as-item-symbol code))
  (for/or ([c forge-intermediate-codes])
    (eq? c key)))

;; Deposit finished workshop output (food, pots, kit, tools) so the
;; fighter/trader can withdraw it. Raw mats and bars/planks stay in the bag
;; for the next craft (bank-when-full / banker still dump a tight bag).
;;
;;   (bank-crafted-products)
;;   (bank-crafted-products #:codes '(cooked_chicken copper_dagger copper_bar))
(define (bank-crafted-products #:codes [codes #f])
  (define products
    (or codes
        (filter (lambda (c) (not (forge-intermediate? c)))
                (remove-duplicates
                 (append default-forge-recipes
                         fighter-kit-codes
                         role-tool-codes
                         '(cooked_shrimp mushroom_soup cooked_wolf_meat
                           minor_health_potion
                           air_boost_potion fire_boost_potion
                           water_boost_potion earth_boost_potion)
                         (apply append
                                (for/list ([b (sort (hash-keys default-gear-table) <)])
                                  (kit-product-codes default-gear-table b))))))))
  (goal-spec 'bank-crafted-products
             (for/list ([code products])
               (guard-spec (lambda (char) (when-has-item char code))
                           (list (action-spec 'deposit-surplus
                                              (list (hasheq 'code (item-code code)
                                                            'keep 0))))))))

;; Pull raw food from the vault, cook, deposit cooked stacks when the bag
;; is tight. Default recipes are the cooking entries in default-recipes
;; (cooked_chicken, cooked_gudgeon). Same restock/craft/bank shape as
;; forge-loop; `craft` routes to the cooking workshop via craft-workshop-skill.
;;
;;   (cook-for-roster)
;;   (cook-for-roster #:batch 10 #:recipes '(cooked_chicken))
(define (cook-for-roster #:batch [batch 10]
                         #:recipes [recipes #f]
                         #:junk [junk '()])
  (define recs (or recipes (default-recipes-for-skill 'cooking)))
  (goal-spec 'cook-for-roster
             (helper-forms
              (forge-loop #:recipes recs #:batch batch #:junk junk))))

(define (kit-bucket-for level table #:next? next? #:bucket bucket)
  (cond
    [bucket bucket]
    [else
     (define buckets (sort (hash-keys table) <))
     (define current
       (for/fold ([best #f]) ([b buckets] #:when (<= b level))
         (if (or (not best) (> b best)) b best)))
     (define upcoming
       (for/or ([b buckets] #:when (> b level)) b))
     (or (and next? upcoming) current upcoming)]))

(define (kit-product-codes table bucket)
  (define slots (and bucket (hash-ref table bucket #f)))
  (if (hash? slots)
      (remove-duplicates
       (for/list ([slot '(weapon shield helmet body_armor leg_armor boots ring amulet)]
                  #:do [(define code (hash-ref slots slot #f))]
                  #:when code)
         (as-item-symbol code)))
      '()))

;; Craft the next (or current) gear-table bucket for a fighter `level`
;; into the vault. Pieces without a `default-recipes` entry are skipped.
;; The smith never sees the fighter's live level — callers pass `#:level`.
;;
;;   (forge-kit-for #:level 3)          ; bucket 5 (sticky_sword kit)
;;   (forge-kit-for #:level 1 #:next? #f) ; bucket 1 (copper starter)
;;   (forge-kit-for #:level 10 #:bucket 10)
(define (forge-kit-for #:level level
                       #:gear-table [table default-gear-table]
                       #:batch [batch 1]
                       #:next? [next? #t]
                       #:bucket [bucket #f]
                       #:junk [junk '()])
  (define chosen (kit-bucket-for level table #:next? next? #:bucket bucket))
  (define recs
    (filter (lambda (code) (recipe-materials code))
            (kit-product-codes table chosen)))
  (goal-spec 'forge-kit-for
             (helper-forms
              (forge-loop #:recipes recs #:batch batch #:junk junk))))

;; Craft every gear-table bucket in turn. Lowest tier is last in the body so
;; expand-guards prefers copper kit first; higher tiers restock/craft as soon
;; as the smith's workshop skill and the recipe mats exist.
;;
;;   (forge-progression)
;;   (forge-progression #:batch 1)
(define (forge-progression #:gear-table [table default-gear-table]
                           #:batch [batch 1]
                           #:junk [junk '()])
  (define buckets (sort (hash-keys table) <))
  (goal-spec 'forge-progression
             (apply append
                    (for/list ([b buckets])
                      (helper-forms
                       (forge-kit-for #:level b
                                      #:gear-table table
                                      #:batch batch
                                      #:next? #f
                                      #:bucket b
                                      #:junk junk))))))

;; Gatherable items the vault/forge actually consume. Node codes match
;; encyclopedia resource tiles (copper_rocks, ash_tree, …), not bag item
;; codes (copper_ore, ash_wood). min-level is the node requirement so a
;; level-1 miner is not pinned to iron_rocks.
;; (item node role min-level)
(define gather-catalog
  '((copper_ore copper_rocks mining 1)
    (iron_ore iron_rocks mining 10)
    (coal coal_rocks mining 20)
    (gold_ore gold_rocks mining 30)
    (mithril_ore mithril_rocks mining 40)
    (adamantite_ore adamantite_rocks mining 50)
    (ash_wood ash_tree woodcutting 1)
    (spruce_wood spruce_tree woodcutting 10)
    (birch_wood birch_tree woodcutting 20)
    (dead_wood dead_tree woodcutting 30)
    (maple_wood maple_tree woodcutting 40)
    (palm_wood palm_tree woodcutting 50)
    (gudgeon gudgeon_fishing_spot fishing 1)
    (shrimp shrimp_fishing_spot fishing 10)
    (trout trout_fishing_spot fishing 20)
    (sunflower sunflower alchemy 1)
    (nettle_leaf nettle alchemy 20)))

(define default-node-for-role
  (hasheq 'mining 'copper_rocks
          'woodcutting 'ash_tree
          'fishing 'gudgeon_fishing_spot
          'alchemy 'sunflower))

(define (catalog-row-item row) (car row))
(define (catalog-row-node row) (cadr row))
(define (catalog-row-role row) (caddr row))
(define (catalog-row-level row) (cadddr row))

(define (catalog-for-item item)
  (define key (as-item-symbol item))
  (for/or ([row gather-catalog])
    (and (eq? (catalog-row-item row) key) row)))

(define (catalog-for-node node)
  (define key (as-item-symbol node))
  (for/or ([row gather-catalog])
    (and (eq? (catalog-row-node row) key) row)))

;; Vault qty. Character hashes do not include bank contents — only
;; `bank_max_items` / `bank_items_used`. If a snapshot list is stuffed on
;; `bank_items` (tests), use it; otherwise `bank-item-quantity` (live GET
;; or the `bank-qty-lookup` parameter). #f means "unknown", not empty.
(define (vault-item-quantity char code)
  (define snap (character-field char 'bank_items #f))
  (cond
    [(list? snap)
     (for/sum ([it snap])
       (if (and (hash? it) (item-code=? (hash-ref it 'code #f) code))
           (hash-ref it 'quantity 0)
           0))]
    [else (bank-item-quantity code)]))

(define (demand-qty entry default-target)
  (if (and (list? entry) (>= (length entry) 2) (number? (cadr entry)))
      (cadr entry)
      default-target))

(define (demand-node-hint entry)
  (and (list? entry) (>= (length entry) 3) (caddr entry)))

(define (demand-item-key entry)
  (cond
    [(or (symbol? entry) (string? entry)) (as-item-symbol entry)]
    [(and (list? entry) (pair? entry)) (as-item-symbol (car entry))]
    [else #f]))

;; One demand row: (item target node min-level). Products in `#:demand`
;; expand through recipe-materials so `(adaptive-gather #:demand '(copper_bar))`
;; gathers copper_ore / copper_rocks.
(define (demand->triples entry role default-target)
  (define item (demand-item-key entry))
  (define target (demand-qty entry default-target))
  (define hinted (demand-node-hint entry))
  (define (row->triple row qty)
    (and row
         (eq? (catalog-row-role row) role)
         (list (catalog-row-item row)
               qty
               (catalog-row-node row)
               (catalog-row-level row))))
  (cond
    [(not item) '()]
    [hinted
     (define row (or (catalog-for-node hinted) (catalog-for-item item)))
     (filter values (list (row->triple row target)))]
    [(catalog-for-item item)
     (filter values (list (row->triple (catalog-for-item item) target)))]
    [(catalog-for-node item)
     (filter values (list (row->triple (catalog-for-node item) target)))]
    [else
     (define mats (recipe-materials item))
     (if mats
         (apply append
                (for/list ([m mats])
                  (demand->triples (list (car m)
                                         (max target (* (cadr m) 1))
                                         #f)
                                   role
                                   target)))
         '())]))

(define (default-demand-entries role default-target)
  (for/list ([row gather-catalog]
             #:when (eq? (catalog-row-role row) role))
    (list (catalog-row-item row) default-target (catalog-row-node row))))

;; Largest vault deficit among unlocked nodes. Unknown snapshot (#f qty)
;; → role default node. Nothing short (or everything above skill) → #f
;; so the helper goes dormant and the planner's role gather can run.
(define (gather-skill-cap char role)
  (case role
    [(mining) (character-field char 'mining_level 1)]
    [(woodcutting) (character-field char 'woodcutting_level 1)]
    [(fishing) (character-field char 'fishing_level 1)]
    [(alchemy) (character-field char 'alchemy_level 1)]
    [else 1]))

(define (pick-gather-node char triples default-node role)
  (define cap (gather-skill-cap char role))
  (define scored
    (for/list ([t triples])
      (define item (car t))
      (define target (cadr t))
      (define node (caddr t))
      (define need (cadddr t))
      (define have (vault-item-quantity char item))
      (list item target node need have)))
  (define known
    (filter (lambda (row) (number? (list-ref row 4))) scored))
  (define unlocked
    (filter (lambda (row) (<= (list-ref row 3) cap))
            (if (pair? known) known scored)))
  (cond
    [(null? triples) default-node]
    [(null? unlocked) default-node]
    [else
     (define critical-short
       (filter (lambda (row)
                 (and (number? (list-ref row 4))
                      (< (list-ref row 4) 10)))
               unlocked))
     (cond
       [(pair? critical-short)
        ;; Empty stacks: lowest node level first so copper/ash feed the first crafts.
        (define best
          (for/fold ([best (car critical-short)]) ([row (cdr critical-short)])
            (if (< (list-ref row 3) (list-ref best 3)) row best)))
        (caddr best)]
       [else
        ;; Vault already has a craft stack: train the highest node this skill can.
        (define best
          (for/fold ([best (car unlocked)]) ([row (cdr unlocked)])
            (if (> (list-ref row 3) (list-ref best 3)) row best)))
        (caddr best)])]))

;; Pick a resource from vault deficit vs forge/cook demand, replacing a
;; hard-coded copper_rocks / ash_tree gather. `#:demand` is item codes,
;; `(item qty)`, `(item qty node)`, or craft products (expanded to mats).
;;
;;   (adaptive-gather #:role 'mining)
;;   (adaptive-gather #:role 'woodcutting #:demand '(ash_wood spruce_wood))
;;   (adaptive-gather #:role 'mining #:demand '(copper_bar iron_bar) #:target 40)
;;
;; Fallback: when the vault cannot be read (no `bank_items` on the character
;; and `bank-item-quantity` is #f), gather the role default node
;; (copper_rocks / ash_tree / gudgeon_fishing_spot / sunflower).
(define (adaptive-gather #:role [role 'mining]
                         #:demand [demand #f]
                         #:target [target 20]
                         #:reserve [reserve 1]
                         #:resource [resource #f])
  (define default-node
    (or resource (hash-ref default-node-for-role role 'copper_rocks)))
  (define entries
    (if (pair? demand)
        demand
        (default-demand-entries role target)))
  (define triples
    (apply append
           (for/list ([entry entries])
             (demand->triples entry role target))))
  (define nodes
    (remove-duplicates
     (cons default-node (map caddr triples))))
  (define legs
    (for/list ([node nodes])
      (guard-spec
       (lambda (char)
         (define pick (pick-gather-node char triples default-node role))
         (and pick (item-code=? pick node)))
       (helper-forms (gather-specific #:resource node #:reserve reserve)))))
  (goal-spec 'adaptive-gather legs))
