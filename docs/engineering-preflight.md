# Engineering Preflight

Read this before implementation work in `artifacts-racket`.

## Preflight Checklist

- State the smallest useful change that satisfies the request.
- Identify assumptions before relying on them; verify with local files or focused commands when possible.
- Keep the Racket library and `#lang artifacts` as the source of truth. Do not move strategy logic into Godot.
- Preserve scope boundaries. Bot work stays in `artifacts/` and `examples/`; visual client work stays in the sibling `artifacts-mmo-ai-3d-visualizer` repo.
- Prefer direct data structures, pure helpers, and focused tests before adding broad abstractions.
- Keep imports at module tops and avoid inline imports.
- Verify the changed behavior with RackUnit or targeted Racket commands. If `racket` or `raco` is missing, report that clearly.
- Write comments and docs in a plain human voice. Avoid generic filler.
- Do not add `Co-Authored-By:` trailers unless the user explicitly reverses that rule.

## Working Default

Choose the narrowest durable step, make behavior visible through tests, and leave the repo easier to continue from.

## The Single Green Check

`raco test tests/artifacts-test.rkt` is the authoritative green check for this
repo. A change is not "done" until that suite passes. It also requires the
`artifacts` collection to be linked (see `AGENTS.md`): either set `PLTCOLLECTS`
to include this repo's root, or run `raco pkg install --link .` from the repo
root. Without the link, `#lang artifacts` example bots cannot compile.

Run it directly:

```sh
raco test tests/artifacts-test.rkt
```

Or use the one-line helper, which also exits non-zero on failure:

```sh
racket tools/preflight.rkt
```

If the suite fails to compile, treat that as a red build — do not work around
it by skipping tests. Fix the compile error (often a missing `provide` or an
unbalanced paren from a concurrent edit) before reporting the change as green.

### Coverage regression tests

`tests/coverage-extras-test.rkt` is an independent suite that guards specific
regressions without coupling to the larger, frequently-edited
`tests/artifacts-test.rkt`:

- every HTTP wrapper exported by `artifacts/http.rkt` is bound (a typo'd or
  dropped `provide` fails loudly instead of shipping `#<undefined>`);
- the `artifacts/auth.rkt` surface (token-source resolution, the
  `make-bridge-config` cascade, `refresh-token`, `save-token!`/`read-token!`)
  round-trips offline;
- `examples/*.rkt` and `tools/gen-token.rkt` compile under `raco make`.

Run it the same way:

```sh
raco test tests/coverage-extras-test.rkt
```
