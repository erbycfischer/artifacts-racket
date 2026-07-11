# Quickstart: writing an Artifacts MMO bot in Racket

`#lang artifacts` is a small Racket dialect for scripting the [Artifacts MMO](https://artifactsmmo.com). You describe *what your characters should be doing* — mine, fight, craft, trade — and the planner figures out *where to go and when*, reacting to the live game state every tick. This guide gets you from zero to a compiling bot.

Everything below maps to real forms in `artifacts/lang/runtime.rkt`, `artifacts/lang/actions.rkt`, and `artifacts/lang/helpers.rkt`. If a symbol isn't in here, it probably doesn't exist yet — check those files first.

## 1. Set your token

Live play needs an Artifacts API token. The framework reads it from the environment:

```bash
export ARTIFACTS_API_TOKEN="your-token-here"   # preferred
# or, for local use:
export ARTIFACTS_TOKEN="your-token-here"        # fallback if API_TOKEN is unset
```

`ARTIFACTS_API_TOKEN` wins when both are set (see `artifacts/config.rkt`). With no token, helpers still *compile* and `play` still runs a **dry run** — but live HTTP actions return a structured `452` auth error.

## 2. The shape of a bot

A bot is a `(bot ...)` form containing one or more `character` forms and optional `strategy` forms. Think of it as a roster: each character has a `role` that tells the planner which skills and tiles to favor, and a body of goals/actions that express intent.

```racket
#lang artifacts

(bot my-bot
  (character miner #:role 'mining
    (mine-until-full #:resource 'copper_rocks))
  (character fighter #:role 'combat
    (combat-loop #:max-hp-ratio 0.5))
  (strategy idle-watch
    (scan-ge)
    (check-events)))
```

- `bot name ...` — the top-level container. `name` is what you hand to `play`.
- `character tag #:role role [#:as name] ...` — one character. `tag` is a local label; `#:as name` (optional) pins it to a specific live Artifacts character name. Without `#:as`, the tag *is* the character name. Both forms exist:
  - `(character miner #:role 'mining ...)` uses the tag as the name.
  - `(character miner #:role 'mining #:as "OreBot42" ...)` maps to a named character.
- `strategy name action ...` — a flat list of actions the planner sprinkles in (scanning the Grand Exchange, watching events). No role attached.

### How the control forms fit together

- `pipeline`, `loop`, and `routine` are synonyms: each names a sequence of actions/guards that become a *goal*. `(pipeline 'mine-forever (gather) (deposit-all))` is a goal named `mine-forever`.
- `goal target action ...` is the same idea with an explicit `goal` keyword.
- `guard #:when predicate body ...` (or `(guard predicate body ...)`) wraps actions so they only run when `predicate`, evaluated against the live character, answers true. The predicate sees the freshest state every tick.
- `repeat n body ...` expands to `n` copies of `body` — "do this N times, then stop."

The planner resolves guards against the live character at decision time, so a goal can stay dormant until the world warrants it (HP low, bag full, standing on the right tile). You never track cooldowns or positions by hand.

## 3. Keyword action builders

These are the verbs. Most take keyword arguments for readability; the file comments keep positional aliases for compact scripts. Builders live in `artifacts/lang/actions.rkt`.

| Builder | Meaning | Example |
| --- | --- | --- |
| `gather` | Gather the role resource (tile chosen by planner) | `(gather)` |
| `fight` | Fight the best-safe monster | `(fight)` |
| `rest` | Recover HP | `(rest)` |
| `move-to` | Move to coordinates | `(move-to #:x 1 #:y 0)` |
| `move-to-map` | Move to a map id | `(move-to-map #:map-id 9)` |
| `transition` | Use a map transition | `(transition)` |
| `craft` | Craft an item | `(craft #:code 'copper_bar #:qty 1)` |
| `recycle` | Recycle an item | `(recycle #:code 'ash #:qty 1)` |
| `buy` | Buy from an NPC | `(buy #:code 'copper_ore #:qty 5)` |
| `sell` | Sell to an NPC | `(sell #:code 'copper_ore #:qty 5)` |
| `deposit-all` | Deposit everything at the bank | `(deposit-all)` |
| `deposit-gold` | Deposit gold | `(deposit-gold #:gold 100)` |
| `withdraw` | Withdraw an item | `(withdraw #:code 'copper_ore #:qty 5)` |
| `withdraw-gold` | Withdraw gold | `(withdraw-gold #:gold 100)` |
| `buy-expansion` | Buy a bank slot (payload-free) | `(buy-expansion)` |
| `equip` / `unequip` | Manage gear | `(equip 'weapon 'armor)` |
| `task-start` / `task-complete` / `task-cancel` / `task-exchange` / `task-trade` | Task board flows | `(task-complete)` |
| `use-item` | Consume an item | `(use-item #:code 'small_health_potion #:qty 1)` |
| `sell-on-ge` | Post a GE sell order | `(sell-on-ge #:code 'copper_ore #:qty 5 #:price 10)` |
| `buy-on-ge` | Fill a GE buy order | `(buy-on-ge #:order-id 42 #:qty 5)` |
| `bid-on-ge` | Post a GE buy order | `(bid-on-ge #:code 'coal #:qty 5 #:price 8)` |
| `scan-ge` | List your GE orders | `(scan-ge)` |
| `cancel-order` | Cancel a GE order | `(cancel-order #:order-id 42)` |
| `fill-order` | Fill a GE order | `(fill-order #:order-id 42 #:qty 5)` |
| `check-events` / `check-raids` | Inspect world state | `(check-events)` |
| `give-gold` / `give-item` / `claim-item` / `delete-item` / `change-skin` | Misc account actions | `(change-skin #:skin 'women3)` |

Codes are symbols or strings; `item-code` stringifies them for you.

## 4. High-level helpers

These compose builders with the reactive goal conditions from `artifacts/planner.rkt`. Each returns a goal (or a guard) that drops straight into a `character` body. They read like intent: "mine until full, then bank."

| Helper | What it does |
| --- | --- |
| `mine-until-full` | `(gather)` then bank when the bag is within `reserve` slots of capacity. `(mine-until-full #:resource 'copper_rocks #:reserve 1)` |
| `combat-loop` | Rest when HP drops to `ratio`, otherwise fight, and bank when full. `(combat-loop #:max-hp-ratio 0.5)` |
| `sell-surplus` | Sell `code` to an NPC, but only while standing on the shop tile. `(sell-surplus #:code 'copper_ore #:qty 5)` |
| `bank-when-full` | A standalone "bank the moment the bag fills" guard. `(bank-when-full #:reserve 1)` |
| `rest-when-low` | A standalone "rest while hurt" guard. `(rest-when-low #:max-hp-ratio 0.5)` |
| `craft-loop` | Craft `qty` of `code`, banking when the bag fills so a long run never stalls. `(craft-loop #:code 'copper_bar #:qty 1 #:reserve 1)` |
| `ge-trade` | List `qty` of `code` on the Grand Exchange at `price`, but only while on the exchange tile. `(ge-trade #:code 'copper_ore #:qty 5 #:price 10)` |

## 5. Goal conditions (reactive guards)

The conditions run against the live character every tick, so the goal body stays dormant until warranted:

- `(when-low-hp ratio action ...)` — run `action` only while `hp/max_hp <= ratio`.
- `(when-inventory-full action ...)` or `(when-inventory-full #:reserve n action ...)` — run `action` only when the bag is full (minus `n` slots).
- `(when-on-content type action ...)` — run `action` only while standing on a tile of `type` (e.g. `"bank"`, `"npc"`, `"workshop"`, `"grand_exchange"`).

```racket
(when-on-content "workshop"
  (craft #:code 'copper_bar #:qty 1))
```

These are thin syntax over `guard-spec`, so they compose with `repeat`/`loop` and resolve through the same path as plain guards.

## 6. Run it: dry-run first, then live

`play` drives the bot loop. Always dry-run before going live:

```racket
;; Dry run: no token needed, no real actions.
(play my-bot #:dry-run? #t #:iterations 2)

;; Live play once your token is set:
(play my-bot #:dry-run? #f)
```

`play` keywords:

- `#:dry-run?` — `#t` simulates (no HTTP), `#f` acts for real.
- `#:iterations` — how many decision ticks to run (default `+inf.0`, forever).
- `#:sleep-seconds` — pause between ticks (default `2`).
- `#:ensure-characters?` — `#t` creates missing characters from `#::as` names (or tags).
- `#:skin` / `#:skins` — character appearance when creating accounts.

Many example bots read `ARTIFACTS_DRY_RUN`, `ARTIFACTS_ITERATIONS`, and `ARTIFACTS_AS_<TAG>` from the environment, so you can run them with a one-liner:

```bash
ARTIFACTS_DRY_RUN=1 racket examples/workshop-bot.rkt
```

## 7. A complete bot that compiles

Here is a real, self-contained bot. Drop it in a `.rkt` file and run `racket your-bot.rkt` — it compiles and dry-runs with no token.

```racket
#lang artifacts

;; A two-character bot: a crafter who refines copper and banks when loaded,
;; and a fighter who rests when hurt and banks when full. The strategy keeps
;; an eye on the Grand Exchange and world events between goals.

(bot starter
  (character smith #:role 'crafter
    (craft-loop #:code 'copper_bar #:qty 1)
    (rest-when-low #:max-hp-ratio 0.5))
  (character fighter #:role 'combat
    (combat-loop #:max-hp-ratio 0.5))
  (strategy market-watch
    (scan-ge)
    (check-events)))

;; Dry-run by default; flip to #f (and set a token) for live play.
(play starter #:dry-run? #t #:iterations 2)
```

This mirrors `examples/starter-bot.rkt` and `examples/workshop-bot.rkt`, which use the same helpers with live `#:as` name overrides and environment-driven dry-run flags.

## Where to go next

- `examples/apex-bot.rkt` — a competitive multi-character roster using every helper.
- `examples/workshop-bot.rkt` — crafter + tasker + trader flows with `craft-loop`.
- `tests/artifacts-test.rkt` — every form and helper is pinned by a RackUnit test; read it to see exact specs and guard behavior.
