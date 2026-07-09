# Official Artifacts custom 3D client

This is a **custom client** for the **official Artifacts MMO**, not a clone or private server.

- Same live game as [artifactsmmo.com](https://artifactsmmo.com) / the official 2D web client.
- Godot renders official state in 3D; the Racket **bridge** holds the token and calls official REST (and optional realtime).
- Bots never require Godot. Unmodified bots are watchable because they move official characters.

Work in `artifacts-racket`. The misspelled stub `artifcacts-mmo-ai-3d-visualizer` is not the client.

Respect rate limits and the game ToS. Use your own token; never commit it.

## Launch modes

### 1. Bridge only (watch account / manual play)

```sh
export ARTIFACTS_API_TOKEN=your_token_here   # or ARTIFACTS_TOKEN; optional Godot auth
racket examples/artifacts-3d-bridge.rkt
# other terminal:
godot --path godot/client
```

(`examples/visualizer-hub.rkt` is an alias for the same entrypoint.)

In Godot: Connect → Auth with token → select character → click tiles → Move/Fight/Gather/Rest; bank/GE/NPC/tasks when on matching tiles.

### 2. Bot only (headless)

```sh
ARTIFACTS_DRY_RUN=1 ARTIFACTS_VISUALIZER=0 racket examples/apex-bot.rkt
```

### 3. Hybrid (bridge + bot + Godot)

```sh
# terminal 1
racket examples/artifacts-3d-bridge.rkt
# terminal 2 — overlays optional; ARTIFACTS_VISUALIZER=0 still watchable via official state
ARTIFACTS_DRY_RUN=1 racket examples/apex-bot.rkt
# terminal 3
godot --path godot/client
```

**Session owns `world.snapshot`.** Bot `visualizer-publish!` for decisions/routes is an **optional overlay**, not how you see bots.

## Zero bot hooks

- Official state polling is enough to watch bots and other players.
- Acceptance: unmodified bot with `ARTIFACTS_VISUALIZER=0` + bridge on the same account → character motion in 3D.
- Acceptance: web-client / other-account presence appears via public character/leaderboard data without that user running our stack.
- Core watch/play does not require `#lang artifacts`, the runner, or `visualizer-publish!`.

## Protocol

Envelope: `{ type, timestamp, data }`

Local UI protocol only. Every play action maps 1:1 to an official REST action wrapped in `artifacts/http.rkt`.

### Bridge → client

- `world.snapshot` — maps, characters (own + `other: true` world players), routes, events, raids
- `session.status` — authenticated, characters, selected, pending_items, error
- `action.result` — character, action, ok, error_code, message, cooldown
- `account.logs` — recent log entries
- `bot.decision` / `market.signal` — **optional overlays** only

### Client → bridge

- `session.auth` — `{ token }` (local only; never logged)
- `session.logout`
- `player.select` — `{ character }`
- `player.action` — `{ character, action, payload }`
- `ui.subscribe` — request current status/snapshot

### Supported `player.action` names (official REST)

Core: `move`, `transition`, `rest`, `fight`, `gather`  
Items: `craft`, `recycle`, `equip`, `unequip`, `use`  
Bank: `bank-deposit-item`, `bank-withdraw-item`, `bank-deposit-gold`, `bank-withdraw-gold`, `bank-buy-expansion`  
NPC: `npc-buy`, `npc-sell`  
GE: `grand-exchange-buy`, `grand-exchange-create-sell-order`, `grand-exchange-create-buy-order`, `grand-exchange-cancel`, `grand-exchange-fill`, `grand-exchange-orders`  
Tasks: `task-new`, `task-complete`, `task-cancel`, `task-exchange`, `task-trade`

## Controls

Move sends `map_id` when the selected tile has one (preferred by the official move API), plus `x`/`y`/`layer`.


- WASD: pan (disables follow)
- F: follow selected character
- R: rest selected character
- Middle-drag: orbit
- Wheel: zoom
- Left-click tile: select
- UI: Connect/Auth, character picker, tile actions, bank/GE/NPC/tasks

## Modes (Godot status)

- **Offline** — fixtures only / disconnected
- **Connected / Live** — hub streaming; may be unauthenticated
- **Authenticated / Playing** — token accepted; manual actions enabled

URL is persisted in `user://settings.cfg`. Token is **not** persisted.

## Resilience

- Bridge binds `127.0.0.1:8787` only; bots continue if hub cannot start.
- Godot reconnects with exponential backoff (3s → 30s).
- Fixtures-only mode keeps Godot usable offline.
- Optional realtime: set `ARTIFACTS_REALTIME=1` to subscribe to official `online_characters` / events (REST poll remains the default for own characters; leaderboard lookup is the REST fallback for others).
- Market signals are capped/deduped client-side.

## World population

Own characters: `GET /my/characters`. Other players/bots: realtime `online_characters` when enabled, else public leaderboard + `GET /characters/{name}` (TTL `ARTIFACTS_OTHERS_POLL_SECONDS`, default 15). Marked `other: true` in snapshots. Events/raids from official endpoints.

## Cooldown rings

Character markers show a blue torus when `cooldown` / `on_cooldown` is set. Other players use an amber tint and `[world]` label prefix.

## Verification checklist

1. **Play without a bot:** `ARTIFACTS_API_TOKEN=… racket examples/artifacts-3d-bridge.rkt` + `godot --path godot/client` → Auth → Move / Fight / Gather / Rest; state matches the official web client.
2. **Watch unmodified bots:** Start the bridge, then run `ARTIFACTS_VISUALIZER=0 racket examples/apex-bot.rkt` (or any non-Racket bot). Character motion appears from official polling—no hub publish required.
3. **Other players:** Amber `[world]` markers appear from public leaderboard/character lookups (same server as the web client).
4. **Safety:** Bridge binds localhost only; token never logged or committed; poll interval defaults to 3s (`ARTIFACTS_SESSION_POLL_SECONDS`).
5. **Headless bots:** Still work with zero Godot.
