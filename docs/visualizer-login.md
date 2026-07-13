# Login with the 3D Visualizer

This document is the authoritative spec for "login with the 3D Visualizer" — the
path where a running `artifacts-mmo-ai-3d-visualizer` already holds your live
Artifacts MMO login and your Racket bot picks that token up locally. It covers
the exact interface contract between the bot framework (this repo) and the
visualizer bridge, plus the user-facing steps and troubleshooting.

> The Racket bot framework and the 3D visualizer are **separate repos**. The bot
> MUST NOT import the visualizer. It only consumes a token the bridge exposes
> locally — over a loopback HTTP endpoint or a well-known token file. This keeps
> the framework isolated and the visualizer free to evolve independently.

## The bridge contract

The framework (`artifacts/auth.rkt`, `artifacts/config.rkt`) obtains the
visualizer token from exactly two local sources, in this order:

### 1. HTTP endpoint (preferred)

- **URL:** `http://127.0.0.1:7878/token` (override via the `#:bridge-url`
  argument on `login-via-visualizer` / `make-bridge-config` / `make-bridge-source`).
- **Method:** `GET` (the bot only ever reads this URL; it never POSTs or imports
  the bridge).
- **Response shape:** one of
  - JSON: `{"token": "<raw-jwt>"}` — the token is the string value of the
    `"token"` key.
  - Raw body: a bare token string (with optional surrounding whitespace/newline).
    The framework trims and uses the whole body as the token.

  Either form works; the JSON form is preferred so a bridge can return other
  fields later without breaking clients.
- **Any non-2xx / connection failure / empty body** is treated as "no token
  here" and the framework falls through to the file source (or raises a clear
  error when no fallback yields a token).

### 2. Token file (fallback)

- **Path:** `~/.artifacts/visualizer-token` (override via `#:bridge-file`).
- **Format:** the raw token on a single line (no quotes; a trailing newline is
  fine and trimmed). This is the same plain-token format used by
  `~/.artifacts/token`.
- The bridge writes this file when it has a live login but is not serving HTTP,
  or as a durable copy. The bot reads it only when the HTTP endpoint yields
  nothing.

### Cascade order

`make-bridge-config` resolves a token from the highest-priority source that
currently yields one:

```
bridge (HTTP → file) → ~/.artifacts/token → $ARTIFACTS_API_TOKEN / $ARTIFACTS_TOKEN
```

Because the source is re-resolved on every request, a `make-bridge-config`
client keeps working as one source becomes unavailable or another appears
(e.g. the user logs in to the visualizer mid-run). `login-via-visualizer`
resolves **bridge only** (HTTP → file) and installs that token explicitly into
`current-config`.

## User steps

### Option A — Just log in, then run the bot

1. Start the 3D visualizer repo (`artifacts-mmo-ai-3d-visualizer`) and log in to
   your Artifacts account there. The bridge begins serving the token locally.
2. In your bot (or a REPL), call:

```racket
(require artifacts/auth)

;; Block briefly (≤10s by default) until the visualizer serves a token,
;; then install it into current-config. If you started the visualizer
;; already, this returns immediately.
(login-via-visualizer)
```

You can also build a config that auto-cascades and recovers at runtime:

```racket
(require artifacts/auth)

;; current-config now resolves bridge → file → env on every request.
(current-config (make-bridge-config))
```

### Option B — Bot waits for you to log in

If your bot launches *before* you've logged in to the visualizer, call
`login-via-visualizer` with the default `#:wait? #t`. It polls the bridge every
`#:interval` seconds up to `#:timeout` seconds, succeeding the moment you log
in — no need to restart the bot.

```racket
;; Poll up to 30s, checking every 1s.
(login-via-visualizer #:wait? #t #:timeout 30 #:interval 1)
```

For finer control, `wait-for-visualizer` returns the token (or `#f` after the
timeout) without touching `current-config`:

```racket
(define tok (wait-for-visualizer #:bridge-url "http://127.0.0.1:7878/token"
                                 #:timeout 10 #:interval 0.5))
```

## Troubleshooting

| Symptom | Cause | Fix |
|---------|-------|-----|
| `could not reach the 3D Visualizer bridge at http://127.0.0.1:7878/token ... Start the visualizer ... and log in` | The bridge HTTP endpoint is not listening (visualizer not running, or a different port). | Start `artifacts-mmo-ai-3d-visualizer` and log in. Confirm it listens on `127.0.0.1:7878`. |
| `the 3D Visualizer bridge ... responded but returned no token` | Bridge is up but you haven't logged in yet. | Log in to the visualizer; re-run, or use `#:wait? #t` so it resolves once you do. |
| `could not obtain a token from the 3D Visualizer bridge ...` | Neither the bridge HTTP endpoint nor the `visualizer-token` file has a token. | Log in to the visualizer, or fall back to `ARTIFACTS_API_TOKEN` / `~/.artifacts/token`. |
| Auth still fails (452) mid-run after it worked at startup | Token expired / logged out of the visualizer. | Call `(refresh-token)` to re-resolve the source. With a `make-bridge-config` or `login-via-visualizer` source, this picks up a fresh token if the bridge/file now has one; `current-config` is updated only if the token actually changed. |

### Notes

- All sources are purely local. No visualizer code is imported by the framework,
  and the token never leaves your machine except in the `Authorization` header
  sent to the official Artifacts API.
- `login-via-visualizer` / `wait-for-visualizer` are **bounded**: they make a
  finite number of polls (`ceiling(timeout / interval)`) and then return `#f`
  or raise — they never spin forever.
- If you only need a token without the visualizer, the simplest path is
  `export ARTIFACTS_API_TOKEN=...` or writing the raw token to `~/.artifacts/token`.
