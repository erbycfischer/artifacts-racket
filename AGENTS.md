## Learned User Preferences

- Prefer a Racket-first architecture for this project; add TypeScript only if a browser-native UI or dashboard clearly needs it.
- Keep secrets, tokens, `.cursor/` state, and other local/editor artifacts out of commits because the GitHub repository is public.
- Keep the agent/build workspace at the repository root, while focusing Godot visualizer editing on `godot/client` so Godot project detection and LSP work cleanly.
- Build competitive live-play bots with `#lang artifacts`, not only DSL showcase or example bots.

## Learned Workspace Facts

- This workspace is the public GitHub repository `erbycfischer/artifacts-mmo-3d-visualizer`.
- The project is a Racket-first Artifacts MMO bot framework with `#lang artifacts`, bot scheduling/optimization, and a Godot 4/GDScript 3D visualizer.
- The Godot visualizer project lives under `godot/client`, with `project.godot` as that subdirectory's project root.
- `#lang artifacts` bots run through a planner/runner loop; dry-run works without credentials, and live play uses an API token via the environment.
