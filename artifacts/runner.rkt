#lang racket

(require racket/string
         "config.rkt"
         "dsl-forms.rkt"
         "http.rkt"
         "planner.rkt"
         "world.rkt")

(provide fetch-all-pages
         load-world-index
         load-encyclopedia
         character-data
         enrich-character
         bot-characters
         bot-roles
         bind-bot-to-account
         execute-planned-action
         run-bot-once
         run-bot-loop)

(define (response-data response)
  (cond
    [(and (hash? response) (hash-has-key? response 'data))
     (hash-ref response 'data)]
    [else response]))

(define (fetch-all-pages getter #:config [config (current-config)] #:size [size 100])
  (let loop ([page 1] [acc '()])
    (define response (getter #:page page #:size size #:config config))
    (define data (response-data response))
    (define items (if (list? data) data '()))
    (define pages (and (hash? response) (hash-ref response 'pages #f)))
    (define next (append acc items))
    (cond
      [(or (null? items)
           (and (number? pages) (>= page pages))
           (< (length items) size))
       next]
      [else (loop (add1 page) next)])))

(define (load-world-index #:config [config (current-config)])
  (build-world-index
   (fetch-all-pages get-maps #:config config #:size 100)))

(define (load-encyclopedia #:config [config (current-config)])
  (hasheq 'monsters (fetch-all-pages get-monsters #:config config)
          'resources (fetch-all-pages get-resources #:config config)
          'items (fetch-all-pages get-items #:config config)))

(define (character-data response)
  (define data (response-data response))
  (if (list? data)
      data
      (if (hash? data) data #hasheq())))

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
     (printf "No ARTIFACTS_TOKEN; dry-run using synthetic characters.\n")
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
  results)

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
      (with-handlers ([exn:fail:artifacts-api?
                       (lambda (exn)
                         (define err (exn:fail:artifacts-api-error exn))
                         (printf "API error ~a: ~a\n"
                                 (api-error-code err)
                                 (api-error-message err))
                         (flush-output))]
                      [exn:fail?
                       (lambda (exn)
                         (printf "Runner error: ~a\n" (exn-message exn))
                         (flush-output))])
        (run-bot-once bot
                      #:config config
                      #:world world
                      #:encyclopedia encyclopedia
                      #:dry-run? dry-run?))
      (sleep sleep-seconds)
      (loop (add1 n)))))
