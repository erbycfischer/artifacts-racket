# Architecture

Racket-first bot framework for the official Artifacts MMO.

## Two runtimes (two repos)

1. **Bot framework** (this repo) — REST client, planner, runner, `#lang artifacts`.
2. **3D visual client** (`~/artifacts-mmo-ai-3d-visualizer`) — Godot shell + local bridge for manual play and watching.

```text
#lang artifacts bots ──► Official Artifacts REST API
                              ▲
3D visual bridge ─────────────┘
```

Bots never import the visualizer. Watching bots in 3D is done by the visual client polling official character state.

## Bot stack (`artifacts/`)

- HTTP wrappers and auth (`http.rkt`, `config.rkt`)
- Auth orchestration: `login-via-visualizer`, `refresh-token`, bridge/file/env token sources (`auth.rkt`)
- World index + encyclopedia cache (`world.rkt`, `world-cache.rkt`)
- Planner / runner / scheduler
- `#lang artifacts` reader + runtime

## Sibling visualizer

Develop bots here. Open Godot at `~/artifacts-mmo-ai-3d-visualizer/godot`.
