# artifacts-racket

A Racket-first bot framework and `#lang artifacts` DSL for the **official** [Artifacts MMO](https://artifactsmmo.com).

This is **not a clone** or alternate ruleset. Bots talk only to the official Artifacts API with your real bearer token. The 3D visual client is a separate repo and bots never depend on it.

## What this repo is

A library (`artifacts/`) plus example bots (`examples/`) that let you describe *what your characters should be doing* — mine, fight, craft, trade — in Racket. A planner figures out *where to go and when*, reacting to live game state every tick. You never hand-track cooldowns or coordinates.

| Piece | Role |
|-------|------|
| `artifacts/` | Racket package: REST client, planner, runner, scheduler, `#lang artifacts` |
| `examples/` | Headless bots (`apex-bot.rkt`, `starter-bot.rkt`, `workshop-bot.rkt`) |
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
   ARTIFACTS_DRY_RUN=1 ARTIFACTS_ITERATIONS=3 racket examples/apex-bot.rkt
   ```

5. Go live once your token is set:

   ```sh
   racket examples/apex-bot.rkt
   ```

With no token, bots still *compile* and `play` still runs a dry run; live HTTP actions return a structured `452` auth error.

## The shape of a bot

A bot is a roster of `character` forms (each with a `role` that steers the planner) plus optional `strategy` forms (account-wide watch actions). Each character body is a mix of goals, `guard`s, and conditionals — intent, not bookkeeping.

```racket
#lang artifacts

(bot starter
  (character smith #:role 'crafter #:as "OreBot42"
    (craft-loop #:code 'copper_bar #:qty 1)
    (rest-when-low #:max-hp-ratio 0.5))
  (character fighter #:role 'combat
    (combat-loop #:max-hp-ratio 0.5))
  (strategy market-watch
    (scan-ge)
    (check-events)))
```

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
| `combat-loop` | Rest when HP drops to `ratio`, otherwise fight, bank when full |
| `bank-when-full` | Standalone "bank the moment the bag fills" guard |
| `rest-when-low` | Standalone "rest while hurt" guard |
| `sell-surplus` | Sell `code` to an NPC, only while standing on the shop tile |
| `craft-loop` | Craft `qty` of `code`, banking when the bag fills |
| `ge-trade` | List `qty` of `code` on the Grand Exchange, only while on the exchange tile |

**Goal conditions** (reactive guards) stay dormant until the world warrants action:

- `(when-low-hp ratio action ...)` — run only while `hp/max_hp <= ratio`.
- `(when-inventory-full action ...)` / `(when-inventory-full #:reserve n action ...)` — run only when the bag is full (minus `n` slots).
- `(when-on-content type action ...)` — run only while standing on a tile of `type` (`"bank"`, `"npc"`, `"workshop"`, `"grand_exchange"`).

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
- [`examples/`](examples/) — `apex-bot.rkt` (competitive multi-character roster), `workshop-bot.rkt`, `starter-bot.rkt`.

## Compliance

- Use **your own** Artifacts token. Respect official rate limits and the [Artifacts ToS](https://artifactsmmo.com).
- Never commit tokens or secrets — this GitHub repo is public.

## Run the tests

```sh
raco test tests/artifacts-test.rkt
```
