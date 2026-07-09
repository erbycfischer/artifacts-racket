#lang racket

;; Account session for the optional visualizer hub.
;; Owns auth, polling, and player action dispatch. Bots never require this module.

(require json
         racket/set
         racket/string
         "config.rkt"
         "http.rkt"
         "planner.rkt"
         "visualizer.rkt"
         "world.rkt")

(provide session-authenticated?
         session-selected
         session-characters
         session-set-token!
         session-logout!
         session-select!
         session-status-message
         action-result-message
         account-logs-message
         session-handle-command!
         start-session-service!
         stop-session-service!
         session-publish-snapshot!
         session-publish-status!
         enrich-character-visual)

(define session-token #f)
(define session-selected-name #f)
(define session-chars '())
(define session-world #f)
(define session-poll-thread #f)
(define session-stop? #f)
(define session-sema (make-semaphore 1))

(define (with-session thunk)
  (call-with-semaphore session-sema thunk))

(define (session-authenticated?)
  (and (string? session-token) (regexp-match? #px"\\S" session-token) #t))

(define (session-selected)
  session-selected-name)

(define (session-characters)
  session-chars)

(define (session-config #:base [base (current-config)])
  (artifacts-config (artifacts-config-base-url base)
                    (artifacts-config-realtime-url base)
                    session-token))

(define (session-set-token! token)
  (with-session
   (lambda ()
     (set! session-token (and (string? token) (string-trim token)))
     (when (and session-token (equal? session-token ""))
       (set! session-token #f))
     (unless session-token
       (set! session-chars '())
       (set! session-selected-name #f))))
  (session-publish-status!)
  (when (session-authenticated?)
    (session-refresh-account!)
    (session-publish-snapshot!)
    (session-publish-logs!))
  (session-authenticated?))

(define (session-logout!)
  (session-set-token! #f)
  #t)

(define (session-select! name)
  (define name* (and name (format "~a" name)))
  (with-session
   (lambda ()
     (set! session-selected-name name*)))
  (session-publish-status!)
  #t)

(define (inventory-summary char)
  (define inv (character-field char 'inventory '()))
  (define items (if (list? inv) inv '()))
  (define used
    (for/sum ([slot items] #:when (hash? slot))
      (hash-ref slot 'quantity 0)))
  (hasheq 'used used
          'max (character-field char 'inventory_max_items 0)
          'slots (min 8 (length items))))

(define (base-character-visual char)
  (define cd (cooldown-remaining char))
  (hasheq 'name (character-field char 'name)
          'layer (or (character-field char 'layer) "overworld")
          'x (or (character-field char 'x) 0)
          'y (or (character-field char 'y) 0)
          'map_id (character-field char 'map_id)
          'hp (character-field char 'hp)
          'max_hp (character-field char 'max_hp)
          'cooldown cd
          'on_cooldown (and (number? cd) (> cd 0))))

(define (enrich-character-visual char)
  (define base (base-character-visual char))
  (hash-set* base
             'gold (character-field char 'gold 0)
             'level (character-field char 'level 1)
             'inventory (inventory-summary char)))

(define (load-world-index* #:config [config (current-config)])
  ((dynamic-require "artifacts/runner.rkt" 'load-world-index) #:config config))

(define (character-status-record char)
  (hasheq 'name (character-field char 'name)
          'level (character-field char 'level 1)
          'hp (character-field char 'hp)
          'max_hp (character-field char 'max_hp)
          'x (character-field char 'x 0)
          'y (character-field char 'y 0)
          'layer (character-field char 'layer "overworld")
          'cooldown (cooldown-remaining char)
          'gold (character-field char 'gold 0)))

(define (session-status-message #:error [error #f])
  (make-protocol-message
   "session.status"
   (hasheq 'authenticated (session-authenticated?)
           'selected session-selected-name
           'characters (map character-status-record session-chars)
           'error error)))

(define (action-result-message character action
                               #:ok [ok #t]
                               #:error-code [error-code #f]
                               #:message [message ""]
                               #:cooldown [cooldown #f])
  (make-protocol-message
   "action.result"
   (hasheq 'character character
           'action (if (symbol? action) (symbol->string action) (format "~a" action))
           'ok ok
           'error_code error-code
           'message message
           'cooldown cooldown)))

(define (account-logs-message entries)
  (make-protocol-message
   "account.logs"
   (hasheq 'entries (if (list? entries) entries '()))))

(define (session-publish-status! #:error [error #f])
  (visualizer-publish! (session-status-message #:error error)))

(define (response-data response)
  (cond
    [(and (hash? response) (hash-has-key? response 'data))
     (hash-ref response 'data)]
    [else response]))

(define (as-list data)
  (cond
    [(list? data) data]
    [(hash? data) (list data)]
    [else '()]))


(define (leaderboard-name entry)
  (and (hash? entry)
       (or (hash-ref entry 'name #f)
           (hash-ref entry 'character #f))))

(define (other-character-visual name char)
  (and (hash? char)
       (hasheq 'name name
               'layer (hash-ref char 'layer "overworld")
               'x (hash-ref char 'x 0)
               'y (hash-ref char 'y 0)
               'map_id (hash-ref char 'map_id #f)
               'hp (hash-ref char 'hp #f)
               'max_hp (hash-ref char 'max_hp #f)
               'level (hash-ref char 'level 1)
               'skin (hash-ref char 'skin "")
               'other #t
               'cooldown (hash-ref char 'cooldown 0)
               'on_cooldown (let ([cd (hash-ref char 'cooldown 0)])
                              (and (number? cd) (> cd 0))))))

(define (fetch-other-characters #:config [config (current-config)]
                                #:limit [limit 40]
                                #:exclude [exclude '()])
  (with-handlers ([exn:fail? (lambda (_exn) '())])
    (define response (get-character-leaderboard #:size (min limit 100) #:config config))
    (define entries (as-list (response-data response)))
    (define exclude-set (list->set (map (lambda (n) (string-downcase (format "~a" n))) exclude)))
    (define names
      (for/list ([e entries]
                 #:when (leaderboard-name e)
                 #:unless (set-member? exclude-set
                                      (string-downcase (format "~a" (leaderboard-name e)))))
        (leaderboard-name e)))
    (define limited (if (> (length names) limit) (take names limit) names))
    (filter values
            (for/list ([name limited])
              (with-handlers ([exn:fail? (lambda (_exn) #f)])
                (define char (response-data (get-character name #:config config)))
                (other-character-visual name char))))))

(define (raid-visual-record raid)
  (and (hash? raid)
       (hasheq 'code (hash-ref raid 'code (hash-ref raid 'name "raid"))
               'layer (hash-ref raid 'layer "overworld")
               'x (hash-ref raid 'x 0)
               'y (hash-ref raid 'y 0))))

(define (event-visual-record e)
  (and (hash? e)
       (hasheq 'code (hash-ref e 'code (hash-ref e 'name "event"))
               'layer (hash-ref e 'layer "overworld")
               'x (hash-ref e 'x 0)
               'y (hash-ref e 'y 0))))

(define (ensure-world! #:config [config (session-config)])
  (unless session-world
    (set! session-world (load-world-index* #:config config)))
  session-world)

(define (session-refresh-account!)
  (cond
    [(not (session-authenticated?)) #f]
    [else
     (with-handlers ([exn:fail:artifacts-api?
                      (lambda (exn)
                        (define err (exn:fail:artifacts-api-error exn))
                        (session-publish-status!
                         #:error (format "~a: ~a"
                                         (api-error-code err)
                                         (api-error-message err)))
                        #f)]
                     [exn:fail?
                      (lambda (exn)
                        (session-publish-status! #:error (exn-message exn))
                        #f)])
       (define config (session-config))
       (ensure-world! #:config config)
       (define response (get-my-characters #:config config #:size 50))
       (define chars (as-list (response-data response)))
       (with-session
        (lambda ()
          (set! session-chars chars)
          (when (and (not session-selected-name) (pair? chars))
            (set! session-selected-name (hash-ref (car chars) 'name #f)))))
       (session-publish-status!)
       #t)]))

(define (session-publish-snapshot!)
  (when (session-authenticated?)
    (ensure-world!))
  (when session-world
    (define chars session-chars)
    (define config (session-config))
    (define events
      (with-handlers ([exn:fail? (lambda (_exn) '())])
        (if (session-authenticated?)
            (as-list (response-data (get-active-events #:config config)))
            '())))
    (define raids
      (with-handlers ([exn:fail? (lambda (_exn) '())])
        (if (session-authenticated?)
            (filter values
                    (map raid-visual-record
                         (as-list (response-data (get-raids #:config config)))))
            '())))
    (define focuses
      (append
       (for/list ([c chars] #:when (hash? c))
         (hasheq 'layer (hash-ref c 'layer "overworld")
                 'x (hash-ref c 'x 0)
                 'y (hash-ref c 'y 0)))
       (for/list ([e events] #:when (hash? e))
         (hasheq 'layer (hash-ref e 'layer "overworld")
                 'x (hash-ref e 'x 0)
                 'y (hash-ref e 'y 0)))))
    (define routes (bot-route-overlay))
    (define mine-names
      (for/list ([c chars] #:when (hash? c))
        (hash-ref c 'name #f)))
    (define others
      (fetch-other-characters #:config config
                              #:limit 12
                              #:exclude (filter values mine-names)))
    (visualizer-publish!
     (world-snapshot-message
      #:maps (summarize-maps-for-visualizer (world-index-maps session-world)
                                           #:focuses focuses)
      #:characters (append (map enrich-character-visual chars) others)
      #:routes (if (list? routes) routes '())
      #:events (filter values (map event-visual-record events))
      #:raids raids))))

(define (session-publish-logs!)
  (when (session-authenticated?)
    (with-handlers ([exn:fail? void])
      (define config (session-config))
      (define name session-selected-name)
      (define response
        (if name
            (get-character-logs name #:size 20 #:config config)
            (get-account-logs #:size 20 #:config config)))
      (define entries
        (for/list ([e (as-list (response-data response))] #:when (hash? e))
          (hasheq 'type (hash-ref e 'type (hash-ref e 'log_type "log"))
                  'description (hash-ref e 'description
                                         (hash-ref e 'message ""))
                  'character (hash-ref e 'character name)
                  'created_at (hash-ref e 'created_at
                                        (hash-ref e 'timestamp "")))))
      (visualizer-publish! (account-logs-message entries)))))

(define (symbolish v)
  (cond
    [(symbol? v) v]
    [(string? v) (string->symbol v)]
    [else #f]))

(define (payload-from-data data)
  (define raw (and (hash? data) (hash-ref data 'payload #f)))
  (cond
    [(hash? raw) raw]
    [(list? raw) raw]
    [(number? raw) raw]
    [(string? raw) raw]
    [else #hasheq()]))

(define (dispatch-player-action! character action-name payload)
  (define config (session-config))
  (define p (if (hash? payload) payload #hasheq()))
  (case action-name
    [(move)
     (cond
       [(hash-has-key? p 'map_id)
        (action-move character #:map-id (hash-ref p 'map_id) #:config config)]
       [(and (hash-has-key? p 'x) (hash-has-key? p 'y))
        (action-move character #:x (hash-ref p 'x) #:y (hash-ref p 'y) #:config config)]
       [else (error 'player.action "move requires map_id or x/y")])]
    [(transition) (action-transition character #:config config)]
    [(rest) (action-rest character #:config config)]
    [(fight) (action-fight character #:participants (hash-ref p 'participants '()) #:config config)]
    [(gather) (action-gather character #:config config)]
    [(craft) (action-craft character p #:config config)]
    [(recycle) (action-recycle character p #:config config)]
    [(equip) (action-equip character p #:config config)]
    [(unequip) (action-unequip character p #:config config)]
    [(use) (action-use character p #:config config)]
    [(bank-deposit-item) (action-bank-deposit-item character (hash-ref p 'items p) #:config config)]
    [(bank-withdraw-item) (action-bank-withdraw-item character (hash-ref p 'items p) #:config config)]
    [(bank-deposit-gold) (action-bank-deposit-gold character (hash-ref p 'quantity 0) #:config config)]
    [(bank-withdraw-gold) (action-bank-withdraw-gold character (hash-ref p 'quantity 0) #:config config)]
    [(bank-buy-expansion) (action-bank-buy-expansion character #:config config)]
    [(npc-buy) (action-npc-buy character p #:config config)]
    [(npc-sell) (action-npc-sell character p #:config config)]
    [(grand-exchange-buy) (action-grand-exchange-buy character p #:config config)]
    [(grand-exchange-create-sell-order) (action-grand-exchange-create-sell-order character p #:config config)]
    [(grand-exchange-create-buy-order) (action-grand-exchange-create-buy-order character p #:config config)]
    [(grand-exchange-cancel) (action-grand-exchange-cancel character p #:config config)]
    [(grand-exchange-fill) (action-grand-exchange-fill character p #:config config)]
    [(grand-exchange-orders) (get-grand-exchange-orders #:config config)]
    [(task-new) (action-task-new character #:config config)]
    [(task-complete) (action-task-complete character #:config config)]
    [(task-cancel) (action-task-cancel character #:config config)]
    [(task-exchange) (action-task-exchange character #:config config)]
    [(task-trade) (action-task-trade character p #:config config)]
    [else (error 'player.action "unsupported action ~v" action-name)]))

(define (handle-player-action! data)
  (define character (and (hash? data) (hash-ref data 'character #f)))
  (define action-name (symbolish (and (hash? data) (hash-ref data 'action #f))))
  (define payload (payload-from-data data))
  (cond
    [(not (session-authenticated?))
     (visualizer-publish!
      (action-result-message (or character "") (or action-name 'unknown)
                             #:ok #f
                             #:error-code 452
                             #:message "Not authenticated."))]
    [(not (and character action-name))
     (visualizer-publish!
      (action-result-message (or character "") (or action-name 'unknown)
                             #:ok #f
                             #:error-code 400
                             #:message "player.action requires character and action."))]
    [else
     (with-handlers
         ([exn:fail:artifacts-api?
           (lambda (exn)
             (define err (exn:fail:artifacts-api-error exn))
             (visualizer-publish!
              (action-result-message character action-name
                                     #:ok #f
                                     #:error-code (api-error-code err)
                                     #:message (api-error-message err)
                                     #:cooldown (api-error-cooldown-until err))))]
          [exn:fail?
           (lambda (exn)
             (visualizer-publish!
              (action-result-message character action-name
                                     #:ok #f
                                     #:error-code 500
                                     #:message (exn-message exn))))])
       (dispatch-player-action! (format "~a" character) action-name payload)
       (visualizer-publish!
        (action-result-message character action-name
                               #:ok #t
                               #:message "ok"))
       (session-refresh-account!)
       (session-publish-snapshot!)
       (session-publish-logs!))]))

(define (session-handle-command! message)
  (define msg
    (cond
      [(string? message)
       (with-handlers ([exn:fail? (lambda (_exn) #f)])
         (string->jsexpr message))]
      [(hash? message) message]
      [else #f]))
  (when (hash? msg)
    (define type (hash-ref msg 'type #f))
    (define data (hash-ref msg 'data #hasheq()))
    (case type
      [("session.auth")
       (define token (and (hash? data) (hash-ref data 'token #f)))
       (session-set-token! token)]
      [("session.logout")
       (session-logout!)]
      [("player.select")
       (session-select! (and (hash? data) (hash-ref data 'character #f)))]
      [("player.action")
       (handle-player-action! data)]
      [("ui.subscribe")
       (session-publish-status!)
       (when (session-authenticated?)
         (session-publish-snapshot!))]
      [else
       (printf "Visualizer ignored unknown command type: ~a\n" type)
       (flush-output)])))

(define (poll-loop interval-seconds)
  (let loop ()
    (unless session-stop?
      (when (session-authenticated?)
        (session-refresh-account!)
        (session-publish-snapshot!)
        (session-publish-logs!))
      (sleep interval-seconds)
      (loop))))

(define (present-env-token? config)
  (define token (artifacts-config-token config))
  (and (string? token) (regexp-match? #px"\\S" token)))

(define (start-session-service! #:config [config (current-config)]
                                #:poll-seconds [poll-seconds 3]
                                #:load-world? [load-world? #t])
  (set-visualizer-command-handler! session-handle-command!)
  (session-owns-snapshots? #t)
  (when (present-env-token? config)
    (session-set-token! (artifacts-config-token config)))
  (when load-world?
    (printf "Session loading world index...\n")
    (flush-output)
    (set! session-world (load-world-index* #:config (if (session-authenticated?)
                                                        (session-config #:base config)
                                                        config)))
    (printf "Session world maps: ~a\n" (length (world-index-maps session-world)))
    (flush-output))
  (set! session-stop? #f)
  (unless (and session-poll-thread (thread-running? session-poll-thread))
    (set! session-poll-thread (thread (lambda () (poll-loop poll-seconds)))))
  (session-publish-status!)
  (when (session-authenticated?)
    (session-refresh-account!)
    (session-publish-snapshot!))
  #t)

(define (stop-session-service!)
  (set! session-stop? #t)
  (set! session-poll-thread #f)
  (session-owns-snapshots? #f)
  (bot-route-overlay '())
  (set-visualizer-command-handler! #f)
  (void))
