# Engineering Preflight

Read this before implementation work in `artifacts-racket`.

## Preflight Checklist

- State the smallest useful change that satisfies the request.
- Identify assumptions before relying on them; verify with local files or focused commands when possible.
- Keep the Racket library and `#lang artifacts` as the source of truth. Do not move strategy logic into Godot.
- Preserve scope boundaries. Do not edit the visualizer unless the task explicitly asks for it.
- Prefer direct data structures, pure helpers, and focused tests before adding broad abstractions.
- Keep imports at module tops and avoid inline imports.
- Verify the changed behavior with RackUnit or targeted Racket commands. If `racket` or `raco` is missing, report that clearly.
- Write comments and docs in a plain human voice. Avoid generic filler.
- Do not add `Co-Authored-By:` trailers unless the user explicitly reverses that rule.

## Working Default

Choose the narrowest durable step, make behavior visible through tests, and leave the repo easier to continue from.
