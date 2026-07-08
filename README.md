# artifacts-racket

Racket-first bot framework, DSL, and Godot 3D visualizer for Artifacts MMO.

The project is intentionally split into two runtimes:

- Racket owns the bot brain: REST API client, WebSocket/event ingest, cooldown scheduler, optimizer, simulator, market engine, and `#lang artifacts`.
- Godot owns rendering: 3D map, camera/UI, animations, overlays, and live playback.

TypeScript is not part of the initial stack. It can be added later only if we decide to build a browser dashboard.

## Layout

- `artifacts/`: Racket package and core modules.
- `artifacts/lang/`: `#lang artifacts` reader/runtime.
- `examples/`: example bot programs.
- `godot/client/`: Godot visualizer project.
- `docs/`: architecture notes and design docs.

## Requirements

- Racket 8.x for the bot framework.
- Godot 4.x for the visual client.
- An Artifacts MMO token in `ARTIFACTS_TOKEN` for authenticated actions.

## First Commands

Install the Racket package from the project root:

```sh
raco pkg install --auto
```

Run the starter DSL example:

```sh
racket examples/starter-bot.rkt
```

Open the visual client:

```sh
godot --path godot/client
```

## Current Status

This is the first scaffold. The Racket package has API configuration, basic REST helpers, combat formulas, market spread helpers, world indexing, scheduler primitives, and a minimal `#lang artifacts`. The Godot project renders sample tiles and is ready for live state integration.
