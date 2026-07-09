#lang racket

(provide (struct-out bot-spec)
         (struct-out character-spec)
         (struct-out strategy-spec)
         (struct-out goal-spec)
         (struct-out action-spec))

(struct bot-spec (name forms) #:transparent)
(struct character-spec (name role forms) #:transparent)
(struct strategy-spec (name forms) #:transparent)
(struct goal-spec (target actions) #:transparent)
(struct action-spec (name payload) #:transparent)
