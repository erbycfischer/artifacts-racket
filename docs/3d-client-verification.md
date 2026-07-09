# Official 3D client — verification checklist

Use this after bridge + Godot changes. Do not commit tokens.

## Local (no token)

```sh
export PLTCOLLECTS="$PWD:"
raco test tests/artifacts-test.rkt
racket examples/artifacts-3d-bridge.rkt
# other terminal:
godot --path godot/client
```

Expect: hub on `ws://127.0.0.1:8787`, Godot Connect → Mode Unauthenticated (or Offline fixtures), fixtures show own + `[world]` other markers.

## Live official token

```sh
export ARTIFACTS_API_TOKEN=your_token_here   # never commit
racket examples/artifacts-3d-bridge.rkt
godot --path godot/client
```

1. Auth (env or Godot panel) → Mode Playing; own characters appear.
2. Select character, click tile → Move / Fight / Gather / Rest; `action.result` matches web-client cooldowns/errors.
3. Bank / GE / Craft / Task / NPC buttons on matching tile types.
4. Amber `[world]` markers for other official characters (leaderboard-backed; plus realtime `online_characters` when `ARTIFACTS_REALTIME=1`).
5. Rate-limit: others refresh on `ARTIFACTS_OTHERS_POLL_SECONDS` (default 15); no token in logs.
6. Optional: `ARTIFACTS_REALTIME=1` on the bridge for faster world population via official WS.

## Unmodified bot watch

```sh
# terminal 1
racket examples/artifacts-3d-bridge.rkt
# terminal 2 — no visualizer publish required
ARTIFACTS_VISUALIZER=0 racket examples/apex-bot.rkt
# terminal 3
godot --path godot/client
```

Character motion appears from official `get-my-characters` polling, not from bot hub hooks.

## Headless bots still work

```sh
ARTIFACTS_VISUALIZER=0 ARTIFACTS_DRY_RUN=1 ARTIFACTS_ITERATIONS=1 racket examples/apex-bot.rkt
```
