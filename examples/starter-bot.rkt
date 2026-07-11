#lang artifacts

;; The smallest readable bot. It mirrors the example in docs/quickstart.md:
;; a couple of characters built from helpers, plus a light account strategy.
;; This file exists to read quickly and compile; it does not run a play loop on
;; its own, so `raco make examples/starter-bot.rkt` is enough to verify it.

(bot starter
  (character miner #:role 'mining
    (mine-until-full #:resource 'copper_rocks))
  (character fighter #:role 'combat
    (combat-loop #:max-hp-ratio 0.5))
  (strategy balanced-growth
    (scan-ge)
    (check-events)
    (check-raids)))
