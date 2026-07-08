#lang racket

(require artifacts/core)

(provide (rename-out [artifacts-module-begin #%module-begin])
         #%app
         #%datum
         #%top-interaction
         quote
         bot
         character
         strategy
         goal
         action
         (struct-out bot-spec)
         (struct-out character-spec)
         (struct-out strategy-spec)
         (all-from-out artifacts/core))

(struct bot-spec (name forms) #:transparent)
(struct character-spec (name role forms) #:transparent)
(struct strategy-spec (name forms) #:transparent)

(define-syntax-rule (artifacts-module-begin form ...)
  (#%module-begin form ...))

(define-syntax-rule (bot name form ...)
  (begin
    (provide name)
    (define name (bot-spec 'name (list form ...)))))

(define-syntax-rule (character name #:role role form ...)
  (character-spec 'name role (list form ...)))

(define-syntax-rule (strategy name form ...)
  (strategy-spec 'name (list form ...)))

(define (goal target . body)
  (list 'goal target body))

(define (action name . payload)
  (list 'action name payload))
