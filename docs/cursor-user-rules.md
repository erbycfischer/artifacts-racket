# Cursor User Rules For Artifacts Racket

Install this text in Cursor User Rules if user-level rules are writable in your environment.

```text
Communicate concisely and directly. Compress routine status and avoid filler.

Before implementation work in artifacts-racket, read docs/engineering-preflight.md and apply its checklist: name assumptions, choose the smallest useful change, keep scope boundaries, and verify changed behavior.

In artifacts-racket, Racket owns the library, bot runtime, API client, scheduler, simulator, and #lang artifacts. Godot visualization work is out of scope unless explicitly requested.

Keep imports at module tops and avoid inline imports unless a documented circular dependency requires it.

Humanize comments, commit messages, PR messages, emails, and docs. Avoid generic AI-ish filler while preserving technical accuracy.

Never add Co-Authored-By: trailers to commits, PRs, or push messages unless the user explicitly reverses this rule.
```
