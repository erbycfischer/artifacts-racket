## Learned User Preferences

- Prefer a Racket-first architecture for this project; add TypeScript only if a browser-native UI or dashboard clearly needs it.
- Keep secrets, tokens, `.cursor/` state, and other local/editor artifacts out of commits because the GitHub repository is public.
- Keep the agent/build workspace at the repository root, while focusing Godot visualizer editing on `godot/client` so Godot project detection and LSP work cleanly.
- Build competitive live-play bots with `#lang artifacts`, not only DSL showcase or example bots.
- Never add `Co-Authored-By` trailers on commits, PRs, or pushes.
- Treat `artifacts-racket` as the monorepo for Racket `#lang` and Godot work; do not develop the real visualizer in the misspelled standalone `artifcacts-mmo-ai-3d-visualizer` folder.
- Bots must not need Godot or visualizer-specific code to run or be watchable; the 3D client is an optional observer/manual-play surface.

## Learned Workspace Facts

- The durable project lives in `/home/dirt/artifacts-racket` (public GitHub `erbycfischer/artifacts-mmo-3d-visualizer`); Cursor often opens the sibling stub `/home/dirt/artifcacts-mmo-ai-3d-visualizer`, which is not the monorepo.
- The project is a Racket-first Artifacts MMO bot framework with `#lang artifacts`, bot scheduling/optimization, and a Godot 4/GDScript 3D visualizer.
- The Godot visualizer project lives under `godot/client`, with `project.godot` as that subdirectory's project root; open it with `godot --path godot/client` from `artifacts-racket`.
- `#lang artifacts` bots run through a planner/runner loop; dry-run works without credentials, and live play reads `ARTIFACTS_API_TOKEN` (preferred; GitHub Actions secret name) or falls back to `ARTIFACTS_TOKEN`.
- Artifacts MMO HTTP auth uses `Authorization: Bearer <token>`; invalid or missing auth can return status 452 (see https://docs.artifactsmmo.com/api_guide/authorization/).
- The visualizer hub/protocol is separate from bot runtime so any player or bot can be watched or controlled in 3D without embedding visualization logic in bots.
