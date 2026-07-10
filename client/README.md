# Official Artifacts MMO — 3D Visual Client

A **visual-only** alternate client for the official [Artifacts MMO](https://artifactsmmo.com). Same live game, same API, same account — rendered in local 3D instead of the web grid.

This is **not** part of the bot framework. Bots run headlessly via `#lang artifacts`; this client is for:

- **Manual play** in 3D (move, fight, gather, rest, bank, GE, tasks, …)
- **Watching** your characters and other players/bots via official API polling

## Quickstart

```sh
export ARTIFACTS_API_TOKEN=your_token_here   # or ARTIFACTS_TOKEN
racket client/bridge.rkt
# other terminal:
godot --path client/godot
```

In Godot: Connect → Auth (if token not in env) → select character → click tiles → Move / Fight / Gather / Rest.

Default bridge: `ws://127.0.0.1:8787` (override with `ARTIFACTS_BRIDGE_PORT`).

## How watching works

The Racket bridge polls official REST (`get-my-characters`, maps, events, raids, other players). Godot never calls Artifacts directly. Any bot playing on your account appears in 3D automatically — no hooks in the bot code.

Optional: `ARTIFACTS_REALTIME=1` on the bridge for faster world population via official WebSocket `online_characters`.

## Layout

- `bridge.rkt` — entrypoint
- `bridge/` — session service, WebSocket hub, optional realtime ingest
- `godot/` — Godot 4 project (`project.godot` is the project root)
- `tests/` — bridge protocol tests

## Docs

- [`../docs/visualizer.md`](../docs/visualizer.md) — protocol and controls
- [`../docs/3d-client-verification.md`](../docs/3d-client-verification.md) — live verification checklist
