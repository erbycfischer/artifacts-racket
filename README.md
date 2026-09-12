# artifacts-racket

A Racket-first bot framework and `#lang artifacts` DSL for the **official** [Artifacts MMO](https://artifactsmmo.com).

This is **not a clone** or alternate ruleset. Bots talk only to the official Artifacts API with your real bearer token. The 3D visual client is a separate repo and bots never depend on it.

## What this repo is

A library (`artifacts/`) plus example bots (`examples/`) that let you describe *what your characters should be doing* — mine, fight, craft, trade — in Racket. A planner figures out *where to go and when*, reacting to live game state every tick. You never hand-track cooldowns or coordinates.

| Piece | Role |
|-------|------|
| `artifacts/` | Racket package: REST client, planner, runner, scheduler, `#lang artifacts` |
| `examples/` | Headless bots; flagship is `harmony-bot.rkt` (5-char shared-bank economy) |
| `docs/` | Quickstart, API inventory, API map, architecture |

## Quick start

1. Install [Racket](https://download.racket-lang.org) 8.x+.
2. Set your token (preferred name first):

   ```sh
   export ARTIFACTS_API_TOKEN="your-token-here"   # preferred
   # export ARTIFACTS_TOKEN="your-token-here"     # fallback if API_TOKEN is unset
   ```

3. Make the package reachable. From the repo root:

   ```sh
   raco pkg install --auto --link
   # or, without installing:  export PLTCOLLECTS="$PWD:"
   ```

4. **Dry-run first** (no token needed, no real actions) to confirm your bot compiles and the loop behaves:

   ```sh
   ARTIFACTS_DRY_RUN=1 ARTIFACTS_ITERATIONS=3 racket examples/harmony-bot.rkt
   ```

5. Go live once your token is set. Live `play` defaults to an infinite tick loop (`#:iterations +inf.0`), which looks like the process never finishes — cap a run with `ARTIFACTS_ITERATIONS`:

   ```sh
   ARTIFACTS_ITERATIONS=20 racket examples/harmony-bot.rkt
   ```

With no token, bots still *compile* and `play` still runs a dry run; live HTTP actions return a structured `452` auth error.

## Flagship: 5-character shared-bank economy

[`examples/harmony-bot.rkt`](examples/harmony-bot.rkt) is the flagship: fighter, miner, woodcutter, smith, and trader (the account cap). They coordinate through the **account bank as a mailbox** — gatherers deposit mats; the smith withdraws and crafts; the fighter outfits from the vault; the trader lists excess on the Grand Exchange.

Rare drops are banked and appended to `logs/rare-drops.ndjson`. They are **never auto-sold**.

## The shape of a bot

A bot is a roster of `character` forms (each with a `role` that steers the planner) plus optional `strategy` forms (account-wide watch actions). Each character body is a mix of goals, `guard`s, and conditionals — intent, not bookkeeping.

```racket
#lang artifacts

(bot starter
  (character smith #:role 'crafter #:as  

- `bot name ...` — top-level container; `name` is what you hand to `play`.
- `character tag #:role role [#:as name] ...` — one character. `tag` is a local label; `#:as name` pins it to a live Artifacts character (without `#:as`, the tag *is* the name).
- `strategy name action ...` — flat, role-less actions sprinkled across ticks (scan the Grand Exchange, watch events).
- `pipeline`, `loop`, `routine` are synonyms; each names a goal — a sequence of actions/guards. `goal target action ...` is the same with an explicit keyword.
- `guard #:when predicate body ...` (or `(guard predicate body ...)`) wraps actions so they run only when `predicate`, checked against the live character, answers true.
- `repeat n body ...` expands to `n` copies — "do this N times, then stop."

**Keyword action builders** (`artifacts/lang/actions.rkt`) are the verbs: `gather`, `fight`, `rest`, `move-to`, `move-to-map`, `transition`, `craft`, `recycle`, `buy`, `sell`, `deposit-all`, `deposit-gold`, `withdraw`, `withdraw-gold`, `buy-expansion`, `equip`, `unequip`, `use-item`, `task-start`/`task-complete`/`task-cancel`/`task-exchange`/`task-trade`, `scan-ge`, `sell-on-ge`, `buy-on-ge`, `bid-on-ge`, `cancel-order`, `fill-order`, `check-events`, `check-raids`, `give-gold`, `give-item`, `claim-item`, `delete-item`, `change-skin`. Most take keyword arguments (positional aliases exist for compact scripts).

**High-level helpers** (`artifacts/lang/helpers.rkt`) compose builders with reactive conditions and drop straight into a character body:

| Helper | What it does |
|--------|--------------|
| `mine-until-full` | Gather the role resource, bank when the bag nears capacity |
| `gather-until` | Gather until the bag holds `qty` of a code, banking when full along the way |
| `haul` | `mine-until-full` + `banker` — gather until full, bank, grow bank capacity |
| `combat-loop` | Rest when HP drops to `ratio`, otherwise fight, bank when full |
| `farm-xp` | Combat `auto-level`: grind toward `target`, then go dormant |
| `bank-when-full` | Standalone "bank the moment the bag fills" guard |
| `rest-when-low` | Standalone "rest while hurt" guard |
| `heal-when-low` | Use a potion when HP drops to `ratio` of max |
| `eat-when-low` | Same trigger, default cooked food |
| `consume-buff` | Use `code` as soon as it lands in the bag |
| `sell-surplus` | Sell `code` to an NPC, only while standing on the shop tile |
| `craft-loop` | Craft `qty` of `code`, banking when the bag fills |
| `production-chain` | `gather-until` each ingredient, then craft the product |
| `craft-if-materials` | Craft only once every listed material is in the bag |
| `recycle-junk` | Recycle listed codes at a workshop when held |
| `ge-trade` | List `qty` of `code` on the Grand Exchange, only while on the exchange tile |
| `snap-up` | Buy on the GE when the best ask is at or below `max-price` |
| `withdraw-then-sell` | Withdraw from bank, then list on the GE |
| `auto-level` | Grind toward `target` level via role skill, banking when full |
| `trader-loop` | Scan GE, list a sell, bank when full; optional `#:fill-order-id` |
| `banker` | Bank when full; buy a bank slot when the bank nears capacity |
| `bank-gold` | Deposit gold when carried gold exceeds `threshold` |
| `keep-gold` | Withdraw gold when carried gold falls below `floor` |
| `stockpile` / `deposit-surplus` | Keep `n` of a code in the bag; deposit the rest at the bank |
| `restock` | Withdraw from bank until the bag holds `n` of a code |
| `gather-specific` | Gather a named resource, bank when the bag fills |
| `hunt` | Fight a named monster, rest when hurt, bank when full |
| `task-loop` | Complete / exchange / accept tasks at the task master |
| `sell-all-on-ge` | Dump listed codes on the Grand Exchange |
| `travel-to` | Walk to the nearest tile of a content type |
| `auto-gear` | Equip the best weapon/armor currently in inventory |
| `buy-kit` | Buy and equip a hash of slot → item-code at the items tile |
| `grind` | Fight, sell or bank loot, upgrade gear — `#:bank-loot-codes` for shared vaults |
| `ruthless-grind` | Best safe monster by level; bank classified loot (never auto-sell rares) |
| `bank-classified-loot` | Deposit soft / premium / rare buckets into the shared vault |
| `log-rare-drops` | Bank rares and append `logs/rare-drops.ndjson` |
| `adaptive-gather` | Gather the resource the vault is short of for the role |
| `spend-policy` / `procure-needs` / `bargain-consumables` / `flip-spread` / `snipe-valuables` / `sell-excess` | Trader auto-spend gold; craftable kit is never GE-bought; commodity snipes relist high; uniques hold/equip-review |
| `bank-loot` | Deposit listed loot codes into the shared bank |
| `outfit-from-bank` | Equip the best vault/bag piece per slot (rank-compared); rares log `equipped-for-review` |
| `forge-loop` | Bank-backed refine + forge (bars, planks, starter gear) |
| `workshop-loop` | Ordered multi-workshop craft (cooking through jewelry) |
| `sell-products` | Withdraw goods from the bank and list them on the GE |

**Goal conditions** (reactive guards) stay dormant until the world warrants action:

- `(when-low-hp ratio action ...)` — run only while `hp/max_hp <= ratio`.
- `(when-inventory-full action ...)` / `(when-inventory-full #:reserve n action ...)` — run only when the bag is full (minus `n` slots).
- `(when-on-content type action ...)` — run only while standing on a tile of `type` (`"bank"`, `"npc"`, `"workshop"`, `"grand_exchange"`).
- `(when-has-item code action ...)` / `(when-gold-above n action ...)` / `(when-gold-below n action ...)` — run only when the bag or purse matches.
- `(when-hp-above ratio action ...)` / `(when-inventory-empty action ...)` — run only while HP or bag slots match.
- `(when-on-map id action ...)` / `(when-below-level target action ...)` — run only on a map or while under a level target.

Fight decisions use a [matchup scorer](artifacts/combat.rkt): `matchup-score` prefers the API `/simulation/fight` probability and falls back to a local heuristic; `best-safe-monster` in `artifacts/planner.rkt` then picks the safest reachable target.

Run a bot with `play`:

```racket
(play starter #:dry-run? #t #:iterations 2)   ; simulate
(play starter #:dry-run? #f)                   ; live (token required)
```

`play` keywords: `#:dry-run?` (boolean), `#:iterations` (ticks; default forever), `#:sleep-seconds` (pause between ticks, default `2`), `#:ensure-characters?` (create missing characters from `#:as`/tags), `#:skin`/`#:skins`.

## Boundary: bots and the 3D visual client are separate

The 3D visual client lives in the sibling repo [`artifacts-mmo-ai-3d-visualizer`](https://github.com/erbycfischer/artifacts-mmo-ai-3d-visualizer). **Bots must not import or depend on it.** Watching bots in 3D works by the visualizer bridge polling official character state — zero bot-side visualization code. The `realtime.rkt` layer in this repo models the live-character data shape and readiness flags only; it opens no WebSocket.

```sh
cd ~/artifacts-mmo-ai-3d-visualizer
export PLTCOLLECTS="$HOME/artifacts-racket:${PLTCOLLECTS:-}"
export ARTIFACTS_API_TOKEN=your_token_here
racket bridge.rkt
# in another terminal:  godot --path godot
```

## Docs and examples

- [`docs/quickstart.md`](docs/quickstart.md) — full from-zero walkthrough with a compiling bot.
- [`docs/api-map.md`](docs/api-map.md) — every Artifacts MMO capability mapped to its Racket entry point.
- [`docs/api-inventory.md`](docs/api-inventory.md) — the REST wrapper surface in `artifacts/http.rkt`.
- [`docs/architecture.md`](docs/architecture.md) — bot stack and the two-repo split.
- [`examples/`](examples/) — `harmony-bot.rkt` (flagship 5-char shared-bank economy), `everything-bot.rkt` (one-line helpers playbook), `apex-bot.rkt` (competitive multi-character roster), `workshop-bot.rkt`, `starter-bot.rkt`.
- [`docs/multi-account-eval.md`](docs/multi-account-eval.md) — second-account / dual-token evaluation (not implemented; not recommended soon).

## Compliance

- Use **your own** Artifacts token. Respect official rate limits and the [Artifacts ToS](https://artifactsmmo.com).
- Never commit tokens or secrets — this GitHub repo is public.

## Run the tests

```sh
raco test tests/artifacts-test.rkt
```
