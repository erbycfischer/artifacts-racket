# API map: Artifacts MMO capabilities → Racket entry points

Every name below is one that actually exists in the source. The three columns are:

- **Racket wrapper** — the mutating/reading function in `artifacts/http.rkt`.
- **`#lang artifacts` builder** — the keyword builder in `artifacts/lang/actions.rkt` (what you write inside a bot).
- **Helper** — the high-level composition in `artifacts/lang/helpers.rkt`, where one applies.

Builders dispatch through `artifacts/dispatch.rkt` onto the `http.rkt` wrappers. Verified against the `provide` lists of `http.rkt`, `actions.rkt`, and `helpers.rkt`.

## Action capabilities

| Capability | Racket wrapper (`http.rkt`) | `#lang artifacts` builder (`actions.rkt`) | Helper (`helpers.rkt`) |
|-----------|------------------------------|-------------------------------------------|-------------------------|
| Movement (move to x/y) | `action-move` | `move-to` | — |
| Movement (move to map id) | `action-move` | `move-to-map` | — |
| Map transition | `action-transition` | `transition` | — |
| Rest / recover HP | `action-rest` | `rest` | `rest-when-low` |
| Equip item | `action-equip` | `equip` | — |
| Unequip item | `action-unequip` | `unequip` | — |
| Use consumable | `action-use` | `use-item` | — |
| Gather (role resource) | `action-gather` | `gather` | `mine-until-full` |
| Fight (+ matchup scoring) | `action-fight` | `fight` | `combat-loop` |
| Craft | `action-craft` | `craft` | `craft-loop` |
| Recycle | `action-recycle` | `recycle` | — |
| Bank deposit item | `action-bank-deposit-item` | `deposit-all` | `mine-until-full`, `bank-when-full`, `craft-loop` |
| Bank deposit gold | `action-bank-deposit-gold` | `deposit-gold` | — |
| Bank withdraw item | `action-bank-withdraw-item` | `withdraw` | — |
| Bank withdraw gold | `action-bank-withdraw-gold` | `withdraw-gold` | — |
| Bank buy expansion | `action-bank-buy-expansion` | `buy-expansion` | — |
| NPC buy | `action-npc-buy` | `buy` | `sell-surplus` (sell side) |
| NPC sell | `action-npc-sell` | `sell` | `sell-surplus` |
| Grand Exchange buy (fill order) | `action-grand-exchange-buy` | `buy-on-ge` | — |
| Grand Exchange create sell order | `action-grand-exchange-create-sell-order` | `sell-on-ge` | `ge-trade` |
| Grand Exchange create buy order | `action-grand-exchange-create-buy-order` | `bid-on-ge` | — |
| Grand Exchange cancel order | `action-grand-exchange-cancel` | `cancel-order` | — |
| Grand Exchange fill order | `action-grand-exchange-fill` | `fill-order` | — |
| Task: new | `action-task-new` | `task-start` | — |
| Task: complete | `action-task-complete` | `task-complete` | — |
| Task: cancel | `action-task-cancel` | `task-cancel` | — |
| Task: exchange rewards | `action-task-exchange` | `task-exchange` | — |
| Task: trade | `action-task-trade` | `task-trade` | — |
| Give gold | `action-give-gold` | `give-gold` | — |
| Give item | `action-give-item` | `give-item` | — |
| Claim item | `action-claim-item` | `claim-item` | — |
| Delete item | `action-delete-item` | `delete-item` | — |
| Change skin | `action-change-skin` | `change-skin` | — |

## Read-only capabilities

The `scan-ge`, `check-events`, and `check-raids` builders are reads, not actions: they dispatch to `get-*` functions (no character name needed) rather than a character action endpoint.

| Capability | Racket reader (`http.rkt`) | `#lang artifacts` builder (`actions.rkt`) | Helper |
|-----------|-----------------------------|-------------------------------------------|--------|
| Grand Exchange: list my orders | `get-my-grand-exchange-orders` | `scan-ge` | — |
| Events: active | `get-active-events` | `check-events` | — |
| Raids: list | `get-raids` | `check-raids` | — |

## Encyclopedia & account reads (Racket only — no builder)

These are exposed as `http.rkt` readers for scripting/strategy logic. They have no `#lang artifacts` builder because the planner pulls them automatically into its world index; bots rarely call them directly.

| Capability | Racket reader (`http.rkt`) |
|-----------|-----------------------------|
| Server details | `get-server-details` |
| Account details | `get-account-details` |
| My characters | `get-my-characters` |
| Character (single) | `get-character` |
| Create character | `create-character` |
| Delete character | `delete-character` |
| Known skins / valid skin / valid name | `known-character-skins`, `valid-character-skin?`, `valid-character-name?` |
| Bank details | `get-bank-details` |
| Bank items | `get-bank-items` |
| My GE history | `get-my-grand-exchange-history` |
| Pending items | `get-pending-items` |
| Purchase history | `get-purchase-history` |
| Gems history | `get-gems-history` |
| Active task | `get-my-tasks-active` |
| Task history | `get-my-tasks-history` |
| Auctions (public) | `get-auctions` |
| My auctions | `get-my-auctions` |
| My events / balance / badges / stats | `get-my-events`, `get-my-balance`, `get-my-badges`, `get-my-stats` |
| Rate limits | `get-rate-limits` |
| Account logs | `get-account-logs` |
| Character logs | `get-character-logs` |
| Maps (list / by coord / by id) | `get-maps`, `get-map`, `get-map-by-id` |
| Items (list / one) | `get-items`, `get-item` |
| Monsters (list / one) | `get-monsters`, `get-monster` |
| Resources (list / one) | `get-resources`, `get-resource` |
| NPCs (list / one / items) | `get-npcs`, `get-npc`, `get-npc-items`, `get-npc-item` |
| Tasks (list / one) | `get-tasks`, `get-task` |
| Achievements | `get-achievements` |
| Effects | `get-effects` |
| GE orders (public) | `get-grand-exchange-orders` |
| GE order (public, by id) | `get-grand-exchange-order` (`ge-order`) |
| GE history (public, by code) | `get-grand-exchange-history` |
| Events (list / one) | `get-events`, `get-event` |
| Raids (list / one / leaderboard) | `get-raids`, `get-raid`, `get-raid-leaderboard` |
| Character / account leaderboards | `get-character-leaderboard`, `get-account-leaderboard` |
| Column leaderboard / rankings | `get-leaderboard`, `get-rankings` |
| Fight simulation | `simulate-fight` (used by `matchup-score`) |

## Fight matchup scoring (helpers, not direct API builders)

| Capability | Racket entry point (`combat.rkt`) |
|-----------|-----------------------------------|
| Combine API sim + local heuristic | `matchup-score` |
| API `/simulation/fight` score | `simulate-fight-score` |
| Pure local combat heuristic | `local-combat-score` |
| Suggest equipment from inventory | `suggest-equipment` |
| Damage / XP math | `elemental-damage`, `final-damage`, `critical-damage`, `expected-critical-damage`, `fight-cooldown-seconds`, `combat-xp` |

The planner uses `best-safe-monster` (`artifacts/planner.rkt`) on top of `matchup-score` to pick the safest reachable target per tick.

## Coverage notes

- Every capability the Artifacts MMO action API exposes is wrapped here; nothing is deliberately left unwrapped.
- The `scan-ge` / `check-events` / `check-raids` builders look like actions in `#lang artifacts` but dispatch to read endpoints. That is intentional — they are world-state reads, not character actions.
- Characters reads (`get-character`) and world/encyclopedia caches are resolved internally by the planner; you normally don't call them from a bot body.
