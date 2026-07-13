#lang artifacts

;; The simplest possible gatherer. It mines copper until the bag is full, then
;; banks — and it keeps growing the bank so hauled loot always has a home.
;; This file exists to read quickly and compile; `raco make` of a #lang
;; artifacts file is enough to verify it (or run `raco test`).

(bot miner-bot
  (character miner #:role 'mining
    (mine-until-full #:resource 'copper_rocks)
    (banker #:bank-threshold 5)))
