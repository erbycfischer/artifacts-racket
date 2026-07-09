#lang racket

(require json
         racket/file
         racket/string
         "config.rkt"
         "dsl-forms.rkt"
         "http.rkt"
         "market.rkt"
         "planner.rkt"
         "scheduler.rkt"
         "visualizer.rkt"
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
         route-for-plan
         ge-anchor-point
         fetch-world-others
         cooldown-jobs-from-characters
         suggested-loop-sleep
         run-bot-once
         run-bot-loop
         (all-from-out "visualizer.rkt"))

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

(define world-cache-seconds
  (let ([v (getenv "ARTIFACTS_WORLD_CACHE_SECONDS")])
    (or (and v (string->number v)) 900)))

(define (world-cache-path)
  (define root (or (getenv "ARTIFACTS_CACHE_DIR")
                   (build-path (find-system-path 'temp-dir) "artifacts-racket-cache")))
  (make-directory* root)
  (build-path root "world-maps.json"))

(define (read-world-cache)
  (define path (world-cache-path))
  (and (file-exists? path)
       (< (- (current-seconds) (file-or-directory-modify-seconds path))
          world-cache-seconds)
       (with-handlers ([exn:fail? (lambda (_exn) #f)])
         (define data (call-with-input-file path read-json))
         (and (list? data) (pair? data) data))))

(define (write-world-cache! maps)
  (with-handlers ([exn:fail? (lambda (_exn) (void))])
    (call-with-output-file (world-cache-path)
      (lambda (out) (write-json maps out))
      #:exists 'replace)))

(define (load-world-index #:config [config (current-config)]
                          #:use-cache? [use-cache? #t])
  (define maps
    (or (and use-cache? (read-world-cache))
        (let ([fresh (fetch-all-pages get-maps #:config config #:size 100)])
          (when use-cache?
            (write-world-cache! fresh))
          fresh)))
  (build-world-index maps))

(define encyclopedia-cache-seconds
  (let ([v (getenv "ARTIFACTS_ENCYCLOPEDIA_CACHE_SECONDS")])
    (or (and v (string->number v)) 900)))

(define (encyclopedia-cache-path)
  (define root (or (getenv "ARTIFACTS_CACHE_DIR")
                   (build-path (find-system-path 'temp-dir) "artifacts-racket-cache")))
  (make-directory* root)
  (build-path root "encyclopedia.json"))

(define (read-encyclopedia-cache)
  (define path (encyclopedia-cache-path))
  (and (file-exists? path)
       (< (- (current-seconds) (file-or-directory-modify-seconds path))
          encyclopedia-cache-seconds)
       (with-handlers ([exn:fail? (lambda (_exn) #f)])
         (define data (call-with-input-file path read-json))
         (and (hash? data)
              (hash-has-key? data 'monsters)
              (hash-has-key? data 'resources)
              data))))

(define (write-encyclopedia-cache! data)
  (with-handlers ([exn:fail? (lambda (_exn) (void))])
    (call-with-output-file (encyclopedia-cache-path)
      (lambda (out) (write-json data out))
      #:exists 'replace)))

(define (load-encyclopedia #:config [config (current-config)]
                           #:use-cache? [use-cache? #t])
  (or (and use-cache? (read-encyclopedia-cache))
      (let ([fresh (hasheq 'monsters (fetch-all-pages get-monsters #:config config)
                           'resources (fetch-all-pages get-resources #:config config)
                           'items (fetch-all-pages get-items #:config config))])
        (when use-cache?
          (write-encyclopedia-cache! fresh))
        fresh)))

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

(define (character-visual-record char)
  (define cd (cooldown-remaining char))
  (define inv (character-field char 'inventory '()))
  (define items (if (list? inv) inv '()))
  (define used
    (for/sum ([slot items] #:when (hash? slot))
      (hash-ref slot 'quantity 0)))
  (hasheq 'name (character-field char 'name)
          'layer (or (character-field char 'layer) "overworld")
          'x (or (character-field char 'x) 0)
          'y (or (character-field char 'y) 0)
          'map_id (character-field char 'map_id)
          'hp (character-field char 'hp)
          'max_hp (character-field char 'max_hp)
          'gold (character-field char 'gold 0)
          'level (character-field char 'level 1)
          'inventory (hasheq 'used used
                             'max (character-field char 'inventory_max_items 0)
                             'slots (min 8 (length items)))
          'cooldown cd
          'on_cooldown (and (number? cd) (> cd 0))))

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

(define (orders-by-side orders side)
  (for/list ([order orders]
             #:when (and (hash? order)
                         (equal? (hash-ref order 'type #f) side)))
    order))

(define (score-item-orders code orders)
  (define buys (orders-by-side orders "buy"))
  (define sells (orders-by-side orders "sell"))
  (define spread (order-spread buys sells))
  (define score (score-spread buys sells))
  (and spread
       score
       (profitable-spread? buys sells #:minimum-margin 1)
       (hasheq 'code code
               'spread spread
               'score score
               'buy_depth (side-depth buys)
               'sell_depth (side-depth sells))))

(define (top-market-signals signals #:limit [limit 8])
  (define ranked
    (sort (filter values signals)
          >
          #:key (lambda (s) (hash-ref s 'score 0))))
  (if (> (length ranked) limit)
      (take ranked limit)
      ranked))

(define (ge-anchor-point world #:from [from #f])
  (define origin
    (or from #hasheq((layer . "overworld") (x . 0) (y . 0))))
  (define ge (and (world-index? world)
                  (nearest-typed-content world origin "grand_exchange")))
  (and (hash? ge)
       (hasheq 'layer (hash-ref ge 'layer "overworld")
               'x (hash-ref ge 'x 0)
               'y (hash-ref ge 'y 0))))

(define (publish-signal-at! code spread score anchor)
  (if (hash? anchor)
      (visualizer-publish!
       (market-signal-message code spread score
                              #:x (hash-ref anchor 'x)
                              #:y (hash-ref anchor 'y)
                              #:layer (hash-ref anchor 'layer "overworld")))
      (visualizer-publish!
       (market-signal-message code spread score))))

(define (publish-market-signals! #:config [config (current-config)]
                                 #:dry-run? [dry-run? #f]
                                 #:world [world #f]
                                 #:from [from #f])
  (define anchor (or (ge-anchor-point world #:from from)
                     (and dry-run?
                          #hasheq((layer . "overworld") (x . 0) (y . 1)))))
  (cond
    [dry-run?
     (publish-signal-at! "iron_ore" 7 0.82 anchor)
     (publish-signal-at! "ash_wood" 4 0.55
                         (if (hash? anchor)
                             (hash-set* anchor 'x (add1 (hash-ref anchor 'x 0)))
                             #f))]
    [(not (config-has-token? config))
     (void)]
    [else
     (with-handlers ([exn:fail:artifacts-api? (lambda (_exn) (void))]
                     [exn:fail? (lambda (_exn) (void))])
       (define response (get-grand-exchange-orders #:config config #:size 100))
       (define data (response-data response))
       (define orders (if (list? data) data '()))
       (define by-code (make-hash))
       (for ([order orders] #:when (hash? order))
         (define code (hash-ref order 'code #f))
         (when code
           (hash-update! by-code code (lambda (xs) (cons order xs)) '())))
       (define signals
         (for/list ([(code grouped) (in-hash by-code)])
           (score-item-orders code grouped)))
       (for ([signal (top-market-signals signals)])
         (publish-signal-at! (hash-ref signal 'code)
                             (hash-ref signal 'spread)
                             (hash-ref signal 'score)
                             anchor)))]))

(define (snapshot-focus-points characters events routes)
  (define from-chars
    (for/list ([c characters] #:when (hash? c))
      (hasheq 'layer (hash-ref c 'layer "overworld")
              'x (hash-ref c 'x 0)
              'y (hash-ref c 'y 0))))
  (define from-events
    (for/list ([e events] #:when (hash? e))
      (hasheq 'layer (hash-ref e 'layer "overworld")
              'x (hash-ref e 'x 0)
              'y (hash-ref e 'y 0))))
  (define from-routes
    (apply append
           (for/list ([r routes] #:when (hash? r))
             (define pts (hash-ref r 'points '()))
             (if (list? pts) pts '()))))
  (append from-chars from-events from-routes))


(define (fetch-world-others #:config [config (current-config)]
                            #:limit [limit 12]
                            #:exclude [exclude '()])
  (with-handlers ([exn:fail? (lambda (_exn) '())])
    (define response (get-character-leaderboard #:size (min limit 100) #:config config))
    (define entries (let ([data (response-data response)]) (if (list? data) data '())))
    (define exclude-set
      (for/hash ([n exclude] #:when n)
        (values (string-downcase (format "~a" n)) #t)))
    (define names
      (for/list ([e entries]
                 #:when (and (hash? e) (hash-ref e 'name #f))
                 #:unless (hash-has-key? exclude-set (string-downcase (format "~a" (hash-ref e 'name)))))
        (hash-ref e 'name)))
    (define limited (if (> (length names) limit) (take names limit) names))
    (filter values
            (for/list ([name limited])
              (with-handlers ([exn:fail? (lambda (_exn) #f)])
                (define char (response-data (get-character name #:config config)))
                (and (hash? char)
                     (hasheq 'name name
                             'layer (hash-ref char 'layer "overworld")
                             'x (hash-ref char 'x 0)
                             'y (hash-ref char 'y 0)
                             'map_id (hash-ref char 'map_id #f)
                             'level (hash-ref char 'level 1)
                             'skin (hash-ref char 'skin "")
                             'other #t
                             'cooldown (hash-ref char 'cooldown 0)
                             'on_cooldown #f)))))))

(define (raid-visual-record raid)
  (and (hash? raid)
       (hasheq 'code (hash-ref raid 'code (hash-ref raid 'name "raid"))
               'layer (hash-ref raid 'layer "overworld")
               'x (hash-ref raid 'x 0)
               'y (hash-ref raid 'y 0))))

(define (active-raids-list #:config [config (current-config)]
                           #:dry-run? [dry-run? #f])
  (cond
    [(not (config-has-token? config)) '()]
    [else
     (with-handlers ([exn:fail:artifacts-api?
                      (lambda (exn) (if dry-run? '() (raise exn)))]
                     [exn:fail? (lambda (_exn) '())])
       (define response (get-raids #:config config))
       (define data (response-data response))
       (filter values (map raid-visual-record (if (list? data) data '()))))]))

(define (publish-world-snapshot! world characters events
                                 #:routes [routes '()]
                                 #:raids [raids '()])
  (define focuses (snapshot-focus-points characters events routes))
  (visualizer-publish!
   (world-snapshot-message
    #:maps (summarize-maps-for-visualizer (world-index-maps world)
                                         #:focuses focuses)
    #:characters (append (map character-visual-record characters)
                       (fetch-world-others #:limit 12
                       #:exclude (for/list ([c characters] #:when (hash? c))
                                  (hash-ref c 'name #f))))
    #:routes routes
    #:events (for/list ([e events] #:when (hash? e))
               (hasheq 'code (hash-ref e 'code (hash-ref e 'name "event"))
                       'layer (hash-ref e 'layer "overworld")
                       'x (hash-ref e 'x 0)
                       'y (hash-ref e 'y 0)))
    #:raids raids)))

(define (publish-decision! name plan)
  (visualizer-publish!
   (bot-decision-message name
                         (planned-action-name plan)
                         (planned-action-reason plan)
                         #:target (planned-action-payload plan))))

(define (run-bot-once bot
                      #:config [config (current-config)]
                      #:world [world #f]
                      #:encyclopedia [encyclopedia #f]
                      #:dry-run? [dry-run? #f]
                      #:bind-account? [bind-account? #t]
                      #:publish-visualizer? [publish-visualizer? #t])
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
  (define planned-routes '())
  (define saw-market-scan? #f)
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
            (when (eq? (planned-action-name plan) 'grand-exchange-orders)
              (set! saw-market-scan? #t))
            (define route (route-for-plan name enriched plan world*))
            (when route
              (set! planned-routes (cons route planned-routes)))
            (when publish-visualizer?
              (publish-decision! name plan))
            (define result
              (if dry-run?
                  #hasheq((dry_run . #t)
                          (action . (symbol->string (planned-action-name plan)))
                          (reason . (planned-action-reason plan)))
                  (execute-planned-action name plan #:config config)))
            (list name 'acted result)])])))
  ;; Optional overlays only. When the standalone bridge owns snapshots,
  ;; bots do not need to publish world state for characters to appear in 3D.
  (when publish-visualizer?
    (define routes* (reverse planned-routes))
    (bot-route-overlay routes*)
    (unless (session-owns-snapshots?)
      (define raids (active-raids-list #:config config #:dry-run? dry-run?))
      (publish-world-snapshot! world* my-chars events #:routes routes* #:raids raids))
    ;; Dry-run always emits a sample market signal so Godot can exercise overlays
    ;; without waiting for a live GE scan plan.
    (when (or dry-run? saw-market-scan?)
      (define trader
        (for/first ([c my-chars]
                    #:when (and (hash? c)
                                (equal? (string-downcase (format "~a" (hash-ref c 'name "")))
                                        "trader")))
          c))
      (publish-market-signals! #:config config
                               #:dry-run? dry-run?
                               #:world world*
                               #:from trader)))
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
                      #:visualizer? [visualizer? (visualizer-enabled?)]
                      #:visualizer-port [visualizer-port 8787])
  ;; Godot is optional. Attach to an existing hub when present; otherwise start one.
  (when visualizer?
    (if (hub-alive?)
        (printf "Visualizer hub already running; bot will publish overlays only.\n")
        (start-visualizer-hub! #:port visualizer-port #:enabled? #t))
    (flush-output))
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
          (define-values (tick-results chars)
            (run-bot-once bot
                          #:config config
                          #:world world
                          #:encyclopedia encyclopedia
                          #:dry-run? dry-run?
                          #:publish-visualizer? visualizer?))
          (define next-wait
            (suggested-loop-sleep chars #:base-seconds sleep-seconds))
          (when (> next-wait sleep-seconds)
            (printf "Cooldown wait ~as before next tick.\n" next-wait)
            (flush-output))
          next-wait))
      (sleep wait)
      (loop (add1 n)))))
