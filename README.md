# artifacts-racket

Racket bot framework and `#lang artifacts` DSL for the **official** [Artifacts MMO](https://artifactsmmo.com).

This is **not a clone** or alternate ruleset. Bots talk only to the official Artifacts API. Your bearer token is your real account.

The **3D visual client** lives separately under [`client/`](client/) — a Godot app for manual play and watching bots via official game state. Bots do not depend on it.

## What this repo is

| Piece | Role |
|-------|------|
| **`artifacts/`** | Racket package: REST client, planner, runner, `#lang artifacts` |
| **`examples/`** | Headless bots (`apex-bot.rkt`, `starter-bot.rkt`) |
| **`client/`** | Official Artifacts **visual-only** 3D client (bridge + Godot) |

Work in this repo (`artifacts-racket`). The misspelled stub `artifcacts-mmo-ai-3d-visualizer` is not the client.

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

## 3D visual client (optional)

Manual play and watch bots in 3D — separate from the bot framework:

```sh
export ARTIFACTS_API_TOKEN=your_token_here
racket client/bridge.rkt
# other terminal:
godot --path client/godot
```

See [`client/README.md`](client/README.md) for controls and protocol.

## Watch bots in 3D

1. Start the visual client bridge + Godot with your token.
2. Run any bot (Racket or otherwise) against the official API.
3. Character motion appears in 3D because the bridge polls official character state. **No bot-side visualization code.**

## Layout

- `artifacts/`: Racket bot library and `#lang artifacts`.
- `examples/`: competitive and starter bots.
- `client/`: 3D visual client (Racket bridge + Godot).
- `docs/`: bot framework architecture and API inventory.

## Docs

- [`docs/architecture.md`](docs/architecture.md) — bot stack overview
- [`docs/api-inventory.md`](docs/api-inventory.md) — REST wrapper surface
- [`client/README.md`](client/README.md) — 3D visual client
