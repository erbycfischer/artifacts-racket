#lang artifacts

(bot starter
  (character miner #:role 'mining
    (goal 'bootstrap-bankroll
          (action 'gather-best-ore)
          (action 'sell-surplus)))
  (character fighter #:role 'combat
    (goal 'safe-xp
          (action 'fight-best-safe-monster)
          (action 'rest-when-needed)))
  (strategy balanced-growth
    (goal 'maximize-account-value
          (action 'keep-all-characters-busy)
          (action 'reroute-for-profitable-events)
          (action 'scan-grand-exchange-spreads))))
