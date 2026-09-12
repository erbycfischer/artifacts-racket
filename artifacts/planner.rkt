#lang racket

(require racket/date
         "world.rkt"
         "combat.rkt"
         "config.rkt"
         "dsl-forms.rkt"
         "http.rkt"
         "game-data.rkt")

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
         skill-level
         character-first-goal
         forms->action-specs
         goal-preferred-actions
         when-low-hp
         when-inventory-full
         when-on-content
         when-below-level
         when-has-item
         when-has-qty
         when-gold-above
         when-gold-below
         when-hp-above
         when-inventory-empty
         when-on-map
         when-bank-has
         when-vault-short
         item-quantity
         item-code=?
         safe-win-threshold
         bank-qty-lookup
         bank-item-quantity
         snapshot-bank-quantities
         bank-items-from-qty-table)

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

;; Parse Artifacts' ISO-8601 cooldown_expiration (e.g.
;; "2026-08-20T14:10:22.034Z") into unix seconds (UTC). Fractional seconds
;; and a missing trailing Z are tolerated. Returns #f when the string is not
;; an ISO timestamp so callers can fall back to the relative `cooldown` field.
(define (iso8601->seconds value)
  (define m
    (and (string? value)
         (regexp-match
          #px"^(\\d{4})-(\\d{2})-(\\d{2})[Tt](\\d{2}):(\\d{2}):(\\d{2})(?:\\.\\d+)?(?:Z|[+-]\\d{2}:?\\d{2})?$"
          value)))
  (cond
    [(not m) #f]
    [else
     (define y (string->number (list-ref m 1)))
     (define mo (string->number (list-ref m 2)))
     (define d (string->number (list-ref m 3)))
     (define h (string->number (list-ref m 4)))
     (define mi (string->number (list-ref m 5)))
     (define se (string->number (list-ref m 6)))
     (and y mo d h mi se
          ;; `#f` => treat the fields as UTC, matching the API's trailing Z.
          (find-seconds se mi h d mo y #f))]))

(define (parse-cooldown-expiration value now)
  (cond
    [(and (number? value) (> value 1000000000)) value] ; unix seconds
    [(and (number? value) (>= value 0)) (+ now value)] ; relative seconds mistaken as expiration
    [(string? value) (iso8601->seconds value)]
    [else #f]))

;; Absolute `cooldown_expiration` wins when present: the API's relative
;; `cooldown` field is often a stale last-action duration that never ticks
;; down between GETs, which previously left every character "busy" forever
;; once an ISO expiration string was ignored. Fall back to `cooldown` only
;; when no parseable expiration exists.
(define (cooldown-remaining char [now (current-seconds)])
  (define expiration (parse-cooldown-expiration
                      (character-field char 'cooldown_expiration #f)
                      now))
  (cond
    [expiration (max 0 (- expiration now))]
    [else
     (define remaining (character-field char 'cooldown 0))
     (if (and (number? remaining) (> remaining 0)) remaining 0)]))

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
         [(string? expiration-raw) (iso8601->seconds expiration-raw)]
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

;; True when the character's overall level is below `target`. `auto-level`
;; gates bank runs and role work behind this so a bot keeps grinding until it
;; reaches the goal level; a character with no level reads as "below target"
;; (level defaults to 1) so the goal never silently stops.
(define (when-below-level char target)
  (< (character-field char 'level 1) target))

;; Item codes arrive as symbols from helpers and strings from the API. Compare
;; them as strings so `(when-has-item char 'copper_ore)` matches `"copper_ore"`.
(define (item-code=? a b)
  (define (as-string v)
    (cond
      [(symbol? v) (symbol->string v)]
      [(string? v) v]
      [(false? v) #f]
      [else (format "~a" v)]))
  (define left (as-string a))
  (define right (as-string b))
  (and left right (equal? left right)))

;; Live bank qty for `code`. Returns a number when the vault answered (0 =
;; confirmed empty), or #f when the bank cannot be queried (no token / network
;; error) so callers can fall back to walking instead of treating "unknown" as
;; empty. Used by restock planning so confirmed-empty vaults do not capture the
;; preferred-action scan.
;;
;; Tests can bind `bank-qty-lookup` to a `(λ (code-string) qty)` override.
(define bank-qty-lookup (make-parameter #f))

(define (bank-item-quantity code #:config [config (current-config)])
  (define want (cond [(symbol? code) (symbol->string code)]
                     [(string? code) code]
                     [else #f]))
  (cond
    [(not want) 0]
    [(bank-qty-lookup) ((bank-qty-lookup) want)]
    [else
     (with-handlers ([exn:fail? (lambda (_) #f)])
       (define raw (get-bank-items #:item-code want #:config config))
       (define data (cond [(and (hash? raw) (hash-has-key? raw 'data)) (hash-ref raw 'data)]
                          [(list? raw) raw]
                          [else '()]))
       (for/sum ([it (if (list? data) data '())])
         (if (and (hash? it) (item-code=? (hash-ref it 'code #f) want))
             (hash-ref it 'quantity 0)
             0)))]))

;; One paged GET /my/bank/items for the whole vault. Restock/vault guards
;; used to call bank-item-quantity per code (dozens of requests per tick),
;; which trips the Artifacts data bucket (200/min, 2000/hour) after a long run.
(define (snapshot-bank-quantities #:config [config (current-config)])
  (define items
    (let loop ([page 1] [acc '()])
      (define raw (get-bank-items #:page page #:size 100 #:config config))
      (define data (cond
                     [(and (hash? raw) (hash-has-key? raw 'data)) (hash-ref raw 'data)]
                     [(list? raw) raw]
                     [else '()]))
      (define rows (if (list? data) data '()))
      (define pages (and (hash? raw) (hash-ref raw 'pages #f)))
      (define next (append acc rows))
      (cond
        [(or (null? rows)
             (and (number? pages) (>= page pages))
             (< (length rows) 100)
             (>= page 10))
         next]
        [else (loop (add1 page) next)])))
  (define table (make-hash))
  (for ([it items] #:when (hash? it))
    (define code (hash-ref it 'code #f))
    (define qty (hash-ref it 'quantity 0))
    (when (and code (number? qty) (positive? qty))
      (define key (if (symbol? code) (symbol->string code) (format "~a" code)))
      (hash-set! table key (+ (hash-ref table key 0) qty))))
  table)

(define (bank-items-from-qty-table table)
  (for/list ([(code qty) (in-hash table)])
    (hasheq 'code code 'quantity qty)))

;; Total quantity of `code` across every inventory slot. Missing/empty bags
;; read as 0 so quantity guards stay false rather than erroring.
(define (item-quantity char code)
  (for/sum ([slot (inventory-items char)])
    (if (and (hash? slot)
             (item-code=? (hash-ref slot 'code #f) code))
        (hash-ref slot 'quantity 0)
        0)))

;; True when inventory holds at least one stack of `code` with a positive qty.
(define (when-has-item char code)
  (> (item-quantity char code) 0))

;; True when inventory holds at least `n` of `code` (summed across stacks).
(define (when-has-qty char code n)
  (>= (item-quantity char code) n))

;; True when carried gold is strictly above `amount`.
(define (when-gold-above char amount)
  (> (character-field char 'gold 0) amount))

;; True when carried gold is strictly below `amount`.
(define (when-gold-below char amount)
  (< (character-field char 'gold 0) amount))

;; Inverse of when-low-hp: true when hp is strictly above `ratio` of max.
(define (when-hp-above char ratio)
  (define max-hp (character-field char 'max_hp 0))
  (and (not (zero? max-hp))
       (> (hp-ratio char) ratio)))

;; True when used inventory slots are at or below `reserve` (default 0 = empty).
(define (when-inventory-empty char [reserve 0])
  (<= (inventory-used char) reserve))

;; True when the character's map_id matches `map-id` (number or string).
(define (when-on-map char map-id)
  (equal? (character-field char 'map_id) map-id))

;; Optional bank-contents snapshot on the character hash (`bank_items`, `bank`,
;; or `vault` as a list of `{code, quantity}` slots). The live character payload
;; does not include vault stacks — only `bank_max_items` / `bank_items_used`
;; for slot capacity — so this is usually #f and callers fall through to
;; `bank-item-quantity` (account GET /bank/items, or the `bank-qty-lookup`
;; test parameter). There is no dual-account vault; one token, one bank.
(define (character-bank-snapshot-items char)
  (define raw (or (character-field char 'bank_items #f)
                  (character-field char 'bank #f)
                  (character-field char 'vault #f)))
  (cond
    [(list? raw) raw]
    [(and (hash? raw) (list? (hash-ref raw 'data #f))) (hash-ref raw 'data)]
    [else #f]))

(define (bank-quantity-for char code)
  (define snapshot (character-bank-snapshot-items char))
  (if snapshot
      (for/sum ([it snapshot])
        (if (and (hash? it) (item-code=? (hash-ref it 'code #f) code))
            (hash-ref it 'quantity 0)
            0))
      (bank-item-quantity code)))

;; True when the shared account bank appears to hold a positive stack of `code`.
;; Unknown (#f from a failed bank read, no snapshot) is not treated as "has".
(define (when-bank-has char code)
  (define qty (bank-quantity-for char code))
  (and (number? qty) (> qty 0)))

;; True when the bank qty of `code` is below `threshold` (default 1 = empty).
;; Unknown (#f) counts as short so mailbox gatherers keep filling instead of
;; idling on a failed vault read — same spirit as restock treating unknown as
;; "not confirmed empty".
(define (when-vault-short char code [threshold 1])
  (define qty (bank-quantity-for char code))
  (or (not (number? qty)) (< qty threshold)))

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
    [(cooking) (character-field char 'cooking_level 1)]
    [(weaponcrafting) (character-field char 'weaponcrafting_level 1)]
    [(gearcrafting) (character-field char 'gearcrafting_level 1)]
    [(jewelrycrafting) (character-field char 'jewelrycrafting_level 1)]
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

;; When win-probabilities differ by less than this, fall through to score,
;; then monster level. Keeps a copper-dagger fighter on chicken/yellow instead
;; of max-level red_slime when the air matchup is only marginally different.
(define win-prob-tie-epsilon 0.05)

(define (matchup-win-prob entry)
  (define match (car entry))
  (define prob (hash-ref match 'win-probability #f))
  (define score (hash-ref match 'score #f))
  (cond [(number? prob) prob]
        [(number? score) score]
        [else 0]))

(define (matchup-desirability entry)
  (define score (hash-ref (car entry) 'score #f))
  (if (number? score) score (matchup-win-prob entry)))

(define (monster-level-of entry)
  (hash-ref (cdr entry) 'level 0))

;; Prefer higher win-prob; within epsilon, higher score; then higher level.
(define (prefer-matchup-entry? a b)
  (define pa (matchup-win-prob a))
  (define pb (matchup-win-prob b))
  (cond
    [(> (abs (- pa pb)) win-prob-tie-epsilon) (> pa pb)]
    [(not (= (matchup-desirability a) (matchup-desirability b)))
     (> (matchup-desirability a) (matchup-desirability b))]
    [else (> (monster-level-of a) (monster-level-of b))]))

;; Score reachable monsters with matchup-score. Prefer monsters within one
;; level above the character, but never prune to an empty board. Among
;; candidates with win-probability ≥ safe-win-threshold (or everyone if none
;; clear that bar), rank by win-probability (then score); level only tie-breaks
;; when probs are within win-prob-tie-epsilon. Max-level bias previously sent
;; an air-dagger lv6 at red_slime / green_slime over chicken / yellow_slime.
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
     (define best
       (for/fold ([best (car pool)])
                 ([entry (in-list (cdr pool))])
         (if (prefer-matchup-entry? entry best) entry best)))
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

;; Nearest map tile whose content type matches `type`. Optional `code` pins the
;; content code (e.g. workshop skill "mining") so craft/recycle do not walk to
;; the geographically nearest cooking tile and stall forever.
(define (nearest-typed-content world char type [code #f])
  (define from (character-map char))
  (define want (cond [(symbol? code) (symbol->string code)]
                     [(string? code) code]
                     [else #f]))
  (define nodes
    (filter (lambda (map)
              (define interactions (hash-ref map 'interactions #f))
              (define content (and interactions (hash-ref interactions 'content #f)))
              (and (hash? content)
                   (equal? (hash-ref content 'type #f) type)
                   (or (not want)
                       (equal? (hash-ref content 'code #f) want))))
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
  ;; Walk toward a nearby active event, but only when we are not already on
  ;; its tile. Distance 0 used to keep posting move and 490 forever, which
  ;; starved gather/fight/craft preferred goals for every character.
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
              (> distance 0)
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
  ;; Flatten preferred actions from EVERY character form. First-form-only used
  ;; to let a dormant-looking goal (e.g. outfit-from-bank whose only live leg is
  ;; a no-op auto-gear) starve later goals like grind/fight forever.
  (apply append
         (for/list ([form (character-spec-forms spec)])
           (cond
             [(guard-spec? form)
              (if ((guard-spec-predicate form) char)
                  (forms->action-specs (guard-spec-forms form) char)
                  '())]
             [(goal-spec? form)
              (forms->action-specs (goal-spec-actions form) char)]
             [(action-spec? form) (list form)]
             [else '()]))))

(define (first-payload spec [default #hasheq()])
  (define payload (action-spec-payload spec))
  (if (pair? payload) (car payload) default))

(define (plan-craft char world [craft #f])
  ;; Never POST an empty craft payload — the API 422s. Without a concrete
  ;; recipe hash we only pathfind to the workshop (or no-op if already there)
  ;; so role-default crafters wait for a forge-loop / craft-if-materials goal.
  ;; When a code is known, route to that product's workshop skill (mining /
  ;; weaponcrafting / …) — the nearest untyped workshop is usually cooking.
  (define code (and craft (hash? craft) (hash-ref craft 'code #f)))
  (define skill (and code (craft-workshop-skill code)))
  (define skill-str (cond [(symbol? skill) (symbol->string skill)]
                          [(string? skill) skill]
                          [else #f]))
  (cond
    [(and craft code (on-content? char "workshop" skill-str))
     (planned-action 'craft
                     craft
                     (format "Craft ~a." code)
                     72)]
    [(and craft code)
     (define workshop (nearest-typed-content world char "workshop" skill-str))
     (and workshop
          (move-to workshop
                   (format "Travel to ~a workshop." (or skill-str "any"))
                   #:priority 64))]
    [(on-content? char "workshop") #f]
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
  (define (fire mode)
    (case mode
      [(new) (planned-action 'task-new '() "Accept a new task." 62)]
      [(complete) (planned-action 'task-complete '() "Complete the active task." 74)]
      [(cancel) (planned-action 'task-cancel '() "Cancel the active task." 58)]
      [(exchange) (planned-action 'task-exchange '() "Exchange task rewards." 60)]
      [else #f]))
  (cond
    [on-task-tile? (fire mode)]
    [else
     (define node (or (nearest-typed-content world char "tasks_master")
                      (nearest-typed-content world char "npc")))
     (and node (move-to node "Travel to task master." #:priority 52))]))

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

;; Walk to `type` if needed, otherwise fire `name` with `payload`. Used for
;; bank gold, GE orders, and the cross-account dispatch helpers that only
;; make sense while standing on a specific tile.
(define (plan-on-content char world type name payload reason
                         #:priority [priority 88])
  (cond
    [(on-content? char type)
     (planned-action name payload reason priority)]
    [else
     (define node (nearest-typed-content world char type))
     (and node (move-to node (format "Travel to ~a." type) #:priority (- priority 3)))]))

;; Pin gathering to a specific resource code (from gather-specific / gather-until)
;; instead of the role's highest-level node. Still banks when the bag is tight.
(define (plan-gather-named char world resources code #:reserve [reserve 1])
  (cond
    [(inventory-full? char #:reserve reserve)
     (plan-bank-trip char world)]
    [else
     (define want (if (symbol? code) (symbol->string code) code))
     (define resource
       (or (for/or ([r resources])
             (and (hash? r) (item-code=? (hash-ref r 'code #f) want) r))
           (and want (hasheq 'code want))))
     (cond
       [(on-content? char "resource" (hash-ref resource 'code #f))
        (planned-action 'gather '() (format "Gather ~a." (hash-ref resource 'code)) 70)]
       [else
        (define target
          (nearest-content-map world (character-map char) "resource"
                               (hash-ref resource 'code #f)))
        (and target
             (move-to target
                      (format "Move to ~a." (hash-ref resource 'code))
                      #:priority 65))])]))

;; Pin fighting to a specific monster code (from hunt) instead of the safest
;; matchup. Walks to that monster's tile when not already standing on it.
(define (plan-combat-named char world code)
  (define want (if (symbol? code) (symbol->string code) code))
  (cond
    [(on-content? char "monster" want)
     (planned-action 'fight '() (format "Fight ~a." want) 70)]
    [else
     (define target (nearest-content-map world (character-map char) "monster" want))
     (and target
          (move-to target (format "Move to ~a." want) #:priority 65))]))

(define (payload-code payload)
  (cond
    [(and (hash? payload) (hash-ref payload 'code #f))]
    [(symbol? payload) (symbol->string payload)]
    [(string? payload) payload]
    [else #f]))

(define (plan-move char world payload)
  (cond
    [(and (hash? payload) (hash-ref payload 'type #f))
     (define type (hash-ref payload 'type))
     (if (on-content? char type)
         #f
         (let ([node (nearest-typed-content world char type)])
           (and node (move-to node (format "Travel to ~a." type) #:priority 55))))]
    [(and (hash? payload)
          (or (hash-has-key? payload 'map_id)
              (and (hash-has-key? payload 'x) (hash-has-key? payload 'y))))
     (planned-action 'move payload "Move per goal." 55)]
    [else #f]))

(define (plan-auto-gear char)
  ;; Only plan when inventory holds something suggest-equipment recognizes.
  ;; Returning a no-op auto-gear action used to monopolize preferred goals
  ;; (fighter never reached fight) while printing "nothing to equip" forever.
  (define suggestion (suggest-equipment char #hasheq()))
  (and suggestion
       (planned-action 'equip
                       (for/list ([(slot code) (in-hash suggestion)])
                         (hasheq 'slot (if (symbol? slot) (symbol->string slot) slot)
                                 'code (if (symbol? code) (symbol->string code) code)))
                       "Equip best inventory gear."
                       60)))

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
    [(fight)
     (define code (payload-code payload))
     (if code
         (plan-combat-named char world code)
         (plan-combat char world monsters))]
    [(gather)
     (define code (payload-code payload))
     (if code
         (plan-gather-named char world resources code #:reserve 1)
         (let ([skill (or (role-skill role) 'mining)])
           (best-gather-plan char world resources skill #:reserve 1)))]
    [(bank-deposit-item) (plan-bank-trip char world)]
    [(bank-withdraw-item)
     (plan-on-content char world "bank" 'bank-withdraw-item payload "Withdraw bank items.")]
    [(bank-deposit-gold)
     (plan-on-content char world "bank" 'bank-deposit-gold
                      (first-payload spec #f) "Deposit gold.")]
    [(deposit-gold-surplus)
     (plan-on-content char world "bank" 'deposit-gold-surplus payload
                      "Deposit surplus gold." #:priority 87)]
    [(bank-withdraw-gold)
     (plan-on-content char world "bank" 'bank-withdraw-gold
                      (first-payload spec #f) "Withdraw gold.")]
    [(top-up-gold)
     (plan-on-content char world "bank" 'top-up-gold payload
                      "Top up gold from vault." #:priority 85)]
    [(bank-buy-expansion)
     (plan-on-content char world "bank" 'bank-buy-expansion '() "Buy bank expansion."
                      #:priority 86)]
    [(deposit-surplus)
     (plan-on-content char world "bank" name payload (format "Run ~a." name)
                      #:priority 86)]
    [(restock)
     ;; Skip only when the vault is *confirmed* empty. Unknown (#f from a failed
     ;; bank read) still paths to the bank so offline/tests keep routing. A
     ;; confirmed-empty restock must not monopolize preferred actions forever.
     (define code (and (hash? payload) (hash-ref payload 'code #f)))
     (define want (and (hash? payload) (hash-ref payload 'qty 0)))
     (define have (if code (item-quantity char code) 0))
     (define bank-have (if code (bank-item-quantity code) #f))
     (cond
       [(or (not code) (not (number? want)) (<= want 0)) #f]
       [(>= have want) #f]
       [(and (number? bank-have) (<= bank-have 0)) #f]
       [(on-content? char "bank")
        (planned-action 'restock payload (format "Restock ~a." code) 86)]
       [else
        (define node (nearest-typed-content world char "bank"))
        (and node (move-to node "Travel to bank." #:priority 83))])]
    [(craft) (plan-craft char world (if (hash? payload) payload #f))]
    [(recycle) (plan-recycle char world (if (hash? payload) payload #f))]
    [(task-new) (plan-task char world 'new)]
    [(task-complete) (plan-task char world 'complete)]
    [(task-cancel) (plan-task char world 'cancel)]
    [(task-exchange) (plan-task char world 'exchange)]
    [(task-trade)
     (define on-task-tile?
       (or (on-content? char "tasks_master") (on-content? char "npc")))
     (cond
       [on-task-tile?
        (planned-action 'task-trade payload "Trade task items." 62)]
       [else
        (define node (or (nearest-typed-content world char "tasks_master")
                         (nearest-typed-content world char "npc")))
        (and node (move-to node "Travel to task master." #:priority 52))])]
    [(npc-buy) (plan-npc char world 'buy (if (hash? payload) payload #f))]
    [(npc-sell) (plan-npc char world 'sell (if (hash? payload) payload #f))]
    [(grand-exchange-orders) (plan-trade char world)]
    [(grand-exchange-buy grand-exchange-cancel grand-exchange-fill
      grand-exchange-create-sell-order grand-exchange-create-buy-order
      snap-up market-tick)
     (plan-on-content char world "grand_exchange" name payload
                      (format "Run ~a at the Grand Exchange." name)
                      #:priority 72)]
    [(active-events)
     (or (plan-event-intercept char world events)
         (planned-action 'active-events '() "Check active events." 40))]
    [(use)
     ;; Skip when the stack is missing — a doomed use would starve later forms.
     (define code (payload-code payload))
     (and code
          (when-has-item char code)
          (planned-action 'use payload "Use item." 88))]
    [(move) (plan-move char world payload)]
    [(transition) (or (plan-transition char world)
                      (let ([node (nearest-typed-content world char "transition")])
                        (and node (move-to node "Travel to transition." #:priority 57))))]
    ;; equip / unequip need no tile; the goal's guard already vetted the slot
    ;; and item, so we forward the action payload straight to dispatch.
    [(equip unequip)
     (planned-action name (action-spec-payload spec)
                     (format "Manage ~a." name) 60)]
    [(auto-gear) (plan-auto-gear char)]
    [(give-gold give-item delete-item change-skin)
     (planned-action name payload (format "Perform ~a." name) 70)]
    [(claim-item)
     (planned-action 'claim-item (first-payload spec 0) "Claim item." 70)]
    [(raids)
     (planned-action 'raids '() "Check raids." 40)]
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
    ;; Critically hurt with no preferred body → rest. When the bot supplies
    ;; preferred forms, they run in author order (restock/heal/rest/fight is
    ;; bot policy, not language policy).
    [(and (< (hp-ratio char) 0.45) (null? preferred))
     (planned-action 'rest '() "Recover HP before the next fight." 100)]
    [(inventory-full? char #:reserve 2)
     (plan-bank-trip char world)]
    ;; Preferred goals (gather/fight/craft/trade) win over event tourism so a
    ;; nearby festival NPC cannot starve the economy loop. Opportunistic
    ;; intercept only runs when the character has nothing else to do.
    [(pair? preferred)
     (or (plan-from-preferred char world preferred
                              #:role role
                              #:monsters monsters
                              #:resources resources
                              #:events events)
         (plan-event-intercept char world events)
         (plan-role-default char world role
                            #:monsters monsters
                            #:resources resources))]
    [else
     (or (plan-event-intercept char world events)
         (plan-role-default char world role
                            #:monsters monsters
                            #:resources resources))]))
