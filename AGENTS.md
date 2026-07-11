## Learned User Preferences

- Prefer a Racket-first architecture for this project; add TypeScript only if a browser-native UI or dashboard clearly needs it.
- Keep secrets, tokens, `.cursor/` state, and other local/editor artifacts out of commits because the GitHub repository is public.
- Keep the bot framework (`artifacts/`, `examples/`) in this repo; the 3D visual client is the sibling repo `artifacts-mmo-ai-3d-visualizer`.
- Build competitive live-play bots with `#lang artifacts`, not only DSL showcase or example bots.
- Never add `Co-Authored-By` trailers on commits, PRs, or pushes; attribute that work to the user, not the agent.
- Bots must not import or depend on the 3D client; watching bots uses official API polling in the visual bridge only.

## Learned Workspace Facts

- This repo is `/home/dirt/artifacts-racket` (bot framework + `#lang artifacts`).
- The 3D visual client is a **separate git repo** at `/home/dirt/artifacts-mmo-ai-3d-visualizer` (bridge + Godot).
- `#lang artifacts` bots run headlessly; dry-run works without credentials; live play reads `ARTIFACTS_API_TOKEN` (preferred) or `ARTIFACTS_TOKEN`.
- Artifacts MMO HTTP auth uses `Authorization: Bearer <token>`; invalid or missing auth can return status 452 (see https://docs.artifactsmmo.com/api_guide/authorization/).
- Watching bots in 3D requires only the visual bridge polling official character state — zero bot-side hooks.
- The visualizer bridge requires this package on `PLTCOLLECTS` (or `raco pkg install --link`).
- Git `origin` for this repo MUST be `https://github.com/erbycfischer/artifacts-racket.git` — never the sibling `artifacts-mmo-ai-3d-visualizer` repo (it was once pointed at the visualizer by mistake, which would smear the framework's history into the client repo).
- `raco test tests/artifacts-test.rkt` is the authoritative green check. Running `racket tests/artifacts-test.rkt` hides failures because the suite lives in `(module+ test …)`, which only executes under `raco test`.
- `#lang artifacts` example bots only compile via `raco make` after the package is linked as the `artifacts` collection (`raco pkg install --link` or a symlink into the Racket collects dir). The sandbox's missing `syntax/module-reader` otherwise blocks `raco make` of `examples/`.
- `compiled/` bytecode (`*.zo`, `*.dep`) and `.env`/`.env.local` are gitignored and must not be staged or committed.
- The coordinator agent commits and pushes batched changes; the individual `#lang artifacts` build subagents intentionally do NOT commit or push their own work.
