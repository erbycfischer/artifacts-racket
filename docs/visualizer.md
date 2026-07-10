# Official Artifacts custom 3D visual client

This is a **visual-only custom client** for the **official Artifacts MMO**, not a clone or private server.

- Same live game as [artifactsmmo.com](https://artifactsmmo.com) / the official 2D web client.
- Godot renders official state in 3D; the Racket **bridge** (`client/bridge.rkt`) holds the token and calls official REST (and optional realtime).
- **Bots never use this client.** Run bots headlessly; watch them here via official character polling.

Work in `artifacts-racket/client/`. The misspelled stub `artifcacts-mmo-ai-3d-visualizer` is not the client.

Respect rate limits and the game ToS. Use your own token; never commit it.

## Launch

```sh
export ARTIFACTS_API_TOKEN=your_token_here   # or ARTIFACTS_TOKEN; optional Godot auth
racket client/bridge.rkt
# other terminal:
godot --path client/godot
```

In Godot: Connect → Auth with token → select character → click tiles → Move/Fight/Gather/Rest; bank/GE/NPC/tasks when on matching tiles.

## Watch bots (no bot hooks)

1. Start the bridge + Godot with your token.
2. Run any bot against the official API (Racket or otherwise).
3. Character motion appears from official `get-my-characters` polling — **no visualization code in the bot.**

## Protocol

Local WebSocket `ws://127.0.0.1:8787` (or `ARTIFACTS_BRIDGE_PORT`), envelope `{ type, timestamp, data }`.

### Server → Godot

- `world.snapshot` — maps, characters (own + `other: true`), events, raids
- `session.status` — authenticated, characters, selected, pending_items, error
- `action.result` — manual play feedback
- `account.logs` — recent log lines
- `bot.decision` / `market.signal` — fixture/offline samples only (not published by bots)

### Godot → bridge

- `session.auth` — `{ token }` (local only; never logged)
- `session.logout`
- `player.select` — `{ character }`
- `player.action` — `{ character, action, payload }` → official REST
- `ui.subscribe`

## World population

Own characters come from `GET /my/characters`. Other players/bots:

1. Official realtime `online_characters` when `ARTIFACTS_REALTIME=1` (preferred live positions).
2. Public character leaderboard + `GET /characters/{name}` (rate-limited by `ARTIFACTS_OTHERS_POLL_SECONDS`, default 15).

Others are marked `other: true` in snapshots. REST polling is the default path; realtime is opt-in.

## Controls

See Godot UI panels. Keyboard shortcuts in `client/godot/scripts/Main.gd` (R = rest, F = follow selected character; WASD/arrows pan and clear follow).

## Verification

See [`3d-client-verification.md`](3d-client-verification.md).
