# Architecture

## Product identity

This repo has two separate pieces:

1. **Racket bot framework** — `#lang artifacts`, planner, runner, official REST client.
2. **3D visual client** (`client/`) — Godot shell + local bridge for manual play and watching.

Both talk to the **official Artifacts MMO** only (`api.artifactsmmo.com`, optional `realtime.artifactsmmo.com`). Not a clone, private shard, or alternate economy.

```text
Official web client ──┐
Any bot (any language)─┼──► Artifacts REST / realtime
Racket bots (#lang) ───┘              │
                                      ▼
3D visual bridge ─────────────────────┘
        │
        ▼
Godot 3D client ◄── local WS (127.0.0.1:8787)
```

## Bot framework (`artifacts/`)

- REST client with bearer auth and structured API errors.
- Rate-limit and cooldown accounting.
- Public encyclopedia / world map cache (`world-cache.rkt`).
- World graph indexing over `(layer, x, y)` and `map_id`.
- Planner, scheduler, runner loop.
- `#lang artifacts` DSL — headless only; **no Godot, no bridge, no WebSocket**.

Bots never import `client/`. Watching bots in 3D is done by the visual client polling official character state.

## 3D visual client (`client/`)

- Racket bridge: auth, poll account/world, dispatch manual `player.action` → official REST.
- Local WebSocket hub for Godot (`client/bridge/visualizer.rkt` + `client/bridge/session.rkt`).
- Godot: 3D tiles, camera, UI, character markers, manual play.
- Optional realtime ingest (`ARTIFACTS_REALTIME=1`).

Godot does not decide bot strategy. The bridge is visual-only.

## Workspace note

Develop here (`/home/dirt/artifacts-racket`). Ignore the misspelled stub `artifcacts-mmo-ai-3d-visualizer`.
