#lang racket

;; The single green check for artifacts-racket.
;;
;; `tests/artifacts-test.rkt` is the authoritative test suite (see
;; docs/engineering-preflight.md). This thin wrapper runs it via `raco test`
;; and exits non-zero if it fails to compile or any test fails, so it can be
;; used as a preflight gate in a shell pipeline:
;;
;;   racket tools/preflight.rkt && echo "green"

(require racket/system
         racket/string)

(define repo-root (path-only (path->complete-path (find-system-path 'run-file))))
(define test-file (build-path repo-root "tests" "artifacts-test.rkt"))
(define cmd (format "raco test \"~a\"" (path->string test-file)))

(define ok? (system cmd))
(unless ok?
  (eprintf "preflight: raco test tests/artifacts-test.rkt did NOT pass.\n"))
(exit (if ok? 0 1))
