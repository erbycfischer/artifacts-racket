# artifacts-racket

Custom **3D client** and Racket bot framework for the **official** [Artifacts MMO](https://artifactsmmo.com).

This is **not a clone**, private shard, or alternate ruleset. The Godot app is an alternate visual client (2D web grid → local 3D view) of the **same live game**. All state and actions go through the official Artifacts API. Your bearer token is your real account.

## What this repo is

| Piece | Role |
|-------|------|
| **Racket bridge** | Local process that holds the token, calls official REST (+ optional realtime), speaks a simple protocol to Godot |
| **Godot 3D client** | Optional UI: watch the world, play manually, follow characters |
| **`#lang artifacts` bots** | Headless bots via the official API — **no Godot or hub hooks required** |

Work in this repo (`artifacts-racket`). The misspelled stub folder `artifcacts-mmo-ai-3d-visualizer` is **not** the client.

## Compliance

- Use **your own** Artifacts token (`ARTIFACTS_API_TOKEN` or `ARTIFACTS_TOKEN`).
- Respect official rate limits and the [Artifacts game ToS](https://artifactsmmo.com).
- Never commit tokens or secrets (this GitHub repo is public).
- Bridge binds `127.0.0.1` only by default.

## Layout

- `artifacts/`: Racket package (HTTP, session bridge, planner, `#lang artifacts`).
- `examples/`: bots and the standalone 3D bridge (`artifacts-3d-bridge.rkt`).
- `godot/client/`: Godot 4 custom 3D client.
- `docs/`: architecture, protocol, API inventory.

## Requirements

- Racket 8.x+
- Godot 4.x (optional; only for the 3D client)
- Official Artifacts token for live play / authenticated bots

## Player quickstart (bridge + Godot, no bot)

```sh
export ARTIFACTS_API_TOKEN=your_token_here   # or ARTIFACTS_TOKEN
racket examples/artifacts-3d-bridge.rkt
# other terminal:
godot --path godot/client
```

In Godot: Connect → Auth (if token not in env) → select character → click tiles → Move / Fight / Gather / Rest (and bank / GE / tasks when on the right tile).

`examples/visualizer-hub.rkt` is a compatibility alias for the same bridge.

## Bot quickstart (headless; Godot optional)

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

Disable optional bot→hub overlays (bots still appear in 3D via official character state when the bridge is running on the same account):

```sh
ARTIFACTS_VISUALIZER=0 racket examples/apex-bot.rkt
```

## Watch unmodified bots

1. Start the bridge + Godot with your token.
2. Run any bot (Racket or otherwise) against the official API — even with `ARTIFACTS_VISUALIZER=0`.
3. Character motion appears in 3D because the bridge polls official `get-my-characters` / public character data. No bot-side visualization code.

## Modes

| Mode | Run | Result |
|------|-----|--------|
| Play in 3D | Bridge + Godot + token | Same account actions as the web client |
| Watch the world | Bridge + Godot + token | Own chars + other players/bots from official data |
| Watch my bots | Bridge + Godot; bots unchanged | Official character state mirrored in 3D |
| Headless bots only | Bot process only | No Godot |

Default bridge: `ws://127.0.0.1:8787`.

## Docs

- [`docs/visualizer.md`](docs/visualizer.md) — 3D client protocol and controls
- [`docs/architecture.md`](docs/architecture.md) — stack overview
- [`docs/api-inventory.md`](docs/api-inventory.md) — REST wrapper surface
- [`docs/3d-client-verification.md`](docs/3d-client-verification.md) — live/token verification checklist
