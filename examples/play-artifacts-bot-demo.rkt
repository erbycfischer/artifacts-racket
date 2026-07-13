#lang artifacts

;; Minimal, self-playing demo bot used to exercise the `play-artifacts-bot`
;; skill. It is intentionally tiny: two characters on the basic helpers, plus a
;; light account strategy. It compiles cleanly and dry-runs with no token.
;;
;; Run it through the skill:
;;   /play-artifacts-bot play-artifacts-bot-demo
;; Or directly:
;;   ARTIFACTS_DRY_RUN=1 racket examples/play-artifacts-bot-demo.rkt

(bot demo
  (character miner #:role 'mining
    (mine-until-full #:resource 'copper_rocks))
  (character fighter #:role 'combat
    (combat-loop #:max-hp-ratio 0.5))
  (strategy idle-watch
    (scan-ge)
    (check-events)))

(define dry-run?
  (let ([v (getenv "ARTIFACTS_DRY_RUN")])
    (and v (member v '("1" "true" "TRUE" "yes" "YES")) #t)))

(play demo
      #:dry-run? dry-run?
      #:iterations (if dry-run? 2 +inf.0)
      #:sleep-seconds 2)
