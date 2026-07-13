#lang racket

;; Local token generator for the Artifacts MMO framework.
;;
;; Lets a user obtain a bearer token and persist it to ~/.artifacts/token (or
;; a path of their choosing) so a #lang artifacts bot can play without ever
;; exporting ARTIFACTS_API_TOKEN / ARTIFACTS_TOKEN into the shell.
;;
;; Subcommands:
;;   login <username> <password>   exchange credentials for a JWT and save it
;;   register <username> <email> <password>  create an account, then log in
;;   whoami | verify               confirm the saved token still works
;;
;; Flags (any subcommand):
;;   --token-file <path>  override the default token file
;;   --base-url <url>     target production / sandbox / beta server

(require json
         racket/cmdline
         racket/file
         racket/string
         "../artifacts/config.rkt"
         "../artifacts/http.rkt"
         "../artifacts/auth.rkt")

;; ---- helpers ----------------------------------------------------------------

(define (token-from-response body)
  ;; The Artifacts /token and /accounts/create endpoints wrap the JWT in
  ;; data.token, but be tolerant of a bare token field too. Returns the
  ;; trimmed token string or #f when neither is present.
  (cond
    [(not (hash? body)) #f]
    [(hash-has-key? body 'data)
     (define d (hash-ref body 'data))
     (and (hash? d)
          (hash-has-key? d 'token)
          (let ([t (hash-ref d 'token)]) (and (string? t) (string-trim t))))]
    [(hash-has-key? body 'token)
     (let ([t (hash-ref body 'token)]) (and (string? t) (string-trim t)))]
    [else #f]))

(define (config-for base-url token-file)
  (cond
    [base-url (artifacts-config base-url
                                "wss://realtime.artifactsmmo.com"
                                (make-file-source #:path token-file))]
    [else (artifacts-config (artifacts-config-base-url production-config)
                            (artifacts-config-realtime-url production-config)
                            (make-file-source #:path token-file))]))

(define (resolve-token-file override)
  (if override
      (if (path-string? override) override (string->path override))
      (token-file-path)))

(define (relative-home path)
  ;; Render a path relative to the user's home dir when possible, so the
  ;; success message is readable (no C:\Users\manam\... noise).
  (define home (path->string (find-system-path 'home-dir)))
  (define ps (path->string (if (path? path) path (string->path path))))
  (cond
    [(string-prefix? ps home)
     (string-append "~" (substring ps (string-length home)))]
    [else ps]))

(define (print-saved path token)
  (printf "Token saved to ~a\n" (relative-home path))
  (printf "Token present (~a chars). It is stored locally and never printed.\n"
          (string-length token))
  (printf "Your bot will read it automatically via the file token-source.\n"))

;; ---- subcommands ------------------------------------------------------------

(define (do-login username password base-url token-file)
  (define cfg (config-for base-url token-file))
  (define response
    (with-handlers ([exn:fail:artifacts-api?
                     (lambda (exn)
                       (define err (exn:fail:artifacts-api-error exn))
                       (eprintf "Login failed (~a): ~a\n"
                                (api-error-code err)
                                (api-error-message err))
                       (exit 1))]
                    [exn:fail?
                     (lambda (exn)
                       (eprintf "Login failed: ~a\n" (exn-message exn))
                       (exit 1))])
      (post-token username password #:config cfg)))
  (define token (token-from-response response))
  (unless token
    (eprintf "Login succeeded but no token was returned by the server.\n")
    (exit 1))
  (define path (resolve-token-file token-file))
  (save-token! token #:path path)
  (print-saved path token))

(define (do-register username email password base-url token-file)
  (define cfg (config-for base-url token-file))
  (with-handlers ([exn:fail:artifacts-api?
                   (lambda (exn)
                     (define err (exn:fail:artifacts-api-error exn))
                     (eprintf "Registration failed (~a): ~a\n"
                              (api-error-code err)
                              (api-error-message err))
                     (exit 1))]
                  [exn:fail?
                   (lambda (exn)
                     (eprintf "Registration failed: ~a\n" (exn-message exn))
                     (exit 1))])
    (post-accounts-create #:config cfg
                          #:body (hasheq 'username username
                                         'email email
                                         'password password)))
  (printf "Account '~a' created. Logging in...\n" username)
  (do-login username password base-url token-file))

(define (do-verify base-url token-file)
  (define path (resolve-token-file token-file))
  (define token (read-token! #:path path))
  (unless token
    (eprintf "No token found at ~a.\n" (relative-home path))
    (eprintf "Run: racket tools/gen-token.rkt login <username> <password>\n")
    (exit 1))
  (define cfg (config-for base-url token-file))
  (with-handlers ([exn:fail:artifacts-api?
                   (lambda (exn)
                     (define err (exn:fail:artifacts-api-error exn))
                     (when (= (api-error-code err) 452)
                       (eprintf "Token invalid or expired (~a). Re-run login:\n" (api-error-code err))
                       (eprintf "  racket tools/gen-token.rkt login <username> <password>\n")
                       (exit 1))
                     (eprintf "Verification failed (~a): ~a\n"
                              (api-error-code err)
                              (api-error-message err))
                     (exit 1))]
                  [exn:fail?
                   (lambda (exn)
                     (eprintf "Verification failed: ~a\n" (exn-message exn))
                     (exit 1))])
    (get-my-characters #:config cfg))
  (printf "Token is valid. Bot can authenticate from ~a.\n" (relative-home path)))

;; ---- CLI dispatch -----------------------------------------------------------

(define arg-token-file #f)
(define arg-base-url #f)

;; Flags may appear before or after the subcommand (e.g. `login u p --token-file
;; f`). command-line only scans the pre-subcommand region for flags, so we
;; pull any --token-file / --base-url out of `rest` ourselves and leave the
;; positional arguments behind.
(define (parse-post-subcommand-args rest)
  (let loop ([args rest] [positionals '()])
    (cond
      [(null? args)
       (values (reverse positionals) arg-token-file arg-base-url)]
      [(and (equal? (car args) "--token-file") (pair? (cdr args)))
       (set! arg-token-file (cadr args))
       (loop (cddr args) positionals)]
      [(and (equal? (car args) "--base-url") (pair? (cdr args)))
       (set! arg-base-url (cadr args))
       (loop (cddr args) positionals)]
      [(or (equal? (car args) "--token-file")
           (equal? (car args) "--base-url"))
       (eprintf "Option ~a requires an argument.\n" (car args))
       (exit 1)]
      [else (loop (cdr args) (cons (car args) positionals))])))

(command-line
 #:program "gen-token"
 #:usage-help "Generate and store a local Artifacts MMO token."
 #:once-each
 [("--token-file") file
  "Write/read the token to FILE instead of ~/.artifacts/token"
  (set! arg-token-file file)]
 [("--base-url") url
  "Target server base URL (e.g. https://api.sandbox.artifactsmmo.com)"
  (set! arg-base-url url)]
 #:args (command . rest)
 (define-values (positionals _tf _bu)
   (parse-post-subcommand-args rest))
 (case (string->symbol command)
   [(login)
    (unless (= (length positionals) 2)
      (eprintf "usage: gen-token login <username> <password> [--token-file F] [--base-url U]\n")
      (exit 1))
    (do-login (car positionals) (cadr positionals) arg-base-url arg-token-file)]
   [(register)
    (unless (= (length positionals) 3)
      (eprintf "usage: gen-token register <username> <email> <password> [--token-file F] [--base-url U]\n")
      (exit 1))
    (do-register (car positionals) (cadr positionals) (caddr positionals) arg-base-url arg-token-file)]
   [(whoami verify)
    (unless (null? positionals)
      (eprintf "usage: gen-token ~a [--token-file F] [--base-url U]\n" command)
      (exit 1))
    (do-verify arg-base-url arg-token-file)]
   [else
    (eprintf "Unknown subcommand '~a'. Try login, register, or whoami.\n" command)
    (exit 1)]))
