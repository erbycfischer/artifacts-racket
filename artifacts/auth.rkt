#lang racket

;; Authentication orchestration for the Artifacts MMO client.
;;
;; The framework supports several ways to obtain the bearer token, all of which
;; resolve to the same `Authorization: Bearer <token>` header eventually:
;;
;;   - env    : ARTIFACTS_API_TOKEN / ARTIFACTS_TOKEN (see config.rkt)
;;   - file   : a local token file (~/.artifacts/token or ARTIFACTS_TOKEN_FILE)
;;   - bridge : the running 3D visualizer bridge, which already holds the user's
;;              live login. The bot MUST NOT import the visualizer; it only
;;              consumes a token the bridge exposes locally (HTTP endpoint or a
;;              known token file). This is "login with the 3D Visualizer".
;;
;; This module builds configs from those sources and exposes the high-level
;; `login-via-visualizer` flow plus a defensive `refresh-token` used to recover
;; a long-running bot after a 452 / expired-token signal. Every token source is
;; pure and optional: if the bridge is down, the bot falls back to env/file, and
;; if none yield a token, `ensure-authenticated!` still raises the structured
;; 452 at request time.

(require racket/string
         racket/file
         "config.rkt"
         "http.rkt")

;; Programmatic save of a raw JWT to a token file. Creates the parent
;; directory if missing and writes a single trimmed line (no trailing
;; newline), matching the format make-file-source / read-token-file expects.
;; Used by the local token generator (tools/gen-token.rkt) so a user can
;; obtain a token without exporting env vars.
(define (save-token! token #:path [path (token-file-path)])
  (unless (present-token? token)
    (error 'save-token! "refusing to write an empty token"))
  (define dir (path-only (if (path? path) path (string->path path))))
  (when (and dir (not (directory-exists? dir)))
    (make-directory* dir))
  (call-with-output-file (if (path? path) path (string->path path))
    (lambda (out) (display (string-trim token) out))
    #:exists 'replace)
  (string-trim token))

;; Read a token back from a file via the framework's file source, or #f when
;; the file is absent. Defensive wrapper around make-file-source so callers
;; (e.g. `gen-token whoami`) resolve the same way the bot does at runtime.
(define (read-token! #:path [path (token-file-path)])
  (resolve-token-source (make-file-source #:path path)))

(provide with-token-source
         login-via-visualizer
         wait-for-visualizer
         refresh-token
         make-bridge-config
         save-token!
         read-token!
         login!)

;; Build a config that resolves its token from the highest-priority available
;; source: bridge first (live login), then file, then env. A config created this
;; way recovers automatically as long as one source keeps yielding a token.
(define (make-bridge-config #:base-url [base-url (artifacts-config-base-url production-config)]
                             #:realtime-url [realtime-url (artifacts-config-realtime-url production-config)]
                             #:bridge-url [bridge-url default-bridge-url]
                             #:bridge-file [bridge-file (bridge-token-path)]
                             #:token-file [token-file (token-file-path)])
  (define source
    (token-source
     'bridge
     (lambda ()
       (or (resolve-token-source (make-bridge-source #:url bridge-url #:file bridge-file))
           (resolve-token-source (make-file-source #:path token-file))
           (env-token)))))
  (artifacts-config base-url realtime-url source))

;; Install a token source into `current-config` for the rest of the session.
;; `source` may be a token-source or a plain string (wrapped as explicit).
(define (with-token-source source
                            #:base-url [base-url (artifacts-config-base-url (current-config))]
                            #:realtime-url [realtime-url (artifacts-config-realtime-url (current-config))])
  (define resolved
    (cond
      [(token-source? source) source]
      [(present-token? source) (make-explicit-source source)]
      [else (error 'with-token-source "expected a token-source or token string, got ~v" source)]))
  (current-config (artifacts-config base-url realtime-url resolved))
  (current-config))

;; Poll the bridge for a usable token, bounded so it never loops forever.
;; Returns the token string on success. After the timeout expires (default
;; ~10s) it returns #f so the caller can fall back to another source or raise a
;; clear error. The first attempt is immediate; subsequent attempts sleep
;; `interval` apart and there are at most (ceiling (/ timeout interval)) polls.
;; A zero/negative timeout still makes exactly one attempt and returns #f, so
;; callers always get a definitive answer rather than hanging.
(define (wait-for-visualizer #:bridge-url [bridge-url default-bridge-url]
                             #:timeout [timeout 10.0]
                             #:interval [interval 0.5])
  (define attempts (max 1 (ceiling (/ (max 0.0 timeout) (max 0.001 interval)))))
  (let loop ([n 1])
    (define status (bridge-token-status bridge-url))
    (cond
      [(eq? status 'ready)
       (bridge-token-via-http bridge-url)]
      [(< n attempts)
       (sleep interval)
       (loop (add1 n))]
      [else #f])))

;; The "simply login with the 3D Visualizer" experience. Obtain the live token
;; from the running visualizer bridge and install it into `current-config`. If
;; the bridge is unreachable or returns no token, raise a clear, human-readable
;; error telling the user to start the visualizer and log in.
;;
;; With #:wait? #t (the default), the call blocks briefly — polling the bridge
;; readiness up to `#:timeout` seconds — so a bot can call this right after the
;; user starts the visualizer and succeed as soon as they log in, without the
;; user having to re-run the bot. When the bridge does not yield a token within
;; the timeout, the call falls back to the bridge token file, then raises a
;; clear error if neither source has a token. With #:wait? #f it makes a single
;; attempt (bridge, then file) and raises immediately.
(define (login-via-visualizer #:bridge-url [bridge-url default-bridge-url]
                              #:bridge-file [bridge-file (bridge-token-path)]
                              #:base-url [base-url (artifacts-config-base-url production-config)]
                              #:realtime-url [realtime-url (artifacts-config-realtime-url production-config)]
                              #:wait? [wait? #t]
                              #:timeout [timeout 10.0]
                              #:interval [interval 0.5])
  (define token
    (cond
      [wait?
       (or (wait-for-visualizer #:bridge-url bridge-url
                                #:timeout timeout
                                #:interval interval)
           (read-token-file bridge-file #:silent? #t))]
      [else
       (or (bridge-token-via-http bridge-url)
           (read-token-file bridge-file #:silent? #t))]))
  (unless (present-token? token)
    (error 'login-via-visualizer
           "could not obtain a token from the 3D Visualizer bridge at ~a.\n  Start the visualizer (artifacts-mmo-ai-3d-visualizer) and log in, then retry.\n  Alternatively, set ARTIFACTS_API_TOKEN or ~~/.artifacts/token."
           bridge-url))
  (with-token-source (make-explicit-source token)
                     #:base-url base-url
                     #:realtime-url realtime-url)
  token)

;; Re-resolve the token from the current config's source after a 452 or
;; expired-token signal, and update `current-config` if a fresh token appears.
;; Defensive: it only re-resolves (never loops), and returns the resolved token
;; (or #f when the source yields nothing). Callers should give up after a bounded
;; number of attempts rather than calling this in a tight loop.
(define (refresh-token #:config [config (current-config)])
  (define fresh (reresolve-token config))
  (when (and (present-token? fresh)
             (not (equal? fresh (config-token config))))
    (current-config (artifacts-config (artifacts-config-base-url config)
                                      (artifacts-config-realtime-url config)
                                      (make-explicit-source fresh))))
  fresh)

;; Thin REPL/user convenience: log in via the visualizer bridge (blocking until
;; the user logs in) and return the resolved token. Equivalent to calling
;; login-via-visualizer directly, just a friendlier name.
(define (login!)
  (login-via-visualizer #:wait? #t))
