#lang racket

;; Local WebSocket hub for the official Artifacts custom 3D visual client.
;; The bridge/session owns world.snapshot from official API polling.
;; Bots never connect here — watch them via official character state.

(require json
         net/rfc6455
         racket/async-channel
         racket/set)

(provide hub-alive?
         start-visualizer-hub!
         stop-visualizer-hub!
         visualizer-publish!
         set-visualizer-command-handler!
         session-owns-snapshots?
         make-protocol-message
         world-snapshot-message
         bot-decision-message
         market-signal-message
         session-status-message-proto
         action-result-message-proto
         account-logs-message-proto
         select-maps-for-visualizer
         summarize-maps-for-visualizer)

(define default-port 8787)

(define hub-thread #f)
(define hub-stopper #f)
(define hub-port #f)
(define clients (mutable-set))
(define clients-sema (make-semaphore 1))
(define publish-ch (make-async-channel))
(define command-handler #f)

(define (set-visualizer-command-handler! handler)
  (set! command-handler handler))

(define session-owns-snapshots? (make-parameter #f))

(define (iso-now)
  (define t (seconds->date (current-seconds) #f))
  (format "~a-~a-~aT~a:~a:~aZ"
          (date-year t)
          (~a (date-month t) #:width 2 #:pad-string "0" #:align 'right)
          (~a (date-day t) #:width 2 #:pad-string "0" #:align 'right)
          (~a (date-hour t) #:width 2 #:pad-string "0" #:align 'right)
          (~a (date-minute t) #:width 2 #:pad-string "0" #:align 'right)
          (~a (date-second t) #:width 2 #:pad-string "0" #:align 'right)))

(define (make-protocol-message type data)
  (hasheq 'type type
          'timestamp (iso-now)
          'data data))

(define (world-snapshot-message #:maps [maps '()]
                                #:characters [characters '()]
                                #:routes [routes '()]
                                #:events [events '()]
                                #:raids [raids '()])
  (make-protocol-message
   "world.snapshot"
   (hasheq 'maps maps
           'characters characters
           'routes routes
           'events events
           'raids raids)))

(define (bot-decision-message character action reason #:target [target #f])
  (define data
    (hasheq 'character character
            'action (if (symbol? action) (symbol->string action) (format "~a" action))
            'reason reason))
  (make-protocol-message
   "bot.decision"
   (if target (hash-set data 'target target) data)))

(define (session-status-message-proto #:authenticated [authenticated #f]
                                      #:selected [selected #f]
                                      #:characters [characters '()]
                                      #:error [error #f])
  (make-protocol-message
   "session.status"
   (hasheq 'authenticated authenticated
           'selected selected
           'characters characters
           'error error)))

(define (action-result-message-proto character action
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

(define (account-logs-message-proto entries)
  (make-protocol-message
   "account.logs"
   (hasheq 'entries (if (list? entries) entries '()))))

(define (market-signal-message code spread score #:x [x #f] #:y [y #f] #:layer [layer #f])
  (define data (hasheq 'code code 'spread spread 'score score))
  (define with-pos
    (cond
      [(and x y)
       (hash-set* data
                  'x x
                  'y y
                  'layer (or layer "overworld"))]
      [else data]))
  (make-protocol-message "market.signal" with-pos))

(define interesting-content-types
  '("monster" "resource" "bank" "grand_exchange" "workshop" "tasks_master" "npc"))

(define (map-content-hash m)
  (define interactions (hash-ref m 'interactions #f))
  (and (hash? interactions) (hash-ref interactions 'content #f)))

(define (map-has-interesting-content? m)
  (define content (map-content-hash m))
  (and (hash? content)
       (member (hash-ref content 'type #f) interesting-content-types)))

(define (point-layer p)
  (if (hash? p) (hash-ref p 'layer "overworld") "overworld"))

(define (point-xy p)
  (values (if (hash? p) (hash-ref p 'x 0) 0)
          (if (hash? p) (hash-ref p 'y 0) 0)))

(define (near-any-focus? m focuses #:radius [radius 12])
  (define layer (hash-ref m 'layer "overworld"))
  (define mx (hash-ref m 'x 0))
  (define my (hash-ref m 'y 0))
  (for/or ([p focuses] #:when (hash? p))
    (and (equal? layer (point-layer p))
         (let-values ([(px py) (point-xy p)])
           (<= (+ (abs (- mx px)) (abs (- my py))) radius)))))

(define (map-visual-priority m focuses)
  (define content (map-content-hash m))
  (define type (and (hash? content) (hash-ref content 'type #f)))
  (+ (if (near-any-focus? m focuses) 1000 0)
     (cond
       [(equal? type "grand_exchange") 80]
       [(equal? type "bank") 70]
       [(equal? type "monster") 60]
       [(equal? type "resource") 50]
       [(member type interesting-content-types) 40]
       [else 0])))

(define (summarize-one-map m)
  (define interactions (hash-ref m 'interactions #f))
  (define content (and (hash? interactions) (hash-ref interactions 'content #f)))
  (hasheq 'map_id (hash-ref m 'map_id #f)
          'layer (hash-ref m 'layer "overworld")
          'x (hash-ref m 'x 0)
          'y (hash-ref m 'y 0)
          'skin (hash-ref m 'skin "forest_1")
          'content_type (if (hash? content) (hash-ref content 'type "terrain") "terrain")
          'content_code (if (hash? content) (hash-ref content 'code "") "")
          'interactions (if interactions interactions #hasheq())))

(define (select-maps-for-visualizer maps
                                    #:focuses [focuses '()]
                                    #:limit [limit 400])
  (define items (filter hash? (if (list? maps) maps '())))
  (define ranked
    (sort items >
          #:key (lambda (m) (map-visual-priority m focuses))))
  (define selected
    (cond
      [(null? focuses)
       (define interesting (filter map-has-interesting-content? ranked))
       (define rest (filter (lambda (m) (not (map-has-interesting-content? m))) ranked))
       (append interesting rest)]
      [else ranked]))
  (if (> (length selected) limit)
      (take selected limit)
      selected))

(define (summarize-maps-for-visualizer maps
                                       #:focuses [focuses '()]
                                       #:limit [limit 400])
  (map summarize-one-map
       (select-maps-for-visualizer maps #:focuses focuses #:limit limit)))

(define (with-clients thunk)
  (call-with-semaphore clients-sema thunk))

(define (add-client! c)
  (with-clients (lambda () (set-add! clients c))))

(define (remove-client! c)
  (with-clients (lambda () (set-remove! clients c))))

(define (snapshot-clients)
  (with-clients (lambda () (set->list clients))))

(define (connection-handler c _state)
  (add-client! c)
  (printf "3D client connected (~a total).\n" (length (snapshot-clients)))
  (flush-output)
  (let loop ()
    (define msg (ws-recv c #:payload-type 'text))
    (cond
      [(eof-object? msg)
       (remove-client! c)
       (with-handlers ([exn:fail? void]) (ws-close! c))
       (printf "3D client disconnected (~a total).\n" (length (snapshot-clients)))
       (flush-output)]
      [else
       (when command-handler
         (with-handlers ([exn:fail?
                          (lambda (exn)
                            (printf "3D bridge command error: ~a\n" (exn-message exn))
                            (flush-output))])
           (command-handler msg)))
       (loop)])))

(define (publisher-loop)
  (let loop ()
    (define payload (async-channel-get publish-ch))
    (unless (eq? payload 'stop)
      (define text (if (string? payload) payload (jsexpr->string payload)))
      (for ([c (snapshot-clients)])
        (with-handlers ([exn:fail?
                         (lambda (_exn)
                           (remove-client! c)
                           (with-handlers ([exn:fail? void])
                             (ws-close! c)))])
          (ws-send! c text)))
      (loop))))

(define (hub-alive?)
  (and hub-thread (thread-running? hub-thread)))

(define (start-visualizer-hub! #:port [port default-port]
                               #:enabled? [enabled? #t])
  (cond
    [(not enabled?)
     (printf "3D bridge disabled.\n")
     (flush-output)
     #f]
    [(hub-alive?)
     (printf "3D bridge already running on ~a.\n" (or hub-port port))
     (flush-output)
     #t]
    [else
     (when (or hub-thread hub-stopper)
       (with-handlers ([exn:fail? void])
         (stop-visualizer-hub!)))
     (with-handlers
         ([exn:fail?
           (lambda (exn)
             (printf "3D bridge not started: ~a\n" (exn-message exn))
             (flush-output)
             #f)])
       (set! hub-stopper (ws-serve #:port port #:listen-ip "127.0.0.1" connection-handler))
       (set! hub-thread (thread publisher-loop))
       (set! hub-port port)
       (printf "3D bridge listening on ws://127.0.0.1:~a\n" port)
       (flush-output)
       #t)]))

(define (stop-visualizer-hub!)
  (when hub-thread
    (with-handlers ([exn:fail? void])
      (async-channel-put publish-ch 'stop))
    (set! hub-thread #f))
  (when hub-stopper
    (with-handlers ([exn:fail? void])
      (hub-stopper))
    (set! hub-stopper #f))
  (set! hub-port #f)
  (with-clients (lambda () (set-clear! clients)))
  (void))

(define (visualizer-publish! message)
  (when hub-thread
    (async-channel-put publish-ch message)))
