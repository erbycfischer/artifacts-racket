# Architecture

## Principle

Racket is the source of truth. Godot is the visual shell.

Artifacts is API-first and cooldown-bound, so the hard problems are planning and orchestration rather than rendering throughput. The bot should optimize around time, inventory, travel, rate limits, market liquidity, and character specialization.

## Racket Runtime

The Racket side owns:

- REST API and WebSocket clients.
- Rate-limit and cooldown accounting.
- Public encyclopedia cache for maps, monsters, resources, items, NPCs, tasks, raids, effects, and achievements.
- World graph indexing over `(layer, x, y)` and `map_id`.
- Combat math and fight simulation wrappers.
- Market scoring for Grand Exchange buy/sell orders.
- Job scheduler for up to 5 characters.
- `#lang artifacts` strategy DSL.

## Godot Runtime

The Godot side owns:

- 3D tile rendering.
- Camera and UI interaction.
- Character markers, paths, cooldown rings, event/raid overlays, and market highlights.
- Playback of bot decisions and account logs.

Godot should not decide strategy. It should display strategy decisions from Racket and optionally send user commands back to Racket.

## Runtime Protocol

Use a local WebSocket first. It maps naturally to both Racket and Godot and matches the real-time nature of the game.

Example messages:

```json
{"type":"world.snapshot","data":{"maps":[],"characters":[],"routes":[]},"timestamp":"2026-07-08T00:00:00Z"}
{"type":"bot.decision","data":{"character":"alice","action":"fight","reason":"best_safe_xp"},"timestamp":"2026-07-08T00:00:05Z"}
{"type":"market.signal","data":{"code":"iron_ore","spread":7,"score":0.82},"timestamp":"2026-07-08T00:00:10Z"}
```

## Initial Milestones

1. Fetch and cache all public game data.
2. Render the full map in Godot from Racket-provided state.
3. Add authenticated character polling and cooldown display.
4. Implement the scheduler loop for simple fight/gather/bank jobs.
5. Add combat matchup scoring and equipment recommendations.
6. Add Grand Exchange scanner and market signals.
7. Add WebSocket ingestion for events, raids, account logs, and market order streams.
