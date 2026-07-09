# artifacts-racket

Racket-first bot framework, DSL, and Godot 3D visualizer for Artifacts MMO.

The project is intentionally split into two runtimes:

- Racket owns the bot brain: REST API client, WebSocket/event ingest, cooldown scheduler, optimizer, simulator, market engine, and `#lang artifacts`.
- Godot owns rendering: 3D map, camera/UI, animations, overlays, and live playback.

TypeScript is not part of the initial stack. It can be added later only if we decide to build a browser dashboard.

## Layout

- `artifacts/`: Racket package and core modules.
- `artifacts/lang/`: `#lang artifacts` reader/runtime.
- `examples/`: bot programs, including the competitive live bot.
- `godot/client/`: Godot visualizer project.
- `docs/`: architecture notes and design docs.

## Requirements

- Racket 8.x for the bot framework.
- Godot 4.x for the visual client.
- An Artifacts MMO token in `ARTIFACTS_TOKEN` for authenticated actions.

## First Commands

Install the Racket package from the project root:

```sh
raco pkg install --auto --link
```

If package install is awkward in your environment, point Racket at the repo instead:

```sh
export PLTCOLLECTS="$PWD:"
```

Play with the competitive `#lang artifacts` bot:

```sh
export ARTIFACTS_TOKEN=your_token_here
racket examples/apex-bot.rkt
```

Dry-run a few planner ticks without sending actions:

```sh
ARTIFACTS_DRY_RUN=1 ARTIFACTS_ITERATIONS=3 racket examples/apex-bot.rkt
```

Run the starter DSL example:

```sh
racket examples/starter-bot.rkt
```

Bots do not need Godot. The runner can publish optional live state on `ws://127.0.0.1:8787` while continuing headless.

Disable the optional hub:

```sh
ARTIFACTS_VISUALIZER=0 racket examples/apex-bot.rkt
```

Open the visual client (optional watcher):

```sh
godot --path godot/client
```

## Current Status

`#lang artifacts` now has a live runner and planner. `examples/apex-bot.rkt` binds roles to your account characters and keeps them busy with combat, gathering, banking, event intercepts, and market scans.

## Encyclopedia cache

`load-encyclopedia` and `load-world-index` cache under `ARTIFACTS_CACHE_DIR` (default: system temp `artifacts-racket-cache`). TTL defaults: `ARTIFACTS_ENCYCLOPEDIA_CACHE_SECONDS` and `ARTIFACTS_WORLD_CACHE_SECONDS` (both 900). Bots stay headless; this only cuts repeat API fan-out.
