# Architecture

## Product identity

This monorepo ships a **custom 3D client** for the **official Artifacts MMO**, plus a Racket bot framework that talks to the same API.

- Source of truth: official Artifacts servers (`api.artifactsmmo.com`, optional `realtime.artifactsmmo.com`).
- Not a clone, private shard, or alternate economy/ruleset.
- Godot never calls Artifacts REST directly; the local Racket bridge owns auth, errors, and cooldowns.

```text
Official web client ──┐
Any bot (any language)─┼──► Artifacts REST / realtime
Racket 3D bridge ──────┘              │
                                      ▼
Godot 3D client ◄── local WS (127.0.0.1:8787) ── Racket bridge
```

## Principle

Racket is the source of truth for API access and (for bots) planning. Godot is the visual shell and manual-play surface.

Artifacts is API-first and cooldown-bound, so the hard problems are planning and orchestration rather than rendering throughput.

## Racket runtime

- REST client and optional realtime ingest stub.
- Rate-limit and cooldown accounting.
- Public encyclopedia / world map cache.
- World graph indexing over `(layer, x, y)` and `map_id`.
- Session service: auth, poll `get-my-characters`, maps, events, raids, other characters; publish `world.snapshot`.
- Local WebSocket bridge for Godot (`artifacts/visualizer.rkt` + `artifacts/session.rkt`).
- Bot planner/runner and `#lang artifacts` (optional; not required for 3D watch/play).

## Godot runtime

- 3D tile rendering, camera, UI.
- Character markers (own vs other), paths, cooldown rings, event/raid overlays, market highlights.
- Manual play: `player.action` → bridge → official REST.
- Offline fixtures when the bridge is down.

Godot should not decide bot strategy. Optional `bot.decision` / `market.signal` overlays are niceties.

## Zero bot coupling

- Bridge runs without any bot (`examples/artifacts-3d-bridge.rkt`).
- Runner `visualizer-publish!` is optional overlay; `session-owns-snapshots?` prevents bots from owning world snapshots when the session service is active.
- `ARTIFACTS_VISUALIZER=0` bots remain watchable via official character polling.

## Runtime protocol

Local WebSocket, envelope `{ type, timestamp, data }`. See [`visualizer.md`](visualizer.md).

## Workspace note

Develop here (`/home/dirt/artifacts-racket`). Ignore the misspelled stub `artifcacts-mmo-ai-3d-visualizer`.
