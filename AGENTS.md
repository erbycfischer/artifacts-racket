## Learned User Preferences

- Prefer a Racket-first architecture for this project; add TypeScript only if a browser-native UI or dashboard clearly needs it.
- Keep secrets, tokens, `.cursor/` state, and other local/editor artifacts out of commits because the GitHub repository is public.
- Keep the bot framework (`artifacts/`, `examples/`) separate from the 3D visual client (`client/`). Open Godot at `client/godot` for LSP/project detection.
- Build competitive live-play bots with `#lang artifacts`, not only DSL showcase or example bots.
- Never add `Co-Authored-By` trailers on commits, PRs, or pushes; attribute that work to the user, not the agent.
- Do not develop the real visualizer in the misspelled standalone `artifcacts-mmo-ai-3d-visualizer` folder.
- Bots must not import or depend on the 3D client; watching bots uses official API polling in the visual bridge only.

## Learned Workspace Facts

- The durable work lives in `/home/dirt/artifacts-racket` (public GitHub `erbycfischer/artifacts-mmo-3d-visualizer`); Cursor often opens the sibling stub `/home/dirt/artifcacts-mmo-ai-3d-visualizer`, which is not the live client.
- **Bot framework**: `#lang artifacts`, planner/runner, REST client under `artifacts/`; examples in `examples/`.
- **3D visual client**: `client/bridge.rkt` + `client/godot/` — official Artifacts visual-only client for manual play and watching bots.
- `#lang artifacts` bots run headlessly; dry-run works without credentials; live play reads `ARTIFACTS_API_TOKEN` (preferred) or `ARTIFACTS_TOKEN`.
- Artifacts MMO HTTP auth uses `Authorization: Bearer <token>`; invalid or missing auth can return status 452 (see https://docs.artifactsmmo.com/api_guide/authorization/).
- Watching bots in 3D requires only the visual bridge polling official character state — zero bot-side hooks.
