#lang artifacts

;; Flagship five-character account bot. The shared bank is the trade bus:
;; nobody give-item's on the same tile — they deposit what others need and
;; withdraw what they will actually use.
;;
;;   miner/wood dump raw mats at 10, outfit tools/bags, then gather shorts
;;   fighter dumps cook/craft drops, equips the best vault piece (incl. rares),
;;     stocks utility pots, then grinds
;;   smith withdraws those mats, forges food/pots/kit/tools, deposits products
;;   trader buys mats + bargains pots, sells only dominated excess, never
;;     upgrades / craftable kit / rares
;;
;; Auth cascade: visualizer bridge -> ~/.artifacts/token -> ARTIFACTS_API_TOKEN.
;;
;;   ARTIFACTS_DRY_RUN=1 racket examples/harmony-bot.rkt
;;   ARTIFACTS_ITERATIONS=20 racket examples/harmony-bot.rkt

(require artifacts/auth)

(current-config (make-bridge-config))

(define (env-as-name tag default)
  (let ([v (getenv (format "ARTIFACTS_AS_~a" (string-upcase (symbol->string tag))))])
    (if (and v (not (string=? v ""))) v default)))

(bot harmony
  ;; Use vault kit/food first, mail drops for the smith, then grind up.
  ;; Character-level preferred order is source order (first form wins).
  (character fighter #:role 'combat #:as (env-as-name 'fighter "fighter")
    (heal-when-low)
    (eat-when-low)
    (outfit-from-bank)
    (equip-utility)
    (restock #:code 'cooked_chicken #:qty 3)
    (restock #:code 'cooked_gudgeon #:qty 3)
    (restock #:code 'small_health_potion #:qty 3)
    (bank-classified-loot #:soft soft-loot-codes
                          #:premium premium-loot-codes
                          #:rare rare-loot-codes)
    ;; Fighters do not spend gold — dump loot gold into the vault so the
    ;; trader can procure. Keep nothing in the pocket.
    (bank-gold #:keep 0)
    (ruthless-grind #:soft soft-loot-codes
                    #:premium premium-loot-codes
                    #:rare rare-loot-codes)
    (log-rare-drops #:codes rare-loot-codes)
    (banker #:bank-threshold 5))

  ;; Mail ore to the smith, then gather the node the forge is short of.
  (character miner #:role 'mining #:as (env-as-name 'miner "hrminer")
    (mailbox-when-used #:qty 10)
    (outfit-from-bank #:gear-table miner-kit-table)
    (adaptive-gather #:role 'mining
                     #:demand '(copper_bar iron_bar steel_bar gold_bar mithril_bar)
                     #:target 20)
    (banker #:bank-threshold 5))

  (character woodcutter #:role 'woodcutting #:as (env-as-name 'woodcutter "hrwood")
    (mailbox-when-used #:qty 10)
    (outfit-from-bank #:gear-table woodcutter-kit-table)
    (adaptive-gather #:role 'woodcutting
                     #:demand '(ash_plank spruce_plank hardwood_plank maple_plank)
                     #:target 20)
    (banker #:bank-threshold 5))

  ;; Mail finished food/kit to the fighter, pull gatherer drops, then craft.
  (character smith #:role 'crafter #:as (env-as-name 'smith "hrsmith")
    (bank-crafted-products)
    (outfit-from-bank #:gear-table crafter-kit-table)
    (fulfill-demand #:codes mailbox-raw-codes #:qty 10)
    (forge-progression)
    (workshop-loop)
    (banker #:bank-threshold 5))

  ;; Buy what the roster is short of; sell only true excess; keep gold to spend.
  (character trader #:role 'trader #:as (env-as-name 'trader "trader")
    (pipeline 'exchange
      (spend-policy)
      (procure-needs #:rare rare-loot-codes)
      (bargain-consumables)
      (flip-spread #:rare rare-loot-codes)
      (snipe-valuables #:rare rare-loot-codes)
      (sell-excess #:rare rare-loot-codes)
      (ruthless-market)
      (keep-gold #:floor 100)
      (banker #:bank-threshold 5)))

  (strategy maximize-account-value
    (ruthless-market)
    (scan-ge)
    (check-events)
    (check-raids)))

(define dry-run?
  (let ([v (getenv "ARTIFACTS_DRY_RUN")])
    (and v (member v '("1" "true" "TRUE" "yes" "YES")) #t)))

(define pretend?
  (let ([v (getenv "ARTIFACTS_PRETEND")])
    (and v (member v '("1" "true" "TRUE" "yes" "YES")) #t)))

(define iterations
  (let ([v (getenv "ARTIFACTS_ITERATIONS")])
    (cond
      [v (string->number v)]
      [dry-run? 2]
      [else +inf.0])))

(play harmony
      #:ensure-characters? #t
      #:iterations (or iterations +inf.0)
      #:sleep-seconds 2
      #:dry-run? dry-run?
      #:pretend? pretend?)
