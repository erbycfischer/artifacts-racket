# Godot Visualizer

Godot is an optional local UI. Racket owns Artifacts auth, REST actions, and the WebSocket hub.
Bots never require Godot (`ARTIFACTS_VISUALIZER=0` keeps them headless).

## Launch modes

### 1. Hub only (watch account / manual play)

```sh
export ARTIFACTS_API_TOKEN=your_token_here   # or ARTIFACTS_TOKEN; optional Godot auth
racket examples/visualizer-hub.rkt
# other terminal:
godot --path godot/client
```

In Godot: Connect → Auth with token → select character → click tiles → Move/Fight/Gather/Rest.

### 2. Bot only (headless)

```sh
ARTIFACTS_DRY_RUN=1 ARTIFACTS_VISUALIZER=0 racket examples/apex-bot.rkt
```

### 3. Hybrid (hub + bot + Godot)

```sh
# terminal 1
racket examples/visualizer-hub.rkt
# terminal 2
ARTIFACTS_DRY_RUN=1 racket examples/apex-bot.rkt   # attaches to existing hub
# terminal 3
godot --path godot/client
```

Session owns `world.snapshot` positions. Bot publishes `bot.decision`, routes overlay, and `market.signal`.

## Protocol

Envelope: `{ type, timestamp, data }`

### Hub → client

- `world.snapshot` — maps, characters, routes, events, raids
- `bot.decision` — character, action, reason, optional target
- `market.signal` — code, spread, score, optional x/y/layer
- `session.status` — authenticated, characters, selected, pending_items, error
- `action.result` — character, action, ok, error_code, message, cooldown
- `account.logs` — recent log entries

### Client → hub

- `session.auth` — `{ token }` (local only; never logged)
- `session.logout`
- `player.select` — `{ character }`
- `player.action` — `{ character, action, payload }`
- `ui.subscribe` — request current status/snapshot

## Controls

- WASD: pan (disables follow)
- F: follow selected character
- R: rest selected character
- Middle-drag: orbit
- Wheel: zoom
- Left-click tile: select
- UI: Connect/Auth, character picker, Move/Fight/Gather/Rest, bank/GE buttons

## Resilience

- Hub binds `127.0.0.1:8787` only (not all interfaces); bots continue if hub cannot start.
- Godot reconnects with exponential backoff (3s → 30s).
- Fixtures-only mode keeps Godot usable offline.
- Market signals are capped/deduped client-side.

## Cooldown rings

Character markers show a blue torus when `cooldown` / `on_cooldown` is set.
