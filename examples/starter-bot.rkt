#lang artifacts

(bot starter
  (character miner #:role 'mining
    (goal 'bootstrap-bankroll
          (action 'gather)
          (action 'bank-deposit-item)))
  (character fighter #:role 'combat
    (goal 'safe-xp
          (action 'fight)
          (action 'rest)))
  (strategy balanced-growth
    (action 'grand-exchange-orders)
    (action 'active-events)
    (action 'raids)))
