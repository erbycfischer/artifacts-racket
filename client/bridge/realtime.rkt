#lang racket

;; Official Artifacts realtime WebSocket ingest.
;; Prefer REST session polling for own characters; use realtime for
;; online_characters / events when ARTIFACTS_REALTIME=1.

(require json
         net/rfc6455
         net/url
         "../../artifacts/config.rkt")

(provide realtime-enabled?
         realtime-url
         realtime-online-characters
         set-realtime-online-handler!
         start-realtime-ingest!
         stop-realtime-ingest!)

(define ingest-thread #f)
(define ingest-conn #f)
(define ingest-stop? #f)
(define online-characters '())
(define online-sema (make-semaphore 1))
(define online-handler #f)
(define message-handler #f)

(define default-subscriptions
  '("online_characters"
    "event_spawn"
    "event_removed"
    "raid_started"
    "raid_ended"
    "account_log"))

(define (realtime-enabled?)
  (define v (getenv "ARTIFACTS_REALTIME"))
  (and v (member v '("1" "true" "TRUE" "yes" "YES")) #t))

(define (realtime-url #:config [config (current-config)])
  (artifacts-config-realtime-url config))

(define (realtime-online-characters)
  (call-with-semaphore online-sema (lambda () online-characters)))

(define (set-realtime-online-handler! handler)
  (set! online-handler handler))

(define (set-online-characters! chars)
  (call-with-semaphore online-sema
                       (lambda ()
                         (set! online-characters (if (list? chars) chars '()))))
  (when online-handler
    (with-handlers ([exn:fail? void])
      (online-handler (realtime-online-characters)))))

(define (as-list data)
  (cond
    [(list? data) data]
    [(hash? data) (list data)]
    [else '()]))

(define (notification-type msg)
  (and (hash? msg)
       (or (hash-ref msg 'type #f)
           (hash-ref msg 'notification #f)
           (hash-ref msg 'event #f))))

(define (notification-data msg)
  (cond
    [(not (hash? msg)) '()]
    [(hash-has-key? msg 'data) (hash-ref msg 'data)]
    [(hash-has-key? msg 'payload) (hash-ref msg 'payload)]
    [else msg]))

(define (handle-realtime-message! raw)
  (define msg
    (cond
      [(string? raw)
       (with-handlers ([exn:fail? (lambda (_exn) #f)])
         (string->jsexpr raw))]
      [(hash? raw) raw]
      [else #f]))
  (when (hash? msg)
    (when message-handler
      (with-handlers ([exn:fail? void])
        (message-handler msg)))
    (define type (notification-type msg))
    (define data (notification-data msg))
    (when (member type '("online_characters" "online-characters"))
      (set-online-characters! (as-list data)))))

(define (auth-payload token #:subscriptions [subscriptions default-subscriptions])
  (hasheq 'token token
          'subscriptions subscriptions))

(define (connect-and-loop! config)
  (define token (artifacts-config-token config))
  (cond
    [(not (and (string? token) (regexp-match? #px"\\S" token)))
     (printf "Realtime ingest skipped: no token.\n")
     (flush-output)
     #f]
    [else
     (define url-str (realtime-url #:config config))
     (printf "Realtime connecting to ~a ...\n" url-str)
     (flush-output)
     (define c
       (with-handlers ([exn:fail?
                        (lambda (exn)
                          (printf "Realtime connect failed: ~a\n" (exn-message exn))
                          (flush-output)
                          #f)])
         (ws-connect (string->url url-str))))
     (cond
       [(not c) #f]
       [else
        (set! ingest-conn c)
        (ws-send! c (jsexpr->string (auth-payload token)))
        (printf "Realtime subscribed (online_characters + events).\n")
        (flush-output)
        (let loop ()
          (unless ingest-stop?
            (define msg
              (with-handlers ([exn:fail? (lambda (_exn) eof)])
                (ws-recv c #:payload-type 'text)))
            (cond
              [(or (eof-object? msg) (eq? msg eof))
               (printf "Realtime connection closed.\n")
               (flush-output)]
              [else
               (handle-realtime-message! msg)
               (loop)])))
        (with-handlers ([exn:fail? void]) (ws-close! c))
        (set! ingest-conn #f)
        #t])]))

(define (start-realtime-ingest! #:config [config (current-config)]
                                #:on-message [on-message #f]
                                #:on-online [on-online #f])
  (when on-online
    (set-realtime-online-handler! on-online))
  (when on-message
    (set! message-handler on-message))
  (cond
    [(not (realtime-enabled?))
     #f]
    [(and ingest-thread (thread-running? ingest-thread))
     #t]
    [else
     (set! ingest-stop? #f)
     (set! ingest-thread
           (thread
            (lambda ()
              (let retry ()
                (unless ingest-stop?
                  (connect-and-loop! config)
                  (unless ingest-stop?
                    (sleep 5)
                    (retry)))))))
     #t]))

(define (stop-realtime-ingest!)
  (set! ingest-stop? #t)
  (when ingest-conn
    (with-handlers ([exn:fail? void])
      (ws-close! ingest-conn))
    (set! ingest-conn #f))
  (set! ingest-thread #f)
  (set! message-handler #f)
  (set-online-characters! '())
  (void))
