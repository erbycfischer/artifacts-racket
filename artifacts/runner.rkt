#lang racket

(require json
         racket/string
         "config.rkt"
         "dispatch.rkt"
         "dsl-forms.rkt"
         "http.rkt"
         "market.rkt"
         "planner.rkt"
         "scheduler.rkt"
         "world-cache.rkt"
         "world.rkt")

(provide load-world-index
         load-encyclopedia
         character-data
         enrich-character
         bot-characters
         bot-roles
         bind-bot-to-account
         bot-character-names
         missing-bot-character-names
         ensure-bot-characters
         strategy-actor-spec
         run-strategy-tick
         execute-planned-action
         route-for-plan
         ge-anchor-point
         cooldown-jobs-from-characters
         suggested-loop-sleep
         run-bot-once
         run-bot-loop
         api-error-wait-seconds
         generic-error-wait-seconds)

(define (character-data response)
  (cond
    [(and (hash? response) (hash-has-key? response 'data))
     (hash-ref response 'data)]
    [else response]))

(define (map-content-for-character char #:config [config (current-config)])
  (define layer (character-field char 'layer))
  (define x (character-field char 'x))
  (define y (character-field char 'y))
  (cond
    [(and layer x y)
     (define map-response (get-map layer x y #:config config))
     (define map (character-data map-response))
     (and (hash? map) (hash-ref map 'interactions #f))]
    [else #f]))

(define (interactions-from-world world char)
  (define m (map-at world
                    (character-field char 'layer)
                    (character-field char 'x)
                    (character-field char 'y)))
  (and (hash? m) (hash-ref m 'interactions #f)))

(define (enrich-character char
                          #:config [config (current-config)]
                          #:world [world #f]
                          #:live-map? [live-map? #t])
  (define interactions
    (or (interactions-from-world world char)
        (and live-map? (map-content-for-character char #:config config))))
  (if interactions
      (hash-set char 'interactions interactions)
      char))

(define (bot-characters bot)
  (filter character-spec? (bot-spec-forms bot)))

(define (bot-roles bot)
  (for/hash ([spec (bot-characters bot)])
    (values (character-spec-live-name spec)
            (character-spec-role spec))))

(define max-account-characters 5)

(define (bot-character-names bot)
  (map character-spec-live-name (bot-characters bot)))

(define (live-character-names live-characters)
  (for/list ([live (if (list? live-characters) live-characters '())]
             #:when (hash? live))
    (hash-ref live 'name)))

(define (missing-bot-character-names bot live-characters)
  (define live-names (list->set (live-character-names live-characters)))
  (filter (lambda (name) (not (set-member? live-names name)))
          (bot-character-names bot)))

(define (skin-for-spec spec #:skin [default-skin "men1"] #:skins [skins #hasheq()])
  (define tag (character-spec-tag spec))
  (define live (character-spec-account-name spec))
  (cond
    [(hash-has-key? skins tag) (hash-ref skins tag)]
    [(and live (hash-has-key? skins live)) (hash-ref skins live)]
    [(hash-has-key? skins (string->symbol (character-spec-live-name spec)))
     (hash-ref skins (string->symbol (character-spec-live-name spec)))]
    [else default-skin]))

(define (ensure-bot-characters bot
                              #:config [config (current-config)]
                              #:skin [default-skin "men1"]
                              #:skins [skins #hasheq()]
                              #:dry-run? [dry-run? #f])
  (define lives (load-my-characters #:config config #:dry-run? dry-run? #:bot bot))
  (define missing (missing-bot-character-names bot lives))
  (cond
    [(null? missing) lives]
    [(> (+ (length (live-character-names lives)) (length missing)) max-account-characters)
     (error 'ensure-bot-characters
            "account already has ~a character(s); need ~a more but the limit is ~a"
            (length (live-character-names lives))
            (length missing)
            max-account-characters)]
    [else
     (define missing-set (list->set missing))
     (for ([spec (bot-characters bot)]
           #:when (set-member? missing-set (character-spec-live-name spec)))
       (define name (character-spec-live-name spec))
       (define skin (skin-for-spec spec #:skin default-skin #:skins skins))
       (if dry-run?
           (printf "[dry-run] would create character ~a (skin ~a)\n" name (character-skin-string skin))
           (begin
             (printf "Creating character ~a (skin ~a)...\n" name (character-skin-string skin))
             (flush-output)
             (create-character name #:skin skin #:config config))))
     (if dry-run?
         lives
         (load-my-characters #:config config #:dry-run? #f #:bot bot))]))

(define (bind-bot-to-account bot live-characters)
  (define specs (bot-characters bot))
  (define lives (filter hash? (if (list? live-characters) live-characters '())))
  (define live-by-name
    (for/hash ([live lives])
      (values (hash-ref live 'name) live)))
  (define claimed (make-hash))
  (define (claim live)
    (when live
      (hash-set! claimed (hash-ref live 'name) #t))
    live)
  (define (first-unclaimed)
    (for/or ([live lives])
      (and (not (hash-ref claimed (hash-ref live 'name) #f))
           live)))
  (define bound
    (for/list ([spec specs])
      (define desired (character-spec-live-name spec))
      (define explicit? (character-spec-account-name spec))
      (define live
        (claim (or (hash-ref live-by-name desired #f)
                   (and (not explicit?) (first-unclaimed)))))
      (character-spec (character-spec-tag spec)
                      (character-spec-role spec)
                      (if live (hash-ref live 'name) desired)
                      (character-spec-forms spec))))
  (bot-spec (bot-spec-name bot)
            (append bound
                    (filter strategy-spec? (bot-spec-forms bot)))))

(define (find-character-by-name characters name)
  (for/or ([char characters])
    (and (hash? char)
         (equal? (hash-ref char 'name #f) name)
         char)))

(define (config-has-token? config)
  (define token (config-token config))
  (and token (non-empty-string? token)))

(define (synthetic-character spec index)
  (define role (character-spec-role spec))
  (define skill-level (if (memq role '(combat fighter)) 3 2))
  (hasheq 'name (character-spec-live-name spec)
          'level (max 1 skill-level)
          'hp 90
          'max_hp 100
          'cooldown 0
          'inventory_max_items 20
          'inventory '()
          'x index
          'y 0
          'layer "overworld"
          'map_id 1
          'mining_level skill-level
          'woodcutting_level skill-level
          'fishing_level skill-level
          'alchemy_level skill-level
          'interactions #hasheq((content . #f))))

(define (synthetic-account bot)
  (for/list ([spec (bot-characters bot)]
             [i (in-naturals)])
    (synthetic-character spec i)))

(define (load-my-characters #:config [config (current-config)]
                            #:dry-run? [dry-run? #f]
                            #:bot [bot #f])
  (cond
    [(config-has-token? config)
     (with-handlers ([exn:fail:artifacts-api?
                      (lambda (exn)
                        (cond
                          [dry-run?
                           (printf "Account fetch failed in dry-run; using synthetic characters.\n")
                           (flush-output)
                           (synthetic-account bot)]
                          [else (raise exn)]))])
       (character-data (get-my-characters #:config config)))]
    [dry-run?
     (printf "No ARTIFACTS_API_TOKEN/ARTIFACTS_TOKEN; dry-run using synthetic characters.\n")
     (flush-output)
     (synthetic-account bot)]
    [else
     (character-data (get-my-characters #:config config))]))

(define (active-events-list #:config [config (current-config)]
                            #:dry-run? [dry-run? #f])
  (cond
    [(not (config-has-token? config))
     '()]
    [else
     (with-handlers ([exn:fail:artifacts-api?
                      (lambda (exn)
                        (if dry-run? '() (raise exn)))])
       (define response (get-active-events #:config config))
       (define data (response-data response))
       (if (list? data) data '()))]))

(define (log-decision name plan)
  (printf "[~a] ~a :: ~a\n"
          name
          (planned-action-name plan)
          (planned-action-reason plan))
  (flush-output))

(define (inventory-top-codes char [n 3])
  (define slots
    (sort (filter (lambda (slot)
                    (and (hash? slot) (positive? (hash-ref slot 'quantity 0))))
                  (inventory-items char))
          >
          #:key (lambda (slot) (hash-ref slot 'quantity 0))))
  (for/list ([slot (in-list slots)] [_ (in-range n)])
    (format "~a×~a" (hash-ref slot 'code "?") (hash-ref slot 'quantity 0))))

(define (worn-gear-summary char)
  (define slots
    '((weapon_slot weapon) (shield_slot shield) (helmet_slot helm)
      (body_armor_slot body) (leg_armor_slot legs) (boots_slot boots)
      (ring1_slot ring1) (ring2_slot ring2) (amulet_slot amulet)
      (utility1_slot util1) (utility2_slot util2) (bag_slot bag)))
  (define parts
    (filter values
            (for/list ([pair slots])
              (define code (character-field char (car pair) #f))
              (and code (non-empty-string? (format "~a" code))
                   (format "~a=~a" (cadr pair) code)))))
  (if (null? parts) "" (format " worn [~a]" (string-join parts " "))))

(define (log-roster-snapshot characters)
  (printf "roster:\n")
  (for ([char characters] #:when (hash? char))
    (define bag (inventory-top-codes char))
    (printf "  ~a lv~a xp ~a/~a hp ~a/~a @~a,~a gold ~a bag ~a/~a cd ~as~a~a\n"
            (character-field char 'name "?")
            (character-field char 'level 0)
            (character-field char 'xp 0)
            (character-field char 'max_xp 0)
            (character-field char 'hp 0)
            (character-field char 'max_hp 0)
            (character-field char 'x 0)
            (character-field char 'y 0)
            (character-field char 'gold 0)
            (inventory-used char)
            (character-field char 'inventory_max_items 0)
            (cooldown-remaining char)
            (if (null? bag) "" (format " [~a]" (string-join bag " ")))
            (worn-gear-summary char)))
  (flush-output))

(define (bank-details-gold #:config [config (current-config)])
  (with-handlers ([exn:fail? (lambda (_) #f)])
    (define raw (get-bank-details #:config config))
    (define data (character-data raw))
    (and (hash? data) (hash-ref data 'gold #f))))

;; Print vault stacks from the once-per-tick bank snapshot (same table restock
;; uses). Caps the line length so a full bank stays readable. `#:gold` is the
;; vault purse from GET /my/bank (separate from item stacks).
(define (log-bank-snapshot table [limit 40] #:gold [gold #f])
  (cond
    [(not table)
     (printf "bank: (unavailable)~a\n"
             (if (number? gold) (format " gold ~a" gold) ""))]
    [(zero? (hash-count table))
     (printf "bank: empty~a\n"
             (if (number? gold) (format " gold ~a" gold) ""))]
    [else
     (define rows
       (sort (for/list ([(code qty) (in-hash table)])
               (cons code qty))
             >
             #:key cdr))
     (define shown (take rows (min limit (length rows))))
     (printf "bank (~a stacks~a): ~a"
             (hash-count table)
             (if (number? gold) (format ", gold ~a" gold) "")
             (string-join
              (for/list ([row shown])
                (format "~a×~a" (car row) (cdr row)))
              " "))
     (when (> (length rows) limit)
       (printf " … +~a more" (- (length rows) limit)))
     (printf "\n")])
  (flush-output))

(define (execute-planned-action name plan #:config [config (current-config)])
  (dispatch-action-name name
                        (planned-action-name plan)
                        (planned-action-payload plan)
                        #:config config))

(define (bot-strategy bot)
  (for/or ([form (bot-spec-forms bot)] #:when (strategy-spec? form))
    form))

(define (strategy-actor-spec bot)
  ;; Prefer the character already playing the market, since GE/event watching
  ;; naturally belongs to a trader; otherwise fall back to the first character.
  ;; The bot may arrive already bound to the account (via bind-bot-to-account),
  ;; in which case the actor's live name is the one we dispatch through.
  (define specs (bot-characters bot))
  (or (for/or ([spec specs]
               #:when (memq (character-spec-role spec) '(trader market)))
        spec)
      (and (pair? specs) (car specs))))

(define (action-spec-payload-value spec)
  (define payload (action-spec-payload spec))
  (if (pair? payload) (car payload) payload))

(define (run-strategy-tick bot* #:config [config (current-config)] #:dry-run? [dry-run? #f])
  (define strategy (bot-strategy bot*))
  (when strategy
    (define actor (strategy-actor-spec bot*))
    (define live-name (and actor (character-spec-live-name actor)))
    ;; A strategy runs helpers (goal-specs like (scan-ge) / (ge-trade ...)) and
    ;; plain actions through the same flatten+resolve path as character pipelines.
    ;; If the strategy needs a character but none is bound yet, skip cleanly
    ;; instead of crashing: a strategy is advisory, not mandatory.
    (when (and live-name (non-empty-string? live-name))
      (printf "[strategy ~a via ~a]\n"
              (strategy-spec-name strategy)
              live-name)
      (flush-output)
      (for ([spec (forms->action-specs (strategy-spec-forms strategy))])
        (define action-name (action-spec-name spec))
        (printf "  ~a\n" action-name)
        (flush-output)
        ;; In dry-run we must not touch the live API: scan-ge, active-events,
        ;; raids, and the ruthless-market `market-tick` are all network-backed
        ;; strategy actions that block (no token, no network). Skip only those
        ;; when dry-running; every other action still dispatches so a dry-run
        ;; mirrors a real tick as closely as possible without hanging.
        (define network-action?
          (member action-name
                  '(grand-exchange-orders active-events raids market-tick)))
        (when (or (not dry-run?) (not network-action?))
          (dispatch-action-name live-name
                                action-name
                                (action-spec-payload-value spec)
                                #:config config))))))

(define (point-from-char char)
  (hasheq 'layer (or (character-field char 'layer) "overworld")
          'x (or (character-field char 'x) 0)
          'y (or (character-field char 'y) 0)))

(define (point-from-payload payload world)
  (cond
    [(and (hash? payload) (hash-has-key? payload 'x) (hash-has-key? payload 'y))
     (hasheq 'layer (hash-ref payload 'layer "overworld")
             'x (hash-ref payload 'x)
             'y (hash-ref payload 'y))]
    [(and (hash? payload) (hash-has-key? payload 'map_id) (world-index? world))
     (define m (hash-ref (world-index-by-id world) (hash-ref payload 'map_id) #f))
     (and (hash? m)
          (hasheq 'layer (hash-ref m 'layer "overworld")
                  'x (hash-ref m 'x 0)
                  'y (hash-ref m 'y 0)))]
    [else #f]))

(define (route-for-plan name char plan world)
  (and (eq? (planned-action-name plan) 'move)
       (let ([dest (point-from-payload (planned-action-payload plan) world)])
         (and dest
              (hasheq 'character name
                      'points (list (point-from-char char) dest))))))

(define (ge-anchor-point world #:from [from #f])
  (define origin
    (or from #hasheq((layer . "overworld") (x . 0) (y . 0))))
  (define ge (and (world-index? world)
                  (nearest-typed-content world origin "grand_exchange")))
  (and (hash? ge)
       (hasheq 'layer (hash-ref ge 'layer "overworld")
               'x (hash-ref ge 'x 0)
               'y (hash-ref ge 'y 0))))

(define (retry-after-seconds retry)
  (cond
    [(number? retry) retry]
    [(string? retry) (string->number (string-trim retry))]
    [else #f]))

;; 429 is the Artifacts data/action bucket filling up, not a random outage.
;; Honor Retry-After when present; otherwise wait ~20s instead of 2s.
(define (api-error-wait-seconds err
                                #:base-seconds [base 2]
                                #:rate-limit-seconds [rl 20])
  (define retry (retry-after-seconds (api-error-retry-after err)))
  (cond
    [(and retry (positive? retry)) (max retry base)]
    [(or (equal? (api-error-code err) 429)
         (equal? (api-error-status err) 429))
     rl]
    [else base]))

(define (generic-error-wait-seconds msg
                                    #:base-seconds [base 2]
                                    #:rate-limit-seconds [rl 20])
  (if (and (string? msg) (regexp-match? #px"\\b429\\b" msg))
      rl
      base))

(define (stamp-bank-items characters table)
  (define items (bank-items-from-qty-table table))
  (for/list ([c characters])
    (if (hash? c) (hash-set c 'bank_items items) c)))

(define (with-bank-qty-table table thunk)
  (if table
      (parameterize ([bank-qty-lookup (lambda (want) (hash-ref table want 0))])
        (thunk))
      (thunk)))

(define (run-bot-once bot
                      #:config [config (current-config)]
                      #:world [world #f]
                      #:encyclopedia [encyclopedia #f]
                      #:dry-run? [dry-run? #f]
                      #:bind-account? [bind-account? #t])
  (define world* (or world (load-world-index #:config config)))
  (define encyclopedia*
    (or encyclopedia (load-encyclopedia #:config config)))
  (define monsters (hash-ref encyclopedia* 'monsters '()))
  (define resources (hash-ref encyclopedia* 'resources '()))
  (define events (active-events-list #:config config #:dry-run? dry-run?))
  (define loaded
    (load-my-characters #:config config #:dry-run? dry-run? #:bot bot))
  (define bank-table
    (and (not dry-run?)
         (config-has-token? config)
         (snapshot-bank-quantities #:config config)))
  (define bank-gold
    (and (not dry-run?)
         (config-has-token? config)
         (bank-details-gold #:config config)))
  (define my-chars
    (if (and bank-table (list? loaded))
        (stamp-bank-items loaded bank-table)
        loaded))
  (define live-map?
    (not (and dry-run? (not (config-has-token? config)))))
  (define-values (results updated-chars)
    (with-bank-qty-table
     bank-table
     (lambda ()
       (log-roster-snapshot my-chars)
       (log-bank-snapshot bank-table #:gold bank-gold)
       (define bot*
         (if bind-account?
             (bind-bot-to-account bot my-chars)
             bot))
       (run-strategy-tick bot* #:config config #:dry-run? dry-run?)
       (define updated my-chars)
       (define (record-cooldown live-name result)
         ;; Fold a live action's cooldown back into the shared character snapshot so
         ;; the loop's sleep (via cooldown-jobs-from-characters) gates on the real
         ;; next-ready time rather than the stale snapshot cooldown.
         (set! updated
               (for/list ([c updated])
                 (if (and (hash? c) (equal? (hash-ref c 'name #f) live-name))
                     (update-character-cooldown c result)
                     c))))
       (define tick-results
         (for/list ([spec (bot-characters bot*)])
           (define tag (symbol->string (character-spec-tag spec)))
           (define live-name (character-spec-live-name spec))
           (define label
             (if (equal? tag live-name) tag (format "~a (~a)" tag live-name)))
           (define role (character-spec-role spec))
           (define live (find-character-by-name my-chars live-name))
           (cond
             [(not live)
              (printf "[~a] missing on account; skipping.\n" label)
              (list tag 'missing #f)]
             [else
              (define enriched
                (enrich-character live
                                  #:config config
                                  #:world world*
                                  #:live-map? live-map?))
              ;; Preferred goal actions are resolved against the live character so
              ;; character-conditioned guards (when-low-hp, etc.) see real state.
              (define preferred (goal-preferred-actions spec enriched))
              (define plan
                (plan-character enriched
                               world*
                               #:role role
                               #:monsters monsters
                               #:resources resources
                               #:events events
                               #:preferred preferred))
              (cond
                [(not plan)
                 (printf "[~a] waiting on cooldown or no plan.\n" label)
                 (list tag 'idle #f)]
                [else
                 (log-decision label plan)
                 (define result
                   (cond
                     [dry-run?
                      #hasheq((dry_run . #t)
                              (action . (symbol->string (planned-action-name plan)))
                              (reason . (planned-action-reason plan)))]
                     [else
                      ;; Per-character catch so a failed gold withdraw names the
                      ;; actor and does not abort the rest of the roster tick.
                      (with-handlers
                          ([exn:fail:artifacts-api?
                            (lambda (exn)
                              (define err (exn:fail:artifacts-api-error exn))
                              (printf "[~a] API error ~a: ~a\n"
                                      label
                                      (api-error-code err)
                                      (api-error-message err))
                              (flush-output)
                              #f)]
                           [exn:fail?
                            (lambda (exn)
                              (printf "[~a] action error: ~a\n"
                                      label
                                      (exn-message exn))
                              (flush-output)
                              #f)])
                        (execute-planned-action live-name plan #:config config))]))
                 (when (and result (not dry-run?))
                   (record-cooldown live-name result))
                 (list tag (if result 'acted 'failed) result)])])))
       (values tick-results updated))))
  (values results updated-chars))

(define (cooldown-jobs-from-characters characters [now (current-seconds)])
  (for/list ([char characters] #:when (hash? char))
    (define remaining (cooldown-remaining char now))
    (make-job #:character (string->symbol (format "~a" (hash-ref char 'name "char")))
              #:action 'wait
              #:ready-at (+ now (max 0 remaining))
              #:priority 0)))

(define (suggested-loop-sleep characters
                              #:base-seconds [base-seconds 2]
                              #:min-seconds [min-seconds 1]
                              #:max-seconds [max-seconds 15]
                              #:now [now (current-seconds)])
  (define jobs (cooldown-jobs-from-characters characters now))
  (define any-cooling?
    (for/or ([char characters] #:when (hash? char))
      (> (cooldown-remaining char now) 0)))
  (if any-cooling?
      (suggested-wait-seconds jobs
                              #:now now
                              #:min-seconds min-seconds
                              #:max-seconds max-seconds
                              #:default-seconds base-seconds)
      base-seconds))

(define (run-bot-loop bot
                      #:config [config (current-config)]
                      #:iterations [iterations +inf.0]
                      #:sleep-seconds [sleep-seconds 2]
                      #:dry-run? [dry-run? #f]
                      #:pretend? [pretend? #f]
                      #:ensure-characters? [ensure-characters? #f]
                      #:skin [default-skin "men1"]
                      #:skins [skins #hasheq()])
  (when ensure-characters?
    (ensure-bot-characters bot
                           #:config config
                           #:skin default-skin
                           #:skins skins
                           #:dry-run? dry-run?))
  (when pretend?
    (artifacts-pretend? #t)
    (printf "PRETEND mode: real login + real movement, but orders are simulated (no gold moves).\n")
    (flush-output))
  (printf "Loading world and encyclopedia...\n")
  (flush-output)
  (define-values (world encyclopedia)
    (if dry-run?
        (values #f (hasheq 'monsters '() 'resources '() 'items '()))
        (values (load-world-index #:config config)
                (load-encyclopedia #:config config))))
  (printf "World maps: ~a | monsters: ~a | resources: ~a\n"
          (if (world-index? world) (length (world-index-maps world)) 0)
          (length (hash-ref encyclopedia 'monsters '()))
          (length (hash-ref encyclopedia 'resources '())))
  (flush-output)
  (let loop ([n 0])
    (when (< n iterations)
      (printf "\n--- tick ~a ---\n" (add1 n))
      (flush-output)
      (define wait
        (with-handlers ([exn:fail:artifacts-api?
                         (lambda (exn)
                           (define err (exn:fail:artifacts-api-error exn))
                           (define wait* (api-error-wait-seconds err #:base-seconds sleep-seconds))
                           (printf "API error ~a: ~a\n"
                                   (api-error-code err)
                                   (api-error-message err))
                           (when (> wait* sleep-seconds)
                             (printf "Backing off ~as (rate limit).\n" wait*))
                           (flush-output)
                           wait*)]
                        [exn:fail?
                         (lambda (exn)
                           (define msg (exn-message exn))
                           (define wait* (generic-error-wait-seconds msg #:base-seconds sleep-seconds))
                           (printf "Runner error: ~a\n" msg)
                           (when (> wait* sleep-seconds)
                             (printf "Backing off ~as (rate limit).\n" wait*))
                           (flush-output)
                           wait*)])
          (define-values (_tick-results chars)
            (run-bot-once bot
                          #:config config
                          #:world world
                          #:encyclopedia encyclopedia
                          #:dry-run? dry-run?))
          (define next-wait
            (suggested-loop-sleep chars #:base-seconds sleep-seconds))
          (when (> next-wait sleep-seconds)
            (printf "Cooldown wait ~as before next tick.\n" next-wait)
            (flush-output))
          next-wait))
      (sleep wait)
      (loop (add1 n)))))
