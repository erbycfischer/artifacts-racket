#lang artifacts

;; The simplest possible fighter. It rests when hurt, fights the best-safe
;; monster, and banks when the bag is full — all driven toward level 10 by
;; auto-level so the grind stops once the goal is reached. Reads as intent,
;; not bookkeeping. Compiles with no token.

(bot fighter-bot
  (character fighter #:role 'combat
    (auto-level 'combat #:target 10 #:max-hp-ratio 0.5)))
