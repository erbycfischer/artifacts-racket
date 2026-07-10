#lang artifacts

;; Minimal DSL example. For live play, use examples/apex-bot.rkt.

(bot starter
  (character miner #:role 'mining
    (pipeline 'bootstrap-bankroll
      (gather)
      (deposit-all)))
  (character fighter #:role 'combat
    (pipeline 'safe-xp
      (fight)
      (rest)))
  (strategy balanced-growth
    (scan-ge)
    (check-events)
    (check-raids)))
