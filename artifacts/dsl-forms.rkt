#lang racket

(provide (struct-out bot-spec)
         (struct-out character-spec)
         (struct-out strategy-spec)
         (struct-out goal-spec)
         (struct-out action-spec)
         (struct-out guard-spec)
         character-spec-name
         character-spec-live-name
         normalize-account-name
         expand-guards
         guard?)

(struct bot-spec (name forms) #:transparent)
(struct character-spec (tag role account-name forms) #:transparent)
(struct strategy-spec (name forms) #:transparent)
(struct goal-spec (target actions) #:transparent)
(struct action-spec (name payload) #:transparent)

;; A guard wraps a predicate and a body of action/goal forms. The predicate
;; receives the live character and answers true/false at decision time: a false
;; answer contributes nothing, a true answer inlines the wrapped body. The
;; predicate is the single source of truth for whether the guarded forms run,
;; so condition helpers (when-low-hp, when-inventory-full, when-on-content) and
;; plain thunks all fit the same guard shape.
(struct guard-spec (predicate forms) #:transparent)

;; Flatten a list of character/goal forms so guards are resolved against the
;; live `char`. A guard whose predicate is false contributes nothing; a true
;; guard contributes its unwrapped body (its own guards resolved recursively).
(define (expand-guards forms [char #f])
  (for/fold ([acc '()]) ([form (in-list forms)])
    (cond
      [(guard-spec? form)
       (if ((guard-spec-predicate form) char)
           (append (reverse (expand-guards (guard-spec-forms form) char)) acc)
           acc)]
      [else (cons form acc)])))

(define guard? guard-spec?)

;; Tag is the bot-local descriptor; account-name is the live Artifacts character.
(define character-spec-name character-spec-tag)

(define (normalize-account-name name)
  (cond
    [(false? name) #f]
    [(string? name) name]
    [(symbol? name) (symbol->string name)]
    [else (error 'normalize-account-name
                 "expected account name symbol, string, or #f, got ~v"
                 name)]))

(define (character-spec-live-name spec)
  (or (character-spec-account-name spec)
      (symbol->string (character-spec-tag spec))))
