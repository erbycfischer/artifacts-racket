# Artifacts API Inventory

This file tracks the Racket wrapper surface for the Artifacts MMO API. The goal is practical parity: every game capability should have a named Racket entry point, clear auth behavior, and tests for request construction before it is wired into bot strategy.

## Implemented Surface

- Core request helpers: `api-get`, `api-post`, `request-url`, `request-headers`, `decode-api-response`, `api-error-from-response`.
- Authentication model (verified against Artifacts OpenAPI `8.0.1`): the API uses a JWT bearer token sent as `Authorization: Bearer <token>` (security scheme `JWTBearer`); a missing or invalid token returns HTTP `452`. `post-token` exchanges credentials for a token via HTTP Basic (`HTTPBasic`), and `post-accounts-create` (`POST /accounts/create`) is a public, token-free registration endpoint. Authenticated wrappers require a bearer token and raise a client-side `452` API error when the token is missing.
- Character creation is fully API-driven: `create-character` (`POST /characters/create`, auth-gated) plus `ensure-bot-characters` in `runner.rkt` provision missing characters headlessly (up to 5 per account). The only manual prerequisite for live play is obtaining an account + bearer token; characters are never created by hand on the website.
- Account and character reads: account details, characters, bank, pending items, purchase history, gems history, active/history tasks, auctions, character events, balance, badges, stats, rate limits, and logs.
- Account character writes: create and delete characters (`POST /characters/create`, `POST /characters/delete`).
- Public encyclopedia reads: maps, map lookup, content-at-coordinate lookup, items, monsters, resources, NPC details/items, tasks, achievements, and effects.
- Grand Exchange reads and account order/history reads, including a single public order by id (`get-grand-exchange-order` / `ge-order`).
- Events, active events, raids, raid details, and leaderboards (character, account, generic column, and rankings).
- Fight simulation wrapper.
- Character actions: movement, transition, rest, equip/unequip, use, fight, gather, craft, recycle, bank, NPC buy/sell, Grand Exchange, tasks, give, claim, delete, and skin change.
- Additional encyclopedia / companion reads (public): account-by-name, account achievements/characters, active characters, badge catalog + badge, skin catalog + skin, season rewards + season reward, task rewards + task reward, gems-shop catalog, and game-assistant ask.
- Account management writes: gems-shop purchases (custom design, skin, spawn event, subscription), account registration / forgot-password / reset-password, and basic-auth token exchange (`post-token`).
- Multiple authentication methods behind a `token-source` abstraction: explicit string, environment (`ARTIFACTS_API_TOKEN`/`ARTIFACTS_TOKEN`), local token file (`~/.artifacts/token` or `ARTIFACTS_TOKEN_FILE`), and the 3D visualizer bridge (HTTP endpoint or a known token file). The high-level `login-via-visualizer` flow installs the live token from the running bridge; `refresh-token` re-resolves a possibly-rotated token from its source without a restart.

## Module Map

- `artifacts/config.rkt`: API base URLs, realtime URLs, and the `token-source` abstraction (explicit/file/env/bridge) plus resolution and token-file helpers.
- `artifacts/auth.rkt`: auth orchestration — `login-via-visualizer`, `refresh-token`, `with-token-source`, `make-bridge-config`.
- `artifacts/http.rkt`: REST wrappers, auth headers (resolving the config's token source), JSON request/response helpers, and API error representation.
- `artifacts/world.rkt`: map indexing and nearest-content lookup over API-shaped map hashes.
- `artifacts/market.rkt`: local Grand Exchange spread helpers.
- `artifacts/combat.rkt`: fight matchup scoring (`simulate-fight-score`, `local-combat-score`, `matchup-score`) combining API simulation, local combat math, and equipment suggestions.
- `artifacts/scheduler.rkt`: cooldown-aware job ordering primitives.
- `artifacts/world-cache.rkt`: encyclopedia and world map disk cache + `load-world-index`.
- `artifacts/runner.rkt`: bot execution loop, character provisioning, and planner dispatch.
- `artifacts/planner.rkt`: role-based planning and cooldown helpers, including `cooldown-from-response` (extracts seconds from a live action response) and `update-character-cooldown` (folds the response's `cooldown` / `cooldown_expiration` into a character's `cooldown_expiration` so `cooldown-remaining` and the scheduler clock see real next-ready time).
- `artifacts/runner.rkt`: after a successful live action, `run-bot-once` folds the response's cooldown back into the returned character snapshot; `run-bot-loop` then gates the next tick via `suggested-loop-sleep` → `cooldown-jobs-from-characters`, which builds `make-job` entries with `ready-at` derived from the updated expiration. Dry-run keeps the synthetic character (no live response), so behavior is unchanged.
- `artifacts/lang/runtime.rkt`: `#lang artifacts` specs, action validation, and executor mappings into the HTTP layer.
- `artifacts/lang/actions.rkt`: readable action builders (`gather`, `buy`, `craft`, Grand Exchange helpers, etc.).
- `artifacts/dispatch.rkt`: shared action dispatch for the runner and DSL executor.

## 3D visual client (separate repo — `artifacts-mmo-ai-3d-visualizer`)

- Bridge (`~/artifacts-mmo-ai-3d-visualizer/bridge.rkt`) polls official REST and publishes `world.snapshot` / `session.status` over local WS.
- Manual play actions from Godot map 1:1 onto the character action wrappers in `artifacts/http.rkt`.
- Other players: public `get-character-leaderboard` + `get-character` (marked `other: true` in snapshots).
- Optional official realtime: `ARTIFACTS_REALTIME=1` on the bridge (REST polling remains the default path).

## Remaining Gaps

- Full official realtime WebSocket ingest in the visual client bridge (REST polling is the production path).
- Game-assistant ask streaming / richer response handling (currently a single POST forward).
- Goal conditions (`when-low-hp`, inventory thresholds) beyond ordered action preference.
