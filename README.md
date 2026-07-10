# artifacts-racket

Racket bot framework and `#lang artifacts` DSL for the **official** [Artifacts MMO](https://artifactsmmo.com).

This is **not a clone** or alternate ruleset. Bots talk only to the official Artifacts API. Your bearer token is your real account.

The **3D visual client** is a separate git repo: [`artifacts-mmo-ai-3d-visualizer`](../artifacts-mmo-ai-3d-visualizer). Bots do not depend on it.

## What this repo is

| Piece | Role |
|-------|------|
| **`artifacts/`** | Racket package: REST client, planner, runner, `#lang artifacts` |
| **`examples/`** | Headless bots (`apex-bot.rkt`, `starter-bot.rkt`, `workshop-bot.rkt`) |

## Compliance

- Use **your own** Artifacts token (`ARTIFACTS_API_TOKEN` or `ARTIFACTS_TOKEN`).
- Respect official rate limits and the [Artifacts game ToS](https://artifactsmmo.com).
- Never commit tokens or secrets (this GitHub repo is public).

## Requirements

- Racket 8.x+
- Official Artifacts token for live play

## Bot quickstart

```sh
raco pkg install --auto --link
# or: export PLTCOLLECTS="$PWD:"

export ARTIFACTS_API_TOKEN=your_token_here
racket examples/apex-bot.rkt
```

Dry-run without sending actions:

```sh
ARTIFACTS_DRY_RUN=1 ARTIFACTS_ITERATIONS=3 racket examples/apex-bot.rkt
```

## 3D visual client (separate repo)

```sh
cd ~/artifacts-mmo-ai-3d-visualizer
export PLTCOLLECTS="$HOME/artifacts-racket:${PLTCOLLECTS:-}"
export ARTIFACTS_API_TOKEN=your_token_here
racket bridge.rkt
# other terminal:
godot --path godot
```

## Watch bots in 3D

1. Start the visualizer bridge + Godot with your token.
2. Run any bot from this repo against the official API.
3. Character motion appears in 3D from official character polling — **no bot-side visualization code.**

## Layout

- `artifacts/`: Racket bot library and `#lang artifacts`.
- `examples/`: competitive and starter bots.
- `docs/`: bot framework architecture and API inventory.

## Docs

- [`docs/architecture.md`](docs/architecture.md) — bot stack overview
- [`docs/api-inventory.md`](docs/api-inventory.md) — REST wrapper surface
