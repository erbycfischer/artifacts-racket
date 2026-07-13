# Quickstart: writing an Artifacts MMO bot in Racket

`#lang artifacts` is a small Racket dialect for scripting the [Artifacts MMO](https://artifactsmmo.com). You describe *what your characters should be doing* — mine, fight, craft, trade — and the planner figures out *where to go and when*, reacting to the live game state every tick. This guide gets you from zero to a compiling bot.

Everything below maps to real forms in `artifacts/lang/runtime.rkt`, `artifacts/lang/actions.rkt`, and `artifacts/lang/helpers.rkt`. If a symbol isn't in here, it probably doesn't exist yet — check those files first.

## 1. Set your token

The **only** manual, out-of-band step to run a live bot is getting an account and a bearer token. Everything else — including **creating your characters** — the framework does for you over the API (`create-character` → `POST /characters/create`, driven by `ensure-bot-characters`; see §6 `#:ensure-characters?`). You do not create characters on the website by hand.

Getting a token is a one-time thing:

- **Have an account already?** Grab your JWT bearer token from the [Artifacts website](https://artifactsmmo.com) (Account → token).
- **No account yet?** The framework can register one over the API too: `post-accounts-create` (`POST /accounts/create`, public) takes `username`/`password`/`email`, and `post-token` (`POST /token`, HTTP Basic) exchanges those credentials for a bearer token.

The API authenticates every request with `Authorization: Bearer <token>`; a missing or invalid token returns HTTP `452` (verified against Artifacts OpenAPI `8.0.1`, security scheme `JWTBearer`). Once you have a token, the framework reads it from the environment:

```bash
export ARTIFACTS_API_TOKEN="your-token-here"   # preferred
# or, for local use:
export ARTIFACTS_TOKEN="your-token-here"        # fallback if API_TOKEN is unset
```

`ARTIFACTS_API_TOKEN` wins when both are set (see `artifacts/config.rkt`). With no token, helpers still *compile* and `play` still runs a **dry run** — but live HTTP actions return a structured `452` auth error.

## 1a. Authentication methods (you have options)

The framework resolves your bearer token through a `token-source` abstraction (`artifacts/config.rkt`), so you can authenticate however you like — every method ends up sending the same `Authorization: Bearer <token>` header.

| Method | Setup |
|--------|-------|
| **Environment** (default) | `export ARTIFACTS_API_TOKEN="..."` (or `ARTIFACTS_TOKEN`). This is what `make-config` reads by default. |
| **Token file** | Drop your raw token (no quotes) in `~/.artifacts/token`, or set `ARTIFACTS_TOKEN_FILE=/path/to/token`. No exports needed. Prefer `racket tools/gen-token.rkt login ...` to populate it for you (see below). |
| **3D Visualizer login** | Run the visualizer (`artifacts-mmo-ai-3d-visualizer`), log in there, then call `(login-via-visualizer)` — it picks up your live token from the bridge. If the bridge is down, it tells you to start the visualizer. |
| **Explicit string** | `(make-config #:token "TOKEN")` or `(with-token-source "TOKEN")` for a script. |

A `bridge` config cascades through sources so it keeps working as one becomes unavailable:

```racket
(require artifacts/auth)

;; "Simply login with the 3D Visualizer":
(login-via-visualizer)

;; Or build a config that falls back bridge -> file -> env automatically:
(current-config (make-bridge-config))
```

All token sources are pure and optional. If none yields a token, requests raise the same structured `452` as before — nothing silently succeeds. For a long-running bot that hits a `452` or an expiry signal, `refresh-token` re-resolves the token from its source (never looping) so the bot can recover without a restart:

```racket
(refresh-token)  ; re-resolves current-config's source; updates it if fresh
```

### Generate your token locally (no env exports)

If you don't want to paste a token into `export` every session, use the bundled generator. It exchanges your username/password for a JWT and writes it to `~/.artifacts/token`, which the **token file** source reads automatically — no shell env vars required.

```bash
# Log in with your existing account; writes ~/.artifacts/token
racket tools/gen-token.rkt login <username> <password>

# Or create a fresh account, then log in automatically
racket tools/gen-token.rkt register <username> <email> <password>

# Confirm the saved token still works (calls a lightweight auth'd GET)
racket tools/gen-token.rkt whoami        # alias: verify
```

Flags (any subcommand):

- `--token-file <path>` — write/read the token to a file other than `~/.artifacts/token` (or set `ARTIFACTS_TOKEN_FILE`).
- `--base-url <url>` — target the sandbox or beta server, e.g. `https://api.sandbox.artifactsmmo.com`.

The generator stores a single trimmed JWT line (no trailing newline) and never prints the token itself — only its presence. Under the hood it calls `post-token` (HTTP Basic) / `post-accounts-create`, then `save-token!` from `artifacts/auth.rkt`; the `whoami`/`verify` check reads the file back through the same `make-file-source` path your bot uses at runtime, so a token that verifies here will work in `(play ...)`. If the token is invalid or expired, the check prints a clear "re-run login" message (HTTP `452`) instead of failing obscurely.

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
| `auto-level` | Grind toward `target` level using the character's role skill (gather for miners/woodcutters/fishers, fight for combat), banking when full — and stops once the target is reached. `(auto-level 'combat #:target 10 #:max-hp-ratio 0.5)` |
| `trader-loop` | Watch the GE, list a sell order, and bank when full — a complete trade loop in one call. Add `#:fill-order-id` to also fill a specific buy order. `(trader-loop #:code 'copper_ore #:qty 5 #:price 10)` |
| `banker` | Deposit everything when the bag is full, and buy a bank slot when the bank itself nears capacity. Pair with any gather/loop goal. `(banker #:bank-threshold 5)` |

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
- `#:ensure-characters?` — `#t` creates any missing characters over the API (`POST /characters/create`) from their `#:as` names (or tags), up to the 5-per-account limit. No website clicking required — just a valid token.
- `#:skin` / `#:skins` — character appearance when creating accounts.

Many example bots read `ARTIFACTS_DRY_RUN`, `ARTIFACTS_ITERATIONS`, and `ARTIFACTS_AS_<TAG>` from the environment, so you can run them with a one-liner:

```bash
ARTIFACTS_DRY_RUN=1 racket examples/workshop-bot.rkt
```

## 6b. Just run it (auto-login)

A bot file needs no `current-config` line. When you call `play` with live play
(normal `racket examples/<bot>.rkt`), the framework auto-logs-in: if the
resolved config has no token, it tries the visualizer bridge once (bounded — it
never hangs or loops), installs any token it finds into `current-config`, and
runs. A minimal bot is literally:

```racket
#lang artifacts
(bot my-bot (character bob #:role 'combat (auto-level 'combat #:target 10)))
(play my-bot)
```

The token-resolving **cascade order** (handled inside `make-bridge-config` /
`play`'s auto-login) is:

1. **Visualizer bridge** — `http://127.0.0.1:7878/token`, then the
   `~/.artifacts/visualizer-token` file (the 3D client writes your live login
   here; the bot never imports the visualizer).
2. **`~/.artifacts/token`** — the local dotfile (`tools/gen-token.rkt login`
   writes it; honors `ARTIFACTS_TOKEN_FILE`).
3. **`ARTIFACTS_API_TOKEN` / `ARTIFACTS_TOKEN`** — environment.

In dry-run (`#:dry-run? #t`, or `ARTIFACTS_DRY_RUN=1`) the auto-login step is
skipped entirely and the bot ticks with synthetic characters — no network.

If auto-login finds no token, it prints one line
(`No token: start the visualizer and log in, run tools/gen-token.rkt login, or
set ARTIFACTS_API_TOKEN`) and proceeds; a live bot then surfaces a clear `452`
at request time. You can also opt in declaratively with `(auto-login)` at
module top level.

## 6c. Watch in the 3D Visualizer

Run your bot with `play-with-visualizer` (same pass-through options as `play`:
`#:iterations`, `#:sleep-seconds`, `#:dry-run?`, `#:ensure-characters?`,
`#:skin`, `#:skins`). It blocks briefly until you log into the visualizer,
installs the token, starts the loop, and prints the watch instruction:

```racket
(play-with-visualizer my-bot #:ensure-characters? #t)
;; → "Watching in 3D: open the artifacts-mmo-ai-3d-visualizer and log in
;;    with the same account — it polls your character live. Press Ctrl-C to stop."
```

Then open the separate **artifacts-mmo-ai-3d-visualizer** repo and log in with
the same account. It polls the official Artifacts API for your character state,
so watching requires zero bot-side hooks — just run the bot and open the
visualizer. See `docs/visualizer-login.md` for the bridge contract.

## 6a. One-command launch with the Cursor skill

If you use Cursor, the `play-artifacts-bot` skill launches any bot by name with
a single slash command. It dry-runs first (no token needed) to prove the bot
compiles and ticks, then offers live play only when you ask:

```
/play-artifacts-bot starter-bot
/play-artifacts-bot play-artifacts-bot-demo
```

`<name>` is either an example-file basename (`examples/<name>.rkt`) or a bot
symbol already defined in the repo. The skill resolves the token from the
environment, `~/.artifacts/token`, or the 3D Visualizer bridge, and prints a
clear next step if none are present.

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

## 8. Write your first bot in 10 lines

The three newest helpers collapse a whole role into a single line, so a real bot is tiny. Drop this in `my-first-bot.rkt`:

```racket
#lang artifacts

(bot my-first-bot
  ;; Mine copper until the bag is full, bank it, and grow the bank as I go.
  (character miner #:role 'mining
    (mine-until-full #:resource 'copper_rocks)
    (banker #:bank-threshold 5))
  ;; Grind to level 10, resting and banking automatically along the way.
  (character fighter #:role 'combat
    (auto-level 'combat #:target 10 #:max-hp-ratio 0.5))
  ;; Run a single trade loop: scan, list copper, bank when full.
  (character trader #:role 'trader
    (trader-loop #:code 'copper_ore #:qty 5 #:price 10)))

;; Dry-run by default; flip #:dry-run? to #f (with a token) for live play.
(play my-first-bot #:dry-run? #t #:iterations 2)
```

That is a three-character roster built entirely from the high-level helpers — no manual `guard`, `when-*`, or action wiring. It compiles and dry-runs with no token:

```bash
racket my-first-bot.rkt
```

The ready-to-run versions live in `examples/`:

- `examples/miner-bot.rkt` — `mine-until-full` + `banker`
- `examples/fighter-bot.rkt` — `auto-level 'combat #:target 10`
- `examples/trader-bot.rkt` — `trader-loop` (runs a dry-run play loop)

## Where to go next

- `examples/apex-bot.rkt` — a competitive multi-character roster using every helper.
- `examples/workshop-bot.rkt` — crafter + tasker + trader flows with `craft-loop`.
- `tests/artifacts-test.rkt` — every form and helper is pinned by a RackUnit test; read it to see exact specs and guard behavior.
