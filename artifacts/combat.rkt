#lang racket

(require "config.rkt"
         "http.rkt")

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

;; Pure, network-free heuristic for how winnable a fight is. Each factor is a
;; 0..1 "safety" ratio centered on 0.5 for an even match, so a same-level,
;; same-stat monster scores right around 0.5 rather than collapsing toward 0.
;; We average the factors so an even matchup stays near the middle of the scale
;; instead of being crushed by multiplying several sub-1 ratios together.
;; Fields that are absent contribute a neutral 0.5 so missing data degrades
;; gently instead of distorting the score.
(define (local-combat-score char monster)
  (define char-level (field char 'level 1))
  (define monster-level (field monster 'level 1))
  (define level-safety (/ (+ char-level 1) (+ char-level monster-level 1)))

  (define char-max-hp (field char 'max_hp 0))
  (define monster-hp (field monster 'hp 0))
  (define hp-safety
    (if (and (> char-max-hp 0) (> monster-hp 0))
        (/ (+ char-max-hp 1) (+ char-max-hp monster-hp 1))
        0.5))

  (define char-attack (field char 'attack 0))
  (define monster-defense (field monster 'defense 0))
  (define attack-safety
    (if (or (> char-attack 0) (> monster-defense 0))
        (/ (+ char-attack 1) (+ char-attack monster-defense 1))
        0.5))

  (define char-defense (field char 'defense 0))
  (define monster-attack (field monster 'attack 0))
  (define defense-safety
    (if (or (> char-defense 0) (> monster-attack 0))
        (/ (+ char-defense monster-attack 1) (+ char-defense (* 2 monster-attack) 1))
        0.5))

  (/ (+ level-safety hp-safety attack-safety defense-safety) 4))

;; Known equipment name fragments, used only to surface a suggestion that the
;; bot might equip something from inventory before fighting. We don't have item
;; stats here, so this is a light nudge, not a damage model.
(define weapon-keywords
  '("sword" "axe" "bow" "staff" "wand" "spear" "dagger" "mace" "hammer" "club"))
(define armor-keywords
  '("armor" "shield" "helmet" "boots" "pants" "legs" "body" "ring" "amulet"))

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
      (cond
        [(and (hash-has-key? acc 'weapon) (hash-has-key? acc 'armor)) acc]
        [(matches? (code-of slot) weapon-keywords)
         (hash-set acc 'weapon (code-of slot))]
        [(matches? (code-of slot) armor-keywords)
         (hash-set acc 'armor (code-of slot))]
        [else acc])))
  (if (and (not (hash-has-key? found 'weapon))
           (not (hash-has-key? found 'armor)))
      #f
      found))

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
