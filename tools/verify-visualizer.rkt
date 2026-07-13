#lang racket
;; Offline proof that "login with the 3D Visualizer" works end-to-end.
;;
;; Self-contained: spins up a tiny local TCP "bridge" that answers GET /token
;; with a fake token, so the visualizer login flow is exercised with no real
;; visualizer and no network. Covers the bridge contract (JSON + raw-body
;; shapes), the clear error when the bridge is down, bounded waiting that never
;; loops, the bridge->file->env cascade, and refresh-token being a no-op when
;; the source is unchanged.
;;
;; Run with:  raco test tools/verify-visualizer.rkt
(require rackunit
         racket/tcp
         "../artifacts/config.rkt"
         "../artifacts/auth.rkt")

;; A stand-in visualizer bridge: a tiny TCP server answering GET /token with
;; `body` (JSON, raw token, or empty for the no-token case).
(define (start-mock-bridge body)
  (define cust (make-custodian))
  (define port
    (parameterize ([current-custodian cust])
      (let retry ([p (+ 8000 (random 57000))])
        (define l
          (with-handlers ([exn:fail? (lambda (_e) #f)])
            (tcp-listen p 4 #t "127.0.0.1")))
        (if l
            (begin
              (thread
               (lambda ()
                 (with-handlers ([exn:fail? (lambda (_e) (void))])
                   (let accept-loop ()
                     (define-values (in out) (tcp-accept l))
                     (with-handlers ([exn:fail? (lambda (_e) (void))])
                       (let ([req (read-line in 'any)])
                         (when (regexp-match? #px"^GET\\s+/token" (or req ""))
                           (fprintf out "HTTP/1.1 200 OK\r\n")
                           (fprintf out "Content-Type: text/plain\r\n")
                           (fprintf out "Content-Length: ~a\r\n" (string-length body))
                           (fprintf out "\r\n")
                           (fprintf out "~a" body)
                           (flush-output out))))
                     (close-input-port in)
                     (close-output-port out)
                     (accept-loop)))))
              p)
            (retry (+ 8000 (random 57000)))))))
  (values port cust))

(module+ test
  (test-case "bridge HTTP endpoint yields the token (JSON shape)"
    ;; The contract's preferred form: {"token": "..."}.
    (define-values (port cust) (start-mock-bridge "{\"token\":\"BRIDGE_JSON_TOKEN\"}"))
    (dynamic-wind void
                  (lambda ()
                    (define cfg
                      (artifacts-config "https://api.artifactsmmo.com"
                                        "wss://realtime.artifactsmmo.com"
                                        (make-bridge-source #:url (format "http://127.0.0.1:~a/token" port))))
                    (check-equal? (config-token cfg) "BRIDGE_JSON_TOKEN"))
                  (lambda () (custodian-shutdown-all cust))))

  (test-case "bridge HTTP endpoint yields the token (raw body shape)"
    ;; The fallback contract: a bare trimmed token in the body.
    (define-values (port cust) (start-mock-bridge "BRIDGE_RAW_TOKEN\n"))
    (dynamic-wind void
                  (lambda ()
                    (define cfg
                      (artifacts-config "https://api.artifactsmmo.com"
                                        "wss://realtime.artifactsmmo.com"
                                        (make-bridge-source #:url (format "http://127.0.0.1:~a/token" port))))
                    (check-equal? (config-token cfg) "BRIDGE_RAW_TOKEN"))
                  (lambda () (custodian-shutdown-all cust))))

  (test-case "login-via-visualizer installs a token from a live bridge"
    ;; With a running mock bridge, login-via-visualizer (wait? #f) reads the
    ;; token and installs it into current-config.
    (define-values (port cust) (start-mock-bridge "{\"token\":\"LOGIN_BRIDGE_TOKEN\"}"))
    (dynamic-wind void
                  (lambda ()
                    (define prior (current-config))
                    (login-via-visualizer #:bridge-url (format "http://127.0.0.1:~a/token" port)
                                          #:wait? #f)
                    (check-equal? (config-token (current-config)) "LOGIN_BRIDGE_TOKEN")
                    (current-config prior))
                  (lambda () (custodian-shutdown-all cust))))

  (test-case "login-via-visualizer raises a clear error when the bridge is down"
    ;; Point at a port with no listener: the bridge is down, so login must raise
    ;; the human-readable "Start the visualizer" error, not a silent 452.
    (check-exn (lambda (e)
                (and (exn:fail? e)
                     (regexp-match? #rx"could not obtain a token from the 3D Visualizer bridge"
                                    (exn-message e))))
               (lambda ()
                 (login-via-visualizer #:bridge-url "http://127.0.0.1:1/token"
                                       #:wait? #f))))

  (test-case "login-via-visualizer installs a token from a bridge file fallback"
    ;; The bridge HTTP endpoint is unreachable in tests, so the bridge source
    ;; falls back to the token file; login-via-visualizer reads it and installs
    ;; it into current-config. #:wait? #f skips the bounded poll.
    (define token-file (make-temporary-file "artifacts-bridge-file-~a"))
    (call-with-output-file token-file
      (lambda (out) (displayln "FILE_TOKEN_VALUE" out))
      #:exists 'replace)
    (define prior (current-config))
    (with-handlers ([exn:fail? (lambda (_exn) (void))])
      (login-via-visualizer #:bridge-url "http://127.0.0.1:9/token"
                            #:bridge-file token-file #:wait? #f))
    (check-equal? (config-token (current-config)) "FILE_TOKEN_VALUE")
    (current-config prior)
    (delete-file token-file))

  (test-case "login-via-visualizer raises when the bridge has no token"
    ;; A bridge whose source yields nothing must raise a clear, human-readable
    ;; error pointing at the visualizer. #:wait? #f keeps it a single attempt.
    (define empty (make-temporary-file "artifacts-empty-~a"))
    (call-with-output-file empty (lambda (out) (display "" out)) #:exists 'replace)
    (check-exn (lambda (e)
                (and (exn:fail? e)
                     (regexp-match? #rx"could not obtain a token from the 3D Visualizer bridge"
                                    (exn-message e))))
               (lambda ()
                 (login-via-visualizer #:bridge-url "http://127.0.0.1:9/token"
                                       #:bridge-file empty #:wait? #f)))
    (delete-file empty))

  (test-case "wait-for-visualizer returns #f on a down bridge, never loops"
    ;; Bounded: against a closed port it makes a finite number of attempts and
    ;; returns #f rather than blocking or raising. (Windows TCP connect to a
    ;; refused port is slow, so we only assert it terminates and yields #f.)
    (check-false (wait-for-visualizer #:bridge-url "http://127.0.0.1:1/token"
                                      #:timeout 1.0 #:interval 0.1)))

  (test-case "wait-for-visualizer times out on a no-token bridge, bounded"
    ;; A live bridge serving an empty body reports 'no-token; the bounded poll
    ;; returns #f after the timeout instead of hanging.
    (define-values (port cust) (start-mock-bridge ""))
    (dynamic-wind void
                  (lambda ()
                    (check-false (wait-for-visualizer #:bridge-url (format "http://127.0.0.1:~a/token" port)
                                                      #:timeout 1.0 #:interval 0.1)))
                  (lambda () (custodian-shutdown-all cust))))

  (test-case "make-bridge-config resolves bridge, then file, then env"
    ;; With the bridge endpoint down and a token file present, the cascading
    ;; source resolves through the file layer, then env once the file is gone.
    (define token-file (make-temporary-file "artifacts-cascade-~a"))
    (call-with-output-file token-file
      (lambda (out) (displayln "CASCADE_FILE_TOKEN" out))
      #:exists 'replace)
    (define prior-env (getenv "ARTIFACTS_API_TOKEN"))
    (putenv "ARTIFACTS_API_TOKEN" "CASCADE_ENV_TOKEN")
    (dynamic-wind void
                  (lambda ()
                    (define cfg-file
                      (make-bridge-config #:bridge-url "http://127.0.0.1:1/token"
                                          #:bridge-file token-file))
                    (check-equal? (config-token cfg-file) "CASCADE_FILE_TOKEN")
                    (delete-file token-file)
                    (define cfg-env
                      (make-bridge-config #:bridge-url "http://127.0.0.1:1/token"
                                          #:bridge-file token-file))
                    (check-equal? (config-token cfg-env) "CASCADE_ENV_TOKEN"))
                  (lambda ()
                    (when prior-env (putenv "ARTIFACTS_API_TOKEN" prior-env))
                    (when (file-exists? token-file) (delete-file token-file)))))

  (test-case "refresh-token is a no-op when the source is unchanged"
    ;; An explicit source re-resolves to the same token; refresh-token returns
    ;; it and must NOT swap current-config for a different source.
    (define cfg (with-token-source "STABLE_TOKEN"))
    (define before (current-config))
    (define fresh (refresh-token #:config cfg))
    (check-equal? fresh "STABLE_TOKEN")
    (check-equal? (config-token (current-config)) (config-token before))
    (current-config before))

  (test-case "bridge-token-status reports down / no-token / ready"
    ;; down: closed port. no-token: bridge serves empty body. ready: serves a
    ;; token. The probe must never raise, only classify.
    (check-eq? (bridge-token-status "http://127.0.0.1:1/token") 'down)
    (define-values (port-no cust-no) (start-mock-bridge ""))
    (dynamic-wind void
                  (lambda ()
                    (check-eq? (bridge-token-status (format "http://127.0.0.1:~a/token" port-no)) 'no-token))
                  (lambda () (custodian-shutdown-all cust-no)))
    (define-values (port-ready cust-ready) (start-mock-bridge "{\"token\":\"X\"}"))
    (dynamic-wind void
                  (lambda ()
                    (check-eq? (bridge-token-status (format "http://127.0.0.1:~a/token" port-ready)) 'ready))
                  (lambda () (custodian-shutdown-all cust-ready)))))
