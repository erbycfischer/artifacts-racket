# Godot Visualizer

Godot is an optional watcher. Racket bots run headless and do not need Godot open.

## Headless bots

```sh
# Normal bot run (starts optional hub on :8787, continues even if nobody connects)
ARTIFACTS_DRY_RUN=1 ARTIFACTS_ITERATIONS=3 racket examples/apex-bot.rkt

# Explicitly disable the hub
ARTIFACTS_VISUALIZER=0 ARTIFACTS_DRY_RUN=1 racket examples/apex-bot.rkt
```

## Optional Godot watch

1. Start a bot (hub listens on `ws://127.0.0.1:8787`).
2. In another terminal:

```sh
godot --path godot/client
```

Godot loads offline fixtures first, then connects to the hub and follows live `world.snapshot` / `bot.decision` / `market.signal` messages.

Dry-run publishes sample `market.signal` data every tick so overlays work without a live GE scan. Move plans include `routes` in `world.snapshot`.

## Protocol

- `world.snapshot` with `maps` (focus-ranked near characters/routes/events + content tiles), `characters`, `routes`, `events`, `raids`
- `bot.decision` with `character`, `action`, `reason`
- `market.signal` with `code`, `spread`, `score`, and `x`/`y`/`layer` anchored to the nearest `grand_exchange` tile when the world index is available

## Controls

- WASD: pan
- Middle-drag: orbit
- Wheel: zoom
- Left-click tile: select

## Resilience

- Racket hub restarts cleanly if the publisher thread dies; bot loops keep going if the hub cannot bind.
- Godot `StateClient` reconnects with exponential backoff (3s → 30s cap) and resets delay after a successful connect.
- Live GE publishing ranks top spreads by depth-aware score; dry-run emits sample signals every tick.

## Offline vs live

Godot boots from fixtures and shows `Mode: Offline`. When the hub connects it switches to `Connected`, then `Live` after the first protocol message. If the hub drops, mode becomes `Reconnecting` while the last live overlays stay on screen.

## Cooldown rings

Character markers show a blue torus when `cooldown` / `on_cooldown` is set on the snapshot character record. Decision pulses remain magenta and sit above the cooldown ring.
