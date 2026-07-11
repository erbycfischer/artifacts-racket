#lang racket

(require rackunit
         json
         racket/file
         net/url
         "../artifacts/config.rkt"
         "../artifacts/http.rkt"
         (except-in "../artifacts/lang/runtime.rkt" when-low-hp when-inventory-full when-on-content)
         "../artifacts/lang/helpers.rkt"
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
    (check-false (cooldown-ready? #hasheq((cooldown . 3)))))

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

  (test-case "buy-expansion builds a payload-free bank-buy-expansion spec"
    (define spec (buy-expansion))
    (check-equal? (action-spec-name spec) 'bank-buy-expansion)
    (check-equal? (action-spec-payload spec) '())
    (check-true (known-action? 'bank-buy-expansion)))
)
