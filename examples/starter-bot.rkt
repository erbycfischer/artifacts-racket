#lang artifacts

;; Minimal showcase of the high-level helpers. For live play, see
;; examples/apex-bot.rkt; this file is here to read quickly and compile.
;;
;; Each helper returns a goal/pipeline that the planner keeps dormant until the
;; world warrants action, so the bots below are just intent, no bookkeeping.

(bot starter
  (character miner #:role 'mining
    (mine-until-full #:resource 'copper_rocks))
  (character fighter #:role 'combat
    (combat-loop #:max-hp-ratio 0.5))
  (strategy balanced-growth
    (scan-ge)
    (check-events)
    (check-raids)))
