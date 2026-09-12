# Ruthless Shared-Bank Economy Bot

Evolve [`examples/harmony-bot.rkt`](../examples/harmony-bot.rkt) into a ruthless 5-character shared-bank economy covering all 8 Artifacts skills, while growing intent-level `#lang artifacts` helpers from watching live play. Visualizer is out of scope.

## Constraints (game facts)

- **5 characters max** per account — cannot dedicate one character per skill.
- **8 skills**: mining, woodcutting, fishing, alchemy (gather + craft), cooking, weaponcrafting, gearcrafting, jewelrycrafting.
- **Shared account bank** is the coordination bus (“mailbox”): if the smith/cook is busy, deposit raw mats; when free, they withdraw and process.
- Direct `give-item` exists but is secondary (same-tile handoff only). Prefer the bank.
- Live play loops forever by default (`#:iterations +inf.0`) — that is why Racket “never finishes.” Use `ARTIFACTS_ITERATIONS=N` for finite observation runs.
- **Visualizer / 3D bridge: non-goals** (project scrapped for now).

## Flagship target

Keep evolving [`examples/harmony-bot.rkt`](../examples/harmony-bot.rkt) so existing `ARTIFACTS_AS_*` env overrides keep working.

### Roster (5 slots)

| Tag | Role | Job |
|-----|------|-----|
| fighter | combat | Fight highest safe monster; bank classified loot; outfit from vault; restock food/pots |
| miner | mining | Ore → vault; when ore backlog high, adaptive gather (alchemy plants / fish if vault short) |
| woodcutter | woodcutting | Wood → vault; same adaptive fallback |
| smith | crafter | Multi-workshop: bars/planks → cook food → alchemy pots → weapon/gear/jewelry → bank products |
| trader | trader | Sell excess on GE; snap useful deficits; flip underpriced valuables; bank gold |

Fishing and alchemy **gathering** are not dedicated characters — covered by `adaptive-gather` plus trader GE buy when the vault is empty.

```text
fighter ──soft loot / meat / feathers / hides──► SharedBank
miner ──ores──────────────────────────────────► SharedBank
woodcutter ──wood─────────────────────────────► SharedBank
SharedBank ──mats─────────────────────────────► smith
smith ──food / gear / pots / planks / bars────► SharedBank
SharedBank ──kit / food / pots────────────────► fighter
SharedBank ──excess / premium─────────────────► trader
trader ──GE sell / buy / flip─────────────────► GrandExchange
trader ──procured mats / pots─────────────────► SharedBank
fighter ──rares───────────────────────────────► RareDropLog (+ bank, never auto-sell)
```

## Loot classification (`artifacts/game-data.rkt`)

Extend [`artifacts/game-data.rkt`](../artifacts/game-data.rkt):

- `soft-loot-codes` — cook/craft inputs (meat, raw_chicken, feather, wool, hides, fish, …)
- `premium-loot-codes` — GE sell candidates
- `rare-loot-codes` — bank + append-only log; **never auto-sell**
- Expand `default-recipes` / `default-craft-skills` / `default-forge-recipes` / gear tables from the live encyclopedia (`world-cache` / items API)
- Priority forge queue: food for fighter → potions → bars/planks → current-tier kit → next-tier kit

## New / expanded helpers (DSL surface)

Grow helpers so bots read as intent. Prefer small composable macros under [`artifacts/lang/helpers/`](../artifacts/lang/helpers/).

### Logistics / mailbox

- `bank-classified-loot` — deposit by soft / premium / rare buckets
- `log-rare-drops` — bank rares + write `logs/rare-drops.ndjson` (code, qty, char, tick, monster if known)
- `supply-role` / `fulfill-demand` — restock codes needed by another role’s recipes from bank
- `when-bank-has` / `when-vault-short` predicates in the planner

### Production

- `workshop-loop` — ordered multi-skill craft: cooking → alchemy → mining bars → woodcutting planks → weapon/gear/jewelry (route via `craft-workshop-skill`)
- `cook-for-roster` — pull raw food from bank, cook, deposit cooked
- `forge-kit-for` — craft next gear tier for fighter level into vault
- `adaptive-gather` — pick resource from vault deficit vs forge/cook demand (replaces hard-coded copper/ash-only)

### Combat progression

- `ruthless-grind` — best safe monster by level; bank classified loot; heal/food/pot; `outfit-from-bank` with level-bucketed kit; raise target as levels climb
- Keep / extend `upgrade-gear`, `outfit-from-bank`, `heal-when-low`

### Market

Trader **may and should auto-spend gold** when the book shows a good deal. Spending is intentional and aggressive within defined thresholds — not timid.

- `sell-excess` — true excess only. Never GE-sell food, pots, bars/planks the forge needs, rares, current-best kit, or next-tier upgrades. **Dominated spares** (leftover copper once steel exists in the vault or on the wearer) list at **fair**, never dump-cheap. Death does not strip gear (spawn + 1 HP only); do not keep a spare starter set after upgrade.
- `procure-needs` — auto-buy underpriced **mats and consumables** the roster needs; deposit for smith/fighter. **Do not GE-buy craftable kit/tools** — the smith forges those.
- `bargain-consumables` — if vault food/pots are below target, buy at `#:need` (up to 1.5× fair). If already at target but the ask is a bargain (≤ 0.7× fair), fill up to a stockpile cap. Gold floor 100.
- `flip-spread` — auto-buy routine undervalued trade goods; relist higher when spread is profitable. Sniped **commodities** relist at `max(fair, cost × (1 + min-roi), cost + min-spread)` and strictly above fill. If the book will not clear at that premium, **hold** — do not cut the ask.
- `snipe-valuables` — buy when fair ≫ ask (`#:snipe` / `min-fair-multiple` 1.75) **only if the code is not craftable gear** (weapon/gear/jewelry recipes, role tools, bags). Then classify:
  - **equip-review** — unique/uncraftable gear that can outfit a role; fighter `outfit-from-bank` equips if better and logs `kind: equipped-for-review`
  - **hold** — unique non-gear (eggs, keys, bags of gems); bank + log; never auto-sell
  - **flip** — cheap commodities (stones, extra bars); relist high
  - Consumables are **not** snipes — buy via `#:need` / `#:bargain` only
- `spend-policy` / threshold table — acceptable max ask (or max % under fair value) **per situation**, e.g.:
  - `#:need` (roster deficit: food, pots, forge mats) — higher willingness to pay; may auto-deliver to vault
  - `#:bargain` (stockpile fill when ask ≤ 0.7× fair) — cap quantity so gold is not dumped into infinite flasks
  - `#:flip` (routine arbitrage on non-rare trade goods) — require minimum spread / ROI; may auto-relist
  - `#:snipe` (extreme underprice on uniques / commodities) — buy aggressively; disposition above
  - `#:upgrade` — unused for smith products; do not GE-buy craftable kit
  - optional floors: keep at least `N` gold in bank; max spend per tick / per item
- Keep `snap-up`, `sell-products`, `keep-gold` (gold banking must not starve the spend policy — prefer `keep-gold` floor + spend the rest)

**Player agency on extreme value:** combat rare drops and GE snipes of unique gear are logged (`logs/rare-drops.ndjson` / `logs/ge-snipes.ndjson`). Better fighter gear is equipped and tagged `equipped-for-review` — you decide later whether to keep or bank it. Never auto-sell those holdings. Routine craft mats / food / pots / premium junk / dominated leftover kit remain automated.

### Ergonomics (“tons of helpers”)

Add thin aliases as real gaps appear while watching play, e.g. `haul-to-bank`, `eat-when-low`, `equip-best-from-bank`, `clear-bag-except`, `relist-stale-orders`. Rule: every repeated multi-step pattern in logs becomes a named helper in the same session when possible.

Those named aliases exist. Empty-restock skip, bag-full mid-craft, and vault-short gather switch are already inside `restock` / `workshop-loop` / `adaptive-gather` — do not add second copies on the harmony bodies. Further helpers wait on live/dry tick watches (observe → improve).

## Bot body shape (harmony)

Rewrite character bodies to helpers only (no low-level action soup):

- **fighter:** `(heal-when-low)` `(eat-when-low)` `(outfit-from-bank)` `(equip-utility)` `(ruthless-grind …)` `(bank-classified-loot)` `(restock food)` `(log-rare-drops)` — `equip-best-from-bank` is an alias of `outfit-from-bank`; do not call both
- **miner / wood:** `(mailbox-when-used)` `(outfit-from-bank #:gear-table miner/woodcutter-kit-table)` `(adaptive-gather)` `(banker)`
- **smith:** `(bank-crafted-products)` `(outfit-from-bank #:gear-table crafter-kit-table)` `(workshop-loop)` `(banker)` — forges **one** current-tier tool/bag plus one fighter set; stops a slot once the vault already has that piece or better
- **trader:** `(pipeline … spend-policy procure-needs bargain-consumables flip-spread snipe-valuables sell-excess ruthless-market keep-gold banker)`
- **strategy:** events/raids + market watch

## Observe → improve loop (no visualizer)

1. Run finite ticks: `ARTIFACTS_ITERATIONS=N racket examples/harmony-bot.rkt` (or dry-run first).
2. Read tick/decision prints + rare-drop log.
3. When stuck / idle / wrong workshop / unsold mat → add helper or fix planner guard.
4. Expand encyclopedia tables when unknown drops/recipes appear.
5. Authoritative green check: `raco test tests/artifacts-test.rkt` after helper/planner changes.

## Tests and docs

- Unit-test new helpers’ goal-spec shapes in [`tests/artifacts-test.rkt`](../tests/artifacts-test.rkt) (same style as stockpile / forge-loop).
- Brief README / quickstart note: 5-char economy, bank mailbox, `ARTIFACTS_ITERATIONS`, rare-drop log path.
- Do **not** expand visualizer docs.

## Implementation order

1. Loot taxonomy + rare log + `bank-classified-loot`
2. `workshop-loop` / cook path on smith; wire harmony smith to it
3. `adaptive-gather` on miner/wood; fighter `ruthless-grind` + outfit
4. Trader `procure-needs` + `flip-spread` + `sell-excess` + per-situation spend thresholds
5. Encyclopedia refresh of recipes / gear tiers
6. Play finite live/dry runs; add ergonomic helpers from real stuck points
7. Tests green

## Multi-account (evaluate only — do not implement in this pass)

Goal: document whether / how a **second account** (another 5 characters) can boost efficiency without blocking the primary 5-char upgrade loop. Example: park **task master / tasker / quartermaster / event filler** on account B so account A’s fighter/miner/wood/smith/trader stay on the upgrade loop.

### Game / framework facts to evaluate against

- Character cap is **5 per account**, not 5 global — two tokens ⇒ up to 10 characters.
- **Banks are per-account.** There is no shared vault across accounts. Cross-account “help” cannot use the mailbox pattern; the only shared economy surface is the **Grand Exchange** (and world content: monsters, resources, workshops).
- Today the runtime is **one `current-config` / one bearer token** ([`artifacts/auth.rkt`](../artifacts/auth.rkt), [`artifacts/config.rkt`](../artifacts/config.rkt)). Harmony assumes one shared bank.
- `give-item` / bank deposit only move goods **within** an account.

### Likely useful account-B roles (if multi-account is ever wired)

- Tasker / task-board farmer (does not accelerate A’s forge→fighter kit loop)
- Event / raid / map filler
- Pure GE market-maker that only interacts with A via buy/sell orders
- Overflow gatherer that **lists** mats on GE for A’s trader to snap (lossy: fees, lag, competition)

### What “support without implementing” means

- Write a short design note in this doc (or a sibling `docs/multi-account-eval.md`) covering:
  - Token model: e.g. `ARTIFACTS_API_TOKEN_A` / `_B`, or `#:account` / `#:config` on `character` / `play`
  - Scheduler: one process multi-config vs two processes
  - Explicit non-coupling: account B must not assume A’s bank state
  - GE handoff protocol sketch (list codes/prices both sides agree on)
- Optionally leave **stubs only** (comments / `#:account` keyword ignored with a clear error) — **no** dual-token runner, no second bot process, no GE bridge between accounts in the implementation pass.
- Primary harmony remains a **single-account** 5-char ruthless loop.

### Verdict criteria (filled in)

See [`docs/multi-account-eval.md`](multi-account-eval.md).

- Worth it if: task XP/rewards or GE edge clearly free a slot on A for smith/fighter progression.
- Not worth it soon if: GE handoff friction + dual-token ops cost exceeds the value of freeing `task-loop` off the fighter.

**Not worth it soon.** Dual-token is later, after the single-account 5-char loop is live. Harmony already uses all five A slots (fighter / miner / wood / smith / trader); `(task-loop)` is a secondary goal on the fighter, not a sixth character. B cannot see A’s bank, cannot list A’s vault goods, and cannot transfer task XP — cross-account help is GE-only and lossy. That friction plus two tokens / two processes exceeds the value of keeping the fighter off the task master. Revisit if live ticks show the fighter is actually task-starved, or if a B market-maker plus a written handoff book clearly feeds A’s forge faster than A’s own gatherers.

## Explicit non-goals (this implementation pass)

- 3D visualizer / bridge integration
- Implementing multi-account / dual-token play (evaluate + optional stubs only)
- Auto-selling unique / ultra-valuable holdings (combat drops **or** GE snipes). Better fighter gear may auto-equip with an `equipped-for-review` log; everything else unique is bank + log. Auto-**buying** those snipes with gold is in scope. Do not GE-buy kit the smith can craft.

## Implementation todos

- [x] Extend game-data loot buckets (soft/premium/rare) + `bank-classified-loot` + rare-drop NDJSON log helper
- [x] Add `workshop-loop` (cook/alchemy/bars/planks/gear) and wire harmony smith
- [x] Add `adaptive-gather` for miner/wood driven by vault deficits
- [x] Fighter `ruthless-grind`: safe monster progression, classified banking, outfit/food/pots
- [x] Trader auto-spend gold: `procure-needs` (mats/consumables only) + `bargain-consumables` + `flip-spread` + `snipe-valuables` (skip craftable kit; commodity snipes relist high; uniques hold/equip-review) + `sell-excess` (dominated leftover kit at fair; never upgrades)
- [x] Rank-based `outfit-from-bank` + role tool tables + smith one-of-each tools/bags; fighter `equip-utility`
- [x] Gather catalog + craft-levels past steel (mithril/adamantite/maple/palm). Fighter weapon names past 20 wait on a local encyclopedia dump — do not guess.
- [x] Rewrite harmony-bot character bodies to new helpers only
- [ ] Finite-iteration play watches → add ergonomic helpers for every repeated stuck pattern *(open until live/dry ticks exist; `equip-best-from-bank` alias is in; empty-restock skip / bag-full mid-craft / vault-short gather switch already live inside `restock` / `workshop-loop` / `adaptive-gather` — do not duplicate those in the smith/gatherer bodies)*
- [ ] Extend `artifacts-test.rkt` *(test-gate wave owns this)* + short README/quickstart notes (no visualizer) — README/quickstart notes for 5-char mailbox, `ARTIFACTS_ITERATIONS`, and `logs/rare-drops.ndjson` are in
- [x] **Evaluate only:** multi-account / second 5-char roster (tasker off primary); write design note; no dual-token implementation

## Note on hanging agents / shells

Cursor Shell / Task explore agents have been hanging on even simple `ls` in this environment. Prefer parent-agent `Read` / `Grep` / `Glob` / `Write` over Task+Shell until the tooling update lands. For bot runs, always prefer finite `ARTIFACTS_ITERATIONS` so observation processes exit cleanly.
