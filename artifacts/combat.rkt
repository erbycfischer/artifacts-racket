#lang racket

(require "config.rkt"
         "http.rkt"
         "game-data.rkt")

(provide elemental-damage
         final-damage
         critical-damage
         expected-critical-damage
         fight-cooldown-seconds
         combat-xp
         simulate-fight-score
         local-combat-score
         matchup-score
         suggest-equipment)

(define (round-half-up value)
  (inexact->exact (floor (+ value 1/2))))

(define (elemental-damage base-attack global-damage elemental-bonus)
  (round-half-up (* base-attack (+ 1 (/ (+ global-damage elemental-bonus) 100)))))

(define (final-damage attack resistance)
  (round-half-up (* attack (- 1 (/ resistance 100)))))

(define (critical-damage damage)
  (round-half-up (* damage 3/2)))

(define (expected-critical-damage damage critical-strike)
  (define chance (min 1 (max 0 (/ critical-strike 100))))
  (+ (* chance (critical-damage damage))
     (* (- 1 chance) damage)))

(define (fight-cooldown-seconds turns haste)
  (max 5 (round-half-up (* (* turns 2) (- 1 (/ haste 100))))))

(define (combat-xp #:monster-level monster-level
                   #:player-level player-level
                   #:monster-hp monster-hp
                   #:level-penalty level-penalty
                   #:monster-multiplier monster-multiplier
                   #:wisdom wisdom)
  (round-half-up
   (* (+ (* (/ monster-level player-level) 20)
         (* monster-hp 0.04))
      level-penalty
      monster-multiplier
      (+ 1 (* wisdom 0.001)))))

;; Read a key from a hash, tolerating non-hashes so callers can pass a bare
;; character or monster without first checking its shape.
(define (field value key [default #f])
  (if (hash? value) (hash-ref value key default) default))

;; Local mirror of http.rkt's hash-ref/default, which isn't exported.
(define (hash-ref/default value key default)
  (if (hash? value) (hash-ref value key default) default))

;; A matchup result is a hash with:
;;   score          - desirability of the fight, higher is better (roughly 0..1)
;;   win-probability - best estimate of winning (0..1) or #f when unknown
;;   source         - 'api (from /simulation/fight) or 'local (heuristic)
;;   reason         - human string describing how the score was derived
;;   suggested-equip - hash of weapon/armor codes to consider, or #f
(define (make-matchup score win-probability source reason [suggested-equip #f])
  (hasheq 'score score
          'win-probability win-probability
          'source source
          'reason reason
          'suggested-equip suggested-equip))

;; Build the player half of a fight-simulation body from the live character.
;; Only numeric fields are forwarded; missing values default to 0 so the
;; request stays well-formed even for a partial character hash.
(define (simulation-player-body char)
  (define (num key [default 0])
    (define v (field char key #f))
    (if (number? v) v default))
  (hasheq 'level (num 'level 1)
          'gear_level (num 'gear_level 0)
          'weapon_power (num 'weapon_power 0)
          'armor_power (num 'armor_power 0)
          'hp (num 'hp (num 'max_hp 0))
          'max_hp (num 'max_hp (num 'hp 0))
          'attack (num 'attack 0)
          'defense (num 'defense 0)
          'magic_attack (num 'magic_attack 0)
          'magic_defense (num 'magic_defense 0)
          'critical_strike (num 'critical_strike 0)
          'haste (num 'haste 0)
          'elemental_earth (num 'elemental_earth 0)
          'elemental_fire (num 'elemental_fire 0)
          'elemental_water (num 'elemental_water 0)
          'elemental_wind (num 'elemental_wind 0)
          'effective_attack (num 'effective_attack 0)
          'effective_defense (num 'effective_defense 0)
          'effective_magic_attack (num 'effective_magic_attack 0)
          'effective_magic_defense (num 'effective_magic_defense 0)))

;; Ask the API to simulate the fight. Defensive throughout: a missing token, a
;; network failure, or a response missing the expected fields all yield a low,
;; reason-carrying matchup rather than raising, so plan-time callers can fall
;; back to local math without special-casing every failure mode.
(define (simulate-fight-score char monster #:config [config (current-config)])
  (define code (field monster 'code #f))
  (unless (or (string? code) (symbol? code))
    (make-matchup 0.0 #f 'api "Monster has no code for simulation." #f))
  (define body
    (hasheq 'monster_code (if (symbol? code) (symbol->string code) code)
            'player (simulation-player-body char)))
  (with-handlers ([exn:fail?
                   (lambda (exn)
                     (make-matchup 0.0 #f 'api
                                   (format "Simulation failed: ~a" (exn-message exn))
                                   #f))])
    (define response (simulate-fight body #:config config))
    (define data (hash-ref/default response 'data #f))
    (unless (hash? data)
      (make-matchup 0.0 #f 'api "Simulation response missing data." #f))
    (define prob (hash-ref/default data 'probability #f))
    (unless (number? prob)
      (make-matchup 0.0 #f 'api "Simulation response missing probability." #f))
    (define turns (hash-ref/default data 'turns #f))
    (define safe (max 0.0 (min 1.0 (real->double-flonum prob))))
    (make-matchup safe
                  safe
                  'api
                  (format "API simulation: ~a% win over ~a turns."
                          (round (* safe 100))
                          (if (number? turns) turns "unknown"))
                  #f)))

;; Live Artifacts combat is elemental only (attack_air/earth/fire/water +
;; matching res_*). Generic attack/defense fields are absent on live payloads;
;; treating missing generic stats as a neutral 0.5 previously marked hard
;; monsters "safe" and unlocked suicide pulls (air dagger → red/green slime).

(define combat-elements '(fire earth water air))

(define (attack-key element)
  (string->symbol (format "attack_~a" element)))

(define (dmg-key element)
  (string->symbol (format "dmg_~a" element)))

(define (res-key element)
  (string->symbol (format "res_~a" element)))

(define (numeric-field value key [default 0])
  (define v (field value key #f))
  (if (number? v) v default))

(define (has-elemental-attack? entity)
  (for/or ([el combat-elements])
    (> (numeric-field entity (attack-key el) 0) 0)))

(define (has-elemental-res? entity)
  (for/or ([el combat-elements])
    (number? (field entity (res-key el) #f))))

;; Starter weapons used when a character hash has weapon_slot but no attack_*
;; yet (dry-run / partial fixtures). Values mirror GET /items effects.
(define known-weapon-attack-stats
  (hash "copper_dagger" (hasheq 'attack_air 6 'critical_strike 35)
        "sticky_sword" (hasheq 'attack_earth 16 'critical_strike 5)
        "sticky_dagger" (hasheq 'attack_air 12 'critical_strike 35)
        "wooden_stick" (hasheq 'attack_earth 4)
        "iron_sword" (hasheq 'attack_fire 10 'attack_earth 10)))

(define (weapon-slot-code char)
  (define raw (field char 'weapon_slot #f))
  (cond [(symbol? raw) (symbol->string raw)]
        [(string? raw) raw]
        [else #f]))

;; Merge known weapon effects into a char that lacks live attack_* fields so
;; worn copper_dagger still scores as air damage.
(define (enrich-char-attacks char)
  (cond
    [(has-elemental-attack? char) char]
    [else
     (define code (weapon-slot-code char))
     (define stats (and code (hash-ref known-weapon-attack-stats code #f)))
     (if (not stats)
         char
         (for/fold ([acc char])
                   ([(k v) (in-hash stats)])
           (if (number? (field acc k #f))
               acc
               (hash-set acc k v))))]))

;; Per-turn expected damage across all elements after resist + crit.
(define (total-outgoing-damage attacker defender)
  (define global-dmg (numeric-field attacker 'dmg 0))
  (define crit (numeric-field attacker 'critical_strike 0))
  (for/sum ([el combat-elements])
    (define base (numeric-field attacker (attack-key el) 0))
    (cond
      [(<= base 0) 0]
      [else
       (define elem-bonus (numeric-field attacker (dmg-key el) 0))
       (define res (numeric-field defender (res-key el) 0))
       (define raw (elemental-damage base global-dmg elem-bonus))
       (define after-res (final-damage raw res))
       (expected-critical-damage after-res crit)])))

(define (elemental-data-present? char monster)
  (or (has-elemental-attack? char)
      (has-elemental-attack? monster)
      (has-elemental-res? char)
      (has-elemental-res? monster)))

;; Pure, network-free heuristic for how winnable a fight is (0..1).
;; Scores from elemental outgoing damage vs HP (turns-to-kill vs turns-to-die).
;; Missing elemental data is dampened below the safe-win threshold — never a
;; fake ~0.5 that unlocks hard monsters.
(define (local-combat-score char monster)
  (define fighter (enrich-char-attacks char))
  (define char-level (numeric-field fighter 'level 1))
  (define monster-level (numeric-field monster 'level 1))
  (define level-safety (/ (+ char-level 1) (+ char-level monster-level 1)))

  (define char-max-hp (max 0 (numeric-field fighter 'max_hp
                                           (numeric-field fighter 'hp 0))))
  (define monster-hp (max 0 (numeric-field monster 'hp 0)))
  (define hp-safety
    (if (and (> char-max-hp 0) (> monster-hp 0))
        (/ (+ char-max-hp 1) (+ char-max-hp monster-hp 1))
        0.0))

  (cond
    [(not (elemental-data-present? fighter monster))
     ;; No attack_*/res_* on either side: level+hp only, capped below 0.5 so
     ;; the planner will not treat the fight as "safe".
     (min 0.45 (* 0.5 (+ level-safety hp-safety)))]
    [else
     (define player-dpt (total-outgoing-damage fighter monster))
     (define monster-dpt (total-outgoing-damage monster fighter))
     (cond
       [(or (<= player-dpt 0) (<= monster-hp 0))
        ;; Cannot deal elemental damage → near-unwinnable.
        (min 0.2 (* 0.35 level-safety))]
       [else
        (define turns-to-kill (max 1.0 (/ monster-hp player-dpt)))
        (define turns-to-die
          (if (<= monster-dpt 0)
              +inf.0
              (max 1.0 (/ (max 1 char-max-hp) monster-dpt))))
        (define fight-safety
          (if (infinite? turns-to-die)
              0.95
              (/ turns-to-die (+ turns-to-die turns-to-kill))))
        ;; Mild level blend among winnable fights; elemental margin dominates.
        (+ (* 0.75 fight-safety) (* 0.25 level-safety))])]))

;; Known equipment name fragments, used only to surface a suggestion that the
;; bot might equip something from inventory before fighting. We don't have item
;; stats here, so this is a light nudge, not a damage model.
(define weapon-keywords
  '("sword" "axe" "bow" "staff" "wand" "spear" "dagger" "mace" "hammer" "club"))
(define armor-keywords
  '("armor" "shield" "helmet" "boots" "pants" "legs" "body" "ring" "amulet"))

(define (worn-equipment-code char slot)
  (define key
    (case slot
      [(weapon) 'weapon_slot]
      [(shield) 'shield_slot]
      [(helmet) 'helmet_slot]
      [(body_armor) 'body_armor_slot]
      [(leg_armor) 'leg_armor_slot]
      [(boots) 'boots_slot]
      [(ring) 'ring1_slot]
      [(amulet) 'amulet_slot]
      [(bag) 'bag_slot]
      [(utility) 'utility1_slot]
      [else #f]))
  (and key (field char key #f)))

(define (suggest-equipment char monster)
  (define inv (field char 'inventory '()))
  (define (slots) (if (list? inv) inv '()))
  (define (code-of slot)
    (define c (and (hash? slot) (hash-ref slot 'code #f)))
    (cond [(symbol? c) (symbol->string c)] [(string? c) c] [else #f]))
  (define (matches? code keywords)
    (and code (for/or ([k keywords]) (regexp-match? (pregexp k) code))))
  (define found
    (for/fold ([acc #hasheq()]) ([slot (slots)])
      (define code (code-of slot))
      (define eq-slot
        (and code
             (or (and (matches? code weapon-keywords) (not (gather-tool? code))
                      (or (equipment-slot-of code) 'weapon))
                 (and (matches? code armor-keywords)
                      (or (equipment-slot-of code) 'body_armor)))))
      (cond
        [eq-slot
         (define worn (worn-equipment-code char eq-slot))
         (define prev (hash-ref acc eq-slot #f))
         (define upgrade?
           (cond
             [(and worn (same-item-code? code worn)) #f]
             [(not worn) #t]
             [else (better-gear? code worn)]))
         (if (and upgrade?
                  (or (not prev) (better-gear? code prev) (not worn)))
             (hash-set acc eq-slot code)
             acc)]
        [else acc])))
  (if (hash-empty? found) #f found))

;; Combine the API simulation with local math. Prefer the API probability when
;; it answered; otherwise fall back to the heuristic. Equipment that could
;; improve the matchup is attached as a suggestion in both cases.
(define (matchup-score char monster #:config [config (current-config)])
  (define sim (simulate-fight-score char monster #:config config))
  (define equip (suggest-equipment char monster))
  (if (number? (hash-ref sim 'win-probability))
      (make-matchup (hash-ref sim 'score)
                    (hash-ref sim 'win-probability)
                    'api
                    (hash-ref sim 'reason)
                    equip)
      (let ([local (local-combat-score char monster)])
        (make-matchup local
                      local
                      'local
                      (if (number? (hash-ref sim 'score))
                          (format "Local combat math (simulation unavailable): ~a"
                                  (hash-ref sim 'reason))
                          "Local combat math; no API simulation available.")
                      equip))))
