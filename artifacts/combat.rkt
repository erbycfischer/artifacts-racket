#lang racket

(provide elemental-damage
         final-damage
         critical-damage
         expected-critical-damage
         fight-cooldown-seconds
         combat-xp)

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
