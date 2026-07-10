#lang racket

(require json
         racket/string
         "config.rkt"
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
    (values (symbol->string (character-spec-name spec))
            (character-spec-role spec))))

(define (bind-bot-to-account bot live-characters)
  (define specs (bot-characters bot))
  (define lives (if (list? live-characters) live-characters '()))
  (define bound
    (for/list ([spec specs] [live lives])
      (character-spec (string->symbol (hash-ref live 'name))
                      (character-spec-role spec)
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
  (define skill-level (if (eq? role 'combat) 3 2))
  (hasheq 'name (symbol->string (character-spec-name spec))
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
  (define payload (planned-action-payload plan))
  (case (planned-action-name plan)
    [(move)
     (cond
       [(hash-has-key? payload 'map_id)
        (action-move name #:map-id (hash-ref payload 'map_id) #:config config)]
       [(and (hash-has-key? payload 'x) (hash-has-key? payload 'y))
        (action-move name #:x (hash-ref payload 'x) #:y (hash-ref payload 'y) #:config config)]
       [else (error 'execute-planned-action "move payload needs map_id or x/y")])]
    [(rest) (action-rest name #:config config)]
    [(fight) (action-fight name #:participants (if (list? payload) payload '()) #:config config)]
    [(gather) (action-gather name #:config config)]
    [(bank-deposit-item) (action-bank-deposit-item name payload #:config config)]
    [(grand-exchange-orders) (get-grand-exchange-orders #:config config)]
    [(active-events) (get-active-events #:config config)]
    [(raids) (get-raids #:config config)]
    [else (error 'execute-planned-action "unsupported planned action ~v" (planned-action-name plan))]))

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
  (define results
    (for/list ([spec (bot-characters bot*)])
      (define name (symbol->string (character-spec-name spec)))
      (define role (character-spec-role spec))
      (define live (find-character-by-name my-chars name))
      (cond
        [(not live)
         (printf "[~a] missing on account; skipping.\n" name)
         (list name 'missing #f)]
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
                          #:events events))
         (cond
           [(not plan)
            (printf "[~a] waiting on cooldown or no plan.\n" name)
            (list name 'idle #f)]
           [else
            (log-decision name plan)
            (define result
              (if dry-run?
                  #hasheq((dry_run . #t)
                          (action . (symbol->string (planned-action-name plan)))
                          (reason . (planned-action-reason plan)))
                  (execute-planned-action name plan #:config config)))
            (list name 'acted result)])])))
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
                      #:dry-run? [dry-run? #f])
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
