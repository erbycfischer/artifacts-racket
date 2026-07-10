# Artifacts API Inventory

This file tracks the Racket wrapper surface for the Artifacts MMO API. The goal is practical parity: every game capability should have a named Racket entry point, clear auth behavior, and tests for request construction before it is wired into bot strategy.

## Implemented Surface

- Core request helpers: `api-get`, `api-post`, `request-url`, `request-headers`, `decode-api-response`, `api-error-from-response`.
- Authentication guard: authenticated wrappers require a bearer token and raise a client-side `452` API error when the token is missing.
- Account and character reads: account details, characters, bank, pending items, rate limits, and logs.
- Public encyclopedia reads: maps, map lookup, items, monsters, resources, NPC details/items, tasks, achievements, and effects.
- Grand Exchange reads and account order/history reads.
- Events, active events, raids, raid details, and raid leaderboard.
- Fight simulation wrapper.
- Character actions: movement, transition, rest, equip/unequip, use, fight, gather, craft, recycle, bank, NPC buy/sell, Grand Exchange, tasks, give, claim, delete, and skin change.

## Module Map

- `artifacts/config.rkt`: API base URLs, realtime URLs, and token configuration.
- `artifacts/http.rkt`: REST wrappers, auth headers, JSON request/response helpers, and API error representation.
- `artifacts/world.rkt`: map indexing and nearest-content lookup over API-shaped map hashes.
- `artifacts/market.rkt`: local Grand Exchange spread helpers.
- `artifacts/scheduler.rkt`: cooldown-aware job ordering primitives.
- `artifacts/world-cache.rkt`: encyclopedia and world map disk cache + `load-world-index`.
- `artifacts/runner.rkt`: bot execution loop and planner dispatch.
- `artifacts/planner.rkt`: role-based planning and cooldown helpers.
- `artifacts/lang/runtime.rkt`: `#lang artifacts` specs, action validation, and executor mappings into the HTTP layer.

## 3D visual client (separate — `client/`)

- Bridge (`client/bridge.rkt`) polls official REST and publishes `world.snapshot` / `session.status` over local WS.
- Manual play actions from Godot map 1:1 onto the character action wrappers in `artifacts/http.rkt`.
- Other players: public `get-character-leaderboard` + `get-character` (marked `other: true` in snapshots).
- Optional official realtime: `ARTIFACTS_REALTIME=1` on the bridge (REST polling remains the default path).

## Remaining Gaps

- Full official realtime WebSocket ingest in the visual client bridge (REST polling is the production path).
- Cooldown/rate-limit state that updates from live action responses into a shared scheduler clock.
- Fight matchup scoring that combines API simulation, local combat math, and equipment choices.
- Fuller `#lang` strategy execution beyond validated action dispatch and the competitive planner.
