#lang racket

(require rackunit
         json
         "../../artifacts/config.rkt"
         "../bridge/session.rkt"
         "../bridge/visualizer.rkt"
         "../bridge/realtime.rkt")

(define missing-token-config
  (artifacts-config "https://api.artifactsmmo.com"
                    "wss://realtime.artifactsmmo.com"
                    #f))

(module+ test
  (test-case "visual protocol helpers build snapshot envelopes"
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

  (test-case "market signal message carries score fields"
    (define signal (market-signal-message "iron_ore" 7 0.82 #:x 0 #:y 1))
    (check-equal? (hash-ref signal 'type) "market.signal")
    (check-equal? (hash-ref (hash-ref signal 'data) 'code) "iron_ore")
    (check-equal? (hash-ref (hash-ref signal 'data) 'spread) 7)
    (check-equal? (hash-ref (hash-ref signal 'data) 'score) 0.82))

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

  (test-case "bidirectional protocol helpers"
    (define status (session-status-message-proto #:authenticated #f #:characters '()))
    (check-equal? (hash-ref status 'type) "session.status")
    (define result (action-result-message-proto "alice" 'move #:ok #f #:error-code 452 #:message "Missing"))
    (check-equal? (hash-ref result 'type) "action.result")
    (check-equal? (hash-ref (hash-ref result 'data) 'error_code) 452)
    (define logs (account-logs-message-proto (list #hasheq((type . "move") (description . "ok")))))
    (check-equal? (hash-ref logs 'type) "account.logs"))

  (test-case "session.auth command without token stays unauthenticated"
    (stop-session-service!)
    (session-logout!)
    (session-handle-command! #hasheq((type . "session.auth") (data . #hasheq((token . "")))))
    (check-false (session-authenticated?))
    (session-handle-command!
     #hasheq((type . "player.action")
             (data . #hasheq((character . "alice") (action . "rest") (payload . #hasheq())))))
    (check-false (session-authenticated?)))

  (test-case "hub helpers track session ownership"
    (check-false (hub-alive?))
    (check-false (session-owns-snapshots?)))

  (test-case "enrich-character-visual includes inventory and gold"
    (define char #hasheq((name . "alice")
                         (layer . "overworld")
                         (x . 1)
                         (y . 2)
                         (hp . 10)
                         (max_hp . 20)
                         (gold . 5)
                         (cooldown . 0)
                         (inventory_max_items . 20)
                         (inventory . (#hasheq((code . "ash_wood") (quantity . 3))))))
    (define visual (enrich-character-visual char))
    (check-equal? (hash-ref visual 'gold) 5)
    (check-equal? (hash-ref (hash-ref visual 'inventory) 'used) 3))

  (test-case "standalone hub starts and stops without bot"
    (stop-session-service!)
    (stop-visualizer-hub!)
    (check-true (start-visualizer-hub! #:port 8797 #:enabled? #t))
    (check-true (hub-alive?))
    (start-session-service! #:config missing-token-config #:poll-seconds 60 #:load-world? #f)
    (check-true (session-owns-snapshots?))
    (check-false (session-authenticated?))
    (stop-session-service!)
    (stop-visualizer-hub!)
    (check-false (hub-alive?))
    (check-false (session-owns-snapshots?)))

  (test-case "other-character visuals are marked other"
    (define visual
      (other-character-visual
       "wanderer"
       #hasheq((name . "wanderer")
               (layer . "overworld")
               (x . 1)
               (y . 2)
               (level . 8)
               (hp . 20)
               (max_hp . 30)
               (skin . "women1")
               (cooldown . 0))))
    (check-true (hash-ref visual 'other))
    (check-equal? (hash-ref visual 'name) "wanderer")
    (check-equal? (hash-ref visual 'x) 1))

  (test-case "session owns snapshots for visual-only watch"
    (stop-session-service!)
    (session-owns-snapshots? #f)
    (check-false (session-owns-snapshots?))
    (start-session-service! #:config missing-token-config #:poll-seconds 60 #:load-world? #f)
    (check-true (session-owns-snapshots?))
    (stop-session-service!)
    (check-false (session-owns-snapshots?)))

  (test-case "realtime ingest stays opt-in and non-fatal"
    (check-false (realtime-enabled?))
    (check-false (start-realtime-ingest! #:config missing-token-config))
    (check-equal? (realtime-online-characters) '())
    (stop-realtime-ingest!))

  (test-case "world.snapshot characters can mark other official players"
    (define sample
      (hasheq 'name "WorldHero"
              'layer "overworld"
              'x 3
              'y 4
              'other #t
              'level 12))
    (define snap
      (world-snapshot-message
       #:characters (list sample)
       #:raids (list #hasheq((code . "raid_1") (layer . "overworld") (x . 1) (y . 1)))
       #:events (list #hasheq((code . "evt_1") (layer . "overworld") (x . 2) (y . 2)))))
    (define chars (hash-ref (hash-ref snap 'data) 'characters))
    (check-true (hash-ref (car chars) 'other))
    (check-equal? (length (hash-ref (hash-ref snap 'data) 'raids)) 1)
    (check-equal? (length (hash-ref (hash-ref snap 'data) 'events)) 1))

  (test-case "player.action protocol rejects missing fields without throwing"
    (stop-session-service!)
    (session-logout!)
    (session-handle-command!
     #hasheq((type . "player.action")
             (data . #hasheq((character . "alice")))))
    (session-handle-command!
     #hasheq((type . "ui.subscribe") (data . #hasheq())))
    (check-false (session-authenticated?)))

  (test-case "action.result and session.status helpers used by bridge"
    (define status (session-status-message #:error #f))
    (check-equal? (hash-ref status 'type) "session.status")
    (check-false (hash-ref (hash-ref status 'data) 'authenticated))
    (define result (action-result-message "alice" 'gather #:ok #t #:message "ok"))
    (check-equal? (hash-ref result 'type) "action.result")
    (check-true (hash-ref (hash-ref result 'data) 'ok)))

  (test-case "cooldown-from-action-response extracts expiration"
    (check-equal?
     (cooldown-from-action-response
      #hasheq((data . #hasheq((cooldown_expiration . "2026-07-09T12:00:00Z")))))
     "2026-07-09T12:00:00Z")
    (check-equal?
     (cooldown-from-action-response
      #hasheq((data . #hasheq((character . #hasheq((cooldown_expiration . "soon")))))))
     "soon")
    (check-false (cooldown-from-action-response #hasheq((data . #hasheq())))))

  (test-case "player.select updates session selected name"
    (stop-session-service!)
    (session-logout!)
    (session-handle-command!
     #hasheq((type . "player.select") (data . #hasheq((character . "Alice")))))
    (define status (session-status-message))
    (check-equal? (hash-ref (hash-ref status 'data) 'selected) "Alice")
    (session-logout!))

  (test-case "merge-other-characters prefers realtime then leaderboard"
    (define a (list #hasheq((name . "A") (other . #t) (x . 1) (y . 1))))
    (define b (list #hasheq((name . "B") (other . #t) (x . 2) (y . 2))
                    #hasheq((name . "A") (other . #t) (x . 9) (y . 9))))
    (define merged (merge-other-characters a b #:limit 10))
    (check-equal? (length merged) 2)
    (check-equal? (hash-ref (car merged) 'name) "A")
    (check-equal? (hash-ref (car merged) 'x) 1)))
