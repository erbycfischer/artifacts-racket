#lang racket

;; Consumable helpers: drink a potion when hurt, or burn a buff item that's
;; sitting in the bag. Each returns a guard-spec so it drops into a character
;; body or pipeline as a one-liner.

(require "../../dsl-forms.rkt"
         "../../planner.rkt"
         "../actions.rkt")

(provide heal-when-low
         heal-when-hp-code
         eat-when-low
         consume-buff)

;; Use `code` whenever HP drops to/under `ratio` of max and the stack is in
;; the bag. Default potion is the starter health flask. Dormant when the bag
;; lacks `code` so other preferred forms can run.
(define (heal-when-low #:code [code 'small_health_potion] #:ratio [ratio 0.5])
  (guard-spec (lambda (char)
                (and (when-low-hp char ratio)
                     (when-has-item char code)))
              (list (use-item #:code code #:qty 1))))

;; Same as heal-when-low, named for cooked food. Default is cooked_chicken
;; so a fighter can write `(eat-when-low)` next to `(heal-when-low)`.
(define (eat-when-low #:code [code 'cooked_chicken] #:ratio [ratio 0.5])
  (heal-when-low #:code code #:ratio ratio))

;; Same idea, but the trigger is an absolute HP number rather than a ratio —
;; handy when a character's max HP is still climbing and a fixed flask
;; threshold is easier to reason about than 0.5 of a moving target.
(define (heal-when-hp-code #:code code #:threshold hp)
  (guard-spec (lambda (char) (<= (character-field char 'hp 0) hp))
              (list (use-item #:code code #:qty 1))))

;; Drink/eat `code` as soon as it's in the bag. Pairs with a gather or NPC-buy
;; so a buff item is consumed the tick it lands, not left occupying a slot.
(define (consume-buff #:code code)
  (guard-spec (lambda (char) (when-has-item char code))
              (list (use-item #:code code #:qty 1))))
