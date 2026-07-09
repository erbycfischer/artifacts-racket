#lang racket

(require rackunit
         json
         racket/file
         net/url
         "../artifacts/config.rkt"
         "../artifacts/http.rkt"
         "../artifacts/lang/runtime.rkt"
         "../artifacts/market.rkt"
         "../artifacts/scheduler.rkt"
         "../artifacts/world.rkt"
         "../artifacts/planner.rkt"
         "../artifacts/runner.rkt"
         "../artifacts/visualizer.rkt")

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

  (test-case "world index tolerates null map content"
    (define empty #hasheq((map_id . "empty")
                          (layer . "main")
                          (x . 0)
                          (y . 0)
                          (interactions . #hasheq((content . null)))))
    (define index (build-world-index (list empty)))
    (check-equal? (length (world-index-maps index)) 1)
    (check-false (nearest-content-map index empty "monster" "chicken")))

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
    (check-equal? (api-error-status npc-sell-error) 452))

  (test-case "planner rests low HP and picks safe monsters"
    (define char
      #hasheq((name . "A")
              (level . 3)
              (hp . 10)
              (max_hp . 100)
              (cooldown . 0)
              (inventory_max_items . 20)
              (inventory . ())
              (x . 0)
              (y . 0)
              (layer . "overworld")
              (map_id . 1)
              (mining_level . 1)
              (interactions . #hasheq((content . #f)))))
    (define world (build-world-index
                   (list #hasheq((map_id . 1) (layer . "overworld") (x . 0) (y . 0)
                                 (interactions . #hasheq((content . #f))))
                         #hasheq((map_id . 2) (layer . "overworld") (x . 1) (y . 0)
                                 (interactions . #hasheq((content . #hasheq((type . "monster")
                                                                             (code . "chicken")))))))))
    (define plan (plan-character char world #:role 'combat #:monsters (list #hasheq((code . "chicken") (level . 1)))))
    (check-equal? (planned-action-name plan) 'rest)
    (define healthy (hash-set* char 'hp 90 'interactions #hasheq((content . #hasheq((type . "monster") (code . "chicken"))))))
    (define fight-plan (plan-character healthy world #:role 'combat #:monsters (list #hasheq((code . "chicken") (level . 1))
                                                                                    #hasheq((code . "boss") (level . 40)))))
    (check-equal? (planned-action-name fight-plan) 'fight))

  (test-case "bind-bot-to-account maps roles onto live character names"
    (define bot
      (bot-spec 'apex
                (list (character-spec 'fighter 'combat '())
                      (character-spec 'miner 'mining '())
                      (strategy-spec 's '()))))
    (define live (list #hasheq((name . "Alpha")) #hasheq((name . "Beta"))))
    (define bound (bind-bot-to-account bot live))
    (check-equal? (map character-spec-name (bot-characters bound)) '(Alpha Beta))
    (check-equal? (map character-spec-role (bot-characters bound)) '(combat mining)))

  (test-case "visualizer protocol helpers stay Godot-independent"
    (define decision (bot-decision-message "alice" 'fight "best_safe_xp"))
    (check-equal? (hash-ref decision 'type) "bot.decision")
    (check-equal? (hash-ref (hash-ref decision 'data) 'character) "alice")
    (define snap
      (world-snapshot-message
       #:maps (list #hasheq((map_id . "a") (layer . "overworld") (x . 0) (y . 0)))
       #:characters (list #hasheq((name . "alice") (x . 0) (y . 0) (layer . "overworld")))))
    (check-equal? (hash-ref snap 'type) "world.snapshot")
    (check-equal? (length (hash-ref (hash-ref snap 'data) 'maps)) 1)
    (define summarized
      (summarize-maps-for-visualizer
       (list #hasheq((map_id . 1)
                     (layer . "overworld")
                     (x . 2)
                     (y . 3)
                     (interactions . #hasheq((content . #hasheq((type . "monster")
                                                                 (code . "chicken")))))))))
    (check-equal? (hash-ref (car summarized) 'content_type) "monster")
    (check-equal? (hash-ref (car summarized) 'content_code) "chicken"))

  (test-case "route-for-plan builds move overlays"
    (define world
      (build-world-index
       (list #hasheq((map_id . 1) (layer . "overworld") (x . 0) (y . 0))
             #hasheq((map_id . 2) (layer . "overworld") (x . 3) (y . 1)))))
    (define char #hasheq((name . "miner") (layer . "overworld") (x . 0) (y . 0)))
    (define plan (planned-action 'move #hasheq((map_id . 2)) "go" 1))
    (define route (route-for-plan "miner" char plan world))
    (check-equal? (hash-ref route 'character) "miner")
    (check-equal? (length (hash-ref route 'points)) 2)
    (check-equal? (hash-ref (cadr (hash-ref route 'points)) 'x) 3)
    (check-false (route-for-plan "miner" char (planned-action 'fight #hasheq() "no" 1) world)))

  (test-case "market signal message carries score fields"
    (define signal (market-signal-message "iron_ore" 7 0.82 #:x 0 #:y 1))
    (check-equal? (hash-ref signal 'type) "market.signal")
    (check-equal? (hash-ref (hash-ref signal 'data) 'code) "iron_ore")
    (check-equal? (hash-ref (hash-ref signal 'data) 'spread) 7)
    (check-equal? (hash-ref (hash-ref signal 'data) 'score) 0.82))


  (test-case "score-spread rewards deeper books"
    (define thin-buys (list #hasheq((type . "buy") (price . 20) (quantity . 1))))
    (define thin-sells (list #hasheq((type . "sell") (price . 10) (quantity . 1))))
    (define deep-buys (list #hasheq((type . "buy") (price . 20) (quantity . 40))))
    (define deep-sells (list #hasheq((type . "sell") (price . 10) (quantity . 40))))
    (define thin (score-spread thin-buys thin-sells))
    (define deep (score-spread deep-buys deep-sells))
    (check-true (number? thin))
    (check-true (number? deep))
    (check-true (>= deep thin))
    (check-false (score-spread thin-buys '())))


  (test-case "ge-anchor-point finds grand_exchange tile"
    (define world
      (build-world-index
       (list #hasheq((map_id . 1) (layer . "overworld") (x . 0) (y . 0)
                     (interactions . #hasheq((content . #hasheq((type . "monster") (code . "chicken"))))))
             #hasheq((map_id . 9) (layer . "overworld") (x . 4) (y . 7)
                     (interactions . #hasheq((content . #hasheq((type . "grand_exchange") (code . "grand_exchange")))))))))
    (define anchor (ge-anchor-point world #:from #hasheq((layer . "overworld") (x . 0) (y . 0))))
    (check-equal? (hash-ref anchor 'x) 4)
    (check-equal? (hash-ref anchor 'y) 7)
    (check-equal? (hash-ref anchor 'layer) "overworld")
    (check-false (ge-anchor-point (build-world-index '()) #:from #hasheq((x . 0) (y . 0)))))


  (test-case "encyclopedia cache round-trip"
    (define dir (make-temporary-file "artifacts-cache-~a" 'directory))
    (putenv "ARTIFACTS_CACHE_DIR" (path->string dir))
    (putenv "ARTIFACTS_ENCYCLOPEDIA_CACHE_SECONDS" "3600")
    (define sample #hasheq((monsters . (#hasheq((code . "chicken"))))
                           (resources . ())
                           (items . ())))
    (define path (build-path dir "encyclopedia.json"))
    (call-with-output-file path (lambda (out) (write-json sample out)) #:exists 'replace)
    (define loaded (load-encyclopedia #:config missing-token-config #:use-cache? #t))
    (check-equal? (hash-ref (car (hash-ref loaded 'monsters)) 'code) "chicken")
    (delete-directory/files dir))


  (test-case "select-maps-for-visualizer prefers focus and content"
    (define maps
      (list #hasheq((map_id . 1) (layer . "overworld") (x . 0) (y . 0) (skin . "forest")
                    (interactions . #hasheq()))
            #hasheq((map_id . 2) (layer . "overworld") (x . 50) (y . 50) (skin . "forest")
                    (interactions . #hasheq((content . #hasheq((type . "monster") (code . "chicken"))))))
            #hasheq((map_id . 3) (layer . "overworld") (x . 1) (y . 1) (skin . "forest")
                    (interactions . #hasheq()))))
    (define focused
      (select-maps-for-visualizer maps
                                  #:focuses (list #hasheq((layer . "overworld") (x . 0) (y . 0)))
                                  #:limit 2))
    (check-equal? (length focused) 2)
    (check-equal? (hash-ref (car focused) 'map_id) 1)
    (define no-focus (select-maps-for-visualizer maps #:limit 1))
    (check-equal? (hash-ref (car no-focus) 'map_id) 2))

  (test-case "world cache round-trip"
    (define dir (make-temporary-file "artifacts-world-cache-~a" 'directory))
    (putenv "ARTIFACTS_CACHE_DIR" (path->string dir))
    (putenv "ARTIFACTS_WORLD_CACHE_SECONDS" "3600")
    (define sample
      (list #hasheq((map_id . 1) (layer . "overworld") (x . 0) (y . 0))))
    (define path (build-path dir "world-maps.json"))
    (call-with-output-file path (lambda (out) (write-json sample out)) #:exists 'replace)
    (define world (load-world-index #:config missing-token-config #:use-cache? #t))
    (check-equal? (length (world-index-maps world)) 1)
    (check-equal? (hash-ref (car (world-index-maps world)) 'map_id) 1)
    (delete-directory/files dir))


  (test-case "suggested-wait-seconds clamps to bounds"
    (define jobs
      (list (make-job #:character 'a #:action 'wait #:ready-at 100 #:priority 0)
            (make-job #:character 'b #:action 'wait #:ready-at 5 #:priority 0)))
    (check-equal? (soonest-ready-at jobs 0) 5)
    (check-equal? (suggested-wait-seconds jobs #:now 0 #:min-seconds 1 #:max-seconds 15 #:default-seconds 2)
                  5)
    (check-equal? (suggested-wait-seconds jobs #:now 0 #:min-seconds 1 #:max-seconds 3 #:default-seconds 2)
                  3)
    (check-equal? (suggested-wait-seconds '() #:now 0 #:default-seconds 2) 2))

  (test-case "cooldown-remaining reads cooldown field"
    (check-equal? (cooldown-remaining #hasheq((cooldown . 0))) 0)
    (check-true (> (cooldown-remaining #hasheq((cooldown . 8))) 0))
    (check-true (cooldown-ready? #hasheq((cooldown . 0))))
    (check-false (cooldown-ready? #hasheq((cooldown . 3)))))

  (test-case "suggested-loop-sleep respects cooling characters"
    (define chars
      (list #hasheq((name . "a") (cooldown . 0))
            #hasheq((name . "b") (cooldown . 9))))
    (define wait (suggested-loop-sleep chars #:base-seconds 2 #:min-seconds 1 #:max-seconds 15))
    (check-true (>= wait 2))
    (check-true (<= wait 15)))


)
