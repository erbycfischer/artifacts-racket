#lang artifacts

;; A single-character combat "grinder" for Artifacts MMO.
;;
;; Loop: fight the best monster it can safely beat -> sell loot for gold ->
;; buy/equip better gear for its level -> repeat. Runs headlessly via the API
;; and is watchable in the 3D visualizer (the visualizer polls the official
;; character state; this bot never imports the visualizer).
;;
;; Login cascade: bridge (3D Visualizer token) -> file (~/.artifacts/token)
;; -> env (ARTIFACTS_API_TOKEN / ARTIFACTS_TOKEN). No token is hardcoded.

(require artifacts/auth)

;; --- token cascade: bridge first, then file, then env ------------------------
;; make-bridge-config resolves the token source every request in priority
;; order, so a mid-run visualizer login is picked up automatically.
(current-config (make-bridge-config))

;; --- character name wiring ---------------------------------------------------
;; Drive whichever account character the user names; default to "grinder".
(define (env-char-name)
  (define v (getenv "ARTIFACTS_CHAR_NAME"))
  (and v (not (string=? v "")) v))

;; --- gear upgrade table ------------------------------------------------------
;; Level-appropriate gear keyed by level bucket. Each bucket maps an equipment
;; slot to an item code purchasable from an NPC merchant (the "items" tile). The
;; shared (upgrade-gear) helper only buys+equips the character's current level
;; bucket and only slots it isn't already wearing, so higher-tier codes are
;; candidates verified live; a rejected buy fails gracefully and the goal falls
;; through to the next tick.
(define gear-by-level
  (hasheq
   1  (hasheq 'weapon "wooden_sword"   'shield "wooden_shield"
             'helmet "copper_helmet"   'body_armor "copper_armor"
             'leg_armor "copper_legs"  'boots "boots" 'ring "copper_ring" 'amulet "copper_amulet")
   5  (hasheq 'weapon "iron_sword"      'shield "iron_shield"
             'helmet "iron_helmet"     'body_armor "iron_armor"
             'leg_armor "iron_legs"    'boots "boots" 'ring "iron_ring" 'amulet "iron_amulet")
   10 (hasheq 'weapon "steel_sword"     'shield "steel_shield"
             'helmet "steel_helmet"    'body_armor "steel_armor"
             'leg_armor "steel_legs"   'boots "boots" 'ring "steel_ring" 'amulet "steel_amulet")
   15 (hasheq 'weapon "mithril_sword"   'shield "mithril_shield"
             'helmet "mithril_helmet"  'body_armor "mithril_armor"
             'leg_armor "mithril_legs" 'boots "boots" 'ring "mithril_ring" 'amulet "mithril_amulet")
   20 (hasheq 'weapon "adamantine_sword" 'shield "adamantine_shield"
             'helmet "adamantine_helmet" 'body_armor "adamantine_armor"
             'leg_armor "adamantine_legs" 'boots "boots" 'ring "adamantine_ring" 'amulet "adamantine_amulet")
   25 (hasheq 'weapon "dragon_sword"    'shield "dragon_shield"
             'helmet "dragon_helmet"   'body_armor "dragon_armor"
             'leg_armor "dragon_legs"  'boots "boots" 'ring "dragon_ring" 'amulet "dragon_amulet")))

;; --- loot codes to liquidate -------------------------------------------------
;; Common low-tier monster drops. The shared (sell-loot) helper sells the whole
;; inventory of each code only while standing on the items tile (the planner
;; routes there when that guard is the chosen action).
(define loot-codes
  '(wolf_hide wolf_meat wolf_fur
    rat_hide rat_tail
    iron_ore copper_ore coal
    feathers meat apple
    spider_silk blue_slime_sphere red_slime_sphere green_slime_sphere))

;; --- combined grind goal ----------------------------------------------------
;; A single goal so every leg is visible to goal-preferred-actions. The shared
;; (grind) helper composes combat-loop + sell-loot + upgrade-gear. Order
;; MATTERS inside grind: expand-guards reverses body order when resolving, so
;; listing combat-loop LAST puts `fight` FIRST in the preferred list. Fight
;; therefore wins the planner's for/or and the bot grinds; when nothing is
;; fightable it falls through to selling/buying at the merchant.
(bot grinder
  (character grinder #:role 'combat #:as (env-char-name)
    (grind #:target 25
           #:max-hp-ratio 0.5
           #:loot-codes loot-codes
           #:gear-table gear-by-level)))

;; --- dry-run wiring ----------------------------------------------------------
(define dry-run?
  (let ([v (getenv "ARTIFACTS_DRY_RUN")])
    (and v (member v '("1" "true" "TRUE" "yes" "YES")) #t)))

(play grinder
      #:ensure-characters? #t
      #:dry-run? dry-run?
      #:iterations (if dry-run? 2 +inf.0)
      #:sleep-seconds 2)
