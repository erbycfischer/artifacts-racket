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
         execute-planned-action
         route-for-plan
         ge-anchor-point
         cooldown-jobs-from-characters
         suggested-loop-sleep
         run-bot-once
         run-bot-loop)

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

(define (enrich-character char #:config [config (current-config)])
  (define interactions (map-content-for-character char #:config config))
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
  (define token (artifacts-config-token config))
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

(define (execute-planned-action name plan #:config [config (current-config)])
  (dispatch-action-name name
                        (planned-action-name plan)
                        (planned-action-payload plan)
                        #:config config))

(define (bot-strategy bot)
  (for/or ([form (bot-spec-forms bot)] #:when (strategy-spec? form))
    form))

(define (strategy-actor-spec bot)
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
    (when actor
      (define live-name (character-spec-live-name actor))
      (printf "[strategy ~a via ~a]\n"
              (strategy-spec-name strategy)
              live-name)
      (flush-output)
      (for ([spec (strategy-spec-forms strategy)])
        (define action-name (action-spec-name spec))
        (printf "  ~a\n" action-name)
        (flush-output)
        (unless dry-run?
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
  (define my-chars
    (load-my-characters #:config config #:dry-run? dry-run? #:bot bot))
  (define bot*
    (if bind-account?
        (bind-bot-to-account bot my-chars)
        bot))
  (run-strategy-tick bot* #:config config #:dry-run? dry-run?)
  (define results
    (for/list ([spec (bot-characters bot*)])
      (define tag (symbol->string (character-spec-tag spec)))
      (define live-name (character-spec-live-name spec))
      (define label
        (if (equal? tag live-name) tag (format "~a (~a)" tag live-name)))
      (define role (character-spec-role spec))
      (define preferred (goal-preferred-actions spec))
      (define live (find-character-by-name my-chars live-name))
      (cond
        [(not live)
         (printf "[~a] missing on account; skipping.\n" label)
         (list tag 'missing #f)]
        [else
         (define enriched
           (if (and dry-run? (not (config-has-token? config)))
               live
               (enrich-character live #:config config)))
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
              (if dry-run?
                  #hasheq((dry_run . #t)
                          (action . (symbol->string (planned-action-name plan)))
                          (reason . (planned-action-reason plan)))
                  (execute-planned-action live-name plan #:config config)))
            (list tag 'acted result)])])))
  (values results my-chars))

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
                      #:ensure-characters? [ensure-characters? #f]
                      #:skin [default-skin "men1"]
                      #:skins [skins #hasheq()])
  (when ensure-characters?
    (ensure-bot-characters bot
                           #:config config
                           #:skin default-skin
                           #:skins skins
                           #:dry-run? dry-run?))
  (printf "Loading world and encyclopedia...\n")
  (flush-output)
  (define world (load-world-index #:config config))
  (define encyclopedia (load-encyclopedia #:config config))
  (printf "World maps: ~a | monsters: ~a | resources: ~a\n"
          (length (world-index-maps world))
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
                           (printf "API error ~a: ~a\n"
                                   (api-error-code err)
                                   (api-error-message err))
                           (flush-output)
                           sleep-seconds)]
                        [exn:fail?
                         (lambda (exn)
                           (printf "Runner error: ~a\n" (exn-message exn))
                           (flush-output)
                           sleep-seconds)])
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
