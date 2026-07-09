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
- Character actions: movement, transition, rest, equip/unequip, use, fight, gather, craft, recycle, bank, Grand Exchange, tasks, give, claim, delete, and skin change.

## Module Map

- `artifacts/config.rkt`: API base URLs, realtime URLs, and token configuration.
- `artifacts/http.rkt`: REST wrappers, auth headers, JSON request/response helpers, and API error representation.
- `artifacts/world.rkt`: map indexing and nearest-content lookup over API-shaped map hashes.
- `artifacts/market.rkt`: local Grand Exchange spread helpers.
- `artifacts/scheduler.rkt`: cooldown-aware job ordering primitives.
- `artifacts/lang/runtime.rkt`: `#lang artifacts` specs, action validation, and first executor mappings into the HTTP layer.

## Remaining Gaps

- Fetch-all pagination helpers that walk every page for encyclopedia and account collections.
- WebSocket client and event stream ingestion.
- Cooldown/rate-limit state that updates from live action responses.
- A scheduler loop that connects character jobs to HTTP actions and next-ready timing.
- Fight matchup scoring that combines API simulation, local combat math, and equipment choices.
- Full `#lang` strategy execution beyond validated action dispatch.
