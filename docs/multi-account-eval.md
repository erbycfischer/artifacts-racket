# Multi-account evaluation (WAVE 1 — evaluate only)

Should a **second Artifacts account** (second bearer token, second 5-character roster) join the ruthless shared-bank economy? This note answers that against the current runtime. Dual-token play is **not** implemented here and is **not** recommended for the next implementation pass.

Primary bot: [`examples/harmony-bot.rkt`](../examples/harmony-bot.rkt) — five roles sharing **one** account bank. Plan: [`ruthless-economy-bot-plan.md`](ruthless-economy-bot-plan.md).

## Verdict

**Not worth it soon.** Dual-token is a **later** idea, after the single-account 5-char loop is live and observed.

Harmony already uses all five slots on account A (fighter, miner, woodcutter, smith, trader). The fighter’s `(task-loop)` is a **secondary goal**, not a sixth character. Parking a tasker on account B does not free a production slot on A: B cannot see or fill A’s bank, task XP/rewards stay on B unless they take a lossy Grand Exchange (GE) path, and A still needs its own trader to list vault goods (only A’s characters can withdraw from A’s bank).

Apply the plan’s test:

- **Worth it if** task XP/rewards or a GE edge clearly free a slot on A for smith/fighter progression.
- **Not worth it soon if** GE handoff friction plus dual-token ops cost exceeds the value of taking `task-loop` off the fighter.

The second bullet wins. Revisit if live ticks show the fighter is actually task-starved, or if a dedicated B market-maker plus a written handoff book clearly feeds A’s forge faster than A’s own gatherers.

## What the code does today

One process, one bearer, one bank. Harmony assumes that.

### One `current-config`, one token

[`artifacts/config.rkt`](../artifacts/config.rkt) holds a single `current-config` parameter. `env-token` reads **only** `ARTIFACTS_API_TOKEN` (preferred) then `ARTIFACTS_TOKEN`. There is no `ARTIFACTS_API_TOKEN_A` / `_B`. Token sources are one explicit string, one env pair, one file (`~/.artifacts/token` or `ARTIFACTS_TOKEN_FILE`), or the local bridge cascade. `make-config`, `make-bridge-config`, and `with-token-source` all install **one** source.

HTTP wrappers take `#:config` and default to `(current-config)`, so per-request plumbing exists, but the bot loop does not use it for a second account.

### `play` and `character` are not multi-account hooks

- `character` in [`artifacts/lang/runtime.rkt`](../artifacts/lang/runtime.rkt) has `#:role` and `#:as`. `#:as` is the **live character name** (`make-character-spec`’s `account-name` field), not a second login. Harmony binds it via `ARTIFACTS_AS_<TAG>` (e.g. `ARTIFACTS_AS_FIGHTER`).
- `play` already has `#:config`, but after auto-login it always passes `(current-config)` into `run-bot-loop`, not the keyword argument. Auto-login mutates the parameter. That is not an isolated per-account runner.
- `run-bot-loop` in [`artifacts/runner.rkt`](../artifacts/runner.rkt) is one blocking tick loop over one bot roster.

### `with-account` is a read scope, not a scheduler

[`artifacts/lang/queries.rkt`](../artifacts/lang/queries.rkt) defines `(with-account config thunk)` as `parameterize` on `current-config`. It is for scoping a query (e.g. `account-details`), not for running two rosters.

Helpers such as `restock` call `bank-item-quantity` with the default config ([`artifacts/planner.rkt`](../artifacts/planner.rkt)). Bank qty is whatever token is currently ambient. A second account in the same process would leak A’s vault into B’s restock (or the reverse) unless every bank/GE helper threaded a config — they do not, today.

### Harmony’s mailbox is account-local

Harmony’s loop is bank-as-mailbox: miner/wood deposit, smith `forge-loop` + `restock`, fighter `grind` with `#:bank-loot-codes`, trader `sell-products` / `snap-up`. `give-item` is same-tile and same-account. None of this crosses tokens.

The fighter also runs `(task-loop)` ([`artifacts/lang/helpers/combat-tasks.rkt`](../artifacts/lang/helpers/combat-tasks.rkt)): complete / exchange / start, gated to a `tasks_master` or NPC tile. That is the only “sixth job” on A, and it is stuffed onto the combat slot rather than occupying one.

## Token model sketch (future — do not implement)

Two workable shapes if this is ever wired. Do not confuse them with today’s `#:as` (character name) or `play`’s `#:config` (single-bot config, and even that is not isolated).

### Env split (simplest)

```text
ARTIFACTS_API_TOKEN_A   → account A (harmony)
ARTIFACTS_API_TOKEN_B   → account B
```

Optional files: `ARTIFACTS_TOKEN_FILE_A` / `_B` (or `~/.artifacts/token-a` and `token-b`). Keep today’s `ARTIFACTS_API_TOKEN` as the default for single-account play so harmony does not break.

### DSL keywords (only if one process must host both)

- `#:account 'a` / `'b` on `play`, mapping to the env/file sources above.
- `#:account` on `character` only if one bot form mixed both rosters — almost certainly a mistake (see non-coupling). Prefer **two bot modules**, two `play`s.

Ignored stubs (`#:account` present → clear error, “multi-account is not implemented”) could mark the hole later. **Do not add them in this pass.**

## Scheduler: one process vs two

| | Two processes | One process, two configs |
|--|---------------|---------------------------|
| Framework change | None. Each process has its own `current-config`. | Large: isolate `play` auto-login, thread `#:config` through restock/bank/GE helpers, stop mutating the global parameter mid-loop. |
| Crash / iterations | A finite `ARTIFACTS_ITERATIONS` on A does not kill B. | One loop or two interleaved loops; a 452 on B can take A down unless carefully isolated. |
| Rate limits | Two clients; still one public IP. | Same, plus easier to accidentally share one token. |
| GE protocol | Shared **document** (codes/prices below), not shared memory. | Tempting to peek the other bank. That is a bug. |
| Ops | Two tokens, two logs, two commands. | One command, twice the runtime complexity. |

**If dual-account is ever worth it, start with two processes.** Run harmony under token A; run a separate `#lang artifacts` bot under token B. One-process multi-config is only interesting after that ops path is proven and a single coordinator process is clearly cheaper than two shells.

`run-bot-loop` is sequential and blocking. Threads plus `parameterize` could multiplex, but ambient `bank-item-quantity` / `restock` makes that unsafe until configs are threaded for real.

## Explicit non-coupling

Account B **must not** assume A’s bank state.

- Banks are **per-account**. `get-bank-details` / `get-bank-items` follow the bearer. There is no shared vault.
- `give-item` / deposit / withdraw / `restock` / `outfit-from-bank` / `forge-loop` only move goods **inside** one account.
- Cross-account help is **GE-only** (plus contested world content: monsters, nodes, workshops, events, raids).
- B must not `restock` for codes it expects A to have deposited. B must not plan crafts off A’s vault deficit. A must not `when-bank-has` on B’s ore.
- Gold is per-account. B’s listing fees and A’s snap gold are separate purses.
- Rares stay on the originating account’s bank and rare-drop log. Do not auto-list them as a “handoff.”

The comment in [`artifacts/lang/helpers/market-logistics.rkt`](../artifacts/lang/helpers/market-logistics.rkt) about “cross-account actions” means helpers that read **bank or GE state** rather than the character hash. It is not a multi-login feature.

## GE handoff protocol sketch

Both sides agree on a **written book** (this table or a sibling file), not on live bank peeks. Prices below are protocol placeholders from Harmony’s current listings / potion snap — tune from the live book before any real dual-account run.

Rules:

1. B lists only B’s goods (withdraw from **B’s** bank, then `sell-on-ge`).
2. A snaps with `snap-up` at or below `A max`. A does not restock those codes from A’s vault as a substitute for a fill.
3. A still lists **A’s** crafted products (`sell-products`) from A’s vault. B must not undercut A’s refined SKUs unless the book says B is the seller for that code.
4. Treat fills as lossy: GE tax, delay, third-party snipes. If fill rate is poor, stop listing rather than lowering into a gift for strangers.
5. Never auto-sell rares / snipes on either side (`logs/rare-drops.ndjson` policy).
6. Keep a gold floor on both traders so a snap cannot bankrupt the other loop.

| Code | B lists qty | B ask | A snap max | Role |
|------|-------------|-------|------------|------|
| `copper_ore` | 20 | 8 | 10 | Overflow for A’s forge |
| `ash_wood` | 20 | 7 | 9 | Overflow for planks |
| `sunflower` | 20 | 6 | 8 | Alchemy gather A does not staff |
| `gudgeon` | 20 | 6 | 8 | Cooking/fish A does not staff |
| `small_health_potion` | 5 | 18 | 20 | Already snapped on A’s trader; B may list extras |

Harmony’s trader today lists refined goods (`copper_bar` @ 40, `ash_plank` @ 35, kit, slimeballs, …) and snaps `small_health_potion` at max 20. A **handoff SKU** should not appear on both sides as a sell unless one account is designated seller. Default: B sells raw overflow; A sells refined + premium loot from A’s mailbox.

## Likely account-B roles

None of these replace A’s five-role upgrade loop. They are extras behind a GE wall.

### Tasker / task-board

Closest to “take `task-loop` off the fighter.” Task complete / exchange / start live on B. Rewards and task XP accrue on **B**. They help A only if reward items are listed and A snaps them. That is not a kit-forge accelerator unless those rewards are the missing mats, which is unproven. Value on A is only fewer fighter walks to `tasks_master` — not a freed slot.

### Event / raid filler

Harmony’s `strategy` already `check-events` / `check-raids` on A. B can park bodies on events without pulling A’s smith or fighter off the upgrade loop. Loot still has to GE to A to matter. World tiles are contested, not a mailbox.

### Pure GE market-maker

B only buys/sells. Highest coupling-to-value **if** A is mat- or gold-starved and B can consistently undercut the public ask on the handoff book. Risk: A’s trader and B bid against each other on the same code. Protocol must name one sniper per SKU. A still needs a character on A’s GE to **list vault output**; B cannot withdraw A’s bars.

### Overflow gatherer

B mines / woods / fishes / alchs and lists mats for A to snap. This is the only role that could feed A’s forge directly. It is worth it only when observation shows A’s smith idle on empty vault while miner/wood are already busy — a 6th gatherer problem. Until that bottleneck is measured, A’s own `adaptive-gather` (planned on miner/wood) is the cheaper fix.

## Why “free a slot on A” barely applies

A slot would be freed if B could take over a **whole Harmony role** so A could restaff that slot (e.g. drop trader, add a fisher). B cannot take trader: listing A’s vault requires an A character at the GE. B cannot take smith, miner, or fighter without the shared bank. The only load that moves cleanly is `task-loop` on the fighter, which is not a slot.

So the worth-it clause (task XP/rewards or GE edge **clearly** freeing a slot for smith/fighter progression) is not met. The not-worth-it-soon clause is: GE friction + two tokens + two processes + a handoff book to maintain > fighter ticks spent on `task-loop`.

## Optional stubs (future idea only)

Not in this pass. If marked later, prefer a loud error over a silent ignore:

- `#:account` on `character` / `play` → error: multi-account is not implemented; use a second process with its own `ARTIFACTS_API_TOKEN`.
- Do not invent `ARTIFACTS_API_TOKEN_B` reads until a real second runner exists.

Primary harmony remains a **single-account** 5-char ruthless loop.
