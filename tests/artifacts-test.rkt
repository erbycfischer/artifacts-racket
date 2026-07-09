#lang racket

(require rackunit
         net/url
         "../artifacts/config.rkt"
         "../artifacts/http.rkt"
         "../artifacts/lang/runtime.rkt"
         "../artifacts/market.rkt"
         "../artifacts/scheduler.rkt"
         "../artifacts/world.rkt")

(define test-config
  (artifacts-config "https://api.artifactsmmo.com/"
                    "wss://realtime.artifactsmmo.com"
                    "TEST_TOKEN"))

(define missing-token-config
  (artifacts-config "https://api.artifactsmmo.com"
                    "wss://realtime.artifactsmmo.com"
                    #f))

(define (capture-api-error thunk)
  (with-handlers ([exn:fail:artifacts-api?
                   (lambda (exn) (exn:fail:artifacts-api-error exn))])
    (thunk)
    #f))

(module+ test
  (test-case "request-url builds encoded query strings"
    (define url
      (url->string
       (request-url test-config
                    "/maps"
                    '((page . 2) (size . 10) (code . "iron ore")))))
    (check-true (regexp-match? #px"^https://api\\.artifactsmmo\\.com/maps\\?" url))
    (check-true (regexp-match? #px"page=2" url))
    (check-true (regexp-match? #px"size=10" url))
    (check-true (regexp-match? #px"code=iron\\+ore|code=iron%20ore" url)))

  (test-case "request-headers adds bearer auth"
    (check-equal? (request-headers test-config #:auth? #t)
                  '("Accept: application/json"
                    "Content-Type: application/json"
                    "Authorization: Bearer TEST_TOKEN")))

  (test-case "missing auth raises a structured 452 error"
    (define error
      (capture-api-error
       (lambda ()
         (request-headers missing-token-config #:auth? #t))))
    (check-true (api-error? error))
    (check-equal? (api-error-status error) 452)
    (check-equal? (api-error-code error) 452))

  (test-case "api-error-from-response preserves retry and cooldown details"
    (define error
      (api-error-from-response
       499
       #hasheq((retry-after . "12"))
       #hasheq((error . #hasheq((code . 499)
                                (message . "Cooldown active.")
                                (data . #hasheq((cooldown_expiration . "2026-07-08T00:00:00Z"))))))))
    (check-equal? (api-error-code error) 499)
    (check-equal? (api-error-retry-after error) "12")
    (check-equal? (api-error-cooldown-until error) "2026-07-08T00:00:00Z"))

  (test-case "world index finds nearest content"
    (define start #hasheq((map_id . "start") (layer . "main") (x . 0) (y . 0)))
    (define near #hasheq((map_id . "near")
                         (layer . "main")
                         (x . 1)
                         (y . 0)
                         (interactions . #hasheq((content . #hasheq((type . "monster")
                                                                     (code . "chicken")))))))
    (define far #hasheq((map_id . "far")
                        (layer . "main")
                        (x . 5)
                        (y . 5)
                        (interactions . #hasheq((content . #hasheq((type . "monster")
                                                                    (code . "chicken")))))))
    (define index (build-world-index (list start far near)))
    (check-equal? (hash-ref (nearest-content-map index start "monster" "chicken") 'map_id)
                  "near"))

  (test-case "market helpers score spreads"
    (define buys (list #hasheq((price . 11)) #hasheq((price . 15))))
    (define sells (list #hasheq((price . 9)) #hasheq((price . 12))))
    (check-equal? (best-buy-price buys) 15)
    (check-equal? (best-sell-price sells) 9)
    (check-equal? (order-spread buys sells) 6)
    (check-true (profitable-spread? buys sells #:minimum-margin 5)))

  (test-case "scheduler returns ready jobs by priority"
    (define jobs
      (list (make-job #:character 'a #:action 'gather #:ready-at 0 #:priority 1)
            (make-job #:character 'b #:action 'fight #:ready-at 20 #:priority 99)
            (make-job #:character 'c #:action 'rest #:ready-at 0 #:priority 3)))
    (check-equal? (map job-character (next-ready-jobs jobs 10))
                  '(c a)))

  (test-case "#lang runtime validates actions and dispatches authenticated actions"
    (check-true (known-action? 'gather))
    (check-true (known-action? 'npc-buy))
    (check-true (known-action? 'npc-sell))
    (check-exn #px"unknown Artifacts action"
               (lambda () (action 'not-real)))
    (define spec (goal 'safe-xp (action 'rest)))
    (check-equal? (goal-spec-target spec) 'safe-xp)
    (define error
      (capture-api-error
       (lambda ()
         (execute-action "alice" (action 'rest) #:config missing-token-config))))
    (check-equal? (api-error-status error) 452)
    (define npc-buy-error
      (capture-api-error
       (lambda ()
         (execute-action "alice"
                         (action 'npc-buy #hasheq((code . "small_health_potion") (quantity . 1)))
                         #:config missing-token-config))))
    (check-equal? (api-error-status npc-buy-error) 452)
    (define npc-sell-error
      (capture-api-error
       (lambda ()
         (execute-action "alice"
                         (action 'npc-sell #hasheq((code . "small_health_potion") (quantity . 1)))
                         #:config missing-token-config))))
    (check-equal? (api-error-status npc-sell-error) 452)))
