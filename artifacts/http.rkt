#lang racket

(require json
         net/uri-codec
         net/url
         racket/string
         "config.rkt")

(provide (struct-out api-error)
         (struct-out exn:fail:artifacts-api)
         api-get
         api-post
         ensure-authenticated!
         api-error-from-response
         decode-api-response
         request-url
         request-headers
         pagination-params
         get-server-details
         get-account-details
         get-my-characters
         get-character
         create-character
         delete-character
         known-character-skins
         character-skin-string
         valid-character-skin?
         valid-character-name?
         character-name-string
         get-bank-details
         get-bank-items
         get-my-grand-exchange-orders
         get-my-grand-exchange-history
         get-pending-items
         get-purchase-history
         get-gems-history
         get-my-tasks-active
         get-my-tasks-history
         get-my-auctions
         get-my-events
         get-my-balance
         get-my-badges
         get-my-stats
         get-rate-limits
         get-account-logs
         get-character-logs
         get-maps
         get-map
         get-map-by-id
         get-items
         get-item
         get-monsters
         get-monster
         get-resources
         get-resource
         get-npcs
         get-npc
         get-npc-items
         get-npc-item
         get-tasks
         get-task
         get-achievements
         get-effects
         get-grand-exchange-orders
         get-grand-exchange-order
         get-grand-exchange-history
         get-auctions
         get-events
         get-active-events
         get-event
         get-raids
         get-raid
         get-raid-leaderboard
         get-character-leaderboard
         get-account-leaderboard
         get-leaderboard
         get-rankings
         simulate-fight
         action-move
         action-transition
         action-rest
         action-equip
         action-unequip
         action-use
         action-fight
         action-gather
         action-craft
         action-recycle
         action-bank-deposit-item
         action-bank-deposit-gold
         action-bank-withdraw-item
         action-bank-withdraw-gold
         action-bank-buy-expansion
         action-npc-buy
         action-npc-sell
         action-grand-exchange-buy
         action-grand-exchange-create-sell-order
         action-grand-exchange-create-buy-order
         action-grand-exchange-cancel
         action-grand-exchange-fill
         action-task-new
         action-task-complete
         action-task-cancel
         action-task-exchange
         action-task-trade
         action-give-gold
         action-give-item
         action-claim-item
         action-delete-item
         action-change-skin)

(struct api-error (status code message details retry-after cooldown-until) #:transparent)
(struct exn:fail:artifacts-api exn:fail (error) #:transparent)

(define authentication-error-code 452)

(define (->query-value value)
  (cond
    [(symbol? value) (symbol->string value)]
    [else (format "~a" value)]))

(define (present-token? token)
  (and (string? token)
       (regexp-match? #px"\\S" token)))

(define (compact-params params)
  (filter values params))

(define (pagination-params #:page [page 1] #:size [size 50])
  `((page . ,page) (size . ,size)))

(define (request-url config path params)
  (define query
    (and (pair? params)
         (alist->form-urlencoded
          (for/list ([item (compact-params params)])
            (cons (car item) (->query-value (cdr item)))))))
  (string->url
   (string-append (string-trim (artifacts-config-base-url config) "/" #:right? #t)
                  path
                  (if query (string-append "?" query) ""))))

(define (format-api-error-message status message)
  (format "Artifacts API error ~a: ~a" status message))

(define (raise-api-error error)
  (raise
   (exn:fail:artifacts-api
    (format-api-error-message (api-error-status error) (api-error-message error))
    (current-continuation-marks)
    error)))

(define (missing-auth-error)
  (api-error authentication-error-code
             authentication-error-code
             "Missing Artifacts bearer token."
             #hasheq((source . "client"))
             #f
             #f))

;; Raises a structured 452 api-error when the config carries no usable token.
;; Exported so callers (like the realtime polling layer) can refuse to fire a
;; public, non-auth-gated endpoint with no credentials instead of letting the
;; request silently fail mid-network.
(define (ensure-authenticated! config)
  (unless (present-token? (artifacts-config-token config))
    (raise-api-error (missing-auth-error))))

(define (request-headers config #:auth? [auth? #f])
  (when auth?
    (ensure-authenticated! config))
  (filter values
          (list "Accept: application/json"
                "Content-Type: application/json"
                (and (present-token? (artifacts-config-token config))
                     (string-append "Authorization: Bearer "
                                    (artifacts-config-token config))))))

(define (hash-ref/default value key default)
  (if (hash? value) (hash-ref value key default) default))

(define (api-error-from-response status headers body)
  (define error-body (hash-ref/default body 'error #f))
  (define details (cond
                    [(hash? error-body) error-body]
                    [(hash? body) body]
                    [else #hasheq()]))
  (define data (hash-ref/default details 'data #f))
  (api-error status
             (hash-ref/default details 'code status)
             (hash-ref/default details 'message "Request failed.")
             details
             (hash-ref/default headers 'retry-after #f)
             (hash-ref/default data 'cooldown_expiration #f)))

(define (decode-api-response status headers body)
  (if (or (>= status 400)
          (and (hash? body) (hash-has-key? body 'error)))
      (raise-api-error (api-error-from-response status headers body))
      body))

(define (read-response port)
  (decode-api-response 200 #hasheq() (read-json port)))

(define (api-get path #:params [params '()] #:config [config (current-config)] #:auth? [auth? #f])
  (define url (request-url config path params))
  (call/input-url url
                  (lambda (target-url)
                    (get-pure-port target-url (request-headers config #:auth? auth?)))
                  read-response))

(define (api-post path #:body [body #hasheq()] #:config [config (current-config)] #:auth? [auth? #f])
  (define url (request-url config path '()))
  (define payload (jsexpr->bytes body))
  (call/input-url url
                  (lambda (target-url)
                    (post-pure-port target-url payload (request-headers config #:auth? auth?)))
                  read-response))

(define (paged-get path #:params [params '()] #:page [page 1] #:size [size 50] #:config [config (current-config)] #:auth? [auth? #f])
  (api-get path
           #:params (append params (pagination-params #:page page #:size size))
           #:config config
           #:auth? auth?))

(define (get-server-details #:config [config (current-config)])
  (api-get "/" #:config config))

(define (get-account-details #:config [config (current-config)])
  (api-get "/my/details" #:config config #:auth? #t))

(define (get-my-characters #:page [page 1] #:size [size 50] #:config [config (current-config)])
  (paged-get "/my/characters" #:page page #:size size #:config config #:auth? #t))

(define (get-character name #:config [config (current-config)])
  (api-get (format "/characters/~a" name) #:config config))

(define known-character-skins
  '("men1" "men2" "men3"
    "women1" "women2" "women3"
    "corrupted1" "zombie1" "marauder1"))

(define (character-skin-string skin)
  (cond
    [(string? skin) skin]
    [(symbol? skin) (symbol->string skin)]
    [else (error 'character-skin-string "expected skin symbol or string, got ~v" skin)]))

(define (valid-character-skin? skin)
  (member (character-skin-string skin) known-character-skins))

(define (character-name-string name)
  (cond
    [(string? name) name]
    [(symbol? name) (symbol->string name)]
    [else (error 'character-name-string "expected name symbol or string, got ~v" name)]))

(define (valid-character-name? name)
  (regexp-match #px"^[a-zA-Z0-9_-]{3,12}$" (character-name-string name)))

(define (create-character name
                          #:skin [skin "men1"]
                          #:config [config (current-config)])
  (define name* (character-name-string name))
  (unless (valid-character-name? name*)
    (error 'create-character
           "character name must be 3-12 alphanumeric, hyphen, or underscore characters, got ~a"
           name*))
  (unless (valid-character-skin? skin)
    (error 'create-character "unknown character skin ~v" skin))
  (api-post "/characters/create"
            #:body (hasheq 'name name* 'skin (character-skin-string skin))
            #:config config
            #:auth? #t))

(define (delete-character name #:config [config (current-config)])
  (define name* (character-name-string name))
  (api-post "/characters/delete"
            #:body (hasheq 'name name*)
            #:config config
            #:auth? #t))

(define (get-bank-details #:config [config (current-config)])
  (api-get "/my/bank" #:config config #:auth? #t))

(define (get-bank-items #:item-code [item-code #f] #:page [page 1] #:size [size 50] #:config [config (current-config)])
  (paged-get "/my/bank/items"
             #:params (compact-params (list (and item-code (cons 'item_code item-code))))
             #:page page
             #:size size
             #:config config
             #:auth? #t))

(define (get-my-grand-exchange-orders #:code [code #f] #:type [type #f] #:page [page 1] #:size [size 50] #:config [config (current-config)])
  (paged-get "/my/grandexchange/orders"
             #:params (compact-params (list (and code (cons 'code code))
                                            (and type (cons 'type type))))
             #:page page
             #:size size
             #:config config
             #:auth? #t))

(define (get-my-grand-exchange-history #:id [id #f] #:code [code #f] #:page [page 1] #:size [size 50] #:config [config (current-config)])
  (paged-get "/my/grandexchange/history"
             #:params (compact-params (list (and id (cons 'id id))
                                            (and code (cons 'code code))))
             #:page page
             #:size size
             #:config config
             #:auth? #t))

(define (get-pending-items #:page [page 1] #:size [size 50] #:config [config (current-config)])
  (paged-get "/my/pending_items" #:page page #:size size #:config config #:auth? #t))

;; Records of gems and subscriptions your account has bought. Auth-gated like
;; the other /my reads: a token-less config raises the structured 452 before
;; any request leaves the process.
(define (get-purchase-history #:page [page 1] #:size [size 50] #:config [config (current-config)])
  (paged-get "/my/purchase_history" #:page page #:size size #:config config #:auth? #t))

;; Gem credit and debit records (purchases, conversions, refunds) for the
;; account. Same auth-gated /my shape as purchase history: a missing token
;; raises the structured 452 before any request leaves the process.
(define (get-gems-history #:page [page 1] #:size [size 50] #:config [config (current-config)])
  (paged-get "/my/gems_history" #:page page #:size size #:config config #:auth? #t))

;; The task a character is currently working, if any. Character-scoped /my
;; read: a token-less config raises the structured 452 before any request.
(define (get-my-tasks-active name #:config [config (current-config)])
  (api-get (format "/my/~a/tasks/active" (character-name-string name))
           #:config config #:auth? #t))

;; A character's completed-task history, paginated. Same character-scoped /my
;; shape; a missing token raises the structured 452 before the request leaves.
(define (get-my-tasks-history name #:page [page 1] #:size [size 50] #:config [config (current-config)])
  (paged-get (format "/my/~a/tasks/history" (character-name-string name))
             #:page page #:size size #:config config #:auth? #t))

;; Auctions this character has listed, paginated. Character-scoped /my read:
;; a token-less config raises the structured 452 before any request leaves.
(define (get-my-auctions name #:page [page 1] #:size [size 50] #:config [config (current-config)])
  (paged-get (format "/my/~a/auctions" (character-name-string name))
             #:page page #:size size #:config config #:auth? #t))

;; A character's active event, if any. Character-scoped /my read: a token-less
;; config raises the structured 452 before any request leaves the process.
(define (get-my-events name #:config [config (current-config)])
  (api-get (format "/my/~a/events" (character-name-string name)) #:config config #:auth? #t))

;; A character's gold balance. Character-scoped /my read: a token-less config
;; raises the structured 452 before any request leaves the process.
(define (get-my-balance name #:config [config (current-config)])
  (api-get (format "/my/~a/balance" (character-name-string name)) #:config config #:auth? #t))

;; A character's earned badges. Character-scoped /my read: a token-less config
;; raises the structured 452 before any request leaves the process.
(define (get-my-badges name #:config [config (current-config)])
  (api-get (format "/my/~a/badges" (character-name-string name)) #:config config #:auth? #t))

;; A character's total stats. Character-scoped /my read: a token-less config
;; raises the structured 452 before any request leaves the process.
(define (get-my-stats name #:config [config (current-config)])
  (api-get (format "/my/~a/stats" (character-name-string name)) #:config config #:auth? #t))

(define (get-rate-limits #:config [config (current-config)])
  (api-get "/my/rates" #:config config #:auth? #t))

(define (get-account-logs #:page [page 1] #:size [size 50] #:config [config (current-config)])
  (paged-get "/my/logs" #:page page #:size size #:config config #:auth? #t))

(define (get-character-logs name #:page [page 1] #:size [size 50] #:config [config (current-config)])
  (paged-get (format "/my/logs/~a" name) #:page page #:size size #:config config #:auth? #t))

(define (get-maps #:layer [layer #f] #:page [page 1] #:size [size 100] #:config [config (current-config)])
  (paged-get (if layer (format "/maps/~a" layer) "/maps") #:page page #:size size #:config config))

(define (get-map layer x y #:config [config (current-config)])
  (api-get (format "/maps/~a/~a/~a" layer x y) #:config config))

(define (get-map-by-id map-id #:config [config (current-config)])
  (api-get (format "/maps/id/~a" map-id) #:config config))

(define (get-items #:page [page 1] #:size [size 100] #:config [config (current-config)])
  (paged-get "/items" #:page page #:size size #:config config))

(define (get-item code #:config [config (current-config)])
  (api-get (format "/items/~a" code) #:config config))

(define (get-monsters #:page [page 1] #:size [size 100] #:config [config (current-config)])
  (paged-get "/monsters" #:page page #:size size #:config config))

(define (get-monster code #:config [config (current-config)])
  (api-get (format "/monsters/~a" code) #:config config))

(define (get-resources #:page [page 1] #:size [size 100] #:config [config (current-config)])
  (paged-get "/resources" #:page page #:size size #:config config))

(define (get-resource code #:config [config (current-config)])
  (api-get (format "/resources/~a" code) #:config config))

(define (get-npcs #:page [page 1] #:size [size 100] #:config [config (current-config)])
  (paged-get "/npcs/details" #:page page #:size size #:config config))

(define (get-npc code #:config [config (current-config)])
  (api-get (format "/npcs/details/~a" code) #:config config))

(define (get-npc-items #:page [page 1] #:size [size 100] #:config [config (current-config)])
  (paged-get "/npcs/items" #:page page #:size size #:config config))

(define (get-npc-item code #:config [config (current-config)])
  (api-get (format "/npcs/items/~a" code) #:config config))

(define (get-tasks #:page [page 1] #:size [size 100] #:config [config (current-config)])
  (paged-get "/tasks/list" #:page page #:size size #:config config))

(define (get-task code #:config [config (current-config)])
  (api-get (format "/tasks/list/~a" code) #:config config))

(define (get-achievements #:page [page 1] #:size [size 100] #:config [config (current-config)])
  (paged-get "/achievements" #:page page #:size size #:config config))

(define (get-effects #:page [page 1] #:size [size 100] #:config [config (current-config)])
  (paged-get "/effects" #:page page #:size size #:config config))

(define (get-grand-exchange-orders #:code [code #f]
                                   #:type [type #f]
                                   #:page [page 1]
                                   #:size [size 100]
                                   #:config [config (current-config)])
  (paged-get "/grandexchange/orders"
             #:params (compact-params (list (and code (cons 'code code))
                                            (and type (cons 'type type))))
             #:page page
             #:size size
             #:config config))

;; A single public Grand Exchange sell order by its id. Mirrors the plural
;; /grandexchange/orders list but addresses one order directly, so bots can
;; re-check a specific listing's price and remaining quantity before buying.
(define (get-grand-exchange-order id #:config [config (current-config)])
  (api-get (format "/grandexchange/orders/~a" id) #:config config))

(define (get-grand-exchange-history code #:page [page 1] #:size [size 50] #:config [config (current-config)])
  (paged-get (format "/grandexchange/history/~a" code) #:page page #:size size #:config config))

;; Public auction house listings, paginated (no token needed).
(define (get-auctions #:page [page 1] #:size [size 50] #:config [config (current-config)])
  (paged-get "/auctions" #:page page #:size size #:config config))

(define (get-events #:page [page 1] #:size [size 100] #:config [config (current-config)])
  (paged-get "/events" #:page page #:size size #:config config))

(define (get-active-events #:page [page 1] #:size [size 100] #:config [config (current-config)])
  (paged-get "/events/active" #:page page #:size size #:config config))

(define (get-event code #:config [config (current-config)])
  (api-get (format "/events/~a" code) #:config config))

(define (get-raids #:page [page 1] #:size [size 100] #:config [config (current-config)])
  (paged-get "/raids" #:page page #:size size #:config config))

(define (get-raid code #:config [config (current-config)])
  (api-get (format "/raids/~a" code) #:config config))

(define (get-raid-leaderboard code #:page [page 1] #:size [size 50] #:config [config (current-config)])
  (paged-get (format "/raids/~a/leaderboard" code) #:page page #:size size #:config config))

(define (get-character-leaderboard #:sort [sort #f]
                                   #:page [page 1]
                                   #:size [size 50]
                                   #:config [config (current-config)])
  (api-get "/leaderboard/characters"
           #:params (append `((page . ,page) (size . ,size))
                            (if sort `((sort . ,sort)) '()))
           #:config config))

(define (get-account-leaderboard #:sort [sort #f]
                                 #:page [page 1]
                                 #:size [size 50]
                                 #:config [config (current-config)])
  (api-get "/leaderboard/accounts"
           #:params (append `((page . ,page) (size . ,size))
                            (if sort `((sort . ,sort)) '()))
           #:config config))

;; Generic column leaderboard, e.g. level/gold/fame. Public, paged, sorted by
;; the requested column.
(define (get-leaderboard column #:sort [sort #f] #:page [page 1] #:size [size 50] #:config [config (current-config)])
  (api-get (format "/leaderboard/~a" column)
           #:params (append `((page . ,page) (size . ,size))
                            (if sort `((sort . ,sort)) '()))
           #:config config))

;; Account rankings by column (the account-wide variant of the column
;; leaderboard). Public, paged, sorted by the requested column.
(define (get-rankings column #:sort [sort #f] #:page [page 1] #:size [size 50] #:config [config (current-config)])
  (api-get (format "/rankings/~a" column)
           #:params (append `((page . ,page) (size . ,size))
                            (if sort `((sort . ,sort)) '()))
           #:config config))


(define (simulate-fight body #:config [config (current-config)])
  (api-post "/simulation/fight" #:body body #:config config))

(define (character-action-path name action)
  (format "/my/~a/action/~a" name action))

(define (character-action name action #:body [body #hasheq()] #:config [config (current-config)])
  (api-post (character-action-path name action) #:body body #:config config #:auth? #t))

(define (action-move name #:map-id [map-id #f] #:x [x #f] #:y [y #f] #:config [config (current-config)])
  (define body
    (cond
      [map-id (hasheq 'map_id map-id)]
      [(and x y) (hasheq 'x x 'y y)]
      [else (error 'action-move "expected either #:map-id or both #:x and #:y")]))
  (character-action name "move" #:body body #:config config))

(define (action-transition name #:config [config (current-config)])
  (character-action name "transition" #:config config))

(define (action-rest name #:config [config (current-config)])
  (character-action name "rest" #:config config))

(define (action-equip name items #:config [config (current-config)])
  (character-action name "equip" #:body items #:config config))

(define (action-unequip name items #:config [config (current-config)])
  (character-action name "unequip" #:body items #:config config))

(define (action-use name item #:config [config (current-config)])
  (character-action name "use" #:body item #:config config))

(define (action-fight name #:participants [participants '()] #:config [config (current-config)])
  (character-action name "fight"
                    #:body (hasheq 'participants participants)
                    #:config config))

(define (action-gather name #:config [config (current-config)])
  (character-action name "gathering" #:config config))

(define (action-craft name craft #:config [config (current-config)])
  (character-action name "crafting" #:body craft #:config config))

(define (action-recycle name item #:config [config (current-config)])
  (character-action name "recycling" #:body item #:config config))

(define (action-bank-deposit-item name items #:config [config (current-config)])
  (character-action name "bank/deposit/item" #:body items #:config config))

(define (action-bank-deposit-gold name gold #:config [config (current-config)])
  (character-action name "bank/deposit/gold" #:body (hasheq 'quantity gold) #:config config))

(define (action-bank-withdraw-item name items #:config [config (current-config)])
  (character-action name "bank/withdraw/item" #:body items #:config config))

(define (action-bank-withdraw-gold name gold #:config [config (current-config)])
  (character-action name "bank/withdraw/gold" #:body (hasheq 'quantity gold) #:config config))

(define (action-bank-buy-expansion name #:config [config (current-config)])
  (character-action name "bank/buy_expansion" #:config config))

(define (action-npc-buy name item #:config [config (current-config)])
  (character-action name "npc/buy" #:body item #:config config))

(define (action-npc-sell name item #:config [config (current-config)])
  (character-action name "npc/sell" #:body item #:config config))

(define (action-grand-exchange-buy name order #:config [config (current-config)])
  (character-action name "grandexchange/buy" #:body order #:config config))

(define (action-grand-exchange-create-sell-order name order #:config [config (current-config)])
  (character-action name "grandexchange/create_sell_order" #:body order #:config config))

(define (action-grand-exchange-create-buy-order name order #:config [config (current-config)])
  (character-action name "grandexchange/create_buy_order" #:body order #:config config))

(define (action-grand-exchange-cancel name order #:config [config (current-config)])
  (character-action name "grandexchange/cancel" #:body order #:config config))

(define (action-grand-exchange-fill name order #:config [config (current-config)])
  (character-action name "grandexchange/fill" #:body order #:config config))

(define (action-task-new name #:config [config (current-config)])
  (character-action name "task/new" #:config config))

(define (action-task-complete name #:config [config (current-config)])
  (character-action name "task/complete" #:config config))

(define (action-task-cancel name #:config [config (current-config)])
  (character-action name "task/cancel" #:config config))

(define (action-task-exchange name #:config [config (current-config)])
  (character-action name "task/exchange" #:config config))

(define (action-task-trade name item #:config [config (current-config)])
  (character-action name "task/trade" #:body item #:config config))

(define (action-give-gold name payload #:config [config (current-config)])
  (character-action name "give/gold" #:body payload #:config config))

(define (action-give-item name payload #:config [config (current-config)])
  (character-action name "give/item" #:body payload #:config config))

(define (action-claim-item name id #:config [config (current-config)])
  (character-action name (format "claim_item/~a" id) #:config config))

(define (action-delete-item name item #:config [config (current-config)])
  (character-action name "delete" #:body item #:config config))

(define (action-change-skin name skin #:config [config (current-config)])
  (character-action name "change_skin" #:body skin #:config config))
