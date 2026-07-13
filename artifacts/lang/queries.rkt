#lang racket

;; Read/query layer for the Artifacts MMO. These forms are thin, keyword-based
;; wrappers over the HTTP functions in ../http.rkt. They mirror the API's read
;; surface so a bot author can pull world and account state with plain Racket
;; calls instead of threading `#:config` through raw `get-*` functions.
;;
;; Every form accepts `#:config` (defaulting to `(current-config)`) and returns
;; the decoded response body. The HTTP layer already strips the envelope and
;; raises a structured api-error on failure, so there is nothing to unwrap here.
;;
;; Pagination and `code` filters are passed straight through to the wrappers.
;; `map` keeps the positional (layer x y) signature of get-map because a tile is
;; naturally addressed by three coordinates rather than a keyword bag.

(require "../http.rkt"
         "../config.rkt")

(provide character
         my-characters
         account-details
         bank
         bank-items
         pending-items
        purchase-history
        gems-history
        active-task
        task-history
        auctions
        my-auctions
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
         my-subscription
         cancel-subscription
         buy-gems
         change-password
         change-email
         subscribe-stripe
         subscribe-member-token
         ge-order
        character-leaderboard
        account-leaderboard
        leaderboard
        rankings
        server-details
        maps
        map
        map-content-at
        account-by-name
        account-achievements
        account-characters
        active-characters
        badges
        badge
        badge-catalog
        skin-catalog
        skin
        season-rewards
        season-reward
        task-rewards
        task-reward
        gems-shop
        gems-shop-buy-custom-design
        gems-shop-skin
        gems-shop-spawn-event
        gems-shop-subscription
        register-account
        forgot-password
        reset-password
        request-token
        game-assistant-ask
        all-pages
        with-account)

;; A single character by name. Public endpoint, no token needed.
(define (character name #:config [config (current-config)])
  (get-character name #:config config))

;; The authenticated account's characters, paginated.
(define (my-characters #:page [page 1] #:size [size 50] #:config [config (current-config)])
  (get-my-characters #:page page #:size size #:config config))

;; The authenticated account's profile and totals.
(define (account-details #:config [config (current-config)])
  (get-account-details #:config config))

;; The authenticated account's bank capacity and gold.
(define (bank #:config [config (current-config)])
  (get-bank-details #:config config))

;; Bank item stacks, optionally filtered to one item code.
(define (bank-items #:code [code #f] #:page [page 1] #:size [size 50] #:config [config (current-config)])
  (get-bank-items #:item-code code #:page page #:size size #:config config))

;; Items the bank is still crafting or buying on your behalf.
(define (pending-items #:config [config (current-config)])
  (get-pending-items #:config config))

;; Your account's gem and subscription purchase records, paginated.
(define (purchase-history #:page [page 1] #:size [size 50] #:config [config (current-config)])
  (get-purchase-history #:page page #:size size #:config config))

;; Your account's gem credit and debit records (purchases, conversions,
;; refunds), paginated straight through to get-gems-history.
(define (gems-history #:page [page 1] #:size [size 50] #:config [config (current-config)])
  (get-gems-history #:page page #:size size #:config config))

;; The task a character is currently on, if any. Character-scoped /my read.
(define (active-task name #:config [config (current-config)])
  (get-my-tasks-active name #:config config))

;; A character's completed-task history, paginated. Character-scoped /my read.
(define (task-history name #:page [page 1] #:size [size 50] #:config [config (current-config)])
  (get-my-tasks-history name #:page page #:size size #:config config))

;; Public auction house listings, paginated (no token needed).
(define (auctions #:page [page 1] #:size [size 50] #:config [config (current-config)])
  (get-auctions #:page page #:size size #:config config))

;; Auctions this character has listed, paginated. Character-scoped /my read.
(define (my-auctions name #:page [page 1] #:size [size 50] #:config [config (current-config)])
  (get-my-auctions name #:page page #:size size #:config config))

;; Current rate-limit budget for the authenticated account.
(define (rate-limits #:config [config (current-config)])
  (get-rate-limits #:config config))

;; Static item data by code.
(define (item code #:config [config (current-config)])
  (get-item code #:config config))

;; Static monster data by code.
(define (monster code #:config [config (current-config)])
  (get-monster code #:config config))

;; Static resource data by code.
(define (resource code #:config [config (current-config)])
  (get-resource code #:config config))

;; Static NPC data by code.
(define (npc code #:config [config (current-config)])
  (get-npc code #:config config))

;; The task list, paginated.
(define (tasks #:page [page 1] #:size [size 100] #:config [config (current-config)])
  (get-tasks #:page page #:size size #:config config))

;; Achievement definitions, paginated.
(define (achievements #:page [page 1] #:size [size 100] #:config [config (current-config)])
  (get-achievements #:page page #:size size #:config config))

;; Active account effects, paginated.
(define (effects #:page [page 1] #:size [size 100] #:config [config (current-config)])
  (get-effects #:page page #:size size #:config config))

;; Events currently running.
(define (active-events #:config [config (current-config)])
  (get-active-events #:config config))

;; A character's active event, if any. Character-scoped /my read.
(define (my-events name #:config [config (current-config)])
  (get-my-events name #:config config))

;; A character's gold balance. Character-scoped /my read.
(define (balance name #:config [config (current-config)])
  (get-my-balance name #:config config))

;; A character's earned badges. Character-scoped /my read.
(define (badges name #:config [config (current-config)])
  (get-my-badges name #:config config))

;; A character's total stats. Character-scoped /my read.
(define (stats name #:config [config (current-config)])
  (get-my-stats name #:config config))

;; Raid definitions, paginated.
(define (raids #:page [page 1] #:size [size 100] #:config [config (current-config)])
  (get-raids #:page page #:size size #:config config))

;; Account subscription management. All are auth-gated /my reads or writes, so
;; each forwards to its http.rkt wrapper with #:auth? set; a token-less config
;; raises the structured 452 before any network call (see tests).
(define (my-subscription #:config [config (current-config)])
  (get-my-subscription #:config config))

(define (cancel-subscription #:config [config (current-config)])
  (do-cancel-subscription #:config config))

(define (buy-gems gem-pack #:config [config (current-config)])
  (do-buy-gems gem-pack #:config config))

(define (change-password new-password current-password #:config [config (current-config)])
  (do-change-password new-password current-password #:config config))

(define (change-email new-email current-password #:config [config (current-config)])
  (do-change-email new-email current-password #:config config))

(define (subscribe-stripe plan #:config [config (current-config)])
  (do-subscribe-stripe plan #:config config))

(define (subscribe-member-token #:config [config (current-config)])
  (do-subscribe-member-token #:config config))

;; A single public Grand Exchange order by id, for re-checking one listing.
(define (ge-order id #:config [config (current-config)])
  (get-grand-exchange-order id #:config config))

;; Character leaderboard, optionally sorted by a column name.
(define (character-leaderboard #:sort [sort #f] #:config [config (current-config)])
  (get-character-leaderboard #:sort sort #:config config))

;; Account leaderboard, optionally sorted by a column name.
(define (account-leaderboard #:sort [sort #f] #:config [config (current-config)])
  (get-account-leaderboard #:sort sort #:config config))

;; Generic column leaderboard (level/gold/fame), sorted by that column.
(define (leaderboard column #:sort [sort #f] #:config [config (current-config)])
  (get-leaderboard column #:sort sort #:config config))

;; Account rankings by column (account-wide variant of the column leaderboard).
(define (rankings column #:sort [sort #f] #:config [config (current-config)])
  (get-rankings column #:sort sort #:config config))

;; Server status and the announced next reset time.
(define (server-details #:config [config (current-config)])
  (get-server-details #:config config))

;; The map grid, optionally scoped to one layer and paginated.
(define (maps #:layer [layer #f] #:page [page 1] #:size [size 100] #:config [config (current-config)])
  (get-maps #:layer layer #:page page #:size size #:config config))

;; A single tile, addressed by its three coordinates (layer x y).
(define (map layer x y #:config [config (current-config)])
  (get-map layer x y #:config config))

;; Tiles at a coordinate that carry a given content code (the bank, a specific
;; resource node, etc.). Public read; forwards straight to get-map-content.
(define (map-content-at x y content-code #:config [config (current-config)])
  (get-map-content x y content-code #:config config))

;; ---- New encyclopedia / companion reads (one readable call each) ----
;; Every form below is a thin keyword wrapper over a new http.rkt function, in
;; the same style as the existing query forms. Public reads need no token; the
;; auth-gated ones (game-assistant, gems-shop writes) raise the structured 452
;; when given a token-less config, exactly like the account-management forms.

(define (account-by-name account #:config [config (current-config)])
  (get-account-by-name account #:config config))

(define (account-achievements account #:page [page 1] #:size [size 50] #:config [config (current-config)])
  (get-account-achievements account #:page page #:size size #:config config))

(define (account-characters account #:page [page 1] #:size [size 50] #:config [config (current-config)])
  (get-account-characters account #:page page #:size size #:config config))

;; Public "who's playing" list of characters currently online.
(define (active-characters #:page [page 1] #:size [size 50] #:config [config (current-config)])
  (get-active-characters #:page page #:size size #:config config))

;; Badge catalog and a single badge by code. Public reads. (Note `badges` is
;; already taken by the character-scoped /my read, so the catalog is `badge-catalog`.)
(define (badge-catalog #:page [page 1] #:size [size 100] #:config [config (current-config)])
  (get-badges #:page page #:size size #:config config))

(define (badge code #:config [config (current-config)])
  (get-badge code #:config config))

;; Skin catalog and a single skin by code. Public reads. (Named `skin-catalog`
;; to avoid implying the character-scoped form; `skin` is the single-by-code read.)
(define (skin-catalog #:page [page 1] #:size [size 100] #:config [config (current-config)])
  (get-skins #:page page #:size size #:config config))

(define (skin code #:config [config (current-config)])
  (get-skin code #:config config))

;; Season reward tiers and a single tier by code. Public reads.
(define (season-rewards #:page [page 1] #:size [size 100] #:config [config (current-config)])
  (get-season-rewards #:page page #:size size #:config config))

(define (season-reward code #:config [config (current-config)])
  (get-season-reward code #:config config))

;; Task reward catalog and a single reward table by code. Public reads.
(define (task-rewards #:page [page 1] #:size [size 100] #:config [config (current-config)])
  (get-task-rewards #:page page #:size size #:config config))

(define (task-reward code #:config [config (current-config)])
  (get-task-reward code #:config config))

;; The gems-shop catalog. Public read; forwards to get-gems-shop.
(define (gems-shop #:config [config (current-config)])
  (get-gems-shop #:config config))

;; Gems-shop purchases are auth-gated writes; each forwards to its http.rkt
;; wrapper with #:auth? set, so a token-less config raises the structured 452
;; before any network call.
(define (gems-shop-buy-custom-design #:body [body #hasheq()] #:config [config (current-config)])
  (post-gems-shop-buy-custom-design #:body body #:config config))

(define (gems-shop-skin #:body [body #hasheq()] #:config [config (current-config)])
  (post-gems-shop-skin #:body body #:config config))

(define (gems-shop-spawn-event #:body [body #hasheq()] #:config [config (current-config)])
  (post-gems-shop-spawn-event #:body body #:config config))

(define (gems-shop-subscription #:body [body #hasheq()] #:config [config (current-config)])
  (post-gems-shop-subscription #:body body #:config config))

;; Account registration (public). body carries username/email/password; the
;; returned token is the caller's to install (e.g. with-token-source).
(define (register-account #:body [body #hasheq()] #:config [config (current-config)])
  (post-accounts-create #:body body #:config config))

(define (forgot-password #:body [body #hasheq()] #:config [config (current-config)])
  (post-forgot-password #:body body #:config config))

(define (reset-password #:body [body #hasheq()] #:config [config (current-config)])
  (post-reset-password #:body body #:config config))

;; Exchange basic credentials for a bearer token. The HTTP Basic header is built
;; inside http.rkt; here we just forward username/password. Returns the decoded
;; response (which carries the token) so the caller can install it.
(define (request-token username password #:config [config (current-config)])
  (post-token username password #:config config))

;; Ask the game-assistant LLM a question. Auth-gated: a token-less config raises
;; the structured 452 before any network call.
(define (game-assistant-ask #:body [body #hasheq()] #:config [config (current-config)])
  (post-game-assistant-ask #:body body #:config config))

;; ---- Ergonomic helpers (bot authoring sugar) ----

;; Collect every page of a paged http.rkt reader into one list. `getter` is a
;; procedure like `my-characters` or `items` (accepting #:page #:size #:config);
;; we loop pages until the response reports no further items. Never loops
;; forever: it stops when a page returns fewer than `size` items or the response
;; declares the last page.
(define (all-pages getter #:size [size 100] #:config [config (current-config)] #:max-pages [max-pages 1000])
  (let loop ([page 1] [acc '()])
    (define response (getter #:page page #:size size #:config config))
    (define data
      (cond
        [(and (hash? response) (hash-has-key? response 'data)) (hash-ref response 'data)]
        [else response]))
    (define items (if (list? data) data '()))
    (define pages (and (hash? response) (hash-ref response 'pages #f)))
    (define next (append acc items))
    (cond
      [(>= page max-pages) next]
      [(or (null? items)
           (and (number? pages) (>= page pages))
           (< (length items) size))
       next]
      [else (loop (add1 page) next)])))

;; Run a thunk with a temporary `current-config`. Handy for scoping a request to
;; a specific account config without mutating global state:
;;   (with-account some-config (account-details))
(define (with-account config thunk)
  (parameterize ([current-config config])
    (thunk)))
