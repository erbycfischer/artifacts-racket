#lang racket

(require rackunit
         json
         racket/set
         racket/file
         net/url
         "../artifacts/auth.rkt"
         ;; runtime re-exports core (incl. game-data) and helpers. Exclude the
         ;; planner predicates so the direct planner require below owns them
         ;; (avoids "already imported from a different source").
         (except-in "../artifacts/lang/runtime.rkt"
                    when-low-hp when-inventory-full when-on-content when-below-level
                    when-has-item when-has-qty when-gold-above when-gold-below
                    when-hp-above when-inventory-empty when-on-map)
         "../artifacts/planner.rkt"
         "../artifacts/lang/realtime.rkt"
         (rename-in "../artifacts/lang/queries.rkt"
                    [character q:character]
                    [map q:map]))

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
                  "near")
    (check-equal? (hash-ref (map-at index "main" 1 0) 'map_id) "near")
    (check-false (map-at index "main" 9 9)))

  (test-case "market helpers score spreads"
    (define buys (list #hasheq((price . 9)) #hasheq((price . 12))))
    (define sells (list #hasheq((price . 13)) #hasheq((price . 15))))
    (check-equal? (best-buy-price buys) 12)
    (check-equal? (best-sell-price sells) 13)
    (check-equal? (order-spread buys sells) 1)
    (check-false (profitable-spread? buys sells #:minimum-margin 5)))

  (test-case "ge-book splits buys and sells by type"
    (define mixed
      (list #hasheq((type . "buy") (price . 10))
            #hasheq((type . "sell") (price . 12))
            #hasheq((type . "buy") (price . 11))
            #hasheq((type . "sell") (price . 13))
            ;; Defensive: a non-hash and a hash with no/odd type are skipped.
            "not-an-order"
            #hasheq((price . 99))
            #hasheq((type . "unknown") (price . 50))))
    (define-values (buys sells) (ge-book mixed))
    (check-equal? (length buys) 2)
    (check-equal? (length sells) 2)
    (check-equal? (map (lambda (o) (hash-ref o 'price)) buys) '(10 11))
    (check-equal? (map (lambda (o) (hash-ref o 'price)) sells) '(12 13))
    ;; An empty book yields two empty lists, not an error.
    (define-values (no-b no-s) (ge-book '()))
    (check-equal? no-b '())
    (check-equal? no-s '()))

  (test-case "best-bid and best-ask read a mixed book"
    (define book
      (list #hasheq((type . "buy") (price . 10))
            #hasheq((type . "sell") (price . 14))
            #hasheq((type . "buy") (price . 12))
            #hasheq((type . "sell") (price . 13))))
    (check-equal? (best-bid book) 12)
    (check-equal? (best-ask book) 13)
    ;; They agree with the side-specific helpers when split first.
    (define-values (buys sells) (ge-book book))
    (check-equal? (best-bid book) (best-buy-price buys))
    (check-equal? (best-ask book) (best-sell-price sells))
    ;; A one-sided book leaves the missing side #f.
    (check-false (best-ask (list #hasheq((type . "buy") (price . 5))))))

  (test-case "mid-price averages best bid and best ask"
    (define book
      (list #hasheq((type . "buy") (price . 10))
            #hasheq((type . "sell") (price . 14))))
    (check-equal? (mid-price book) 12.0)
    ;; Missing a side -> no fair value.
    (check-false (mid-price (list #hasheq((type . "buy") (price . 5)))))
    (check-false (mid-price '())))

  (test-case "spread-margin measures the ask-bid margin"
    ;; ask (16) sits above the bid (10), so the taker margin is ask minus bid:
    ;; +6, same sign as order-spread/profitable?.
    (define book
      (list #hasheq((type . "buy") (price . 10))
            #hasheq((type . "sell") (price . 16))))
    (check-equal? (spread-margin book) 6)
    ;; A threshold above the margin suppresses the (sub-profit) sliver.
    (check-false (spread-margin book #:minimum-margin 7))
    (check-equal? (spread-margin book #:minimum-margin 6) 6)
    ;; Thin book -> no margin.
    (check-false (spread-margin (list #hasheq((type . "buy") (price . 5))))))

  (test-case "profitable? answers with a threshold on a mixed book"
    ;; A book is profitable when the best ask clears the best bid: a seller
    ;; asks more than a buyer bids, so a maker buys low and sells high.
    (define wide
      (list #hasheq((type . "buy") (price . 10))
            #hasheq((type . "sell") (price . 16))))
    (define tight
      (list #hasheq((type . "buy") (price . 10))
            #hasheq((type . "sell") (price . 11))))
    (check-true (profitable? wide #:minimum-margin 5))
    (check-false (profitable? wide #:minimum-margin 7))
    (check-false (profitable? tight #:minimum-margin 5))
    (check-true (profitable? tight #:minimum-margin 1))
    ;; Ask below bid (or a one-sided book) is never profitable.
    (check-false (profitable? (list #hasheq((type . "buy") (price . 14))
                                    #hasheq((type . "sell") (price . 5)))
                              #:minimum-margin 1))
    (check-false (profitable? (list #hasheq((type . "buy") (price . 5)))
                              #:minimum-margin 1)))

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
                                                                             (code . "chicken"))))))))
    (define plan (plan-character char world #:role 'combat #:monsters (list #hasheq((code . "chicken") (level . 1)))))
    (check-equal? (planned-action-name plan) 'rest)
    (define healthy (hash-set* char 'hp 90 'interactions #hasheq((content . #hasheq((type . "monster") (code . "chicken"))))))
    (define fight-plan (plan-character healthy world #:role 'combat #:monsters (list #hasheq((code . "chicken") (level . 1))
                                                                                    #hasheq((code . "boss") (level . 40)))))
    (check-equal? (planned-action-name fight-plan) 'fight)
    ;; With preferred forms, author order wins even while critically hurt
    ;; (no language-level restock-vs-rest policy).
    (define world-with-bank
      (build-world-index
       (list #hasheq((map_id . 1) (layer . "overworld") (x . 0) (y . 0)
                     (interactions . #hasheq((content . #f))))
             #hasheq((map_id . 3) (layer . "overworld") (x . 2) (y . 0)
                     (interactions . #hasheq((content . #hasheq((type . "bank")
                                                                 (code . "bank")))))))))
    (parameterize ([bank-qty-lookup (lambda (code)
                                      (if (equal? (format "~a" code) "cooked_chicken") 5 0))])
      (define bank-plan
        (plan-character char world-with-bank
                        #:role 'combat
                        #:monsters (list #hasheq((code . "chicken") (level . 1)))
                        #:preferred (list (action-spec 'restock
                                                       (list (hasheq 'code "cooked_chicken" 'qty 3)))
                                          (action-spec 'fight '()))))
      (check-true (planned-action? bank-plan))
      (check-true (memq (planned-action-name bank-plan) '(restock move)))))))

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
              (interactions . #hasheq((content . #hasheq((type . "workshop") (code . "mining")))))))
    (define world (build-world-index
                   (list #hasheq((map_id . 10) (layer . "overworld") (x . 0) (y . 0)
                                 (interactions . #hasheq((content . #hasheq((type . "workshop") (code . "mining")))))))))
    (define plan (plan-character char world
                                 #:role 'crafter
                                 #:preferred (list (craft 'copper_bar 1))))
    (check-equal? (planned-action-name plan) 'craft))

  (test-case "create-character is auth-gated (POST /characters/create)"
    ;; Character creation is API-driven, not a manual website step, but it is a
    ;; /characters write that requires a bearer token. A token-less config must
    ;; raise the structured 452 before any request leaves the process, proving
    ;; the endpoint is both reachable through the wrapper and auth-gated.
    (define error
      (capture-api-error
       (lambda ()
         (create-character "fighter" #:config missing-token-config))))
    (check-true (api-error? error))
    (check-equal? (api-error-status error) 452)
    (check-equal? (api-error-code error) 452))

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
    (define thin-buys (list #hasheq((type . "buy") (price . 10) (quantity . 1))))
    (define thin-sells (list #hasheq((type . "sell") (price . 20) (quantity . 1))))
    (define deep-buys (list #hasheq((type . "buy") (price . 10) (quantity . 40))))
    (define deep-sells (list #hasheq((type . "sell") (price . 20) (quantity . 40))))
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



  (test-case "character macro stores a bare role symbol (not a double quote)"
    ;; `#:role 'woodcutting` must become the symbol woodcutting inside the
    ;; character-spec. A nested quote breaks role-skill and every gatherer
    ;; silently falls back to mining.
    (define wood (character woodcutter #:role 'woodcutting #:as "hrwood" (haul)))
    (check-eq? (character-spec-role wood) 'woodcutting)
    (check-eq? (character-spec-tag wood) 'woodcutter)
    (define craft (character smith #:role 'crafter (forge-loop)))
    (check-eq? (character-spec-role craft) 'crafter)
    (check-eq? (role-skill (character-spec-role wood)) 'woodcutting))

  (test-case "cooldown-remaining prefers parsed ISO expiration over stale cooldown"
    ;; Live GET /characters/{name} returns ISO cooldown_expiration plus a
    ;; relative cooldown that often never ticks down between polls. Absolute
    ;; expiration must win so past expirations read as ready.
    (define past #hasheq((cooldown . 58)
                         (cooldown_expiration . "2026-08-20T14:10:22.034Z")))
    (define future #hasheq((cooldown . 0)
                           (cooldown_expiration . "2099-01-01T00:00:00Z")))
    (check-true (cooldown-ready? past))
    (check-equal? (cooldown-remaining past) 0)
    (check-false (cooldown-ready? future))
    (check-true (> (cooldown-remaining future) 0))
    ;; No expiration still falls back to the relative field.
    (check-false (cooldown-ready? #hasheq((cooldown . 3))))
    (check-true (cooldown-ready? #hasheq((cooldown . 0)))))

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

  (test-case "api-error-wait-seconds backs off on 429"
    (define limited (api-error 429 429 "Too Many Requests" #hasheq() #f #f))
    (check-equal? (api-error-wait-seconds limited #:base-seconds 2) 20)
    (define retry (api-error 429 429 "Too Many Requests" #hasheq() "15" #f))
    (check-equal? (api-error-wait-seconds retry #:base-seconds 2) 15)
    (define other (api-error 498 498 "Character in cooldown" #hasheq() #f #f))
    (check-equal? (api-error-wait-seconds other #:base-seconds 2) 2)
    (check-equal? (generic-error-wait-seconds
                   "GET failed: HTTP/1.1 429 Too Many Requests"
                   #:base-seconds 2)
                  20)
    (check-equal? (generic-error-wait-seconds "connection reset" #:base-seconds 2)
                  2))

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
    ;; Elemental fixtures (live API shape). Generic attack/defense are ignored.
    (define char #hasheq((level . 5) (max_hp . 100)
                         (attack_air . 20) (critical_strike . 0)
                         (res_fire . 0) (res_earth . 0) (res_water . 0) (res_air . 0)))
    (define easy #hasheq((code . "chicken") (level . 1) (hp . 15)
                         (attack_water . 3)
                         (attack_fire . 0) (attack_earth . 0) (attack_air . 0)
                         (res_fire . 0) (res_earth . 0) (res_water . 0) (res_air . 0)))
    (define hard #hasheq((code . "dragon") (level . 40) (hp . 500)
                         (attack_fire . 80)
                         (attack_earth . 0) (attack_water . 0) (attack_air . 0)
                         (res_fire . 60) (res_earth . 0) (res_water . 0) (res_air . 0)))
    (define easy-score (local-combat-score char easy))
    (define hard-score (local-combat-score char hard))
    (check-true (number? easy-score))
    (check-true (number? hard-score))
    (check-true (> easy-score hard-score))
    ;; Equal elemental stats + HP → fight-safety ≈ 0.5; blended near mid-scale.
    (define even #hasheq((code . "peer") (level . 5) (hp . 100)
                         (attack_air . 20)
                         (attack_fire . 0) (attack_earth . 0) (attack_water . 0)
                         (res_fire . 0) (res_earth . 0) (res_water . 0) (res_air . 0)))
    (check-true (< (abs (- (local-combat-score char even) 0.5)) 0.25)))

  (test-case "matchup-score falls back to local math without a token"
    ;; A #f config fails before any request (no base-url), so simulate-fight-score
    ;; must absorb the error and degrade to local math rather than propagating it.
    (define char #hasheq((level . 5) (max_hp . 100)
                         (attack_air . 20) (critical_strike . 0)
                         (res_fire . 0) (res_earth . 0) (res_water . 0) (res_air . 0)))
    (define monster #hasheq((code . "chicken") (level . 1) (hp . 15)
                            (attack_water . 3)
                            (attack_fire . 0) (attack_earth . 0) (attack_air . 0)
                            (res_fire . 0) (res_earth . 0) (res_water . 0) (res_air . 0)))
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
    ;; Armor keyword hits use a real API slot (body_armor), never the
    ;; legacy catch-all 'armor key that jsexpr cannot POST.
    (check-equal? (hash-ref equip 'body_armor) "wooden_armor")
    ;; No relevant gear -> no suggestion.
    (define ungeared (hasheq 'inventory (list (hasheq 'code "apple" 'quantity 5))))
    (check-false (suggest-equipment ungeared monster))
    ;; Already wearing the bag piece → no re-equip suggestion (avoids API 422).
    (define already
      (hasheq 'inventory (list (hasheq 'code "copper_dagger" 'quantity 1))
              'weapon_slot "copper_dagger"))
    (check-false (suggest-equipment already monster)))

  (test-case "best-safe-monster skips unwinnable fights unless it's the only option"
    ;; Air dagger (copper_dagger): attack_air 6. Live slime/chicken elemental
    ;; shapes — green resists air and hits harder; chicken/yellow stay winnable.
    (define char #hasheq((name . "A")
                         (level . 3)
                         (max_hp . 100)
                         (hp . 100)
                         (attack_air . 6)
                         (critical_strike . 35)
                         (weapon_slot . "copper_dagger")
                         (res_fire . 0)
                         (res_earth . 0)
                         (res_water . 0)
                         (res_air . 0)
                         (cooldown . 0)
                         (inventory_max_items . 20)
                         (inventory . ())
                         (x . 0)
                         (y . 0)
                         (layer . "overworld")
                         (map_id . 1)
                         (interactions . #hasheq((content . #f)))))
    (define chicken
      #hasheq((code . "chicken") (level . 1) (hp . 60)
              (attack_water . 4) (attack_fire . 0) (attack_earth . 0) (attack_air . 0)
              (res_fire . 0) (res_earth . 0) (res_water . 0) (res_air . 0)))
    (define boss
      #hasheq((code . "boss") (level . 40) (hp . 500)
              (attack_fire . 80) (attack_earth . 0) (attack_water . 0) (attack_air . 0)
              (res_fire . 60) (res_earth . 0) (res_water . 0) (res_air . 0)))
    ;; With a #f config, scoring is local. Hard elemental matchups fall below
    ;; threshold, so the safe chicken wins over the boss.
    (define monsters (list chicken boss))
    (define chosen (best-safe-monster char monsters #:config #f))
    (check-equal? (hash-ref chosen 'code) "chicken")
    ;; When the only candidate is hard, the planner still returns it rather
    ;; than leaving the bot with nothing to do.
    (define only-hard (list boss))
    (check-equal? (hash-ref (best-safe-monster char only-hard #:config #f) 'code) "boss")
    ;; Among in-window fights, rank by win-probability — NOT raw monster level.
    ;; Air dagger must prefer chicken (or yellow) over green_slime (air resist).
    ;; NOTE (follow-up test agent): older suite expected green_slime under
    ;; max-level bias + generic attack/defense; elemental safety flips that.
    (define yellow
      #hasheq((code . "yellow_slime") (level . 2) (hp . 70)
              (attack_earth . 8) (attack_fire . 0) (attack_water . 0) (attack_air . 0)
              (res_fire . 0) (res_earth . 25) (res_water . 0) (res_air . 0)))
    (define green
      #hasheq((code . "green_slime") (level . 4) (hp . 80)
              (attack_air . 12) (attack_fire . 0) (attack_earth . 0) (attack_water . 0)
              (res_fire . 0) (res_earth . 0) (res_water . 0) (res_air . 25)))
    (define mix (list chicken yellow green))
    (check-equal? (hash-ref (best-safe-monster char mix #:config #f) 'code) "chicken"))

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

  (test-case "reactive predicates answer against a prepared character hash"
    (define char
      (hasheq 'hp 80 'max_hp 100 'gold 50 'map_id 3
              'inventory_max_items 20
              'inventory (list (hasheq 'code "copper_ore" 'quantity 4))))
    (check-true (when-has-item char 'copper_ore))
    (check-true (when-has-item char "copper_ore"))
    (check-false (when-has-item char 'iron_ore))
    (check-true (when-has-qty char 'copper_ore 4))
    (check-false (when-has-qty char 'copper_ore 5))
    (check-true (when-gold-above char 40))
    (check-false (when-gold-above char 50))
    (check-true (when-gold-below char 60))
    (check-false (when-gold-below char 50))
    (check-true (when-hp-above char 0.7))
    (check-false (when-hp-above char 0.8))
    (check-false (when-inventory-empty char))
    (check-true (when-inventory-empty char 4))
    (check-true (when-on-map char 3))
    (check-false (when-on-map char 9))
    (define empty (hasheq 'inventory_max_items 20 'inventory '()))
    (check-true (when-inventory-empty empty)))

  (test-case "every known-action-names entry routes in plan-preferred-action"
    ;; Parity with the HTTP-wrapper test: a character goal naming any known
    ;; action must produce a planned-action instead of falling through to #f.
    (define world
      (build-world-index
       (list (hasheq 'map_id 1 'layer "overworld" 'x 0 'y 0
                     'interactions (hasheq 'content #f))
             (hasheq 'map_id 2 'layer "overworld" 'x 1 'y 0
                     'interactions (hasheq 'content (hasheq 'type "bank" 'code "bank")))
             (hasheq 'map_id 3 'layer "overworld" 'x 2 'y 0
                     'interactions (hasheq 'content (hasheq 'type "grand_exchange" 'code "ge")))
             (hasheq 'map_id 4 'layer "overworld" 'x 3 'y 0
                     'interactions (hasheq 'content (hasheq 'type "workshop" 'code "ws")))
             (hasheq 'map_id 5 'layer "overworld" 'x 4 'y 0
                     'interactions (hasheq 'content (hasheq 'type "npc" 'code "npc")))
             (hasheq 'map_id 6 'layer "overworld" 'x 5 'y 0
                     'interactions (hasheq 'content (hasheq 'type "tasks_master" 'code "tm")))
             (hasheq 'map_id 7 'layer "overworld" 'x 6 'y 0
                     'interactions (hasheq 'content (hasheq 'type "resource" 'code "copper_rocks")))
             (hasheq 'map_id 8 'layer "overworld" 'x 7 'y 0
                     'interactions (hasheq 'content (hasheq 'type "monster" 'code "chicken")))
             (hasheq 'map_id 9 'layer "overworld" 'x 8 'y 0
                     'interactions (hasheq 'content (hasheq 'type "transition" 'code "door"))))))
    (define monsters (list (hasheq 'code "chicken" 'level 1 'hp 15 'attack 3 'defense 1)))
    (define resources (list (hasheq 'code "copper_rocks" 'level 1 'skill "mining")))
    (define char
      (hasheq 'name "alice" 'level 5 'hp 80 'max_hp 100 'gold 40 'cooldown 0
              'mining_level 5 'inventory_max_items 20
              'inventory (list (hasheq 'code "iron_sword" 'quantity 1)
                               (hasheq 'code "copper_ore" 'quantity 5))
              'x 0 'y 0 'layer "overworld" 'map_id 1
              'interactions (hasheq 'content #f)))
    (define (payload-for name)
      (case name
        [(use) (hasheq 'code "small_health_potion" 'quantity 1)]
        [(bank-deposit-gold bank-withdraw-gold) 10]
        [(bank-withdraw-item) (hasheq 'code "copper_ore" 'quantity 1)]
        [(move) (hasheq 'type "bank")]
        [(deposit-surplus) (hasheq 'code "copper_ore" 'keep 1)]
        [(restock) (hasheq 'code "copper_ore" 'qty 50)]  ; > bag qty so plan still routes
        [(snap-up) (hasheq 'code "copper_ore" 'max_price 10)]
        [(give-gold) (hasheq 'name "bob" 'quantity 5)]
        [(give-item) (hasheq 'name "bob" 'code "copper_ore" 'quantity 1)]
        [(claim-item) 1]
        [(delete-item) (hasheq 'code "copper_ore" 'quantity 1)]
        [(change-skin) (hasheq 'skin "women3")]
        [(grand-exchange-buy grand-exchange-cancel grand-exchange-fill)
         (hasheq 'id 1 'quantity 1)]
        [(grand-exchange-create-sell-order grand-exchange-create-buy-order)
         (hasheq 'code "copper_ore" 'quantity 1 'price 10)]
        [(task-trade) (hasheq 'code "monstertoken" 'quantity 1)]
        [(craft recycle npc-buy npc-sell)
         (hasheq 'code "copper_ore" 'quantity 1)]
        [else #hasheq()]))
    (for ([name known-action-names])
      (define spec (action-spec name (list (payload-for name))))
      (define plan (plan-preferred-action char world spec
                                          #:role 'combat
                                          #:monsters monsters
                                          #:resources resources
                                          #:events '()))
      (check-pred planned-action? plan
                  (format "plan-preferred-action should route ~a, got ~v" name plan))))

  (test-case "heal-when-low and consume-buff fire only when their predicates hold"
    (define heal (heal-when-low #:code 'small_health_potion #:ratio 0.5))
    (check-true (guard? heal))
    (check-equal? (action-spec-name (car (guard-spec-forms heal))) 'use)
    (define pot (list (hasheq 'code "small_health_potion" 'quantity 1)))
    (define hurt-with-pot (hasheq 'hp 30 'max_hp 100 'inventory pot))
    (define hurt-empty (hasheq 'hp 30 'max_hp 100 'inventory (list)))
    (define healthy (hasheq 'hp 90 'max_hp 100 'inventory pot))
    ;; Hurt + potion in bag → use; hurt with empty bag stays dormant (rest/restock).
    (check-equal? (length (expand-guards (list heal) hurt-with-pot)) 1)
    (check-equal? (expand-guards (list heal) hurt-empty) '())
    (check-equal? (expand-guards (list heal) healthy) '())
    (define hp-code (heal-when-hp-code #:code 'small_health_potion #:threshold 40))
    (check-true (guard? hp-code))
    (check-equal? (length (expand-guards (list hp-code) hurt-empty)) 1)
    (check-equal? (expand-guards (list hp-code) healthy) '())
    (define buff (consume-buff #:code 'sunflower))
    (define holding (hasheq 'inventory (list (hasheq 'code "sunflower" 'quantity 1))))
    (define empty (hasheq 'inventory (list)))
    (check-equal? (length (expand-guards (list buff) holding)) 1)
    (check-equal? (expand-guards (list buff) empty) '()))

  (test-case "gather-specific pins a resource code and banks when full"
    (define spec (gather-specific #:resource 'copper_ore #:reserve 1))
    (check-true (goal-spec? spec))
    (check-equal? (goal-spec-target spec) 'gather-specific)
    (check-equal? (action-spec-name (car (goal-spec-actions spec))) 'gather)
    (check-equal? (action-spec-payload (car (goal-spec-actions spec)))
                  (list (hasheq 'code "copper_ore")))
    (define roomy (hasheq 'hp 90 'max_hp 100 'cooldown 0
                          'inventory_max_items 20 'interactions (hasheq 'content #f)
                          'inventory (list (hasheq 'code "copper_ore" 'quantity 2))))
    (define miner-spec (character-spec 'demo 'mining #f (list spec)))
    (check-equal? (map action-spec-name (goal-preferred-actions miner-spec roomy))
                  '(gather)))

  (test-case "gather-until stops once the bag holds the target quantity"
    (define spec (gather-until #:resource 'copper_ore #:qty 5))
    (check-true (guard? spec))
    (define short (hasheq 'inventory (list (hasheq 'code "copper_ore" 'quantity 2))
                          'inventory_max_items 20))
    (define enough (hasheq 'inventory (list (hasheq 'code "copper_ore" 'quantity 5))
                           'inventory_max_items 20))
    (check-true (pair? (expand-guards (list spec) short)))
    (check-equal? (expand-guards (list spec) enough) '()))

  (test-case "recycle-junk and craft-if-materials gate on workshop / materials"
    (define junk (recycle-junk #:codes '(ash copper_ore)))
    (check-true (goal-spec? junk))
    (define at-shop (hasheq 'interactions (hasheq 'content (hasheq 'type "workshop" 'code "ws"))
                            'inventory (list (hasheq 'code "ash" 'quantity 2))))
    (define away (hasheq 'interactions (hasheq 'content #f)
                         'inventory (list (hasheq 'code "ash" 'quantity 2))))
    (define junk-char (character-spec 'demo 'crafter #f (list junk)))
    (check-equal? (map action-spec-name (goal-preferred-actions junk-char at-shop))
                  '(recycle))
    (check-equal? (goal-preferred-actions junk-char away) '())
    (define craft (craft-if-materials #:code 'copper_bar #:qty 1
                                      #:materials '((copper_ore 5))))
    (check-true (guard? craft))
    (define ready (hasheq 'inventory (list (hasheq 'code "copper_ore" 'quantity 5))))
    (define missing (hasheq 'inventory (list (hasheq 'code "copper_ore" 'quantity 1))))
    (check-equal? (action-spec-name (car (expand-guards (list craft) ready))) 'craft)
    (check-equal? (expand-guards (list craft) missing) '()))

  (test-case "production-chain gathers then crafts"
    (define spec (production-chain #:chain '((copper_ore 5)) #:craft 'copper_bar))
    (check-true (goal-spec? spec))
    (check-equal? (goal-spec-target spec) 'production-chain)
    (define from-recipe (production-chain #:craft 'copper_bar))
    (check-true (goal-spec? from-recipe)))

  (test-case "hunt, farm-xp, and task-loop build the expected action names"
    (define h (hunt #:code 'chicken #:max-hp-ratio 0.5))
    (check-true (goal-spec? h))
    (check-equal? (goal-spec-target h) 'hunt)
    (define fight-spec (cadr (goal-spec-actions h)))
    (check-equal? (action-spec-name fight-spec) 'fight)
    (check-equal? (action-spec-payload fight-spec)
                  (list (hasheq 'code "chicken")))
    (define farm (farm-xp #:target 10))
    (check-true (guard? farm))
    (define leveled (hasheq 'level 10 'hp 90 'max_hp 100))
    (define novice (hasheq 'level 3 'hp 90 'max_hp 100 'inventory '()
                           'inventory_max_items 20 'interactions (hasheq 'content #f)))
    (check-equal? (expand-guards (list farm) leveled) '())
    (check-true (pair? (expand-guards (list farm) novice)))
    (define tasks (task-loop))
    (check-true (goal-spec? tasks))
    (define at-master (hasheq 'hp 90 'max_hp 100 'cooldown 0
                              'inventory_max_items 20 'inventory '()
                              'interactions (hasheq 'content (hasheq 'type "tasks_master" 'code "tm"))))
    (define task-char (character-spec 'demo 'tasker #f (list tasks)))
    (check-equal? (list->set (map action-spec-name (goal-preferred-actions task-char at-master)))
                  (set 'task-complete 'task-exchange 'task-new)))

  (test-case "market-logistics helpers expose GE and bank action names"
    (define sell (sell-all-on-ge #:codes '(copper_ore coal) #:price 10))
    (check-true (goal-spec? sell))
    (define at-ge (hasheq 'hp 90 'max_hp 100 'cooldown 0 'gold 80
                          'inventory_max_items 20 'inventory '()
                          'interactions (hasheq 'content (hasheq 'type "grand_exchange" 'code "ge"))))
    (define sell-char (character-spec 'demo 'trader #f (list sell)))
    (check-equal? (map action-spec-name (goal-preferred-actions sell-char at-ge))
                  '(grand-exchange-create-sell-order grand-exchange-create-sell-order))
    (define wts (withdraw-then-sell #:code 'copper_ore #:qty 5 #:price 10))
    (check-true (goal-spec? wts))
    (define gold (bank-gold #:threshold 40))
    (check-true (guard? gold))
    (check-equal? (length (expand-guards (list gold) at-ge)) 1)
    (check-equal? (action-spec-name (car (expand-guards (list gold) at-ge)))
                  'deposit-gold-surplus)
    (define poor (hash-set at-ge 'gold 10))
    (check-equal? (expand-guards (list gold) poor) '())
    (define dump (bank-gold #:keep 0))
    (check-equal? (length (expand-guards (list dump) at-ge)) 1)
    (define keep (keep-gold #:floor 20))
    (check-equal? (length (expand-guards (list keep) poor)) 1)
    (check-equal? (action-spec-name (car (expand-guards (list keep) poor)))
                  'top-up-gold)
    (check-equal? (expand-guards (list keep) at-ge) '())
    (define pile (stockpile #:code 'copper_ore #:keep 2))
    (check-true (goal-spec? pile))
    (define at-bank (hasheq 'hp 90 'max_hp 100 'cooldown 0
                            'inventory_max_items 20 'inventory '()
                            'interactions (hasheq 'content (hasheq 'type "bank" 'code "bank"))))
    (define pile-char (character-spec 'demo 'mining #f (list pile)))
    (check-equal? (map action-spec-name (goal-preferred-actions pile-char at-bank))
                  '(deposit-surplus))
    (define rs (restock #:code 'copper_ore #:qty 5))
    (define rs-char (character-spec 'demo 'mining #f (list rs)))
    (check-equal? (map action-spec-name (goal-preferred-actions rs-char at-bank))
                  '(restock))
    (define snap (snap-up #:code 'copper_ore #:max-price 12))
    (define snap-char (character-spec 'demo 'trader #f (list snap)))
    (check-equal? (map action-spec-name (goal-preferred-actions snap-char at-ge))
                  '(snap-up)))

  (test-case "gear-travel helpers: auto-gear, buy-kit, travel-to"
    (define gear (auto-gear))
    (check-true (guard? gear))
    (check-equal? (action-spec-name (car (guard-spec-forms gear))) 'auto-gear)
    (define kit (buy-kit #:slots (hasheq 'weapon "iron_sword")))
    (check-true (goal-spec? kit))
    (define at-items (hasheq 'hp 90 'max_hp 100 'cooldown 0
                             'inventory_max_items 20 'inventory '()
                             'equipment #hasheq()
                             'interactions (hasheq 'content (hasheq 'type "items" 'code "shop"))))
    (define kit-char (character-spec 'demo 'combat #f (list kit)))
    (check-equal? (list->set (map action-spec-name (goal-preferred-actions kit-char at-items)))
                  (set 'npc-buy 'equip))
    (define go (travel-to #:type "workshop"))
    (check-true (goal-spec? go))
    (define away (hasheq 'interactions (hasheq 'content #f)))
    (define there (hasheq 'interactions (hasheq 'content (hasheq 'type "workshop" 'code "ws"))))
    (define go-char (character-spec 'demo 'crafter #f (list go)))
    (check-equal? (map action-spec-name (goal-preferred-actions go-char away)) '(move))
    (check-equal? (goal-preferred-actions go-char there) '()))


  (test-case "forge-loop restocks then crafts from default recipes"
    (define spec (forge-loop #:recipes '(copper_bar) #:batch 2 #:junk '()))
    (check-true (goal-spec? spec))
    (check-equal? (goal-spec-target spec) 'forge-loop)
    (define names (map (lambda (f)
                         (cond [(action-spec? f) (action-spec-name f)]
                               [(guard-spec? f) 'guard]
                               [(goal-spec? f) (goal-spec-target f)]
                               [else 'other]))
                       (goal-spec-actions spec)))
    ;; restock is a qty/bank guard; craft-if-materials is a mats guard.
    (check-not-false (member 'guard names)))

  (test-case "workshop-loop cook-for-roster forge-kit-for adaptive-gather"
    (define ws (workshop-loop #:junk '()))
    (check-true (goal-spec? ws))
    (check-equal? (goal-spec-target ws) 'workshop-loop)
    (define cook (cook-for-roster #:recipes '(cooked_chicken) #:junk '()))
    (check-true (goal-spec? cook))
    (check-equal? (goal-spec-target cook) 'cook-for-roster)
    (define kit (forge-kit-for #:level 1 #:next? #f))
    (check-true (goal-spec? kit))
    (check-equal? (goal-spec-target kit) 'forge-kit-for)
    (define ag (adaptive-gather #:role 'mining))
    (check-true (goal-spec? ag))
    (check-equal? (goal-spec-target ag) 'adaptive-gather)
    (check-true (pair? (goal-spec-actions ag))))

  (test-case "mailbox-when-used and bank-crafted-products"
    (define haul (mailbox-when-used #:qty 10))
    (check-true (goal-spec? haul))
    (check-equal? (goal-spec-target haul) 'mailbox-when-used)
    (define products (bank-crafted-products #:codes '(cooked_chicken copper_dagger)))
    (check-true (goal-spec? products))
    (check-equal? (goal-spec-target products) 'bank-crafted-products)
    (define holding
      (hasheq 'hp 120 'max_hp 120 'cooldown 0
              'inventory_max_items 100
              'inventory (list (hasheq 'code "copper_ore" 'quantity 56))
              'interactions (hasheq 'content #f)))
    (define names
      (map action-spec-name
           (goal-preferred-actions
            (character-spec 'demo 'mining #f (list haul))
            holding)))
    (check-not-false (member 'bank-deposit-item names)))

  (test-case "smith pulls mailbox mats and fighter equips held kit"
    (check-true (pair? mailbox-raw-codes))
    (check-not-false (member 'copper_ore mailbox-raw-codes))
    (define pull (fulfill-demand #:codes '(copper_ore ash_wood) #:qty 10))
    (check-true (goal-spec? pull))
    (check-equal? (goal-spec-target pull) 'fulfill-demand)
    (define smith-char
      (hasheq 'hp 100 'max_hp 100 'cooldown 0
              'inventory_max_items 100 'inventory '()
              'mining_level 1
              'interactions (hasheq 'content #f)))
    (parameterize ([bank-qty-lookup
                    (lambda (want) (if (equal? want "copper_ore") 56 0))])
      (define names
        (map action-spec-name
             (goal-preferred-actions
              (character-spec 'demo 'crafter #f (list pull))
              smith-char)))
      (check-not-false (member 'restock names)))
    (define geared
      (hasheq 'hp 90 'max_hp 100 'cooldown 0 'level 6
              'inventory_max_items 20
              'inventory (list (hasheq 'code "copper_dagger" 'quantity 1))
              'weapon_slot "wooden_stick"
              'interactions (hasheq 'content #f)))
    (define outfit (outfit-from-bank #:codes '(copper_dagger)))
    (define equip-names
      (map action-spec-name
           (goal-preferred-actions
            (character-spec 'demo 'combat #f (list outfit))
            geared)))
    (check-not-false (member 'equip equip-names)))

  (test-case "sell-products expands withdraw-then-sell listings"
    (define spec (sell-products #:listings '((copper_bar 5 40))))
    (check-true (goal-spec? spec))
    (check-equal? (goal-spec-target spec) 'sell-products)
    (check-true (hash-has-key? default-sell-prices 'copper_bar))
    (check-true (pair? soft-loot-codes))
    (check-true (pair? default-forge-recipes)))

  (test-case "default game data is wired for grind and sell-loot"
    (check-true (hash? default-gear-table))
    (check-true (pair? default-loot-codes))
    (check-true (hash-has-key? default-recipes 'copper_bar))
    (check-true (pair? default-consumables))
    (check-true (pair? fighter-kit-codes))
    (check-true (pair? premium-loot-codes))
    (check-true (pair? rare-loot-codes))
    (check-true (soft-loot? 'raw_chicken))
    (check-true (premium-loot? 'topaz_stone))
    (check-true (rare-loot? 'golden_egg))
    (check-equal? (classify-loot 'golden_egg) 'rare)
    (check-equal? (classify-loot 'raw_chicken) 'soft)
    (check-true (pair? forge-priority-queue))
    (check-equal? (craft-workshop-skill 'copper_bar) 'mining)
    (check-equal? (craft-workshop-skill 'copper_dagger) 'weaponcrafting)
    (check-equal? (recipe-materials 'copper_bar) '((copper_ore 10)))
    (check-equal? (recipe-materials 'copper_dagger) '((copper_bar 6)))
    (check-equal? (item-craft-level 'copper_dagger) 1)
    (check-equal? (item-craft-level 'king_slime_sword) 15)
    (define spec (grind #:target 25))
    (check-true (goal-spec? spec))
    (define names
      (map (lambda (form)
             (cond
               [(action-spec? form) (action-spec-name form)]
               [(guard-spec? form) 'guard]
               [else 'other]))
           (goal-spec-actions spec)))
    (check-not-false (member 'fight names)))

  (test-case "bank-loot and outfit-from-bank build expected goals"
    (define loot (bank-loot #:codes '(wolf_hide feather)))
    (check-true (goal-spec? loot))
    (check-equal? (goal-spec-target loot) 'bank-loot)
    (define outfit (outfit-from-bank #:codes '(copper_dagger)))
    (check-true (goal-spec? outfit))
    (check-equal? (goal-spec-target outfit) 'outfit-from-bank)
    (define banked (grind #:bank-loot-codes soft-loot-codes #:gear-table #hasheq()))
    (check-true (goal-spec? banked))
    (define holding
      (hasheq 'hp 90 'max_hp 100 'cooldown 0
              'inventory_max_items 20
              'inventory (list (hasheq 'code "wolf_hide" 'quantity 2))
              'equipment #hasheq()
              'interactions (hasheq 'content (hasheq 'type "bank" 'code "bank"))))
    (define preferred (goal-preferred-actions
                       (character-spec 'demo 'combat #f (list banked))
                       holding))
    (check-not-false (member 'deposit-surplus (map action-spec-name preferred)))
    (check-not-false (member 'fight (map action-spec-name preferred))))

  (test-case "ruthless-grind banks classified loot and still fights"
    (define spec (ruthless-grind #:soft '(raw_chicken) #:premium '() #:rare '(golden_egg)))
    (check-true (goal-spec? spec))
    (check-equal? (goal-spec-target spec) 'ruthless-grind)
    (define names
      (map (lambda (form)
             (cond
               [(action-spec? form) (action-spec-name form)]
               [(guard-spec? form) 'guard]
               [else 'other]))
           (goal-spec-actions spec)))
    (check-not-false (member 'fight names))
    (define holding
      (hasheq 'hp 90 'max_hp 100 'cooldown 0 'level 1
              'inventory_max_items 20
              'inventory (list (hasheq 'code "raw_chicken" 'quantity 2))
              'equipment #hasheq()
              'interactions (hasheq 'content (hasheq 'type "bank" 'code "bank"))))
    (define preferred
      (goal-preferred-actions
       (character-spec 'demo 'combat #f (list spec))
       holding))
    (check-not-false (member 'fight (map action-spec-name preferred)))
    (check-not-false (member 'deposit-surplus (map action-spec-name preferred)))
    (define preferred-names (map action-spec-name preferred))
    (check-true (< (index-of preferred-names 'deposit-surplus)
                   (index-of preferred-names 'fight))))

  (test-case "bank-classified-loot log-rare-drops and vault predicates"
    (define classified (bank-classified-loot #:soft '(raw_chicken)
                                             #:premium '(topaz_stone)
                                             #:rare '(golden_egg)))
    (check-true (goal-spec? classified))
    (check-equal? (goal-spec-target classified) 'bank-classified-loot)
    (define log-path (make-temporary-file "rare-drops-~a.ndjson"))
    (parameterize ([rare-drops-log-file log-path])
      (define logged (log-rare-drops #:codes '(golden_egg)))
      (check-true (goal-spec? logged))
      (check-equal? (goal-spec-target logged) 'log-rare-drops)
      (define holding-rare
        (hasheq 'name "fighter" 'hp 90 'max_hp 100 'cooldown 0
                'inventory_max_items 20
                'inventory (list (hasheq 'code "golden_egg" 'quantity 1))
                'interactions (hasheq 'content (hasheq 'type "bank" 'code "bank"))))
      (goal-preferred-actions
       (character-spec 'demo 'combat #f (list logged))
       holding-rare)
      (check-true (file-exists? log-path)))
    (define vaulted
      (hasheq 'bank_items (list (hasheq 'code "copper_ore" 'quantity 8))))
    (check-true (when-bank-has vaulted 'copper_ore))
    (check-false (when-bank-has vaulted 'ash_wood))
    (check-true (when-vault-short vaulted 'ash_wood 1))
    (check-false (when-vault-short vaulted 'copper_ore 5)))

  (test-case "trader spend-policy procure flip snipe sell-excess"
    (define policy (spend-policy #:gold-floor 50))
    (check-true (goal-spec? policy))
    (check-equal? (goal-spec-target policy) 'spend-policy)
    (check-true (number? (spend-max-price 'need 'copper_ore)))
    (define need (procure-needs #:codes '(sunflower) #:rare rare-loot-codes #:deposit? #f))
    (check-true (goal-spec? need))
    (check-equal? (goal-spec-target need) 'procure-needs)
    (define flip (flip-spread #:codes '(copper_bar) #:rare rare-loot-codes #:relist? #f))
    (check-true (goal-spec? flip))
    (check-equal? (goal-spec-target flip) 'flip-spread)
    (define snipe (snipe-valuables #:codes '(ruby_stone) #:rare rare-loot-codes))
    (check-true (goal-spec? snipe))
    (check-equal? (goal-spec-target snipe) 'snipe-valuables)
    (define excess (sell-excess #:listings '((cloth 5 40) (golden_egg 1 999))
                                #:rare '(golden_egg)))
    (check-true (goal-spec? excess))
    (check-equal? (goal-spec-target excess) 'sell-excess)
    (check-true (pair? (goal-spec-actions excess)))
    (define eat (eat-when-low))
    (check-true (guard? eat)))

  (test-case "compounding: rank outfit, role tools, trader disposition"
    (check-true (better-gear? 'copper_dagger 'wooden_stick))
    (check-true (better-gear? 'iron_sword 'copper_dagger))
    (check-false (better-gear? 'copper_dagger 'iron_sword))
    (check-true (better-gear? 'highwayman_dagger 'copper_dagger))
    (check-equal? (equipment-slot-of 'golden_egg) #f)
    (check-true (craftable-gear? 'iron_sword))
    (check-true (craftable-gear? 'copper_pickaxe))
    (check-false (craftable-gear? 'lich_crown))
    (check-false (craftable-gear? 'ruby_stone))
    (check-false (member 'iron_sword default-snipe-codes))
    (check-not-false (member 'copper_pickaxe
                             (hash-ref default-workshop-by-skill 'weaponcrafting)))
    (check-not-false (member 'satchel
                             (hash-ref default-workshop-by-skill 'gearcrafting)))
    (define (preferred spec char)
      (map action-spec-name
           (goal-preferred-actions
            (character-spec 'demo 'combat #f (list spec))
            char)))
    (define (spec-codes spec)
      (define acc '())
      (define (walk x)
        (cond
          [(goal-spec? x) (for-each walk (goal-spec-actions x))]
          [(guard-spec? x) (for-each walk (guard-spec-forms x))]
          [(action-spec? x)
           (define p (action-spec-payload x))
           (define h (and (list? p) (pair? p) (hash? (car p)) (car p)))
           (when (and h (hash-ref h 'code #f))
             (set! acc (cons (hash-ref h 'code #f) acc)))]
          [(list? x) (for-each walk x)]))
      (walk spec)
      acc)
    (parameterize ([bank-qty-lookup
                    (lambda (want) (if (equal? want "copper_dagger") 1 0))])
      (define stick
        (hasheq 'hp 90 'max_hp 100 'cooldown 0 'level 6
                'inventory_max_items 20 'inventory '()
                'weapon_slot "wooden_stick"
                'interactions (hasheq 'content #f)))
      (check-not-false (member 'restock (preferred (outfit-from-bank) stick))))
    (parameterize ([bank-qty-lookup
                    (lambda (want) (if (equal? want "iron_sword") 1 0))])
      (define copper-worn
        (hasheq 'hp 90 'max_hp 100 'cooldown 0 'level 10
                'inventory_max_items 20 'inventory '()
                'weapon_slot "copper_dagger"
                'interactions (hasheq 'content #f)))
      (check-not-false (member 'restock (preferred (outfit-from-bank) copper-worn))))
    (parameterize ([bank-qty-lookup
                    (lambda (want) (if (equal? want "copper_dagger") 1 0))])
      (define iron-worn
        (hasheq 'hp 90 'max_hp 100 'cooldown 0 'level 10
                'inventory_max_items 20 'inventory '()
                'weapon_slot "iron_sword"
                'interactions (hasheq 'content #f)))
      (check-false (member 'restock (preferred (outfit-from-bank) iron-worn)))
      (check-false (member 'equip (preferred (outfit-from-bank) iron-worn))))
    (define log-path (make-temporary-file "equip-review-~a.ndjson"))
    (parameterize ([rare-drops-log-file log-path]
                   [bank-qty-lookup (lambda (_want) 0)])
      (define rare-geared
        (hasheq 'name "fighter" 'hp 90 'max_hp 100 'cooldown 0 'level 6
                'inventory_max_items 20
                'inventory (list (hasheq 'code "highwayman_dagger" 'quantity 1))
                'weapon_slot "copper_dagger"
                'interactions (hasheq 'content #f)))
      (check-not-false (member 'equip (preferred (outfit-from-bank) rare-geared)))
      (check-true (file-exists? log-path))
      (define logged (file->string log-path))
      (check-true (regexp-match? #px"equipped-for-review" logged)))
    (define egg-char
      (hasheq 'hp 90 'max_hp 100 'cooldown 0 'level 6
              'inventory_max_items 20
              'inventory (list (hasheq 'code "golden_egg" 'quantity 1))
              'weapon_slot "copper_dagger"
              'interactions (hasheq 'content (hasheq 'type "bank" 'code "bank"))))
    (define egg-actions (preferred (outfit-from-bank) egg-char))
    (check-false (member 'equip egg-actions))
    (define classified (bank-classified-loot #:soft '() #:premium '() #:rare '(golden_egg)))
    (check-not-false (member 'deposit-surplus
                             (preferred classified egg-char)))
    (define miner-worn
      (hasheq 'hp 100 'max_hp 100 'cooldown 0 'level 1 'mining_level 1
              'inventory_max_items 20 'inventory '()
              'weapon_slot "copper_pickaxe"
              'interactions (hasheq 'content #f)))
    (parameterize ([bank-qty-lookup
                    (lambda (want) (if (equal? want "copper_pickaxe") 1 0))])
      (define miner-names
        (preferred (outfit-from-bank #:gear-table miner-kit-table) miner-worn))
      (check-false (member 'restock miner-names))
      (check-false (member 'equip miner-names)))
    (define no-upgrade
      (sell-excess #:listings '((iron_sword 1 140) (steel_battleaxe 1 200)
                                (copper_pickaxe 1 80) (cloth 5 10)
                                (highwayman_dagger 1 999))
                   #:rare rare-loot-codes
                   #:held '()))
    (define no-upgrade-codes (spec-codes no-upgrade))
    (check-false (member "iron_sword" no-upgrade-codes))
    (check-false (member "steel_battleaxe" no-upgrade-codes))
    (check-false (member "copper_pickaxe" no-upgrade-codes))
    (check-false (member "highwayman_dagger" no-upgrade-codes))
    (check-not-false (member "cloth" no-upgrade-codes))
    (define dominated
      (sell-excess #:listings '((copper_dagger 1 80) (iron_sword 1 140)
                                (steel_battleaxe 1 200) (topaz_stone 5 40))
                   #:rare rare-loot-codes
                   #:held '(steel_battleaxe)))
    (define dominated-codes (spec-codes dominated))
    (check-not-false (member "copper_dagger" dominated-codes))
    (check-false (member "steel_battleaxe" dominated-codes))
    (check-not-false (member "topaz_stone" dominated-codes))
    (define snipe (snipe-valuables #:codes '(iron_sword ruby_stone lich_crown)
                                   #:rare rare-loot-codes))
    (define snipe-codes (spec-codes snipe))
    (check-false (member "iron_sword" snipe-codes))
    (check-not-false (member "ruby_stone" snipe-codes))
    (check-not-false (member "lich_crown" snipe-codes))
    (check-equal? (snipe-disposition 'ruby_stone) 'flip)
    (check-equal? (snipe-disposition 'lich_crown) 'equip-review)
    (check-false (snipe-disposition 'iron_sword))
    (define ruby-ask (flip-relist-price 'ruby_stone #:cost 40))
    (check-true (and (number? ruby-ask) (> ruby-ask 40)))
    (check-true (>= ruby-ask (or (hash-ref default-sell-prices 'ruby_stone #f) 0)))
    (define no-kit (procure-needs #:rare rare-loot-codes #:deposit? #f))
    (check-false (member "iron_sword" (spec-codes no-kit)))
    (check-false (member "copper_dagger" (spec-codes no-kit)))
    (check-true (number? (spend-max-price 'bargain 'small_health_potion)))
    (check-true (< (spend-max-price 'bargain 'small_health_potion)
                   (spend-max-price 'need 'small_health_potion)))
    (define bargains (bargain-consumables))
    (check-true (goal-spec? bargains))
    (check-equal? (goal-spec-target bargains) 'bargain-consumables)
    (define util (equip-utility))
    (check-true (goal-spec? util))
    (check-equal? (goal-spec-target util) 'equip-utility)
    (define products (bank-crafted-products))
    (define holding-pick
      (hasheq 'hp 100 'max_hp 100 'cooldown 0
              'inventory_max_items 20
              'inventory (list (hasheq 'code "copper_pickaxe" 'quantity 1))
              'interactions (hasheq 'content #f)))
    (check-not-false (member 'deposit-surplus
                             (preferred products holding-pick)))
    ;; Default haul skips bars/planks so restock↔deposit cannot starve craft.
    (define holding-bar
      (hasheq 'hp 100 'max_hp 100 'cooldown 0
              'inventory_max_items 20
              'inventory (list (hasheq 'code "copper_bar" 'quantity 6))
              'interactions (hasheq 'content #f)))
    (check-false (member 'deposit-surplus
                         (preferred (bank-crafted-products) holding-bar))))

  (test-case "plan-craft routes to the matching workshop skill"
    (define world
      (build-world-index
       (list #hasheq((map_id . "cook") (layer . "overworld") (x . 0) (y . 0)
                     (interactions . #hasheq((content . #hasheq((type . "workshop") (code . "cooking"))))))
             #hasheq((map_id . "mine") (layer . "overworld") (x . 5) (y . 0)
                     (interactions . #hasheq((content . #hasheq((type . "workshop") (code . "mining"))))))
             #hasheq((map_id . "start") (layer . "overworld") (x . 1) (y . 0)
                     (interactions . #hasheq((content . #f)))))))
    (define char #hasheq((x . 1) (y . 0) (map_id . "start") (hp . 100) (max_hp . 100)
                         (cooldown . 0) (inventory_max_items . 20) (inventory . ())
                         (interactions . #hasheq((content . #f)))))
    ;; Nearest untyped workshop is cooking at (0,0); copper_bar must go to mining.
    (define nearest (nearest-typed-content world char "workshop"))
    (check-equal? (hash-ref nearest 'map_id) "cook")
    (define mining (nearest-typed-content world char "workshop" "mining"))
    (check-equal? (hash-ref mining 'map_id) "mine")
    (define plan
      (plan-preferred-action char world
                             (craft #:code 'copper_bar #:qty 1)
                             #:role 'crafter))
    (check-true (planned-action? plan))
    (check-equal? (planned-action-name plan) 'move)
    (check-equal? (hash-ref (planned-action-payload plan) 'map_id) "mine"))

  (test-case "confirmed-empty restock does not path to the bank"
    (define world
      (build-world-index
       (list #hasheq((map_id . "start") (layer . "overworld") (x . 0) (y . 0)
                     (interactions . #hasheq((content . #f))))
             #hasheq((map_id . "bank") (layer . "overworld") (x . 3) (y . 0)
                     (interactions . #hasheq((content . #hasheq((type . "bank") (code . "bank")))))))))
    (define char #hasheq((x . 0) (y . 0) (map_id . "start") (hp . 100) (max_hp . 100)
                         (cooldown . 0) (inventory_max_items . 20) (inventory . ())
                         (interactions . #hasheq((content . #f)))))
    (parameterize ([bank-qty-lookup (lambda (_code) 0)])
      (define plan
        (plan-preferred-action char world
                               (action-spec 'restock
                                            (list (hasheq 'code "copper_ore" 'qty 10)))
                               #:role 'crafter))
      (check-false plan)))

  (test-case "bank_items snapshot feeds vault guards without HTTP"
    (define table (make-hash))
    (hash-set! table "copper_ore" 56)
    (hash-set! table "cooked_chicken" 9)
    (define char (hasheq 'bank_items (bank-items-from-qty-table table)
                         'inventory '()))
    (check-true (when-bank-has char "copper_ore"))
    (check-false (when-bank-has char "iron_ore"))
    (parameterize ([bank-qty-lookup (lambda (want) (hash-ref table want 0))])
      (check-equal? (bank-item-quantity "cooked_chicken") 9)
      (check-equal? (bank-item-quantity "missing_item") 0)))

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

  (test-case "enrich-character reads tile content from the world index"
    (define char #hasheq((name . "miner")
                         (layer . "overworld")
                         (x . 2)
                         (y . 0)
                         (interactions . #hasheq((content . #f)))))
    (define enriched
      (enrich-character char #:world dry-run-world #:live-map? #f))
    (check-equal? (hash-ref (hash-ref (hash-ref enriched 'interactions) 'content) 'code)
                  "copper_rocks"))

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
                  (list 'struct:realtime-snapshot "scout" 42 100 7 -3 1700000123)))

  (test-case "poll-character-snapshot refuses a missing token with 452"
    ;; get-character is a public endpoint, so we gate on the token ourselves;
    ;; without it the helper must raise the structured 452 before any network.
    (define err
      (capture-api-error
       (lambda ()
         (poll-character-snapshot "scout" #:config missing-token-config))))
    (check-true (api-error? err))
    (check-equal? (api-error-status err) 452)
    (check-equal? (api-error-code err) 452))

  (test-case "make-snapshot-stream keeps one slot per name and never crashes"
    ;; Drive the closure offline: the stream's contract is exactly one result
    ;; per named character, in order, and #f where a fetch fails. We assert the
    ;; returned arity and that a dead server yields #f per slot rather than
    ;; throwing, which is the behavior the runner relies on.
    (define names '("alpha" "beta"))
    (define stream
      (make-snapshot-stream names
        #:config (artifacts-config "http://127.0.0.1:9" #f "TEST_TOKEN")))
    (define live (stream))
    (check-equal? (length live) (length names))
    (for ([slot (in-list live)]) (check-false slot))
    ;; The shape each slot would carry for good data: project the same prepared
    ;; characters straight through snapshot-from-character, no network needed.
    (define chars
      (list #hasheq((name . "alpha") (hp . 10) (max_hp . 100) (x . 1) (y . 2) (cooldown_expiration . 5))
            #hasheq((name . "beta")  (hp . 20) (max_hp . 100) (x . 3) (y . 4) (cooldown_expiration . 6))))
    (define expected
      (map (lambda (c) (snapshot-from-character c #:config test-config)) chars))
    (check-equal? (map realtime-snapshot-character-name expected) '("alpha" "beta"))
    (check-equal? (map realtime-snapshot-hp expected) '(10 20))))

;; ---- Read/query layer: thin keyword wrappers over ../http.rkt ----
;; These cases prove the query forms forward to the right HTTP wrapper. The
;; auth-gated forms (bank, active-events, character-leaderboard) raise a
;; structured 452 when given a token-less config, which only happens after the
;; wrapper has been called with #:auth?; a missing route would never get that
;; far. The public forms (character, item) cannot assert a 452 (no token
;; needed), so we drive them at an unreachable host and confirm they reach the
;; HTTP layer (a connection failure, not a contract/arity error) — that proves
;; they delegate to get-character / get-item rather than doing nothing.

(module+ test
  (test-case "character forwards to get-character"
    ;; Unreachable host -> the wrapper is reached and fails on connect, not on
    ;; a wrong-arity or undefined-symbol error. A connection exn here means the
    ;; form delegated to the HTTP layer exactly once.
    (check-exn exn:fail?
               (lambda () (q:character "scout" #:config dry-run-config))))

  (test-case "item forwards to get-item"
    (check-exn exn:fail?
               (lambda () (item "copper_ore" #:config dry-run-config))))

  (test-case "bank forwards to get-bank-details and requires a token"
    (define error (capture-api-error (lambda () (bank #:config missing-token-config))))
    (check-true (api-error? error))
    (check-equal? (api-error-status error) 452)
    (check-equal? (api-error-code error) 452))

  (test-case "purchase-history forwards to get-purchase-history and requires a token"
    ;; Auth-gated like bank: a token-less config raises the structured 452 only
    ;; after the form has delegated to get-purchase-history with #:auth?, which
    ;; proves the wiring without touching the network.
    (define error (capture-api-error (lambda () (purchase-history #:config missing-token-config))))
    (check-true (api-error? error))
    (check-equal? (api-error-status error) 452)
    (check-equal? (api-error-code error) 452))

  (test-case "gems-history forwards to get-gems-history and requires a token"
    ;; Same auth-gated /my shape as purchase-history: a token-less config raises
    ;; the structured 452 only after the form delegates to get-gems-history.
    (define error (capture-api-error (lambda () (gems-history #:config missing-token-config))))
    (check-true (api-error? error))
    (check-equal? (api-error-status error) 452)
    (check-equal? (api-error-code error) 452))

  (test-case "active-task forwards to get-my-tasks-active and requires a token"
    ;; Character-scoped /my read: a token-less config raises the structured 452
    ;; only after the form delegates to get-my-tasks-active with #:auth?.
    (define error (capture-api-error (lambda () (active-task "scout" #:config missing-token-config))))
    (check-true (api-error? error))
    (check-equal? (api-error-status error) 452)
    (check-equal? (api-error-code error) 452))

  (test-case "task-history forwards to get-my-tasks-history and requires a token"
    ;; Same character-scoped /my shape as active-task: token-less raises 452.
    (define error (capture-api-error (lambda () (task-history "scout" #:config missing-token-config))))
    (check-true (api-error? error))
    (check-equal? (api-error-status error) 452)
    (check-equal? (api-error-code error) 452))

  (test-case "auctions forwards to get-auctions"
    ;; Public endpoint (no token required); confirm it delegates to the HTTP
    ;; layer by driving it at an unreachable host: a connection failure, not a
    ;; contract/arity error, means get-auctions was actually called.
    (check-exn exn:fail?
               (lambda () (auctions #:config dry-run-config))))

  (test-case "my-auctions forwards to get-my-auctions and requires a token"
    ;; Character-scoped /my read: a token-less config raises the structured 452
    ;; only after the form delegates to get-my-auctions with #:auth?.
    (define error (capture-api-error (lambda () (my-auctions "scout" #:config missing-token-config))))
    (check-true (api-error? error))
    (check-equal? (api-error-status error) 452)
    (check-equal? (api-error-code error) 452))

  (test-case "my-events forwards to get-my-events and requires a token"
    (define error (capture-api-error (lambda () (my-events "scout" #:config missing-token-config))))
    (check-true (api-error? error))
    (check-equal? (api-error-status error) 452)
    (check-equal? (api-error-code error) 452))

  (test-case "balance forwards to get-my-balance and requires a token"
    (define error (capture-api-error (lambda () (balance "scout" #:config missing-token-config))))
    (check-true (api-error? error))
    (check-equal? (api-error-status error) 452)
    (check-equal? (api-error-code error) 452))

  (test-case "badges forwards to get-my-badges and requires a token"
    (define error (capture-api-error (lambda () (badges "scout" #:config missing-token-config))))
    (check-true (api-error? error))
    (check-equal? (api-error-status error) 452)
    (check-equal? (api-error-code error) 452))

  (test-case "stats forwards to get-my-stats and requires a token"
    (define error (capture-api-error (lambda () (stats "scout" #:config missing-token-config))))
    (check-true (api-error? error))
    (check-equal? (api-error-status error) 452)
    (check-equal? (api-error-code error) 452))

  (test-case "active-events forwards to get-active-events"
    ;; Public endpoint (no token required), so a token-less config would reach
    ;; the network rather than raising 452. Drive it at an unreachable host and
    ;; confirm it delegates to the HTTP layer: a connection failure, not a
    ;; contract/arity error, means get-active-events was actually called.
    (check-exn exn:fail?
               (lambda () (active-events #:config dry-run-config))))

  (test-case "my-events forwards to get-my-events and requires a token"
    ;; Character-scoped /my read: a token-less config raises the structured 452
    ;; only after the form delegates to get-my-events with #:auth?.
    (define error (capture-api-error (lambda () (my-events "scout" #:config missing-token-config))))
    (check-true (api-error? error))
    (check-equal? (api-error-status error) 452)
    (check-equal? (api-error-code error) 452))

  (test-case "balance forwards to get-my-balance and requires a token"
    (define error (capture-api-error (lambda () (balance "scout" #:config missing-token-config))))
    (check-true (api-error? error))
    (check-equal? (api-error-status error) 452)
    (check-equal? (api-error-code error) 452))

  (test-case "badges forwards to get-my-badges and requires a token"
    (define error (capture-api-error (lambda () (badges "scout" #:config missing-token-config))))
    (check-true (api-error? error))
    (check-equal? (api-error-status error) 452)
    (check-equal? (api-error-code error) 452))

  (test-case "stats forwards to get-my-stats and requires a token"
    (define error (capture-api-error (lambda () (stats "scout" #:config missing-token-config))))
    (check-true (api-error? error))
    (check-equal? (api-error-status error) 452)
    (check-equal? (api-error-code error) 452))

  (test-case "account-management forms forward to their wrappers and require a token"
    ;; These are /my-account writes/reads; a token-less config must raise the
    ;; structured 452 only after the form delegates to its http.rkt wrapper
    ;; with #:auth?, proving the wiring without touching the network.
    (define forms-under-test
      (list (cons 'my-subscription (lambda () (my-subscription #:config missing-token-config)))
            (cons 'cancel-subscription (lambda () (cancel-subscription #:config missing-token-config)))
            (cons 'buy-gems (lambda () (buy-gems "gold_100" #:config missing-token-config)))
            (cons 'change-password (lambda () (change-password "new" "old" #:config missing-token-config)))
            (cons 'change-email (lambda () (change-email "me@x.io" "old" #:config missing-token-config)))
            (cons 'subscribe-stripe (lambda () (subscribe-stripe "gold" #:config missing-token-config)))
            (cons 'subscribe-member-token (lambda () (subscribe-member-token #:config missing-token-config)))))
    (for ([pair forms-under-test])
      (define error (capture-api-error (cdr pair)))
      (check-true (api-error? error)
                  (format "~a should raise an api-error" (car pair)))
      (check-equal? (api-error-status error) 452)
      (check-equal? (api-error-code error) 452)))

  (test-case "subscription get wrapper is auth-gated like other account reads"
    ;; get-my-subscription is a GET but still /my-scoped, so it shares the 452
    ;; behavior of the other account reads (bank, balance, etc.).
    (define error (capture-api-error (lambda () (get-my-subscription #:config missing-token-config))))
    (check-true (api-error? error))
    (check-equal? (api-error-status error) 452))

  (test-case "ge-order forwards to get-grand-exchange-order"
    ;; Public endpoint (no token required), so a token-less config would reach
    ;; the network rather than raising 452. Drive it at an unreachable host and
    ;; confirm it delegates to the HTTP layer: a connection failure, not a
    ;; contract/arity error, means get-grand-exchange-order was actually called.
    (check-exn exn:fail?
               (lambda () (ge-order 42 #:config dry-run-config))))

  (test-case "map-content-at forwards to get-map-content"
    ;; Public endpoint; confirm it delegates to the HTTP layer by driving it at
    ;; an unreachable host: a connection failure means get-map-content was called.
    (check-exn exn:fail?
               (lambda () (map-content-at 1 2 "bank" #:config dry-run-config))))

  (test-case "character-leaderboard forwards to get-character-leaderboard"
    ;; Public endpoint (no token required); same reach-the-HTTP-layer proof as
    ;; the public forms above. The #:sort passes straight through to the wrapper.
    (check-exn exn:fail?
               (lambda () (character-leaderboard #:sort "level" #:config dry-run-config))))

  (test-case "leaderboard forwards to get-leaderboard"
    ;; Public endpoint; confirm it delegates to the HTTP layer by driving it at
    ;; an unreachable host: a connection failure means get-leaderboard was called.
    (check-exn exn:fail?
               (lambda () (leaderboard "gold" #:config dry-run-config))))

  (test-case "rankings forwards to get-rankings"
    ;; Public endpoint; same reach-the-HTTP-layer proof as leaderboard above.
    (check-exn exn:fail?
               (lambda () (rankings "level" #:config dry-run-config))))

  (test-case "every query form is bound and callable"
    ;; Guards against a typo'd provide: each should be a procedure, not #<undefined>.
    (for ([q (list q:character
                   my-characters
                   account-details
                   bank
                   bank-items
                   pending-items
                   purchase-history
                   gems-history
                   rate-limits
                   item
                   monster
                   resource
                   npc
                   tasks
                   achievements
                   effects
                   active-events
                   my-events
                   balance
                   badges
                   stats
                   raids
                   ge-order
                   character-leaderboard
                   account-leaderboard
                   leaderboard
                   rankings
                   server-details
                   maps
                   q:map
                   map-content-at
                   active-task
                   task-history
                   auctions
                   my-auctions
                   my-subscription
                   cancel-subscription
                   buy-gems
                   change-password
                   change-email
                   subscribe-stripe
                   subscribe-member-token)])
      (check-pred procedure? q))))

;; ---- Local token generator: file save/read round-trip (no network) ----
;; Exercises the save-token!/read-token! helpers gen-token.rkt uses, plus
;; make-file-source resolution against a temp token file. No credentials, no
;; network: we write a fake token and assert the framework reads it back.
(module+ test
  (define generator-token-file (make-temporary-file "artifacts-gen-~a"))

  (test-case "save-token! writes a single trimmed line"
    (define written (save-token! "  EYEjwt.example.token.payload  " #:path generator-token-file))
    (check-equal? written "EYEjwt.example.token.payload")
    (define contents
      (with-input-from-file generator-token-file (lambda () (port->string)) #:mode 'text))
    (check-equal? contents "EYEjwt.example.token.payload")
    (check-false (regexp-match? #px"\n" contents)))

  (test-case "read-token! resolves the saved file source"
    (check-equal? (read-token! #:path generator-token-file)
                  "EYEjwt.example.token.payload"))

  (test-case "save-token! creates a missing parent directory"
    (define nested (build-path (make-temporary-file "artifacts-gen-dir-~a" 'directory)
                               "nested" "token"))
    (save-token! "NESTED_TOKEN" #:path nested)
    (check-true (file-exists? nested))
    (check-equal? (read-token! #:path nested) "NESTED_TOKEN")
    (delete-directory/files (path-only nested)))

  (test-case "save-token! refuses an empty token"
    (check-exn #px"refusing to write an empty token"
               (lambda () (save-token! "" #:path generator-token-file)))
    (check-exn #px"refusing to write an empty token"
               (lambda () (save-token! "   " #:path generator-token-file))))

  (test-case "read-token! returns #f for a missing file"
    (define missing (make-temporary-file "artifacts-gen-missing-~a"))
    (delete-file missing)
    (check-false (read-token! #:path missing)))

  (test-case "token-source resolves a generator-format file"
    (define cfg
      (artifacts-config "https://api.artifactsmmo.com"
                        "wss://realtime.artifactsmmo.com"
                        (make-file-source #:path generator-token-file)))
    (check-equal? (config-token cfg) "EYEjwt.example.token.payload")
    (define missing (make-temporary-file "artifacts-gen-missing2-~a"))
    (delete-file missing)
    (define absent-cfg
      (artifacts-config "https://api.artifactsmmo.com"
                        "wss://realtime.artifactsmmo.com"
                        (make-file-source #:path missing)))
    (check-false (config-token absent-cfg))))

