## Learned User Preferences

- Prefer a Racket-first architecture for this project; add TypeScript only if a browser-native UI or dashboard clearly needs it.
- Keep secrets, tokens, `.cursor/` state, and other local/editor artifacts out of commits because the GitHub repository is public.
- Never commit absolute machine paths (`/home/…`, `C:\…`, WSL `\\wsl.localhost\…`, etc.) in tracked files, commit messages, or docs — use repo-relative paths only.
- The public repo is the `#lang artifacts` framework and generic examples for others to build Artifacts bots. The user's competitive Harmony roster (`examples/harmony-bot.rkt`, `harmony-bot-progress.md`, and Harmony-specific live status) is private — never stage, commit, or push it.
- Keep the bot framework (`artifacts/`, public `examples/`) in this repo; the 3D visual client is the sibling repo `artifacts-mmo-ai-3d-visualizer`.
- The public `#lang artifacts` surface is a language plus reusable helpers/primitives. Do not push Harmony-specific competitive strategy into shared planner/helpers for “everyone”; compose that privately in `examples/harmony-bot.rkt`. Framework stays general (helpers that go dormant when they cannot act; blank-bot rest only when preferred is empty); bot bodies own restock/heal/rest/gear priority and economy policy (withdraw or buy/cook food and pots before resting; fighters deposit surplus gold—trader/crafters need bank gold, fighters do not).
- Build and iterate competitive live-play bots with `#lang artifacts` locally (Harmony is the private flagship); public examples stay showcase/starter-oriented, not a dump of the user's best roster.
- Never add `Co-Authored-By` trailers on commits, PRs, or pushes; attribute that work to the user, not the agent.
- Bots must not import or depend on the 3D client; watching bots uses official API polling in the visual bridge only.
- Never use Cursor Shell (parent agent or subagents) until the user explicitly says shells work again. If a command is needed, print it for the user to run and wait for their result. (As of 2026-08-30 Shell still fails to spawn / hangs — print commands only.)
- Harmony trader must not GE-snipe kit or tools the smith can forge now or soon (copper through steel); snipes are uniques and cheap commodities relisted strictly above cost or fair — never dumped at the fill ask.
- Never auto-sell upgrade or next-tier gear; sell leftover dominated starter kit at fair once a better piece is worn or in the vault. Death does not strip gear, so do not bank an insurance starter set.

## Learned Workspace Facts

- This repo is the `artifacts-racket` package (bot framework + `#lang artifacts`). Local checkout path is machine-specific — do not put it in commits.
- The 3D visual client is a **separate git repo** named `artifacts-mmo-ai-3d-visualizer` (bridge + Godot), sibling to this package on disk.
- `#lang artifacts` bots run headlessly; dry-run works without credentials; live play reads `ARTIFACTS_API_TOKEN` (preferred) or `ARTIFACTS_TOKEN` as `Authorization: Bearer <token>` (invalid or missing auth can return status 452; see https://docs.artifactsmmo.com/api_guide/authorization/).
- Watching bots in 3D uses only the visualizer bridge polling official character state (zero bot-side hooks); the bridge needs this package on `PLTCOLLECTS` (or `raco pkg install --link`).
- Artifacts MMO `data` bucket limits are 200 GET/min and 2000/hour (`GET /my/characters`, `GET /my/bank/items`, `GET /maps`); long live ticks 429 from load, not an outage. The runner snapshots the bank once per tick, enriches maps from the world index, and backs off ~20s on 429.
- Git `origin` for this repo MUST be `https://github.com/erbycfischer/artifacts-racket.git` — never the sibling `artifacts-mmo-ai-3d-visualizer` repo (it was once pointed at the visualizer by mistake, which would smear the framework's history into the client repo).
- `raco test tests/artifacts-test.rkt` is the authoritative green check. Running `racket tests/artifacts-test.rkt` hides failures because the suite lives in `(module+ test …)`, which only executes under `raco test`.
- `#lang artifacts` example bots only compile via `raco make` after the package is linked as the `artifacts` collection (`raco pkg install --link` or a symlink into the Racket collects dir). The sandbox's missing `syntax/module-reader` otherwise blocks `raco make` of `examples/`.
- `compiled/` bytecode (`*.zo`, `*.dep`), `.env`/`.env.local`, `examples/harmony-bot.rkt`, and `harmony-bot-progress.md` are gitignored and must not be staged or committed.
- The coordinator agent commits and pushes batched framework changes only when asked; individual `#lang artifacts` build subagents intentionally do NOT commit or push. Never include Harmony in those commits.
- Cursor Shell currently hangs forever with zero output (parent and Task subagents). Live bot runs, `raco`, and dry-runs must be executed in the user's own terminal.
- Artifacts MMO death returns the character to spawn `(0,0)` at 1 HP; equipped items and inventory stay (https://docs.artifactsmmo.com/concepts/stats_and_fights/).
