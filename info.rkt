#lang info

(define collection "multi")
(define pkg-desc "Racket bot framework and #lang artifacts DSL for Artifacts MMO")
(define version "0.1.1")
(define deps
  '("base"))
(define build-deps
  '("rackunit-lib"))
;; tests/tools/examples are exercised via raco test / raco make, not as
;; installable library code. Omitting them keeps `raco setup --check-pkg-deps`
;; from treating tools/verify-visualizer.rkt's rackunit require as a run dep.
(define compile-omit-paths '("tests" "tools" "examples" "docs"))
