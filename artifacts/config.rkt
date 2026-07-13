#lang racket

;; API configuration for the Artifacts MMO client.
;;
;; A config pairs the server base URLs with a *token source*. A token source is
;; anything that can answer "what is the bearer token right now?" — an explicit
;; string (the classic env token), a file on disk, or a live bridge (the 3D
;; visualizer) that holds the user's login. Keeping the source rather than a
;; bare string means a long-running bot can re-resolve a rotated token without a
;; restart (see reresolve-token in this module and refresh-token in
;; artifacts/auth.rkt).
;;
;; The resolution is honest and pure: resolving returns either a non-empty token
;; string or #f, never a sentinel. Callers that need a token ask through
;; `config-token`, which resolves the source exactly once per call.

(require racket/file
         racket/string
         net/url)

(provide (struct-out artifacts-config)
         (struct-out token-source)
         current-config
         make-config
         production-config
         sandbox-config
         beta-config
         env-token
         token-file-path
         default-token-file
         bridge-token-path
         default-bridge-url
         make-explicit-source
         token-file-error
         make-env-source
         make-file-source
         make-bridge-source
         bridge-token-via-http
         read-token-file
         resolve-token-source
         reresolve-token
         config-token
         present-token?
         token-source?
         explicit-token-source?
         file-token-source?
         bridge-token-source?
         env-token-source?
         bridge-token-status)

(struct artifacts-config (base-url realtime-url token) #:transparent
  #:guard (lambda (base-url realtime-url token name)
            ;; The token slot accepts a plain string OR a token-source. Any
            ;; other value is rejected loudly so a misconfigured bot fails at
            ;; construction time, not mid-network.
            (unless (or (string? token) (token-source? token) (not token))
              (error 'artifacts-config
                     "token must be a string, token-source, or #f, got ~v"
                     token))
            (values base-url realtime-url token)))

;; A token source names where a bearer token comes from and carries everything
;; needed to re-resolve it. `kind` is a symbol ('explicit 'env 'file 'bridge)
;; for logging/debugging; `resolve` is a thunk returning a token string or #f.
(struct token-source (kind resolve) #:transparent)

;; Predicates over a token-source's kind, so callers can log or branch on how a
;; token was obtained without reaching into the struct internals.
(define (explicit-token-source? source)
  (and (token-source? source) (eq? (token-source-kind source) 'explicit)))

(define (env-token-source? source)
  (and (token-source? source) (eq? (token-source-kind source) 'env)))

(define (file-token-source? source)
  (and (token-source? source) (eq? (token-source-kind source) 'file)))

(define (bridge-token-source? source)
  (and (token-source? source) (eq? (token-source-kind source) 'bridge)))

(define production-config
  (artifacts-config "https://api.artifactsmmo.com"
                    "wss://realtime.artifactsmmo.com"
                    #f))

(define sandbox-config
  (artifacts-config "https://api.sandbox.artifactsmmo.com"
                    "wss://realtime.sandbox.artifactsmmo.com"
                    #f))

(define beta-config
  (artifacts-config "https://api.beta.artifactsmmo.com"
                    "wss://realtime.beta.artifactsmmo.com"
                    #f))

;; Prefer ARTIFACTS_API_TOKEN (GitHub Actions secret name); keep ARTIFACTS_TOKEN
;; for local use. Returns the token string or #f when neither is set.
(define (env-token)
  (or (getenv "ARTIFACTS_API_TOKEN")
      (getenv "ARTIFACTS_TOKEN")))

;; The conventional dotfile a user may drop their token into, so they never have
;; to export it into the shell. Honors ARTIFACTS_TOKEN_FILE when set.
(define (default-token-file)
  (build-path (find-system-path 'home-dir) ".artifacts" "token"))

(define (token-file-path #:path [path (getenv "ARTIFACTS_TOKEN_FILE")])
  (cond
    [path (if (path-string? path) path (string->path path))]
    [else (default-token-file)]))

;; Where the 3D visualizer bridge writes the user's live token once they log in.
;; Bots MUST NOT import the visualizer; they only read this one well-known file.
(define (bridge-token-path)
  (build-path (find-system-path 'home-dir) ".artifacts" "visualizer-token"))

;; The local endpoint the visualizer bridge exposes for token hand-off. Used by
;; login-via-visualizer; the bot only ever GETs this URL and never imports the
;; sibling repo. Falls back to reading bridge-token-path if the bridge isn't
;; serving HTTP.
(define default-bridge-url "http://127.0.0.1:7878/token")

;; ---- token-source constructors ----------------------------------------------

;; An explicit string token. Resolves to itself; reresolution is a no-op.
(define (make-explicit-source token)
  (token-source 'explicit (lambda () (and (present-token? token) token))))

;; Resolve from the environment (ARTIFACTS_API_TOKEN / ARTIFACTS_TOKEN).
(define (make-env-source)
  (token-source 'env env-token))

;; Resolve by reading a local file. The file holds exactly the raw token; a
;; missing/unreadable file resolves to #f (so the bot can fall back to another
;; source) but use token-file-error for a loud, actionable failure.
(define (make-file-source #:path [path (token-file-path)])
  (token-source 'file (lambda () (read-token-file path))))

;; Resolve from the running 3D visualizer bridge. The bridge either serves the
;; token over a local HTTP endpoint or writes it to a known path; we try the
;; bridge URL first and fall back to the file. If both are unavailable, resolve
;; to #f so the bot can degrade to env/file or raise a clear 452 later.
(define (make-bridge-source #:url [url default-bridge-url]
                            #:file [file (bridge-token-path)])
  (token-source 'bridge
                (lambda ()
                  (or (bridge-token-via-http url)
                      (read-token-file file #:silent? #t)))))

;; ---- token resolution --------------------------------------------------------

;; A token is usable only if it is a non-empty string.
(define (present-token? token)
  (and (string? token)
       (regexp-match? #px"\\S" token)))

;; Resolve a token-source to a token string or #f. Pure: no side effects beyond
;; reading a file/network as the source dictates.
(define (resolve-token-source source)
  (cond
    [(token-source? source) ((token-source-resolve source))]
    [(present-token? source) source]
    [else #f]))

;; Read and trim the token from a file, or #f if it cannot be read. Use
;; token-file-error when a missing file should be a hard failure instead.
(define (read-token-file path #:silent? [silent? #f])
  (with-handlers ([exn:fail? (lambda (_exn) #f)])
    (define raw (with-input-from-file path read-line #:mode 'text))
    (define trimmed (and (string? raw) (string-trim raw)))
    (and (present-token? trimmed) trimmed)))

;; Raise a clear, human-readable error for a missing or unreadable token file.
(define (token-file-error path)
  (error 'token-file
         "could not read Artifacts token from ~a\n  Create it with your raw token (no quotes, no newline is fine), or set ARTIFACTS_TOKEN_FILE to a readable path."
         path))

;; Try the bridge HTTP endpoint. Returns the token string on success. When the
;; bridge is unreachable or returns nothing, returns #f — unless #:raise? is
;; true, in which case it raises a clear, human-readable error pointing the user
;; at the visualizer (used by login-via-visualizer when there is no file
;; fallback). Never imports the bridge; connection failures are caught and
;; turned into the structured message.
(define (bridge-token-via-http url #:raise? [raise? #f])
  (with-handlers ([exn:fail?
                   (lambda (exn)
                     (when raise?
                       ;; Pre-format the whole message first, then raise with a
                       ;; single "~a" so any "~" inside the inner exception's
                       ;; message is never re-parsed as a format directive.
                       (define msg
                         (format "could not reach the 3D Visualizer bridge at ~a (~a).\n  Start the visualizer (artifacts-mmo-ai-3d-visualizer) and log in, then retry.\n  Alternatively, set ARTIFACTS_API_TOKEN or ~~/.artifacts/token."
                                 url (exn-message exn)))
                       (error 'login-via-visualizer "~a" msg))
                     #f)])
    (define raw
      (with-output-to-string
        (lambda () (display (port->string (get-pure-port (string->url url)))))))
    (define token
      (cond
        [(regexp-match #px"\"token\"\\s*:\\s*\"([^\"]+)\"" raw)
         => (lambda (m) (cadr m))]
        [else (string-trim raw)]))
    (cond
      [(present-token? token) token]
      [raise?
       (error 'login-via-visualizer
              "the 3D Visualizer bridge at ~a responded but returned no token.\n  Log in to the visualizer, then retry (or set ARTIFACTS_API_TOKEN / ~~/.artifacts/token)."
              url)]
      [else #f])))

;; Probe the bridge for readiness without committing to a token. Returns one of
;;   'down    - the bridge endpoint is not listening / connection failed
;;   'no-token- the bridge answered but yielded no usable token yet (not logged in)
;;   'ready   - the bridge answered with a usable token
;; Used by wait-for-visualizer to poll boundedly until the user logs in.
(define (bridge-token-status url)
  (with-handlers ([exn:fail? (lambda (_exn) 'down)])
    (define raw
      (with-output-to-string
        (lambda () (display (port->string (get-pure-port (string->url url)))))))
    (define token
      (cond
        [(regexp-match #px"\"token\"\\s*:\\s*\"([^\"]+)\"" raw)
         => (lambda (m) (cadr m))]
        [else (string-trim raw)]))
    (if (present-token? token) 'ready 'no-token)))

;; Resolve the token for a config. Accepts either a plain string token or a
;; token-source; returns the resolved token string or #f.
(define (config-token config)
  (resolve-token-source (artifacts-config-token config)))

;; Re-resolve a possibly-stale token from its source. Returns the fresh token
;; string or #f when the source no longer yields one. Explicit string sources
;; resolve to themselves (a token a human typed in does not "rotate").
(define (reresolve-token config)
  (config-token config))

;; ---- config construction -----------------------------------------------------

(define (make-config #:base-url [base-url (artifacts-config-base-url production-config)]
                     #:realtime-url [realtime-url (artifacts-config-realtime-url production-config)]
                     #:token [token (env-token)])
  ;; A bare string (from env) is wrapped in an explicit source so every config
  ;; carries a uniform, resolvable token source.
  (define source
    (cond
      [(token-source? token) token]
      [(present-token? token) (make-explicit-source token)]
      [(not token) #f]
      [else (error 'make-config "invalid token ~v" token)]))
  (artifacts-config base-url realtime-url source))

(define current-config
  (make-parameter (make-config)))
