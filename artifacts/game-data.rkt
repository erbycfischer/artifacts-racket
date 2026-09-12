#lang racket

;; Default Artifacts MMO tables so a bot can grind, sell loot, and craft
;; without hand-writing gear buckets, drop lists, or recipes. Values mirror
;; the live encyclopedia (GET /items, GET /monsters; ores→bars need 10,
;; workshops are skill-coded, steel is iron_ore 3 + coal 7). Live API data
;; still wins when a bot supplies its own tables; these are the
;; "just works" fallbacks.

(provide default-gear-table
         default-loot-codes
         default-recipes
         default-consumables
         default-sell-prices
         default-forge-recipes
         forge-priority-queue
         soft-loot-codes
         premium-loot-codes
         rare-loot-codes
         soft-loot?
         premium-loot?
         rare-loot?
         classify-loot
         fighter-kit-codes
         mailbox-raw-codes
         default-craft-skills
         default-craft-levels
         item-craft-level
         craft-workshop-skill
         recipe-materials
         miner-kit-table
         woodcutter-kit-table
         crafter-kit-table
         role-tool-codes
         equipment-rank-table
         equipment-slot-of
         equipment-rank
         same-item-code?
         better-gear?
         item-level
         item-equip-level
         kit-table-codes
         kit-codes-in-buckets
         highest-held-kit-bucket
         reserved-upgrade-codes
         dominated-spare-codes
         craftable-gear?
         gather-tool?)

;; Level-bucketed craftable kit. Codes match live gearcrafting /
;; weaponcrafting / jewelrycrafting recipes — NPC shops do not sell these
;; starters. outfit-from-bank / forge-loop consume this table; upgrade-gear
;; only helps when a bot points at real merchant stock.
(define default-gear-table
  (hasheq
   1  (hasheq 'weapon "copper_dagger"   'shield "wooden_shield"
             'helmet "copper_helmet"    'boots "copper_boots"
             'ring "copper_ring")
   5  (hasheq 'weapon "sticky_sword"     'shield "wooden_shield"
             'helmet "copper_helmet"    'body_armor "copper_armor"
             'leg_armor "copper_legs_armor" 'boots "copper_boots"
             'ring "copper_ring"        'amulet "life_amulet")
   10 (hasheq 'weapon "iron_sword"       'shield "iron_shield"
             'helmet "iron_helm"        'body_armor "iron_armor"
             'leg_armor "iron_legs_armor" 'boots "iron_boots"
             'ring "iron_ring"          'amulet "fire_and_earth_amulet")
   15 (hasheq 'weapon "king_slime_sword" 'shield "iron_shield"
             'helmet "mushmush_wizard_hat" 'body_armor "mushmush_jacket"
             'leg_armor "adventurer_pants" 'boots "adventurer_boots"
             'ring "life_ring"          'amulet "wisdom_amulet")
   20 (hasheq 'weapon "steel_battleaxe"  'shield "slime_shield"
             'helmet "steel_helm"       'body_armor "steel_armor"
             'leg_armor "steel_legs_armor" 'boots "steel_boots"
             'ring "steel_ring"         'amulet "skull_amulet")))

;; Gatherer / crafter tools. Pickaxes, axes, and gloves occupy the weapon
;; slot; satchel occupies bag. outfit-from-bank uses these tables so a miner
;; never pulls a fighter sword.
(define miner-kit-table
  (hasheq
   1  (hasheq 'weapon "copper_pickaxe")
   10 (hasheq 'weapon "iron_pickaxe" 'bag "satchel")
   20 (hasheq 'weapon "steel_pickaxe" 'bag "satchel")))

(define woodcutter-kit-table
  (hasheq
   1  (hasheq 'weapon "copper_axe")
   10 (hasheq 'weapon "iron_axe")
   20 (hasheq 'weapon "steel_axe")))

(define crafter-kit-table
  (hasheq
   1  (hasheq 'weapon "apprentice_gloves")
   10 (hasheq 'weapon "leather_gloves" 'bag "satchel")))

(define role-tool-codes
  '(copper_pickaxe copper_axe fishing_net apprentice_gloves
    iron_pickaxe iron_axe spruce_fishing_rod leather_gloves
    steel_pickaxe steel_axe satchel))

;; Flat kit the fighter restocks from the shared vault (starter tier).
(define fighter-kit-codes
  '(copper_dagger wooden_shield copper_helmet copper_boots copper_ring))

;; Gatherer + fighter drops the smith withdraws and crafts. Not deposits —
;; the mailbox consume side. 10 of an ore/wood is one bar/plank.
(define mailbox-raw-codes
  '(copper_ore iron_ore coal gold_ore
    ash_wood spruce_wood birch_wood dead_wood
    raw_chicken egg feather sunflower gudgeon))

;; Common live combat / fishing drops grind can name. Ores and wood stay out
;; so gatherers can bank them for the smith instead of NPC-scrapping them.
(define default-loot-codes
  '(raw_chicken egg feather golden_egg
    yellow_slimeball green_slimeball red_slimeball blue_slimeball apple
    wool raw_beef milk_bucket cowhide
    gudgeon shrimp algae
    mushroom forest_ring
    flying_wing snake_hide green_cloth forest_staff
    raw_wolf_meat wolf_hair wolf_bone wolf_ears
    highwayman_dagger
    rat_hide raw_rat_meat
    spider_leg
    king_slimeball))

;; Cook / craft inputs the fighter banks for the smith. Meats, fish, hides,
;; feathers, wool, slimeballs, alchemy plants — not ores/wood (gatherers
;; already mailbox those) and not unique rares.
(define soft-loot-codes
  '(raw_chicken raw_beef raw_wolf_meat raw_porkchop raw_rat_meat
    raw_hellhound_meat desert_scorpion_meat
    egg milk_bucket apple mushroom
    feather wool cowhide wolf_hide rat_hide snake_hide pig_skin
    lizard_skin ogre_skin wolf_hair wolf_bone
    gudgeon shrimp trout bass salmon swordfish algae
    yellow_slimeball green_slimeball red_slimeball blue_slimeball
    king_slimeball
    flying_wing green_cloth spider_leg
    skeleton_bone skeleton_skull ogre_eye cyclops_eye
    sunflower nettle_leaf))

;; High-value trade goods the trader should GE-list (not NPC-scrap, not
;; unique rares, not the cook/craft mailbox). Gem stones cut into jewelry;
;; NPC hides/cloth flip on the book.
(define premium-loot-codes
  '(topaz_stone emerald_stone ruby_stone sapphire_stone diamond_stone
    topaz emerald ruby sapphire diamond
    cloth hard_leather snakeskin vermin_leather
    shell))

;; Bank-and-hold forever; never auto-sell. Unique / 1-in-N combat drops,
;; keys, currencies, gem/gold bags, exchange shards, and uncraftable kit.
(define rare-loot-codes
  '(golden_egg golden_shrimp
    tasks_coin event_ticket corrupted_gem
    small_bag_of_gold bag_of_gold small_bag_of_gems bag_of_gems
    forest_ring forest_staff wolf_ears highwayman_dagger
    wooden_club old_boots bandit_armor death_knight_sword
    lich_crown goblin_guard_shield lich_race_medal lich_race_trophy
    life_crystal life_crystal_shard malefic_shard small_pearls perfect_pearl
    lost_world_map backpack novice_guide
    lich_tomb_key priestess_hideout_key
    healing_rune healing_aura_rune protection_rune burn_rune lifesteal_rune))

(define (loot-key code)
  (if (string? code) (string->symbol code) code))

(define (in-loot-codes? code codes)
  (and (memq (loot-key code) codes) #t))

(define (rare-loot? code)
  (in-loot-codes? code rare-loot-codes))

(define (soft-loot? code)
  (in-loot-codes? code soft-loot-codes))

(define (premium-loot? code)
  (in-loot-codes? code premium-loot-codes))

;; Rare wins, then soft (keep for smith), then premium (GE). Unknown → #f.
(define (classify-loot code)
  (cond
    [(rare-loot? code) 'rare]
    [(soft-loot? code) 'soft]
    [(premium-loot? code) 'premium]
    [else #f]))

(define (as-item-symbol code)
  (cond
    [(symbol? code) code]
    [(string? code) (string->symbol code)]
    [else code]))

(define (as-item-string code)
  (cond
    [(string? code) code]
    [(symbol? code) (symbol->string code)]
    [else (format "~a" code)]))

(define (same-item-code? a b)
  (and a b (equal? (as-item-string a) (as-item-string b))))

;; Slot → codes from worst to best. Crafted kit plus rare combat drops that
;; are actually gear. outfit-from-bank restocks only when a candidate ranks
;; strictly above the worn piece (and the level gate is met).
(define equipment-rank-table
  (hasheq
   'weapon '("wooden_stick" "copper_dagger" "copper_pickaxe" "copper_axe"
             "sticky_dagger" "sticky_sword" "highwayman_dagger" "forest_staff"
             "wooden_club" "iron_dagger" "iron_sword" "iron_pickaxe" "iron_axe"
             "king_slime_sword" "steel_battleaxe" "steel_pickaxe" "steel_axe"
             "death_knight_sword")
   'shield '("wooden_shield" "iron_shield" "goblin_guard_shield" "slime_shield")
   'helmet '("copper_helmet" "iron_helm" "mushmush_wizard_hat" "steel_helm"
             "lich_crown")
   'body_armor '("copper_armor" "bandit_armor" "iron_armor" "mushmush_jacket"
                 "steel_armor")
   'leg_armor '("copper_legs_armor" "iron_legs_armor" "adventurer_pants"
                "steel_legs_armor")
   'boots '("copper_boots" "old_boots" "iron_boots" "adventurer_boots"
            "steel_boots")
   'ring '("copper_ring" "iron_ring" "forest_ring" "life_ring" "steel_ring")
   'amulet '("life_amulet" "fire_and_earth_amulet" "wisdom_amulet" "skull_amulet")
   'bag '("satchel")
   'utility '("small_health_potion" "minor_health_potion" "health_potion")))

(define item-level-overrides
  (hasheq
   'wooden_stick 1
   'highwayman_dagger 5
   'forest_staff 5
   'wooden_club 5
   'old_boots 5
   'bandit_armor 5
   'forest_ring 5
   'goblin_guard_shield 10
   'death_knight_sword 20
   'lich_crown 20
   'satchel 10
   'copper_pickaxe 1
   'copper_axe 1
   'fishing_net 1
   'apprentice_gloves 1
   'iron_pickaxe 10
   'iron_axe 10
   'spruce_fishing_rod 10
   'leather_gloves 10
   'steel_pickaxe 20
   'steel_axe 20))

(define (kit-table-codes table)
  (define acc '())
  (for ([bucket (hash-keys table)])
    (define slots (hash-ref table bucket #f))
    (when (hash? slots)
      (for ([(slot code) (in-hash slots)] #:when code)
        (set! acc (cons code acc)))))
  (reverse acc))

(define (all-kit-tables)
  (list default-gear-table miner-kit-table woodcutter-kit-table crafter-kit-table))

(define (equipment-slot-of code)
  (define key (as-item-string code))
  (or (for/or ([(slot codes) (in-hash equipment-rank-table)])
        (and (for/or ([c codes]) (same-item-code? c key)) slot))
      (for/or ([table (all-kit-tables)])
        (for/or ([bucket (hash-keys table)])
          (define slots (hash-ref table bucket #f))
          (and (hash? slots)
               (for/or ([(slot item) (in-hash slots)] #:when item)
                 (and (same-item-code? item key) slot)))))))

(define (equipment-rank code [slot #f])
  (define key (as-item-string code))
  (define resolved (or slot (equipment-slot-of key)))
  (define codes (and resolved (hash-ref equipment-rank-table resolved #f)))
  (cond
    [(not codes) 0]
    [else
     (define idx
       (for/or ([c codes] [i (in-naturals)])
         (and (same-item-code? c key) i)))
     (if idx (add1 idx) 0)]))

(define (better-gear? candidate worn)
  (cond
    [(not candidate) #f]
    [(not worn) (positive? (equipment-rank candidate))]
    [(and (equipment-slot-of candidate)
          (equipment-slot-of worn)
          (not (eq? (equipment-slot-of candidate) (equipment-slot-of worn))))
     #f]
    [else (> (equipment-rank candidate) (equipment-rank worn))]))

(define (item-level-from-tables code)
  (define key (as-item-string code))
  (define best
    (for/fold ([found #f]) ([table (all-kit-tables)])
      (or found
          (for/or ([bucket (sort (hash-keys table) <)])
            (define slots (hash-ref table bucket #f))
            (and (hash? slots)
                 (for/or ([item (in-hash-values slots)] #:when item)
                   (and (same-item-code? item key) bucket)))))))
  best)

(define (item-level code)
  (define key (as-item-symbol code))
  (or (hash-ref item-level-overrides key #f)
      (item-level-from-tables code)
      1))

(define item-equip-level item-level)

(define (kit-codes-in-buckets table pred)
  (define acc '())
  (for ([bucket (hash-keys table)] #:when (pred bucket))
    (define slots (hash-ref table bucket #f))
    (when (hash? slots)
      (for ([code (in-hash-values slots)] #:when code)
        (set! acc (cons code acc)))))
  (reverse acc))

(define (highest-held-kit-bucket table held-codes)
  (define held (if (list? held-codes) held-codes '()))
  (define buckets (sort (hash-keys table) <))
  (for/fold ([best #f]) ([b buckets])
    (define slots (hash-ref table b #f))
    (define any?
      (and (hash? slots)
           (for/or ([code (in-hash-values slots)] #:when code)
             (for/or ([h held]) (same-item-code? h code)))))
    (if any? b best)))

;; Codes that are still upgrades or the current-best piece: do not GE-sell.
;; Conservative when `held-codes` is empty — reserve the whole table.
(define (reserved-upgrade-codes [held-codes '()]
                                #:tables [tables (all-kit-tables)])
  (define acc '())
  (for ([table tables])
    (define top (highest-held-kit-bucket table held-codes))
    (define keep
      (if top
          (kit-codes-in-buckets table (lambda (b) (>= b top)))
          (kit-table-codes table)))
    (set! acc (append acc keep)))
  acc)

;; Starter / lower-bucket leftovers once a higher piece is held or worn.
(define (dominated-spare-codes held-codes
                               #:tables [tables (all-kit-tables)])
  (define acc '())
  (for ([table tables])
    (define top (highest-held-kit-bucket table held-codes))
    (when top
      (set! acc (append acc (kit-codes-in-buckets table (lambda (b) (< b top)))))))
  acc)

(define craftable-gear-skills
  '(weaponcrafting gearcrafting jewelrycrafting))

(define (craftable-gear? code)
  (define key (as-item-symbol code))
  (define skill (hash-ref default-craft-skills key #f))
  (and skill
       (memq skill craftable-gear-skills)
       (hash-has-key? default-recipes key)
       #t))

(define (gather-tool? code)
  (define s (as-item-string code))
  (or (regexp-match? #px"pickaxe|fishing_net|fishing_rod|_gloves" s)
      (and (regexp-match? #px"_axe$" s)
           (not (regexp-match? #px"battleaxe" s)))))

;; Product → materials. Each value is `((mat qty) ...)` (multi-mat recipes
;; allowed). Legacy `(mat . qty)` pairs are still accepted by recipe-materials.
;; Sourced from live GET /items craft blobs (Aug 2026 encyclopedia).
(define default-recipes
  (hasheq
   ;; Mining bars / gems
   'copper_bar '((copper_ore 10))
   'iron_bar '((iron_ore 10))
   'steel_bar '((iron_ore 3) (coal 7))
   'gold_bar '((gold_ore 10))
   'obsidian_bar '((piece_of_obsidian 4))
   'strangold_bar '((gold_ore 4) (strange_ore 6))
   'mithril_bar '((mithril_ore 10))
   'adamantite_bar '((adamantite_ore 10))
   'topaz '((topaz_stone 24))
   'ruby '((ruby_stone 24))
   'emerald '((emerald_stone 24))
   'sapphire '((sapphire_stone 24))
   'diamond '((diamond_stone 24))
   'alexandrite '((alexandrite_stone 24))
   ;; Woodcutting planks / sap
   'ash_plank '((ash_wood 10))
   'spruce_plank '((spruce_wood 10))
   'hardwood_plank '((ash_wood 4) (birch_wood 6))
   'dead_wood_plank '((dead_wood 10))
   'cursed_plank '((cursed_wood 10))
   'magical_plank '((dead_wood 4) (magic_wood 6))
   'maple_plank '((maple_wood 10))
   'palm_plank '((palm_wood 10))
   'sap '((ash_wood 5) (spruce_wood 5) (dead_wood 5))
   'magic_sap '((magic_wood 15))
   'maple_sap '((maple_wood 15))
   ;; Cooking (fighter food)
   'cooked_chicken '((raw_chicken 1))
   'cooked_gudgeon '((gudgeon 1))
   'cooked_beef '((raw_beef 1))
   'fried_eggs '((egg 2))
   'cookie '((milk_bucket 1) (egg 1))
   'cooked_shrimp '((shrimp 1))
   'cheese '((milk_bucket 1))
   'mushroom_soup '((mushroom 2))
   'cooked_wolf_meat '((raw_wolf_meat 1))
   'apple_pie '((apple 2) (egg 1))
   'cooked_porkchop '((raw_porkchop 1))
   'cooked_trout '((trout 1))
   'cooked_bass '((bass 1))
   'cooked_rat_meat '((raw_rat_meat 1))
   'cooked_salmon '((salmon 1))
   'fish_soup '((milk_bucket 1) (salmon 1) (trout 1))
   'cooked_hellhound_meat '((raw_hellhound_meat 1))
   'maple_syrup '((maple_sap 2))
   'cooked_desert_scorpion_meat '((desert_scorpion_meat 1))
   'cooked_swordfish '((swordfish 1))
   ;; Alchemy (pots the roster actually drinks)
   'small_health_potion '((sunflower 3))
   'recall_potion '((sunflower 1) (gudgeon 1))
   'air_boost_potion '((green_slimeball 1) (sunflower 1) (algae 1))
   'fire_boost_potion '((red_slimeball 1) (sunflower 1) (algae 1))
   'water_boost_potion '((blue_slimeball 1) (sunflower 1) (algae 1))
   'earth_boost_potion '((yellow_slimeball 1) (sunflower 1) (algae 1))
   'minor_health_potion '((nettle_leaf 2) (algae 1))
   'small_antidote '((milk_bucket 1) (sap 1) (nettle_leaf 1))
   'forest_bank_potion '((nettle_leaf 1) (trout 1))
   'health_potion '((nettle_leaf 2) (egg 1) (sap 1))
   'health_splash_potion '((nettle_leaf 2) (sunflower 1) (algae 1))
   'antidote '((strangold_bar 2) (maple_sap 1) (glowstem_leaf 1))
   'greater_health_potion '((glowstem_leaf 2) (egg 1) (algae 1))
   'health_boost_potion '((milk_bucket 1) (sap 1) (nettle_leaf 2))
   ;; Weaponcrafting (tools + fighter weapons through steel)
   'copper_dagger '((copper_bar 6))
   'copper_pickaxe '((copper_bar 6))
   'copper_axe '((copper_bar 6))
   'fishing_net '((ash_plank 6))
   'apprentice_gloves '((feather 6))
   'wooden_staff '((wooden_stick 1) (ash_wood 4))
   'sticky_sword '((yellow_slimeball 2) (copper_bar 5))
   'sticky_dagger '((copper_bar 5) (green_slimeball 2))
   'fire_staff '((red_slimeball 2) (ash_plank 5))
   'water_bow '((blue_slimeball 2) (ash_plank 5))
   'iron_sword '((iron_bar 6) (feather 2))
   'iron_dagger '((iron_bar 6) (feather 2))
   'iron_pickaxe '((spruce_plank 2) (iron_bar 8) (jasper_crystal 1))
   'iron_axe '((spruce_plank 2) (iron_bar 8) (jasper_crystal 1))
   'spruce_fishing_rod '((spruce_plank 8) (iron_bar 2) (jasper_crystal 1))
   'leather_gloves '((ash_plank 2) (cowhide 8) (jasper_crystal 1))
   'fire_bow '((spruce_plank 6) (red_slimeball 2))
   'greater_wooden_staff '((spruce_plank 6) (blue_slimeball 2))
   'king_slime_sword '((iron_bar 8) (king_slimeball 6) (jasper_crystal 1))
   'mushstaff '((spruce_plank 5) (mushroom 4) (green_cloth 2) (jasper_crystal 1))
   'mushmush_bow '((spruce_plank 5) (wolf_hair 2) (mushroom 4) (jasper_crystal 1))
   'steel_battleaxe '((steel_bar 4) (hardwood_plank 4) (skeleton_bone 4) (wolf_hair 4))
   'skull_staff '((skeleton_skull 1) (skeleton_bone 4) (steel_bar 5) (hardwood_plank 5))
   'battlestaff '((hardwood_plank 6) (steel_bar 4) (wolf_bone 3) (blue_slimeball 5))
   'forest_whip '((king_slimeball 2) (wolf_hair 5) (ogre_eye 4) (hardwood_plank 4))
   'shuriken '((steel_bar 5) (wolf_bone 4) (ogre_skin 3) (flying_wing 3))
   'hunting_bow '((hardwood_plank 5) (green_cloth 4) (ogre_skin 3) (pig_skin 3))
   'steel_pickaxe '((steel_bar 7) (pig_skin 3) (spider_leg 3) (astralyte_crystal 2))
   'steel_axe '((steel_bar 7) (ogre_eye 4) (flying_wing 2) (astralyte_crystal 2))
   ;; Gearcrafting
   'wooden_shield '((ash_plank 6))
   'copper_helmet '((copper_bar 6))
   'copper_boots '((copper_bar 8))
   'copper_armor '((copper_bar 5) (wool 2))
   'copper_legs_armor '((copper_bar 5) (feather 2))
   'feather_coat '((feather 5) (ash_plank 2))
   'satchel '((cowhide 5) (feather 2) (jasper_crystal 1))
   'iron_shield '((iron_bar 5) (wool 3))
   'iron_armor '((iron_bar 5) (cowhide 3))
   'iron_legs_armor '((iron_bar 5) (cowhide 3))
   'leather_armor '((spruce_plank 4) (cowhide 4))
   'leather_legs_armor '((spruce_plank 5) (cowhide 3))
   'leather_boots '((ash_plank 4) (cowhide 4))
   'leather_hat '((cowhide 5) (yellow_slimeball 3))
   'iron_boots '((iron_bar 5) (feather 3))
   'iron_helm '((iron_bar 5) (wool 3))
   'adventurer_vest '((wool 2) (cowhide 6) (spruce_plank 4) (yellow_slimeball 4))
   'adventurer_helmet '((feather 4) (cowhide 3) (spruce_plank 3) (mushroom 4))
   'adventurer_boots '((wolf_hair 5) (mushroom 5) (spruce_plank 5))
   'adventurer_pants '((ash_plank 7) (hard_leather 3) (green_cloth 3) (cloth 2))
   'mushmush_wizard_hat '((cowhide 4) (wolf_hair 4) (mushroom 6))
   'lucky_wizard_hat '((green_cloth 6) (flying_wing 6) (snakeskin 3))
   'mushmush_jacket '((hard_leather 3) (flying_wing 6) (mushroom 6))
   'slime_shield '((hardwood_plank 6) (king_slimeball 6) (cloth 3))
   'steel_helm '((steel_bar 8) (ogre_skin 3) (wolf_bone 2) (cloth 3))
   'steel_armor '((steel_bar 7) (green_cloth 2) (cloth 3) (spider_leg 3))
   'steel_legs_armor '((steel_bar 7) (skeleton_skull 2) (cloth 3) (king_slimeball 3))
   'steel_boots '((hardwood_plank 5) (steel_bar 5) (snakeskin 2) (ogre_skin 3))
   'skeleton_helmet '((skeleton_skull 1) (skeleton_bone 3) (wolf_bone 2) (iron_bar 7))
   'skeleton_armor '((skeleton_bone 6) (wolf_bone 3) (pig_skin 2) (steel_bar 4))
   'skeleton_pants '((wolf_bone 3) (skeleton_bone 3) (wolf_hair 2) (ash_plank 7))
   'hard_leather_armor '((hard_leather 6) (spider_leg 3) (pig_skin 2) (steel_bar 4))
   'hard_leather_helmet '((hardwood_plank 7) (hard_leather 4) (wolf_bone 2) (astralyte_crystal 1))
   'hard_leather_pants '((steel_bar 6) (green_cloth 2) (hard_leather 5) (skeleton_skull 2))
   'hard_leather_boots '((hardwood_plank 5) (green_cloth 2) (hard_leather 3) (pig_skin 5))
   'snakeskin_boots '((hardwood_plank 5) (spider_leg 2) (snakeskin 2) (green_cloth 2))
   ;; Jewelrycrafting
   'copper_ring '((copper_bar 6))
   'life_amulet '((feather 4) (red_slimeball 2))
   'iron_ring '((iron_bar 6) (wool 2))
   'air_and_water_amulet '((iron_bar 4) (green_slimeball 2) (blue_slimeball 2))
   'fire_and_earth_amulet '((iron_bar 4) (red_slimeball 2) (yellow_slimeball 2))
   'earth_ring '((iron_bar 5) (yellow_slimeball 4) (flying_wing 3))
   'air_ring '((iron_bar 5) (green_slimeball 4) (flying_wing 3))
   'fire_ring '((iron_bar 5) (red_slimeball 4) (flying_wing 3))
   'water_ring '((iron_bar 5) (blue_slimeball 4) (flying_wing 3))
   'life_ring '((iron_bar 8) (cloth 2) (mushroom 5))
   'wisdom_amulet '((spruce_plank 4) (green_cloth 3) (snake_hide 3) (jasper_crystal 1))
   'steel_ring '((steel_bar 7) (skeleton_bone 3) (hard_leather 2) (snake_hide 3))
   'skull_ring '((steel_bar 4) (wolf_bone 4) (skeleton_skull 1) (jasper_crystal 2))
   'skull_amulet '((hardwood_plank 7) (skeleton_skull 3) (king_slimeball 2) (snake_hide 3))
   'dreadful_amulet '((hardwood_plank 6) (ogre_eye 4) (hard_leather 2) (king_slimeball 2))
   'dreadful_ring '((steel_bar 7) (ogre_eye 4) (cyclops_eye 3) (jasper_crystal 1))
   'ring_of_chance '((jasper_crystal 1) (steel_bar 6) (king_slimeball 4) (pig_skin 4))))

;; Workshop skill code (map content code) for each craftable product. plan-craft
;; routes to this workshop so the smith is not stuck at the nearest cooking tile.
(define default-craft-skills
  (hasheq
   'copper_bar 'mining
   'iron_bar 'mining
   'steel_bar 'mining
   'gold_bar 'mining
   'obsidian_bar 'mining
   'strangold_bar 'mining
   'mithril_bar 'mining
   'adamantite_bar 'mining
   'topaz 'mining
   'ruby 'mining
   'emerald 'mining
   'sapphire 'mining
   'diamond 'mining
   'alexandrite 'mining
   'ash_plank 'woodcutting
   'spruce_plank 'woodcutting
   'hardwood_plank 'woodcutting
   'dead_wood_plank 'woodcutting
   'cursed_plank 'woodcutting
   'magical_plank 'woodcutting
   'maple_plank 'woodcutting
   'palm_plank 'woodcutting
   'sap 'woodcutting
   'magic_sap 'woodcutting
   'maple_sap 'woodcutting
   'cooked_chicken 'cooking
   'cooked_gudgeon 'cooking
   'cooked_beef 'cooking
   'fried_eggs 'cooking
   'cookie 'cooking
   'cooked_shrimp 'cooking
   'cheese 'cooking
   'mushroom_soup 'cooking
   'cooked_wolf_meat 'cooking
   'apple_pie 'cooking
   'cooked_porkchop 'cooking
   'cooked_trout 'cooking
   'cooked_bass 'cooking
   'cooked_rat_meat 'cooking
   'cooked_salmon 'cooking
   'fish_soup 'cooking
   'cooked_hellhound_meat 'cooking
   'maple_syrup 'cooking
   'cooked_desert_scorpion_meat 'cooking
   'cooked_swordfish 'cooking
   'small_health_potion 'alchemy
   'recall_potion 'alchemy
   'air_boost_potion 'alchemy
   'fire_boost_potion 'alchemy
   'water_boost_potion 'alchemy
   'earth_boost_potion 'alchemy
   'minor_health_potion 'alchemy
   'small_antidote 'alchemy
   'forest_bank_potion 'alchemy
   'health_potion 'alchemy
   'health_splash_potion 'alchemy
   'antidote 'alchemy
   'greater_health_potion 'alchemy
   'health_boost_potion 'alchemy
   'wooden_shield 'gearcrafting
   'copper_helmet 'gearcrafting
   'copper_boots 'gearcrafting
   'copper_armor 'gearcrafting
   'copper_legs_armor 'gearcrafting
   'feather_coat 'gearcrafting
   'satchel 'gearcrafting
   'iron_shield 'gearcrafting
   'iron_armor 'gearcrafting
   'iron_legs_armor 'gearcrafting
   'iron_boots 'gearcrafting
   'iron_helm 'gearcrafting
   'leather_armor 'gearcrafting
   'leather_legs_armor 'gearcrafting
   'leather_boots 'gearcrafting
   'leather_hat 'gearcrafting
   'adventurer_vest 'gearcrafting
   'adventurer_helmet 'gearcrafting
   'adventurer_boots 'gearcrafting
   'adventurer_pants 'gearcrafting
   'mushmush_wizard_hat 'gearcrafting
   'lucky_wizard_hat 'gearcrafting
   'mushmush_jacket 'gearcrafting
   'slime_shield 'gearcrafting
   'steel_helm 'gearcrafting
   'steel_armor 'gearcrafting
   'steel_legs_armor 'gearcrafting
   'steel_boots 'gearcrafting
   'skeleton_helmet 'gearcrafting
   'skeleton_armor 'gearcrafting
   'skeleton_pants 'gearcrafting
   'hard_leather_armor 'gearcrafting
   'hard_leather_helmet 'gearcrafting
   'hard_leather_pants 'gearcrafting
   'hard_leather_boots 'gearcrafting
   'snakeskin_boots 'gearcrafting
   'copper_dagger 'weaponcrafting
   'copper_pickaxe 'weaponcrafting
   'copper_axe 'weaponcrafting
   'fishing_net 'weaponcrafting
   'apprentice_gloves 'weaponcrafting
   'wooden_staff 'weaponcrafting
   'sticky_sword 'weaponcrafting
   'sticky_dagger 'weaponcrafting
   'fire_staff 'weaponcrafting
   'water_bow 'weaponcrafting
   'iron_sword 'weaponcrafting
   'iron_dagger 'weaponcrafting
   'iron_pickaxe 'weaponcrafting
   'iron_axe 'weaponcrafting
   'spruce_fishing_rod 'weaponcrafting
   'leather_gloves 'weaponcrafting
   'fire_bow 'weaponcrafting
   'greater_wooden_staff 'weaponcrafting
   'king_slime_sword 'weaponcrafting
   'mushstaff 'weaponcrafting
   'mushmush_bow 'weaponcrafting
   'steel_battleaxe 'weaponcrafting
   'skull_staff 'weaponcrafting
   'battlestaff 'weaponcrafting
   'forest_whip 'weaponcrafting
   'shuriken 'weaponcrafting
   'hunting_bow 'weaponcrafting
   'steel_pickaxe 'weaponcrafting
   'steel_axe 'weaponcrafting
   'copper_ring 'jewelrycrafting
   'life_amulet 'jewelrycrafting
   'iron_ring 'jewelrycrafting
   'air_and_water_amulet 'jewelrycrafting
   'fire_and_earth_amulet 'jewelrycrafting
   'earth_ring 'jewelrycrafting
   'air_ring 'jewelrycrafting
   'fire_ring 'jewelrycrafting
   'water_ring 'jewelrycrafting
   'life_ring 'jewelrycrafting
   'wisdom_amulet 'jewelrycrafting
   'steel_ring 'jewelrycrafting
   'skull_ring 'jewelrycrafting
   'skull_amulet 'jewelrycrafting
   'dreadful_amulet 'jewelrycrafting
   'dreadful_ring 'jewelrycrafting
   'ring_of_chance 'jewelrycrafting))

(define (craft-workshop-skill code)
  (define key (if (string? code) (string->symbol code) code))
  (hash-ref default-craft-skills key #f))

;; Workshop skill level required to craft. Missing keys are treated as 1 so
;; copper/food always attempt; iron/steel wait until the smith has leveled.
(define default-craft-levels
  (hasheq
   'cooked_chicken 1 'cooked_gudgeon 1 'cooked_beef 1 'fried_eggs 1
   'cooked_shrimp 1 'mushroom_soup 5 'cooked_wolf_meat 10
   'small_health_potion 1 'earth_boost_potion 5 'fire_boost_potion 5
   'water_boost_potion 5 'air_boost_potion 5 'minor_health_potion 10
   'copper_bar 1 'ash_plank 1
   'copper_dagger 1 'wooden_shield 1 'copper_helmet 1 'copper_boots 1
   'copper_ring 1 'life_amulet 5 'copper_armor 5 'copper_legs_armor 5
   'sticky_sword 5
   'copper_pickaxe 1 'copper_axe 1 'fishing_net 1 'apprentice_gloves 1
   'iron_bar 10 'spruce_plank 10
   'iron_sword 10 'iron_shield 10 'iron_armor 10 'iron_helm 10
   'iron_boots 10 'iron_ring 10 'iron_legs_armor 10
   'fire_and_earth_amulet 10
   'iron_pickaxe 10 'iron_axe 10 'spruce_fishing_rod 10
   'leather_gloves 10 'satchel 10
   'king_slime_sword 15 'mushmush_wizard_hat 15 'mushmush_jacket 15
   'adventurer_pants 15 'adventurer_boots 15 'life_ring 15 'wisdom_amulet 15
   'steel_bar 20 'hardwood_plank 20
   'steel_battleaxe 20 'steel_armor 20 'steel_helm 20
   'steel_boots 20 'steel_ring 20 'steel_legs_armor 20
   'slime_shield 20 'skull_amulet 20
   'steel_pickaxe 20 'steel_axe 20
   'dead_wood_plank 30 'gold_bar 30
   'maple_plank 40 'maple_sap 40 'mithril_bar 40
   'palm_plank 50 'adamantite_bar 50))

(define (item-craft-level code)
  (define key (if (string? code) (string->symbol code) code))
  (hash-ref default-craft-levels key 1))

;; Normalize a recipe entry to `((mat qty) ...)`.
(define (recipe-materials code-or-recipe)
  (define recipe
    (cond
      [(or (symbol? code-or-recipe) (string? code-or-recipe))
       (hash-ref default-recipes
                 (if (string? code-or-recipe)
                     (string->symbol code-or-recipe)
                     code-or-recipe)
                 #f)]
      [else code-or-recipe]))
  (cond
    [(and (pair? recipe) (not (list? (cdr recipe))) (number? (cdr recipe)))
     (list (list (car recipe) (cdr recipe)))]
    [(and (list? recipe) (pair? recipe) (list? (car recipe)))
     recipe]
    [else #f]))

;; Natural smith order (first = highest intent): food → potions → bars/planks
;; → fighter weapon → role tools → rest of copper kit → satchel/gloves → next
;; tier. workshop-loop / humans should read this.
(define forge-priority-queue
  '(cooked_chicken
    cooked_gudgeon
    cooked_beef
    fried_eggs
    small_health_potion
    copper_bar
    ash_plank
    iron_bar
    spruce_plank
    copper_dagger
    copper_pickaxe
    copper_axe
    wooden_shield
    copper_helmet
    copper_boots
    copper_ring
    copper_armor
    copper_legs_armor
    satchel
    apprentice_gloves
    iron_sword
    iron_pickaxe
    iron_axe
    iron_shield
    iron_armor
    iron_helm
    iron_boots
    iron_ring
    iron_legs_armor
    leather_gloves))

;; Products a bank-backed smith should refine + forge by default. Order matters:
;; expand-guards reverses, so the last entry is preferred first. This list is
;; forge-priority-queue reversed so food/pots/bars win over next-tier kit pull.
(define default-forge-recipes
  '(leather_gloves
    iron_legs_armor
    iron_ring
    iron_boots
    iron_helm
    iron_armor
    iron_shield
    iron_axe
    iron_pickaxe
    iron_sword
    apprentice_gloves
    satchel
    copper_legs_armor
    copper_armor
    copper_ring
    copper_boots
    copper_helmet
    wooden_shield
    copper_axe
    copper_pickaxe
    copper_dagger
    spruce_plank
    iron_bar
    ash_plank
    copper_bar
    small_health_potion
    fried_eggs
    cooked_beef
    cooked_gudgeon
    cooked_chicken))

;; Standing GE ask floors for crafted goods and premium drops. Traders list at
;; these prices unless a live ruthless-market tick rewrites the book. Tuned
;; above typical NPC scrap so refining + GE listing beats raw dumps.
(define default-sell-prices
  (hasheq 'copper_bar 40
          'iron_bar 60
          'steel_bar 120
          'ash_plank 35
          'spruce_plank 55
          'cooked_chicken 12
          'cooked_gudgeon 12
          'cooked_beef 20
          'small_health_potion 25
          'copper_ore 6
          'iron_ore 10
          'ash_wood 4
          'copper_dagger 80
          'wooden_shield 50
          'copper_helmet 70
          'copper_boots 90
          'copper_ring 70
          'iron_sword 140
          'iron_shield 110
          'yellow_slimeball 15
          'green_slimeball 15
          'red_slimeball 15
          'blue_slimeball 15
          'wool 8
          'feather 5
          'cowhide 18
          'topaz_stone 40
          'emerald_stone 40
          'ruby_stone 40
          'sapphire_stone 40
          'topaz 800
          'emerald 800
          'ruby 800
          'sapphire 800
          'cloth 10
          'hard_leather 25
          'shell 4))

;; Consumable codes heal-when-low / consume-buff can name without looking them
;; up. The first entry is the default heal-when-low potion.
(define default-consumables
  '(small_health_potion minor_health_potion health_potion
    cooked_chicken cooked_gudgeon cooked_beef apple sunflower))
