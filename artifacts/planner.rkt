#lang racket

(require "world.rkt"
         "combat.rkt"
         "config.rkt"
         "dsl-forms.rkt")

(provide (struct-out planned-action)
         character-field
         inventory-items
         inventory-used
         inventory-full?
         hp-ratio
         cooldown-ready?
         cooldown-remaining
         cooldown-from-response
         update-character-cooldown
         content-at-character
         on-content?
         nearest-typed-content
         plan-character
         plan-preferred-action
         best-safe-monster
         best-gather-resource
         best-gather-plan
         role-skill
         character-first-goal
         forms->action-specs
         goal-preferred-actions
         when-low-hp
         when-inventory-full
         when-on-content
         safe-win-threshold)

(struct planned-action (name payload reason priority) #:transparent)

(define (character-field char key [default #f])
  (if (hash? char) (hash-ref char key default) default))

(define (inventory-items char)
  (define inv (character-field char 'inventory '()))
  (if (list? inv) inv '()))

(define (inventory-used char)
  (for/sum ([slot (inventory-items char)])
    (if (hash? slot) (hash-ref slot 'quantity 0) 0)))

(define (inventory-full? char #:reserve [reserve 1])
  (define max-items (character-field char 'inventory_max_items 0))
  (>= (inventory-used char) (max 0 (- max-items reserve))))

(define (hp-ratio char)
  (define hp (character-field char 'hp 0))
  (define max-hp (character-field char 'max_hp 1))
  (if (zero? max-hp) 0 (/ hp max-hp)))

(define (parse-cooldown-expiration value now)
  (cond
    [(and (number? value) (> value 1000000000)) value] ; unix seconds
    [(and (number? value) (>= value 0)) (+ now value)] ; relative seconds mistaken as expiration
    [(string? value)
     ;; Accept ISO-ish "YYYY-MM-DDTHH:MM:SSZ" by falling back to remaining field only.
     #f]
    [else #f]))

(define (cooldown-remaining char [now (current-seconds)])
  (define remaining (character-field char 'cooldown 0))
  (define expiration (parse-cooldown-expiration
                      (character-field char 'cooldown_expiration #f)
                      now))
  (define from-remaining
    (if (and (number? remaining) (> remaining 0)) remaining 0))
  (define from-expiration
    (if expiration (max 0 (- expiration now)) 0))
  (max from-remaining from-expiration))

(define (cooldown-ready? char [now (current-seconds)])
  (<= (cooldown-remaining char now) 0))

;; Extract the cooldown seconds an action response reports. Artifacts echoes
;; both an absolute `cooldown_expiration` (ISO timestamp) and a relative
;; `cooldown` (seconds) inside `data`. We trust `cooldown` when present because
;; it is already a number; callers that need an absolute clock can read
;; `cooldown_expiration` directly. Missing/empty fields yield 0 so a response
;; with no cooldown reads as "ready" rather than crashing.
(define (response-data-value response key)
  (define data (cond
                [(and (hash? response) (hash-has-key? response 'data)) (hash-ref response 'data)]
                [(hash? response) response]
                [else #f]))
  (if (hash? data) (hash-ref data key #f) #f))

(define (cooldown-from-response response)
  (define raw (response-data-value response 'cooldown))
  (cond
    [(and (number? raw) (> raw 0)) raw]
    [(and (number? raw) (<= raw 0)) 0]
    [else 0]))

;; Return an updated character hash whose `cooldown_expiration` is set to the
;; absolute time the action's cooldown clears, derived from the response. This
;; lets `cooldown-remaining` (which already parses `cooldown_expiration`) and
;; the scheduler's `cooldown-jobs-from-characters` gate the next tick on the
;; real live cooldown instead of the snapshot's stale `cooldown`. When the
;; response carries no usable cooldown we leave the character untouched (ready).
(define (update-character-cooldown char response [now (current-seconds)])
  (cond
    [(not (hash? char)) char]
    [(not response) char]
    [else
     (define expiration-raw (response-data-value response 'cooldown_expiration))
     (define expiration
       (cond
         [(and (number? expiration-raw) (> expiration-raw 1000000000)) expiration-raw]
         [(and (number? expiration-raw) (>= expiration-raw 0))
          (+ now expiration-raw)] ; relative seconds mislabeled as expiration
         [else #f]))
     (define seconds (cooldown-from-response response))
     (define absolute
       (cond
         [expiration expiration]
         [(> seconds 0) (+ now seconds)]
         [else #f]))
     (if absolute
         (hash-set char 'cooldown_expiration absolute)
         char)]))

(define (content-at-character char)
  (define interactions (character-field char 'interactions #f))
  (cond
    [(hash? interactions) (hash-ref interactions 'content #f)]
    [else #f]))

(define (on-content? char type [code #f])
  (define content (content-at-character char))
  (and (hash? content)
       (equal? (hash-ref content 'type #f) type)
       (or (not code) (equal? (hash-ref content 'code #f) code))))

;; Reactive goal conditions. Each answers true against a live character hash
;; so a goal body can stay dormant until the world state warrants action.

;; True when hp has dropped to at or below `ratio` of max (0..1). A character
;; with no known max_hp can't be assessed, so it reads as "not low" rather than
;; tripping the condition on a divide-by-zero ratio.
(define (when-low-hp char ratio)
  (define max-hp (character-field char 'max_hp 0))
  (and (not (zero? max-hp))
       (<= (hp-ratio char) ratio)))

;; True when inventory is at/over capacity minus `reserve` free slots.
(define (when-inventory-full char #:reserve [reserve 1])
  (inventory-full? char #:reserve reserve))

;; True when the character stands on a tile whose content matches type/code.
(define (when-on-content char type [code #f])
  (on-content? char type code))

(define (character-map char)
  (hasheq 'map_id (character-field char 'map_id)
          'layer (character-field char 'layer)
          'x (character-field char 'x)
          'y (character-field char 'y)))

(define (role-skill role)
  (case role
    [(mining) 'mining]
    [(woodcutting) 'woodcutting]
    [(fishing) 'fishing]
    [(alchemy) 'alchemy]
    [else #f]))

(define (skill-level char skill)
  (case skill
    [(mining) (character-field char 'mining_level 1)]
    [(woodcutting) (character-field char 'woodcutting_level 1)]
    [(fishing) (character-field char 'fishing_level 1)]
    [(alchemy) (character-field char 'alchemy_level 1)]
    [else 1]))

(define (depositable-items char)
  (for/list ([slot (inventory-items char)]
             #:when (and (hash? slot)
                         (hash-ref slot 'code #f)
                         (positive? (hash-ref slot 'quantity 0))))
    (hasheq 'code (hash-ref slot 'code)
            'quantity (hash-ref slot 'quantity))))

(define (move-to map reason #:priority [priority 50])
  (planned-action 'move
                  (hasheq 'map_id (hash-ref map 'map_id))
                  reason
                  priority))

;; Below this win-probability estimate a fight is treated as unwinnable and
;; skipped unless it's the only candidate on the board.
(define safe-win-threshold 0.5)

;; Score every reachable monster with matchup-score, then pick the safest.
;; For pruning we prefer monsters within one level above the character, but the
;; level window must never be the thing that leaves the bot with nothing to do:
;; if no monster survives that window we fall back to the full board, and only
;; return #f once we genuinely have no candidate at all. Among what's left, we
;; take the safest by win-probability; when every candidate is hard we still
;; pick the least-bad one rather than bailing out.
(define (best-safe-monster char monsters #:config [config (current-config)])
  (define level (character-field char 'level 1))
  (define in-window
    (for/list ([monster monsters]
               #:when (and (hash? monster)
                           (<= (hash-ref monster 'level 999) (+ level 1))))
      (define match (matchup-score char monster #:config config))
      (cons match monster)))
  (define scored (if (pair? in-window) in-window
                     (for/list ([monster monsters]
                                #:when (hash? monster))
                       (define match (matchup-score char monster #:config config))
                       (cons match monster))))
  (cond
    [(null? scored) #f]
    [else
     (define safe
       (filter (lambda (entry)
                 (define prob (hash-ref (car entry) 'win-probability #f))
                 (or (not (number? prob))
                     (>= prob safe-win-threshold)))
               scored))
     (define pool (if (pair? safe) safe scored))
     (define best (argmax (lambda (entry) (hash-ref (car entry) 'score 0)) pool))
     (cdr best)]))

(define (resource-matches-skill? resource skill)
  (define skill-value (hash-ref resource 'skill #f))
  (or (equal? skill-value skill)
      (equal? skill-value (symbol->string skill))))

(define (best-gather-resource char resources skill)
  (define level (skill-level char skill))
  (define candidates
    (for/list ([resource resources]
               #:when (and (hash? resource)
                           (resource-matches-skill? resource skill)
                           (<= (hash-ref resource 'level 999) level)))
      resource))
  (and (pair? candidates)
       (argmax (lambda (resource) (hash-ref resource 'level 0)) candidates)))

(define (nearest-typed-content world char type)
  (define from (character-map char))
  (define nodes
    (filter (lambda (map)
              (define interactions (hash-ref map 'interactions #f))
              (define content (and interactions (hash-ref interactions 'content #f)))
              (and (hash? content) (equal? (hash-ref content 'type #f) type)))
            (world-index-maps world)))
  (and (pair? nodes)
       (argmin (lambda (map)
                 (+ (abs (- (hash-ref from 'x 0) (hash-ref map 'x 0)))
                    (abs (- (hash-ref from 'y 0) (hash-ref map 'y 0)))))
               nodes)))

(define (plan-bank-trip char world)
  (cond
    [(on-content? char "bank")
     (define items (depositable-items char))
     (and (pair? items)
          (planned-action 'bank-deposit-item items "Deposit loot before continuing." 90))]
    [else
     (define bank (nearest-typed-content world char "bank"))
     (and bank (move-to bank "Travel to bank; inventory is tight." #:priority 85))]))

(define (plan-combat char world monsters)
  (define monster (best-safe-monster char monsters))
  (cond
    [(not monster) #f]
    [(on-content? char "monster" (hash-ref monster 'code #f))
     (planned-action 'fight '() (format "Fight ~a for XP and loot." (hash-ref monster 'code)) 70)]
    [else
     (define target
       (nearest-content-map world (character-map char) "monster" (hash-ref monster 'code)))
     (and target
          (move-to target
                   (format "Move to ~a (level ~a)."
                           (hash-ref monster 'code)
                           (hash-ref monster 'level))
                   #:priority 65))]))

(define (plan-gather char world resources skill)
  (define resource (best-gather-resource char resources skill))
  (cond
    [(not resource) #f]
    [(on-content? char "resource" (hash-ref resource 'code #f))
     (planned-action 'gather '() (format "Gather ~a." (hash-ref resource 'code)) 70)]
    [else
     (define target
       (nearest-content-map world (character-map char) "resource" (hash-ref resource 'code)))
     (and target
          (move-to target
                   (format "Move to ~a for ~a."
                           (hash-ref resource 'code)
                           skill)
                   #:priority 65))]))

;; Inventory-aware gathering. Before committing to a gather we check whether
;; the bag is close to capacity: a character with only `reserve` slots left
;; can't hold another haul, so a bank run wins over another swing of the pick.
;; Otherwise we fall through to the plain plan-gather behavior (gather when
;; already on the node, move-to-resource when not). `best-gather-plan` is what
;; the role dispatcher calls, so the near-full branch is live for gatherers.
(define (best-gather-plan char world resources skill #:reserve [reserve 1])
  (cond
    [(inventory-full? char #:reserve reserve)
     (plan-bank-trip char world)]
    [else (plan-gather char world resources skill)]))

(define (plan-trade char world)
  (cond
    [(on-content? char "grand_exchange")
     (planned-action 'grand-exchange-orders
                     '()
                     "Scan Grand Exchange spreads while at the market."
                     55)]
    [else
     (define ge (nearest-typed-content world char "grand_exchange"))
     (and ge (move-to ge "Travel to Grand Exchange for trading." #:priority 50))]))

(define (plan-event-intercept char world events)
  (define active (if (list? events) events '()))
  (define from (character-map char))
  (define scored
    (for/list ([event active]
               #:when (hash? event))
      (define map (hash-ref event 'map #f))
      (and (hash? map)
           (cons (+ (abs (- (hash-ref from 'x 0) (hash-ref map 'x 0)))
                    (abs (- (hash-ref from 'y 0) (hash-ref map 'y 0))))
                 map))))
  (define valid (filter values scored))
  (and (pair? valid)
       (let* ([best (argmin car valid)]
              [distance (car best)]
              [map (cdr best)])
         (and (<= distance 12)
              (move-to map "Intercept nearby active event." #:priority 80)))))

(define (character-first-goal spec [char #f])
  (for/or ([form (expand-guards (character-spec-forms spec) char)]
           #:when (goal-spec? form))
    form))

;; Flatten a list of goal/action forms into the bare action-specs the planner
;; should prefer, resolving any nested guards against the live character.
(define (forms->action-specs forms [char #f])
  (apply append
         (for/list ([form (expand-guards forms char)])
           (cond
             [(goal-spec? form) (forms->action-specs (goal-spec-actions form) char)]
             [(action-spec? form) (list form)]
             [else '()]))))

(define (goal-preferred-actions spec [char #f])
  ;; The character's preferred actions come from the first goal or guard body.
  ;; A guard contributes its whole body only when its condition holds; a goal
  ;; contributes its actions. Sibling actions inside that body all count, and
  ;; guards nested deeper (e.g. (when-low-hp 0.5 (rest))) are resolved here.
  (define result
    (for/or ([form (character-spec-forms spec)])
      (cond
        [(guard-spec? form)
         (and ((guard-spec-predicate form) char)
              (forms->action-specs (guard-spec-forms form) char))]
        [(goal-spec? form)
         (forms->action-specs (goal-spec-actions form) char)]
        [else #f])))
  (if result result '()))

(define (first-payload spec [default #hasheq()])
  (define payload (action-spec-payload spec))
  (if (pair? payload) (car payload) default))

(define (plan-craft char world [craft #f])
  (cond
    [(and craft (hash? craft) (on-content? char "workshop"))
     (planned-action 'craft
                     craft
                     (format "Craft ~a." (hash-ref craft 'code "item"))
                     72)]
    [(on-content? char "workshop")
     (planned-action 'craft #hasheq() "Craft at the workshop." 70)]
    [else
     (define workshop (nearest-typed-content world char "workshop"))
     (and workshop (move-to workshop "Travel to workshop." #:priority 64))]))

(define (plan-recycle char world [item #f])
  (cond
    [(and item (hash? item) (on-content? char "workshop"))
     (planned-action 'recycle item (format "Recycle ~a." (hash-ref item 'code "item")) 68)]
    [(on-content? char "workshop")
     (planned-action 'recycle #hasheq() "Recycle at the workshop." 66)]
    [else
     (define workshop (nearest-typed-content world char "workshop"))
     (and workshop (move-to workshop "Travel to recycle." #:priority 63))]))

(define (plan-task char world mode)
  (define on-task-tile?
    (or (on-content? char "tasks_master")
        (on-content? char "npc")))
  (case mode
    [(new)
     (and on-task-tile?
          (planned-action 'task-new '() "Accept a new task." 62))]
    [(complete)
     (and on-task-tile?
          (planned-action 'task-complete '() "Complete the active task." 74))]
    [(cancel)
     (and on-task-tile?
          (planned-action 'task-cancel '() "Cancel the active task." 58))]
    [(exchange)
     (and on-task-tile?
          (planned-action 'task-exchange '() "Exchange task rewards." 60))]
    [else #f]))

(define (plan-npc char world mode [item #f])
  (cond
    [(and item (hash? item) (on-content? char "npc"))
     (case mode
       [(buy) (planned-action 'npc-buy item (format "Buy ~a." (hash-ref item 'code "item")) 61)]
       [(sell) (planned-action 'npc-sell item (format "Sell ~a." (hash-ref item 'code "item")) 61)]
       [else #f])]
    [(on-content? char "npc")
     (case mode
       [(buy) (planned-action 'npc-buy #hasheq() "Buy from NPC." 55)]
       [(sell) (planned-action 'npc-sell #hasheq() "Sell to NPC." 55)]
       [else #f])]
    [else
     (define shop (nearest-typed-content world char "npc"))
     (and shop (move-to shop "Travel to NPC shop." #:priority 52))]))

(define (plan-transition char world)
  (and (on-content? char "transition")
       (planned-action 'transition '() "Use map transition." 58)))

(define (plan-preferred-action char world spec
                               #:role role
                               #:monsters [monsters '()]
                               #:resources [resources '()]
                               #:events [events '()])
  (define name (action-spec-name spec))
  (define payload (first-payload spec))
  (case name
    [(rest)
     (and (< (hp-ratio char) 0.9)
          (planned-action 'rest '() "Rest per goal routine." 96))]
    [(fight) (plan-combat char world monsters)]
    [(gather)
     (define skill (or (role-skill role) 'mining))
     (best-gather-plan char world resources skill #:reserve 1)]
    [(bank-deposit-item) (plan-bank-trip char world)]
    [(bank-withdraw-item)
     (and (on-content? char "bank")
          (planned-action 'bank-withdraw-item payload "Withdraw bank items." 88))]
    [(craft) (plan-craft char world (if (hash? payload) payload #f))]
    [(recycle) (plan-recycle char world (if (hash? payload) payload #f))]
    [(task-new) (plan-task char world 'new)]
    [(task-complete) (plan-task char world 'complete)]
    [(task-cancel) (plan-task char world 'cancel)]
    [(task-exchange) (plan-task char world 'exchange)]
    [(npc-buy) (plan-npc char world 'buy (if (hash? payload) payload #f))]
    [(npc-sell) (plan-npc char world 'sell (if (hash? payload) payload #f))]
    [(grand-exchange-orders) (plan-trade char world)]
    [(active-events) (plan-event-intercept char world events)]
    [(transition) (or (plan-transition char world)
                      (let ([node (nearest-typed-content world char "transition")])
                        (and node (move-to node "Travel to transition." #:priority 57))))]
    [(raids) #f]
    [else #f]))

(define (plan-from-preferred char world preferred
                             #:role role
                             #:monsters monsters
                             #:resources resources
                             #:events events)
  (for/or ([spec preferred])
    (plan-preferred-action char world spec
                           #:role role
                           #:monsters monsters
                           #:resources resources
                           #:events events)))

(define (plan-role-default char world role
                           #:monsters monsters
                           #:resources resources)
  (case role
    [(combat fighter)
     (or (plan-combat char world monsters)
         (plan-bank-trip char world))]
    [(mining woodcutting fishing alchemy gatherer)
     (define skill (or (role-skill role) 'mining))
     (or (best-gather-plan char world resources skill #:reserve 1)
         (plan-bank-trip char world))]
    [(crafter crafting)
     (or (plan-craft char world)
         (plan-recycle char world)
         (plan-bank-trip char world))]
    [(tasker tasks)
     (or (plan-task char world 'complete)
         (plan-task char world 'new)
         (plan-bank-trip char world))]
    [(trader market)
     (or (plan-trade char world)
         (plan-npc char world 'sell)
         (plan-bank-trip char world))]
    [else
     (or (plan-combat char world monsters)
         (plan-gather char world resources 'mining))]))

(define (plan-character char
                        world
                        #:role role
                        #:monsters [monsters '()]
                        #:resources [resources '()]
                        #:events [events '()]
                        #:preferred [preferred '()])
  (cond
    [(not (cooldown-ready? char))
     #f]
    [(< (hp-ratio char) 0.45)
     (planned-action 'rest '() "Recover HP before the next fight." 100)]
    [(inventory-full? char #:reserve 2)
     (plan-bank-trip char world)]
    [(plan-event-intercept char world events)]
    [(pair? preferred)
     (or (plan-from-preferred char world preferred
                              #:role role
                              #:monsters monsters
                              #:resources resources
                              #:events events)
         (plan-role-default char world role
                            #:monsters monsters
                            #:resources resources))]
    [else
     (plan-role-default char world role
                        #:monsters monsters
                        #:resources resources)]))
