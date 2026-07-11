#lang racket

(require rackunit
         json
         racket/set
         racket/file
         net/url
         "../artifacts/config.rkt"
         "../artifacts/http.rkt"
         (except-in "../artifacts/lang/runtime.rkt" when-low-hp when-inventory-full when-on-content)
        "../artifacts/lang/helpers.rkt"
        "../artifacts/lang/realtime.rkt"
        "../artifacts/dsl-forms.rkt"
         "../artifacts/market.rkt"
         "../artifacts/scheduler.rkt"
         "../artifacts/world.rkt"
         "../artifacts/planner.rkt"
         "../artifacts/combat.rkt"
         "../artifacts/runner.rkt")

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
                (list (character-spec 'fighter 'combat #f '())
                      (character-spec 'miner 'mining #f '())
                      (strategy-spec 's '()))))
    (define live (list #hasheq((name . "Alpha")) #hasheq((name . "Beta"))))
    (define bound (bind-bot-to-account bot live))
    (check-equal? (map character-spec-tag (bot-characters bound)) '(fighter miner))
    (check-equal? (map character-spec-account-name (bot-characters bound)) '("Alpha" "Beta"))
    (check-equal? (map character-spec-role (bot-characters bound)) '(combat mining)))

  (test-case "bind-bot-to-account prefers matching live names"
    (define bot
      (bot-spec 'apex
                (list (character-spec 'miner 'mining #f '())
                      (character-spec 'fighter 'combat #f '())
                      (strategy-spec 's '()))))
    (define live
      (list #hasheq((name . "fighter"))
            #hasheq((name . "miner"))))
    (define bound (bind-bot-to-account bot live))
    (check-equal? (map character-spec-tag (bot-characters bound)) '(miner fighter))
    (check-equal? (map character-spec-account-name (bot-characters bound)) '("miner" "fighter"))
    (check-equal? (map character-spec-role (bot-characters bound)) '(mining combat)))

  (test-case "bind-bot-to-account honors explicit #:as names"
    (define bot
      (bot-spec 'apex
                (list (character-spec 'fighter 'combat "IronMike" '())
                      (character-spec 'miner 'mining "OreBot42" '())
                      (strategy-spec 's '()))))
    (define live
      (list #hasheq((name . "IronMike"))
            #hasheq((name . "OreBot42"))))
    (define bound (bind-bot-to-account bot live))
    (check-equal? (map character-spec-tag (bot-characters bound)) '(fighter miner))
    (check-equal? (map character-spec-live-name (bot-characters bound)) '("IronMike" "OreBot42")))

  (test-case "missing-bot-character-names uses live names from tags or #:as"
    (define bot
      (bot-spec 'apex
                (list (character-spec 'fighter 'combat #f '())
                      (character-spec 'miner 'mining "OreBot42" '())
                      (strategy-spec 's '()))))
    (define missing
      (missing-bot-character-names bot
                                 (list #hasheq((name . "fighter"))
                                       #hasheq((name . "Alpha")))))
    (check-equal? missing '("OreBot42")))

  (test-case "character name and skin validation"
    (check-not-false (valid-character-name? "fighter"))
    (check-not-false (valid-character-name? 'miner))
    (check-false (valid-character-name? "ab"))
    (check-not-false (valid-character-skin? 'men1))
    (check-not-false (valid-character-skin? "women3"))
    (check-false (valid-character-skin? "dragon1")))

  (test-case "action builders and pipeline goals"
    (define spec
      (goal 'ore-loop
            (gather)
            (deposit-all)
            (buy 'copper_ore 5)))
    (check-equal? (goal-spec-target spec) 'ore-loop)
    (check-equal? (length (goal-spec-actions spec)) 3)
    (check-equal? (action-spec-name (car (goal-spec-actions spec))) 'gather)
    (check-equal? (action-spec-name (cadr (goal-spec-actions spec))) 'bank-deposit-item)
    (define buy-action (last (goal-spec-actions spec)))
    (check-equal? (action-spec-name buy-action) 'npc-buy)
    (define starter
      (bot-spec 'starter
                (list (character-spec 'miner 'mining #f
                                      (list (goal 'bootstrap (gather) (deposit-all))))
                      (strategy-spec 's '()))))
    (check-equal? (length (goal-preferred-actions (car (bot-characters starter)))) 2))

  (test-case "planner follows preferred goal actions"
    (define char
      #hasheq((name . "miner")
              (level . 5)
              (hp . 90)
              (max_hp . 100)
              (cooldown . 0)
              (inventory_max_items . 20)
              (inventory . ())
              (x . 0)
              (y . 0)
              (layer . "overworld")
              (map_id . 1)
              (mining_level . 5)
              (interactions . #hasheq((content . #f)))))
    (define world (build-world-index
                   (list #hasheq((map_id . 1) (layer . "overworld") (x . 0) (y . 0)
                                 (interactions . #hasheq((content . #f))))
                         #hasheq((map_id . 2) (layer . "overworld") (x . 1) (y . 0)
                                 (interactions . #hasheq((content . #hasheq((type . "resource")
                                                                             (code . "copper_rocks")))))))))
    (define preferred (list (gather) (deposit-all)))
    (define plan (plan-character char world
                                 #:role 'mining
                                 #:resources (list #hasheq((code . "copper_rocks") (level . 1) (skill . "mining")))
                                 #:preferred preferred))
    (check-equal? (planned-action-name plan) 'move))

  (test-case "planner crafts at workshop when preferred"
    (define char
      #hasheq((name . "smith")
              (level . 3)
              (hp . 90)
              (max_hp . 100)
              (cooldown . 0)
              (inventory_max_items . 20)
              (inventory . ())
              (x . 0)
              (y . 0)
              (layer . "overworld")
              (map_id . 10)
              (interactions . #hasheq((content . #hasheq((type . "workshop") (code . "workshop")))))))
    (define world (build-world-index
                   (list #hasheq((map_id . 10) (layer . "overworld") (x . 0) (y . 0)
                                 (interactions . #hasheq((content . #hasheq((type . "workshop") (code . "workshop")))))))))
    (define plan (plan-character char world
                                 #:role 'crafter
                                 #:preferred (list (craft 'copper_bar 1))))
    (check-equal? (planned-action-name plan) 'craft))

  (test-case "create-character requires auth"
    (define error
      (capture-api-error
       (lambda ()
         (create-character "fighter" #:config missing-token-config))))
    (check-equal? (api-error-status error) 452))

  (test-case "route-for-plan builds move paths"
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
    (check-false (cooldown-ready? #hasheq((cooldown . 3))))

  (test-case "cooldown-from-response extracts seconds from a live response"
    (define response
      #hasheq((data . #hasheq((name . "A")
                              (cooldown . 7)
                              (cooldown_expiration . 1760000000)))))
    (check-equal? (cooldown-from-response response) 7)
    ;; A response with no cooldown data reads as ready (0), not an error.
    (check-equal? (cooldown-from-response #hasheq((data . #hasheq((name . "A"))))) 0)
    (check-equal? (cooldown-from-response #f) 0)
    (check-equal? (cooldown-from-response #hasheq()) 0))

  (test-case "update-character-cooldown sets cooldown_expiration so cooldown-remaining matches"
    (define char #hasheq((name . "A") (cooldown . 0)))
    (define response
      #hasheq((data . #hasheq((name . "A")
                              (cooldown . 11)
                              (cooldown_expiration . 1760000000)))))
    (define now 1760000000)
    (define updated (update-character-cooldown char response now))
    ;; cooldown-remaining parses cooldown_expiration (a unix timestamp here).
    (check-equal? (cooldown-remaining updated now) 0)
    ;; With a relative-seconds expiration mislabel, the absolute clock is now+seconds.
    (define rel-response
      #hasheq((data . #hasheq((name . "A")
                              (cooldown . 11)
                              (cooldown_expiration . 11)))))
    (define rel-updated (update-character-cooldown char rel-response now))
    (check-equal? (cooldown-remaining rel-updated now) 11)
    ;; No usable cooldown leaves the character untouched (ready).
    (check-eq? (update-character-cooldown char #hasheq((data . #hasheq((name . "A")))) now) char)
    ;; A non-hash character survives untouched (defensive).
    (check-eq? (update-character-cooldown #f response now) #f))

  (test-case "suggested-loop-sleep reflects an updated cooldown from a live response"
    (define base-char #hasheq((name . "A") (cooldown . 0)))
    (define response
      #hasheq((data . #hasheq((name . "A")
                              (cooldown . 9)
                              (cooldown_expiration . 1760000009)))))
    (define now 1760000000)
    (define cooled (update-character-cooldown base-char response now))
    ;; cooldown-jobs-from-characters builds a wait job with ready-at derived
    ;; from the updated expiration; suggested-loop-sleep should propose a wait
    ;; close to the reported cooldown, clamped to its max bound below.
    (define jobs (cooldown-jobs-from-characters (list cooled) now))
    (check-equal? (job-ready-at (car jobs)) 1760000009)
    (define wait
      (suggested-loop-sleep (list cooled)
                            #:base-seconds 2 #:min-seconds 1 #:max-seconds 15 #:now now))
    (check-true (>= wait 9))
    (check-true (<= wait 15))))

  (test-case "suggested-loop-sleep respects cooling characters"
    (define chars
      (list #hasheq((name . "a") (cooldown . 0))
            #hasheq((name . "b") (cooldown . 9))))
    (define wait (suggested-loop-sleep chars #:base-seconds 2 #:min-seconds 1 #:max-seconds 15))
    (check-true (>= wait 2))
    (check-true (<= wait 15)))

  (test-case "keyword action builders produce correct specs"
    (define b (buy #:code 'copper_ore #:qty 5))
    (check-equal? (action-spec-name b) 'npc-buy)
    (check-equal? (action-spec-payload b)
                  (list (hasheq 'code "copper_ore" 'quantity 5)))
    (define c (craft #:code 'copper_bar #:qty 1))
    (check-equal? (action-spec-name c) 'craft)
    (check-equal? (action-spec-payload c)
                  (list (hasheq 'code "copper_bar" 'quantity 1)))
    (define m (move-to #:x 1 #:y 0))
    (check-equal? (action-spec-name m) 'move)
    (check-equal? (action-spec-payload m)
                  (list (hasheq 'x 1 'y 0)))
    (define s (sell-on-ge #:code 'copper_ore #:qty 5 #:price 10))
    (check-equal? (action-spec-name s) 'grand-exchange-create-sell-order)
    (check-equal? (action-spec-payload s)
                  (list (hasheq 'code "copper_ore" 'quantity 5 'price 10)))
    (define sk (change-skin #:skin 'women3))
    (check-equal? (action-spec-name sk) 'change-skin)
    (check-equal? (action-spec-payload sk)
                  (list (hasheq 'skin "women3"))))

  (test-case "positional action builders still work"
    (check-equal? (action-spec-name (buy 'copper_ore 5)) 'npc-buy)
    (check-equal? (action-spec-name (craft 'copper_bar 1)) 'craft)
    (check-equal? (action-spec-name (move-to 1 0)) 'move)
    (check-equal? (action-spec-name (sell-on-ge 'copper_ore 5 10))
                  'grand-exchange-create-sell-order))

  (test-case "guard struct carries predicate and forms"
    (define g (guard-spec (lambda () #t) (list (gather))))
    (check-true (guard? g))
    (check-pred procedure? (guard-spec-predicate g))
    (check-equal? (length (guard-spec-forms g)) 1))

  (test-case "true guard contributes its forms, false contributes none"
    (define guarded-true
      (character-spec 'smith 'crafter #f
                      (list (guard #:when #t
                                  (pipeline 'refine (craft #:code 'copper_bar #:qty 1))
                                  (deposit-all)))))
    (check-equal? (length (goal-preferred-actions guarded-true)) 2)
    (define guarded-false
      (character-spec 'smith 'crafter #f
                      (list (guard #:when #f
                                  (pipeline 'refine (craft #:code 'copper_bar #:qty 1))
                                  (deposit-all)))))
    (check-equal? (goal-preferred-actions guarded-false) '())
    ;; Predicate thunks let the decision happen at evaluation time; they
    ;; receive the live character so character-conditioned guards can read it.
    (define flips (guard-spec (lambda (char) (not #f)) (list (rest))))
    (check-equal? (expand-guards (list flips) #f) (list (rest))))

  (test-case "loop and routine still build goal specs"
    (define lp (loop 'mine-forever (gather) (deposit-all)))
    (check-true (goal-spec? lp))
    (check-equal? (goal-spec-target lp) 'mine-forever)
    (check-equal? (length (goal-spec-actions lp)) 2)
    (define rt (routine 'patrol (fight) (rest)))
    (check-true (goal-spec? rt))
    (check-equal? (goal-spec-target rt) 'patrol)
    (check-equal? (length (goal-spec-actions rt)) 2))

  (test-case "repeat expands to n copies of the body"
    (define twice (repeat 2 (gather) (deposit-all)))
    (check-equal? (length twice) 4)
    (check-equal? (map action-spec-name twice)
                  '(gather bank-deposit-item gather bank-deposit-item)))


  (test-case "when-low-hp answers against hp ratio"
    (define hurt (hasheq 'hp 40 'max_hp 100))
    (define healthy (hasheq 'hp 80 'max_hp 100))
    (check-true (when-low-hp hurt 0.5))
    (check-true (when-low-hp hurt 0.4))
    (check-false (when-low-hp hurt 0.3))
    (check-false (when-low-hp healthy 0.5))
    (check-false (when-low-hp (hasheq 'hp 0 'max_hp 0) 0.5)))

  (test-case "when-inventory-full answers against capacity minus reserve"
    (define full (hasheq 'inventory_max_items 20 'inventory (list (hasheq 'code "a" 'quantity 20))))
    (define near-full (hasheq 'inventory_max_items 20 'inventory (list (hasheq 'code "a" 'quantity 19))))
    (define roomy (hasheq 'inventory_max_items 20 'inventory (list (hasheq 'code "a" 'quantity 10))))
    (check-true (when-inventory-full full))
    (check-true (when-inventory-full near-full))
    (check-false (when-inventory-full roomy))
    (check-true (when-inventory-full roomy #:reserve 11))
    (check-true (when-inventory-full full #:reserve 0)))

  (test-case "when-on-content answers against the tile under the character"
    (define on-bank (hasheq 'interactions (hasheq 'content (hasheq 'type "bank" 'code "bank"))))
    (define on-resource (hasheq 'interactions (hasheq 'content (hasheq 'type "resource" 'code "copper_rocks"))))
    (define nowhere (hasheq 'interactions (hasheq 'content #f)))
    (check-true (when-on-content on-bank "bank"))
    (check-true (when-on-content on-bank "bank" "bank"))
    (check-false (when-on-content on-bank "bank" "bank_alt"))
    (check-false (when-on-content on-bank "resource"))
    (check-true (when-on-content on-resource "resource" "copper_rocks"))
    (check-false (when-on-content nowhere "bank")))

  (test-case "conditional guard contributes its action only when the condition holds"
    (define hurt-char (hasheq 'hp 30 'max_hp 100 'cooldown 0 'inventory_max_items 20 'inventory (list) 'interactions (hasheq 'content #f)))
    (define healthy-char (hasheq 'hp 90 'max_hp 100 'cooldown 0 'inventory_max_items 20 'inventory (list) 'interactions (hasheq 'content #f)))
    (define low-hp-spec
      (character-spec 'healer 'crafter #f
                      (list (goal 'survive
                                  (guard-spec (lambda (char) (when-low-hp char 0.5))
                                              (list (rest)))))))
    (check-equal? (length (goal-preferred-actions low-hp-spec hurt-char)) 1)
    (check-equal? (action-spec-name (car (goal-preferred-actions low-hp-spec hurt-char))) 'rest)
    (check-equal? (goal-preferred-actions low-hp-spec healthy-char) '())
    (define packed (hasheq 'hp 90 'max_hp 100 'cooldown 0 'inventory_max_items 20 'inventory (list (hasheq 'code "a" 'quantity 20)) 'interactions (hasheq 'content #f)))
    (define light (hasheq 'hp 90 'max_hp 100 'cooldown 0 'inventory_max_items 20 'inventory (list (hasheq 'code "a" 'quantity 5)) 'interactions (hasheq 'content #f)))
    (define packed-spec
      (character-spec 'mule 'crafter #f
                      (list (goal 'haul
                                  (guard-spec (lambda (char) (when-inventory-full char))
                                              (list (deposit-all)))))))
    (check-equal? (length (goal-preferred-actions packed-spec packed)) 1)
    (check-equal? (action-spec-name (car (goal-preferred-actions packed-spec packed)))
                  'bank-deposit-item)
    (check-equal? (goal-preferred-actions packed-spec light) '())
    (define direct (guard-spec (lambda (char) (when-on-content char "bank"))
                               (list (deposit-all))))
    (define on-bank (hasheq 'interactions (hasheq 'content (hasheq 'type "bank" 'code "bank"))))
    (define not-bank (hasheq 'interactions (hasheq 'content #f)))
    (check-equal? (length (expand-guards (list direct) on-bank)) 1)
    (check-equal? (expand-guards (list direct) not-bank) '()))

  (test-case "local-combat-score favors an easier, lower-level monster"
    (define char #hasheq((level . 5) (max_hp . 100) (attack . 20) (defense . 10)))
    (define easy #hasheq((code . "chicken") (level . 1) (hp . 15) (attack . 3) (defense . 1)))
    (define hard #hasheq((code . "dragon") (level . 40) (hp . 500) (attack . 80) (defense . 60)))
    (define easy-score (local-combat-score char easy))
    (define hard-score (local-combat-score char hard))
    (check-true (number? easy-score))
    (check-true (number? hard-score))
    (check-true (> easy-score hard-score))
    ;; A same-level match should sit near the middle of the 0..1 scale.
    (define even #hasheq((code . "peer") (level . 5) (hp . 100) (attack . 20) (defense . 10)))
    (check-true (< (abs (- (local-combat-score char even) 0.5)) 0.25)))

  (test-case "matchup-score falls back to local math without a token"
    ;; A #f config fails before any request (no base-url), so simulate-fight-score
    ;; must absorb the error and degrade to local math rather than propagating it.
    (define char #hasheq((level . 5) (max_hp . 100) (attack . 20) (defense . 10)))
    (define monster #hasheq((code . "chicken") (level . 1) (hp . 15) (attack . 3) (defense . 1)))
    (define local-only (matchup-score char monster #:config #f))
    (check-equal? (hash-ref local-only 'source) 'local)
    (check-true (number? (hash-ref local-only 'score)))
    (check-true (number? (hash-ref local-only 'win-probability)))
    (check-true (string? (hash-ref local-only 'reason)))
    (check-true (> (hash-ref local-only 'score) 0))
    ;; A config with no token must not raise: whether the API is reachable or
    ;; not, simulate-fight-score stays defensive and returns a usable matchup.
    (define result (matchup-score char monster #:config missing-token-config))
    (check-true (number? (hash-ref result 'score)))
    (check-true (string? (hash-ref result 'reason))))

  (test-case "suggest-equipment flags weapons/armor found in inventory"
    (define char
      (hasheq 'inventory
              (list (hasheq 'code "iron_sword" 'quantity 1)
                    (hasheq 'code "wooden_armor" 'quantity 1))))
    (define monster (hasheq 'code "chicken" 'level 1))
    (define equip (suggest-equipment char monster))
    (check-equal? (hash-ref equip 'weapon) "iron_sword")
    (check-equal? (hash-ref equip 'armor) "wooden_armor")
    ;; No relevant gear -> no suggestion.
    (define ungeared (hasheq 'inventory (list (hasheq 'code "apple" 'quantity 5))))
    (check-false (suggest-equipment ungeared monster)))

  (test-case "best-safe-monster skips unwinnable fights unless it's the only option"
    (define char #hasheq((name . "A")
                         (level . 3)
                         (max_hp . 100)
                         (hp . 100)
                         (attack . 5)
                         (defense . 5)
                         (cooldown . 0)
                         (inventory_max_items . 20)
                         (inventory . ())
                         (x . 0)
                         (y . 0)
                         (layer . "overworld")
                         (map_id . 1)
                         (interactions . #hasheq((content . #f)))))
    ;; With a #f config, scoring is local and level-based. A much higher-level
    ;; monster scores below threshold, so the safe (level-1) one wins.
    (define monsters
      (list #hasheq((code . "chicken") (level . 1) (hp . 15) (attack . 3) (defense . 1))
            #hasheq((code . "boss") (level . 40) (hp . 500) (attack . 80) (defense . 60))))
    (define chosen (best-safe-monster char monsters #:config #f))
    (check-equal? (hash-ref chosen 'code) "chicken")
    ;; When the only candidate is hard, the planner still returns it rather
    ;; than leaving the bot with nothing to do.
    (define only-hard (list #hasheq((code . "boss") (level . 40) (hp . 500) (attack . 80) (defense . 60))))
    (check-equal? (hash-ref (best-safe-monster char only-hard #:config #f) 'code) "boss"))

  (test-case "mine-until-full builds a gather + bank-when-full goal"
    (define spec (mine-until-full #:resource 'copper_rocks))
    (check-true (goal-spec? spec))
    (check-equal? (goal-spec-target spec) 'mine-until-full)
    (define actions (goal-spec-actions spec))
    (check-equal? (action-spec-name (car actions)) 'gather)
    (define bank-guard (cadr actions))
    (check-true (guard? bank-guard))
    (check-equal? (action-spec-name (car (guard-spec-forms bank-guard))) 'bank-deposit-item)
    ;; A roomy bag keeps the bank guard dormant, so preferred actions are just gather.
    (define roomy (hasheq 'hp 90 'max_hp 100 'cooldown 0
                          'inventory_max_items 20 'interactions (hasheq 'content #f)
                          'inventory (list (hasheq 'code "a" 'quantity 5))))
    (define miner-spec (character-spec 'demo 'mining #f (list spec)))
    (check-equal? (map action-spec-name (goal-preferred-actions miner-spec roomy)) '(gather))
    ;; A full bag trips the guard, surfacing the bank-deposit-item step.
    (define packed (hasheq 'hp 90 'max_hp 100 'cooldown 0
                           'inventory_max_items 20 'interactions (hasheq 'content #f)
                           'inventory (list (hasheq 'code "a" 'quantity 20))))
    (check-equal? (map action-spec-name (goal-preferred-actions miner-spec packed))
                  '(bank-deposit-item gather)))

  (test-case "combat-loop guards rest on low HP and still fights"
    (define spec (combat-loop #:max-hp-ratio 0.5))
    (check-true (goal-spec? spec))
    (define actions (goal-spec-actions spec))
    (define rest-guard (car actions))
    (check-true (guard? rest-guard))
    (check-equal? (action-spec-name (car (guard-spec-forms rest-guard))) 'rest)
    (check-equal? (action-spec-name (cadr actions)) 'fight)
    (check-true (guard? (caddr actions)))
    ;; A hurt character rests first; the fight step is reached only after recovery.
    (define hurt (hasheq 'hp 30 'max_hp 100 'cooldown 0
                         'inventory_max_items 20 'interactions (hasheq 'content #f)
                         'inventory (list)))
    (define fighter-spec (character-spec 'demo 'combat #f (list spec)))
    ;; Hurt: the rest guard fires and the fight step is also preferred (both
    ;; resolve through the same goal). goal-preferred-actions returns them in
    ;; reverse source order, so fight precedes rest in the list.
    (check-equal? (map action-spec-name (goal-preferred-actions fighter-spec hurt)) '(fight rest))
    ;; A healthy fighter yields (rest-guard dormant) -> fight -> bank guard dormant.
    (define healthy (hasheq 'hp 90 'max_hp 100 'cooldown 0
                            'inventory_max_items 20 'interactions (hasheq 'content #f)
                            'inventory (list)))
    (check-equal? (map action-spec-name (goal-preferred-actions fighter-spec healthy)) '(fight))
    ;; A healthy but packed fighter banks before returning to the fight loop.
    (define healthy-packed (hasheq 'hp 90 'max_hp 100 'cooldown 0
                                   'inventory_max_items 20 'interactions (hasheq 'content #f)
                                   'inventory (list (hasheq 'code "a" 'quantity 20))))
    (check-equal? (map action-spec-name (goal-preferred-actions fighter-spec healthy-packed))
                  '(bank-deposit-item fight)))

  (test-case "sell-surplus only sells while standing on an NPC tile"
    (define spec (sell-surplus #:code 'copper_ore #:qty 5))
    (check-true (goal-spec? spec))
    (define guard (car (goal-spec-actions spec)))
    (check-true (guard? guard))
    (define sell-action (car (guard-spec-forms guard)))
    (check-equal? (action-spec-name sell-action) 'npc-sell)
    (check-equal? (action-spec-payload sell-action)
                  (list (hasheq 'code "copper_ore" 'quantity 5)))
    (define at-npc (hasheq 'hp 90 'max_hp 100 'cooldown 0
                           'inventory_max_items 20 'interactions (hasheq 'content (hasheq 'type "npc" 'code "npc"))
                           'inventory (list)))
    (define trader-spec (character-spec 'demo 'trader #f (list spec)))
    (check-equal? (map action-spec-name (goal-preferred-actions trader-spec at-npc)) '(npc-sell))
    (define not-at-npc (hasheq 'hp 90 'max_hp 100 'cooldown 0
                               'inventory_max_items 20 'interactions (hasheq 'content #f)
                               'inventory (list)))
    (check-equal? (goal-preferred-actions trader-spec not-at-npc) '()))

  (test-case "bank-when-full and rest-when-low guards resolve against the character"
    (define bank-guard (bank-when-full #:reserve 1))
    (check-true (guard? bank-guard))
    (define packed (hasheq 'hp 90 'max_hp 100 'cooldown 0
                           'inventory_max_items 20 'interactions (hasheq 'content #f)
                           'inventory (list (hasheq 'code "a" 'quantity 20))))
    (check-equal? (action-spec-name (car (guard-spec-forms bank-guard))) 'bank-deposit-item)
    (check-equal? (length (expand-guards (list bank-guard) packed)) 1)
    (define rest-guard (rest-when-low #:max-hp-ratio 0.5))
    (check-true (guard? rest-guard))
    (check-equal? (action-spec-name (car (guard-spec-forms rest-guard))) 'rest)
    (define hurt (hasheq 'hp 30 'max_hp 100 'cooldown 0
                         'inventory_max_items 20 'interactions (hasheq 'content #f)
                         'inventory (list)))
    (check-equal? (length (expand-guards (list rest-guard) hurt)) 1)
    (check-equal? (expand-guards (list rest-guard) packed) '()))

  (test-case "every HTTP action wrapper has a builder, a known name, and a dispatch route"
    ;; Real parity check: the framework must cover the full character-action
    ;; surface of the official API. For each wrapper we confirm (a) a DSL
    ;; builder yields the matching action-spec name, (b) that name passes
    ;; known-action? so (action '...) validates, and (c) the dispatcher has a
    ;; route (it reaches the HTTP layer rather than answering "unsupported
    ;; action"). A regression here would mean a new API action was added
    ;; upstream but never wired into the DSL.
    (define builders
      (list (cons 'move (move-to #:x 1 #:y 2))
            (cons 'transition (transition))
            (cons 'rest (rest))
            (cons 'equip (equip "weapon"))
            (cons 'unequip (unequip "weapon"))
            (cons 'use (use-item #:code 'small_health_potion))
            (cons 'fight (fight))
            (cons 'gather (gather))
            (cons 'craft (craft #:code 'copper_bar #:qty 1))
            (cons 'recycle (recycle #:code 'copper_ore #:qty 1))
            (cons 'bank-deposit-item (deposit-all))
            (cons 'bank-deposit-gold (deposit-gold #:gold 5))
            (cons 'bank-withdraw-item (withdraw #:code 'copper_ore #:qty 1))
            (cons 'bank-withdraw-gold (withdraw-gold #:gold 5))
            (cons 'bank-buy-expansion (buy-expansion))
            (cons 'npc-buy (buy #:code 'copper_ore #:qty 1))
            (cons 'npc-sell (sell #:code 'copper_ore #:qty 1))
            (cons 'grand-exchange-orders (scan-ge))
            (cons 'grand-exchange-buy (buy-on-ge #:order-id 1 #:qty 2))
            (cons 'grand-exchange-create-sell-order
                  (sell-on-ge #:code 'copper_ore #:qty 1 #:price 10))
            (cons 'grand-exchange-create-buy-order
                  (bid-on-ge #:code 'copper_ore #:qty 1 #:price 10))
            (cons 'grand-exchange-cancel (cancel-order #:order-id 1))
            (cons 'grand-exchange-fill (fill-order #:order-id 1 #:qty 2))
            (cons 'task-new (task-start))
            (cons 'task-complete (task-complete))
            (cons 'task-cancel (task-cancel))
            (cons 'task-exchange (task-exchange))
            (cons 'task-trade (task-trade #:code 'monstertoken #:qty 1))
            (cons 'give-gold (give-gold #:to "bob" #:qty 5))
            (cons 'give-item (give-item #:to "bob" #:code 'copper_ore #:qty 1))
            (cons 'claim-item (claim-item 1))
            (cons 'delete-item (delete-item #:code 'copper_ore #:qty 1))
            (cons 'change-skin (change-skin #:skin 'women3))
            (cons 'active-events (check-events))
            (cons 'raids (check-raids))))
    ;; (a) every builder yields the expected action-spec name.
    (for ([pair builders])
      (check-equal? (action-spec-name (cdr pair)) (car pair)
                    (format "builder for ~a" (car pair))))
    ;; (b) every resulting name is a known action so (action '...) validates.
    (for ([pair builders])
      (check-true (known-action? (car pair))
                  (format "known-action? ~a" (car pair))))
    ;; (c) the dispatcher routes every name rather than rejecting it. We drive
    ;; each spec through execute-action with no token: a missing route raises
    ;; "unsupported action", whereas a wired route reaches the HTTP layer and
    ;; raises a 452 auth error. Either way it must not be an unknown-action.
    (define (dispatch-claims-unknown? spec)
      (define (mark-unsupported exn)
        (regexp-match? #px"unsupported action" (exn-message exn)))
      (with-handlers ([exn:fail? mark-unsupported])
        (execute-action "alice" spec #:config missing-token-config)
        #f))
    (for ([pair builders])
      (check-false (dispatch-claims-unknown? (cdr pair))
                   (format "dispatch routes ~a" (car pair)))))

  (test-case "buy-expansion builds a payload-free bank-buy-expansion spec"
    (define spec (buy-expansion))
    (check-equal? (action-spec-name spec) 'bank-buy-expansion)
    (check-equal? (action-spec-payload spec) '())
    (check-true (known-action? 'bank-buy-expansion)))

  (test-case "craft-loop crafts then banks when the bag fills"
    (define spec (craft-loop #:code 'copper_bar #:qty 1))
    (check-true (goal-spec? spec))
    (check-equal? (goal-spec-target spec) 'craft-loop)
    (define actions (goal-spec-actions spec))
    (check-equal? (action-spec-name (car actions)) 'craft)
    (check-equal? (action-spec-payload (car actions))
                  (list (hasheq 'code "copper_bar" 'quantity 1)))
    (define bank-guard (cadr actions))
    (check-true (guard? bank-guard))
    (check-equal? (action-spec-name (car (guard-spec-forms bank-guard))) 'bank-deposit-item)
    ;; A roomy bag keeps the bank guard dormant: only the craft step is preferred.
    (define roomy (hasheq 'hp 90 'max_hp 100 'cooldown 0
                          'inventory_max_items 20 'interactions (hasheq 'content #f)
                          'inventory (list (hasheq 'code "a" 'quantity 5))))
    (define smith-spec (character-spec 'demo 'crafter #f (list spec)))
    (check-equal? (map action-spec-name (goal-preferred-actions smith-spec roomy)) '(craft))
    ;; A full bag trips the bank guard, surfacing the deposit step.
    (define packed (hasheq 'hp 90 'max_hp 100 'cooldown 0
                           'inventory_max_items 20 'interactions (hasheq 'content #f)
                           'inventory (list (hasheq 'code "a" 'quantity 20))))
    (check-equal? (map action-spec-name (goal-preferred-actions smith-spec packed))
                  '(bank-deposit-item craft)))

  (test-case "ge-trade only lists on the Grand Exchange tile"
    (define spec (ge-trade #:code 'copper_ore #:qty 5 #:price 10))
    (check-true (goal-spec? spec))
    (define guard (car (goal-spec-actions spec)))
    (check-true (guard? guard))
    (define sell-action (car (guard-spec-forms guard)))
    (check-equal? (action-spec-name sell-action) 'grand-exchange-create-sell-order)
    (check-equal? (action-spec-payload sell-action)
                  (list (hasheq 'code "copper_ore" 'quantity 5 'price 10)))
    (define at-ge (hasheq 'hp 90 'max_hp 100 'cooldown 0
                          'inventory_max_items 20 'interactions (hasheq 'content (hasheq 'type "grand_exchange" 'code "grand_exchange"))
                          'inventory (list)))
    (define trader-spec (character-spec 'demo 'trader #f (list spec)))
    (check-equal? (map action-spec-name (goal-preferred-actions trader-spec at-ge))
                  '(grand-exchange-create-sell-order))
    (define not-at-ge (hasheq 'hp 90 'max_hp 100 'cooldown 0
                              'inventory_max_items 20 'interactions (hasheq 'content #f)
                              'inventory (list)))
    (check-equal? (goal-preferred-actions trader-spec not-at-ge) '()))

  (test-case "pipeline flattens nested goal-spec helpers"
    ;; Helpers that return goal-specs (sell-surplus, ge-trade, bank-when-full)
    ;; should splice into a parent goal rather than being rejected as forms.
    (define spec
      (pipeline 'market-edge
        (rest-when-low #:max-hp-ratio 0.5)
        (sell-surplus #:code 'copper_ore #:qty 5)
        (ge-trade #:code 'copper_ore #:qty 5 #:price 10)
        (bank-when-full #:reserve 1)))
    (check-true (goal-spec? spec))
    (check-equal? (goal-spec-target spec) 'market-edge)
    ;; The four helpers contribute a rest guard, an npc-sell guard, a GE sell
    ;; guard, and a bank guard — four specs total after flattening.
    (define actions (goal-spec-actions spec))
    (check-equal? (length actions) 4)
    (check-true (guard? (car actions)))
    (check-equal? (action-spec-name (car (guard-spec-forms (cadr actions)))) 'npc-sell)
    (check-equal? (action-spec-name (car (guard-spec-forms (caddr actions))))
                  'grand-exchange-create-sell-order)
    (check-true (guard? (cadddr actions)))
    ;; Goal conditions still resolve against the live character after flattening.
    (define at-npc (hasheq 'hp 90 'max_hp 100 'cooldown 0
                           'inventory_max_items 20 'interactions (hasheq 'content (hasheq 'type "npc" 'code "npc"))
                           'inventory (list)))
    (define trader-spec (character-spec 'demo 'trader #f (list spec)))
    (check-equal? (map action-spec-name (goal-preferred-actions trader-spec at-npc))
                  '(npc-sell)))

  (test-case "goal flattens a nested helper alongside plain actions"
    (define spec
      (goal 'mixed
        (gather)
        (mine-until-full #:resource 'copper_rocks)))
    (check-equal? (goal-spec-target spec) 'mixed)
    (define actions (goal-spec-actions spec))
    (check-equal? (action-spec-name (car actions)) 'gather)
    ;; gather plus the mine-until-full helper (which contributes a gather action
    ;; and a bank guard) flattens to three specs total.
    (check-equal? (length actions) 3)
    (check-equal? (action-spec-name (cadr actions)) 'gather)
    (check-true (guard? (caddr actions))))

  (test-case "best-gather-plan returns a bank trip when inventory is near full"
    ;; A copper/iron world so the resource branch is reachable.
    (define world
      (build-world-index
       (list (hasheq 'map_id 1 'layer "overworld" 'x 0 'y 0
                     'interactions (hasheq 'content #f))
             (hasheq 'map_id 2 'layer "overworld" 'x 1 'y 0
                     'interactions (hasheq 'content
                                           (hasheq 'type "resource" 'code "copper_rocks")))
             (hasheq 'map_id 3 'layer "overworld" 'x 0 'y 2
                     'interactions (hasheq 'content
                                           (hasheq 'type "bank" 'code "bank"))))))
    (define resources
      (list (hasheq 'code "copper_rocks" 'level 1 'skill "mining")
            (hasheq 'code "iron_rocks" 'level 10 'skill "mining")))
    ;; Near-full: 19 of 20 used with reserve 1 -> bank, not gather.
    (define near-full
      (hasheq 'name "miner"
               'level 5
               'hp 90 'max_hp 100 'cooldown 0
               'mining_level 5
               'inventory_max_items 20
               'inventory (list (hasheq 'code "a" 'quantity 19))
               'x 0 'y 0 'layer "overworld" 'map_id 1
               'interactions (hasheq 'content #f)))
    (define plan (best-gather-plan near-full world resources 'mining #:reserve 1))
    ;; Not standing on a bank yet, so the trip is a move toward the bank tile.
    (check-equal? (planned-action-name plan) 'move)
    (check-equal? (planned-action-priority plan) 85)
    ;; A character already on the bank deposits instead of moving.
    (define at-bank
      (hash-set near-full
                'interactions (hasheq 'content (hasheq 'type "bank" 'code "bank"))))
    (define deposit-plan (best-gather-plan at-bank world resources 'mining #:reserve 1))
    (check-equal? (planned-action-name deposit-plan) 'bank-deposit-item))

  (test-case "best-gather-plan gathers (or moves to the node) when not full"
    (define world
      (build-world-index
       (list (hasheq 'map_id 1 'layer "overworld" 'x 0 'y 0
                     'interactions (hasheq 'content #f))
             (hasheq 'map_id 2 'layer "overworld" 'x 1 'y 0
                     'interactions (hasheq 'content
                                           (hasheq 'type "resource" 'code "copper_rocks"))))))
    (define resources
      (list (hasheq 'code "copper_rocks" 'level 1 'skill "mining")
            (hasheq 'code "iron_rocks" 'level 10 'skill "mining")))
    ;; Roomy bag: 5 of 20 used, well under capacity minus reserve.
    (define roomy
      (hasheq 'name "miner"
               'level 5
               'hp 90 'max_hp 100 'cooldown 0
               'mining_level 5
               'inventory_max_items 20
               'inventory (list (hasheq 'code "a" 'quantity 5))
               'x 0 'y 0 'layer "overworld" 'map_id 1
               'interactions (hasheq 'content #f)))
    ;; Not standing on the node -> move toward copper_rocks.
    (define move-plan (best-gather-plan roomy world resources 'mining #:reserve 1))
    (check-equal? (planned-action-name move-plan) 'move)
    ;; Standing on the node -> gather directly.
    (define on-node
      (hash-set roomy
                'interactions (hasheq 'content
                                      (hasheq 'type "resource" 'code "copper_rocks"))))
    (define gather-plan (best-gather-plan on-node world resources 'mining #:reserve 1))
    (check-equal? (planned-action-name gather-plan) 'gather)
    ;; Picks the highest-level resource the character can use (copper at lvl 1
    ;; over iron at lvl 10, since mining_level is 5).
    (check-equal? (planned-action-reason gather-plan) "Gather copper_rocks."))

  (test-case "gather-loop returns a goal whose actions include gather + bank-when-full"
    (define spec (gather-loop #:reserve 1))
    (check-true (goal-spec? spec))
    (check-equal? (goal-spec-target spec) 'gather-loop)
    (define actions (goal-spec-actions spec))
    (check-equal? (action-spec-name (car actions)) 'gather)
    (define bank-guard (cadr actions))
    (check-true (guard? bank-guard))
    (check-equal? (action-spec-name (car (guard-spec-forms bank-guard))) 'bank-deposit-item)
    ;; A roomy bag leaves the bank guard dormant: only gather is preferred.
    (define roomy
      (hasheq 'hp 90 'max_hp 100 'cooldown 0
               'inventory_max_items 20 'interactions (hasheq 'content #f)
               'mining_level 5 'inventory (list (hasheq 'code "a" 'quantity 5))))
    (define miner-spec (character-spec 'demo 'mining #f (list spec)))
    (check-equal? (map action-spec-name (goal-preferred-actions miner-spec roomy)) '(gather))
    ;; A full bag trips the guard, surfacing the bank-deposit-item step.
    (define packed
      (hasheq 'hp 90 'max_hp 100 'cooldown 0
               'inventory_max_items 20 'interactions (hasheq 'content #f)
               'mining_level 5 'inventory (list (hasheq 'code "a" 'quantity 20))))
    (check-equal? (map action-spec-name (goal-preferred-actions miner-spec packed))
                  '(bank-deposit-item gather))
    ;; Composes inside a parent goal/pipeline (helpers flatten into goal-specs).
    (define nested (goal 'gatherer (gather-loop #:reserve 1)))
    (check-equal? (length (goal-spec-actions nested)) 2)
    (check-true (guard? (cadr (goal-spec-actions nested)))))

  ;; ---- Dry-run black-box: full framework run without any credentials ----
  ;; These two cases prove the runner executes a bot end-to-end with no token
  ;; and no network. We feed an explicit world/encyclopedia (and prime the
  ;; cache for the loop) and point the config at an unreachable host so that if
  ;; any live call slipped through, it would fail fast instead of reaching the
  ;; real API. The bot intentionally has no strategy: a strategy tick would
  ;; dispatch live actions, and dry-run is about proving the planning/action
  ;; path runs, not about strategy dispatch.

  (define dry-run-config
    (make-config #:token #f #:base-url "http://127.0.0.1:9"))

  (define dry-run-world
    (build-world-index
     (list #hasheq((map_id . "start") (layer . "overworld") (x . 0) (y . 0)
                   (interactions . #hasheq((content . #f))))
           #hasheq((map_id . "copper") (layer . "overworld") (x . 2) (y . 0)
                   (interactions . #hasheq((content . #hasheq((type . "resource") (code . "copper_rocks"))))))
           #hasheq((map_id . "bank") (layer . "overworld") (x . 0) (y . 2)
                   (interactions . #hasheq((content . #hasheq((type . "bank") (code . "bank"))))))
           #hasheq((map_id . "chicken") (layer . "overworld") (x . 3) (y . 0)
                   (interactions . #hasheq((content . #hasheq((type . "monster") (code . "chicken")))))))))

  (define dry-run-encyclopedia
    #hasheq((monsters . (#hasheq((code . "chicken") (level . 1) (hp . 15) (attack . 3) (defense . 1))))
             (resources . (#hasheq((code . "copper_rocks") (level . 1) (skill . "mining"))))
             (items . ())))

  (define dry-run-bot
    (bot-spec 'workshop
              (list (character-spec 'miner 'mining #f
                                    (list (goal 'ore (gather) (deposit-all))))
                    (character-spec 'fighter 'combat #f
                                    (list (goal 'xp (fight)))))))

  (define (outcome-status outcome)
    (cadr outcome))

  (test-case "run-bot-once runs credential-free with synthetic characters"
    (define-values (results my-chars)
      (run-bot-once dry-run-bot
                    #:dry-run? #t
                    #:config dry-run-config
                    #:world dry-run-world
                    #:encyclopedia dry-run-encyclopedia))
    ;; The runner returns (values results chars); results holds one entry per
    ;; character spec, each shaped (tag status detail).
    (check-pred list? results)
    (check-equal? (length results) 2)
    (for ([outcome results])
      (check-equal? (length outcome) 3)
      (define status (outcome-status outcome))
      (check-not-false (memq status '(acted idle missing))
                        (format "unexpected outcome status ~a" status)))
    ;; No 452 or other error escaped; the runner substituted synthetic chars.
    (check-pred list? my-chars)
    (check-equal? (length my-chars) 2)
    ;; Every synthetic character reports a name, confirming it never touched
    ;; the live account in dry-run.
    (check-equal? (map (lambda (c) (hash-ref c 'name)) my-chars)
                  '("miner" "fighter")))

  (test-case "strategy flattens helper goal-specs and plain actions"
    ;; A strategy may hold plain actions alongside high-level helpers that return
    ;; goal-specs. Without a live actor the guard-wrapped helpers stay dormant
    ;; (their condition can't be read), exactly like a character pipeline.
    (define strat
      (strategy-spec 'account-value
        (list (scan-ge)
              (goal 'watch
                    (ge-trade #:code 'copper_ore #:qty 5 #:price 10)
                    (check-events)))))
    (define flat (forms->action-specs (strategy-spec-forms strat)))
    (check-equal? (length flat) 2)
    (check-equal? (list->set (map action-spec-name flat))
                  (set 'grand-exchange-orders 'active-events)))

  (test-case "strategy resolves a helper guard against the live actor"
    ;; Once a live character stands on the right tile, the helper's guard fires
    ;; and the wrapped action reaches the flattened plan.
    (define strat
      (strategy-spec 'account-value
        (list (scan-ge)
              (ge-trade #:code 'copper_ore #:qty 5 #:price 10))))
    (define at-ge
      (hasheq 'hp 90 'max_hp 100 'cooldown 0 'inventory_max_items 20
              'interactions (hasheq 'content (hasheq 'type "grand_exchange" 'code "grand_exchange"))
              'inventory (list)))
    (define flat (forms->action-specs (strategy-spec-forms strat) at-ge))
    (check-equal? (length flat) 2)
    (check-equal? (list->set (map action-spec-name flat))
                  (set 'grand-exchange-orders 'grand-exchange-create-sell-order)))

  (test-case "run-strategy-tick dry-run resolves helpers without network"
    ;; The strategy actor is the market character when one exists, and a
    ;; dry-run tick runs the helpers with no dispatch and no network.
    (define bot
      (bot-spec 'apex
        (list (character-spec 'fighter 'combat #f '())
              (character-spec 'trader 'trader #f
                (list (pipeline 'market-edge (scan-ge) (check-events))))
              (strategy-spec 'maximize-account-value
                (list (scan-ge) (check-events) (check-raids))))))
    (define bound
      (bind-bot-to-account bot (list #hasheq((name . "Alpha")) #hasheq((name . "Beta")))))
    ;; Role preference: the trader is chosen as the actor, not the first char.
    (check-equal? (character-spec-role (strategy-actor-spec bound)) 'trader)
    (check-equal? (character-spec-live-name (strategy-actor-spec bound)) "Beta")
    ;; Dry-run must execute the tick (helpers flattened) with no live dispatch.
    (define done
      (run-strategy-tick bound #:dry-run? #t #:config dry-run-config))
    (check-true (void? done))
    ;; A strategy with no bound actor name is skipped rather than crashing.
    (define unbound
      (bot-spec 'solo (list (strategy-spec 's (list (scan-ge))))))
    (check-true
     (void? (run-strategy-tick unbound #:dry-run? #t #:config dry-run-config))))

  (test-case "run-bot-loop completes one credential-free iteration"
    ;; Prime the world/encyclopedia caches so load-world-index and
    ;; load-encyclopedia read from disk and never reach the network.
    (define cache-dir (make-temporary-file "artifacts-dryrun-~a" 'directory))
    (putenv "ARTIFACTS_CACHE_DIR" (path->string cache-dir))
    (call-with-output-file (build-path cache-dir "world-maps.json")
      (lambda (out)
        (write-json
         (list #hasheq((map_id . "start") (layer . "overworld") (x . 0) (y . 0)
                       (interactions . #hasheq((content . #f))))
               #hasheq((map_id . "copper") (layer . "overworld") (x . 2) (y . 0)
                       (interactions . #hasheq((content . #hasheq((type . "resource") (code . "copper_rocks"))))))
               #hasheq((map_id . "chicken") (layer . "overworld") (x . 3) (y . 0)
                       (interactions . #hasheq((content . #hasheq((type . "monster") (code . "chicken")))))))
         out))
      #:exists 'replace)
    (call-with-output-file (build-path cache-dir "encyclopedia.json")
      (lambda (out) (write-json dry-run-encyclopedia out))
      #:exists 'replace)
    ;; iterations=1 guarantees the loop stops; sleep 0 keeps it instant. The
    ;; loop swallows inner errors into its wait value, so a non-void return
    ;; here would mean a swallowed failure rather than a clean run.
    (define done
      (run-bot-loop dry-run-bot
                    #:dry-run? #t
                    #:iterations 1
                    #:sleep-seconds 0
                    #:config dry-run-config))
    (check-true (void? done))
    (delete-directory/files cache-dir)))

;; Real-time readiness layer: prep only, no socket opened, no client imports.
(module+ test
  (test-case "realtime-url reads the configured ws endpoint"
    (check-equal? (realtime-url test-config) "wss://realtime.artifactsmmo.com")
    (check-false (realtime-url
                  (artifacts-config "https://api.artifactsmmo.com" #f "TEST_TOKEN"))))

  (test-case "realtime-enabled? is false without the env flag"
    ;; Guard against any ambient ARTIFACTS_REALTIME leaking in from the shell.
    (putenv "ARTIFACTS_REALTIME" "")
    (check-false (realtime-enabled? test-config)))

  (test-case "realtime-enabled? is true when ARTIFACTS_REALTIME=1"
    (define prior (getenv "ARTIFACTS_REALTIME"))
    (putenv "ARTIFACTS_REALTIME" "1")
    (check-true (realtime-enabled? test-config))
    (putenv "ARTIFACTS_REALTIME" "")
    (when prior (putenv "ARTIFACTS_REALTIME" prior)))

  (test-case "snapshot-from-character projects the key live fields"
    (define char
      #hasheq((name . "scout")
              (hp . 42)
              (max_hp . 100)
              (x . 7)
              (y . -3)
              (cooldown_expiration . 1700000123)
              (level . 12)))
    (define snap (snapshot-from-character char))
    (check-equal? (realtime-snapshot-character-name snap) "scout")
    (check-equal? (realtime-snapshot-hp snap) 42)
    (check-equal? (realtime-snapshot-max-hp snap) 100)
    (check-equal? (realtime-snapshot-x snap) 7)
    (check-equal? (realtime-snapshot-y snap) -3)
    (check-equal? (realtime-snapshot-cooldown-expiration snap) 1700000123)
    ;; The snapshot is a transparent projection, so struct->vector exposes
    ;; exactly the six modeled fields (plus the struct type tag).
    (check-equal? (vector->list (struct->vector snap))
                  (list 'struct:realtime-snapshot "scout" 42 100 7 -3 1700000123))))
