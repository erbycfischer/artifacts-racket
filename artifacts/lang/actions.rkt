#lang racket

(require "../dsl-forms.rkt")

(provide item-code
         qty-item
         item-stack
         gather
         rest
         fight
         deposit-all
         deposit-gold
         buy-expansion
         withdraw
         withdraw-gold
         buy
         sell
         craft
         recycle
         use-item
         move-to
         move-to-map
         transition
         equip
         unequip
         task-start
         task-complete
         task-cancel
         task-exchange
         task-trade
         scan-ge
         buy-on-ge
         sell-on-ge
         bid-on-ge
         cancel-order
         fill-order
         check-events
         check-raids
         give-gold
         give-item
         claim-item
         delete-item
         change-skin)

(define (item-code code)
  (cond
    [(symbol? code) (symbol->string code)]
    [(string? code) code]
    [else (format "~a" code)]))

(define (qty-item code qty)
  (hasheq 'code (item-code code) 'quantity qty))

(define (item-stack code qty)
  (qty-item code qty))

;; Most builders accept keyword arguments for readability, e.g.
;;   (buy #:code 'copper_ore #:qty 5)
;;   (move-to #:x 1 #:y 0)
;; Positional aliases are kept for compact, expression-heavy scripts.

(define (gather) (action-spec 'gather '()))

(define (rest) (action-spec 'rest '()))

(define (fight [participants '()]) (action-spec 'fight (list participants)))

(define (deposit-all) (action-spec 'bank-deposit-item '()))

(define (deposit-gold #:gold [gold (and (null? '()) #f)] . rest)
  (define g (if (null? rest) (or gold 0) (car rest)))
  (action-spec 'bank-deposit-gold (list g)))

;; Buy an extra bank slot. The API takes no payload, so the builder is a
;; no-argument spec; the dispatcher already treats bank-buy-expansion as a
;; payload-free action.
(define (buy-expansion) (action-spec 'bank-buy-expansion '()))

(define (withdraw #:code [code #f] #:qty [qty #f] . rest)
  (define-values (c q)
    (if (null? rest)
        (values code qty)
        (values (car rest) (cadr rest))))
  (action-spec 'bank-withdraw-item (list (qty-item c q))))

(define (withdraw-gold #:gold [gold (and (null? '()) #f)] . rest)
  (define g (if (null? rest) (or gold 0) (car rest)))
  (action-spec 'bank-withdraw-gold (list g)))

(define (buy #:code [code #f] #:qty [qty #f] . rest)
  (define-values (c q)
    (if (null? rest)
        (values code qty)
        (values (car rest) (cadr rest))))
  (action-spec 'npc-buy (list (qty-item c q))))

(define (sell #:code [code #f] #:qty [qty #f] . rest)
  (define-values (c q)
    (if (null? rest)
        (values code qty)
        (values (car rest) (cadr rest))))
  (action-spec 'npc-sell (list (qty-item c q))))

(define (craft #:code [code #f] #:qty [qty #f] . rest)
  (define-values (c q)
    (if (null? rest)
        (values code qty)
        (values (car rest) (cadr rest))))
  (action-spec 'craft (list (qty-item c q))))

(define (recycle #:code [code #f] #:qty [qty #f] . rest)
  (define-values (c q)
    (if (null? rest)
        (values code qty)
        (values (car rest) (cadr rest))))
  (action-spec 'recycle (list (qty-item c q))))

(define (use-item #:code [code #f] #:qty [qty #f] . rest)
  (define-values (c q)
    (if (null? rest)
        (values code (or qty 1))
        (values (car rest) (if (null? (cdr rest)) 1 (cadr rest)))))
  (action-spec 'use (list (qty-item c q))))

(define (move-to #:x [x #f] #:y [y #f] . rest)
  (define-values (xx yy)
    (if (null? rest)
        (values x y)
        (values (car rest) (cadr rest))))
  (action-spec 'move (list (hasheq 'x xx 'y yy))))

(define (move-to-map #:map-id [map-id #f] . rest)
  (define m (if (null? rest) map-id (car rest)))
  (action-spec 'move (list (hasheq 'map_id m))))

(define (transition) (action-spec 'transition '()))

(define (equip . slots) (action-spec 'equip (list slots)))

(define (unequip . slots) (action-spec 'unequip (list slots)))

(define (task-start) (action-spec 'task-new '()))

(define (task-complete) (action-spec 'task-complete '()))

(define (task-cancel) (action-spec 'task-cancel '()))

(define (task-exchange) (action-spec 'task-exchange '()))

(define (task-trade #:code [code #f] #:qty [qty #f] . rest)
  (define-values (c q)
    (if (null? rest)
        (values code qty)
        (values (car rest) (cadr rest))))
  (action-spec 'task-trade (list (qty-item c q))))

(define (scan-ge) (action-spec 'grand-exchange-orders '()))

(define (buy-on-ge #:order-id [order-id #f] #:qty [qty #f] . rest)
  (define-values (i q)
    (if (null? rest)
        (values order-id qty)
        (values (car rest) (cadr rest))))
  (action-spec 'grand-exchange-buy (list (hasheq 'id i 'quantity q))))

(define (sell-on-ge #:code [code #f] #:qty [qty #f] #:price [price #f] . rest)
  (define-values (c q p)
    (if (null? rest)
        (values code qty price)
        (values (car rest) (cadr rest) (caddr rest))))
  (action-spec 'grand-exchange-create-sell-order
               (list (hasheq 'code (item-code c) 'quantity q 'price p))))

(define (bid-on-ge #:code [code #f] #:qty [qty #f] #:price [price #f] . rest)
  (define-values (c q p)
    (if (null? rest)
        (values code qty price)
        (values (car rest) (cadr rest) (caddr rest))))
  (action-spec 'grand-exchange-create-buy-order
               (list (hasheq 'code (item-code c) 'quantity q 'price p))))

(define (cancel-order #:order-id [order-id #f] . rest)
  (define i (if (null? rest) order-id (car rest)))
  (action-spec 'grand-exchange-cancel (list (hasheq 'id i))))

(define (fill-order #:order-id [order-id #f] #:qty [qty #f] . rest)
  (define-values (i q)
    (if (null? rest)
        (values order-id qty)
        (values (car rest) (cadr rest))))
  (action-spec 'grand-exchange-fill (list (hasheq 'id i 'quantity q))))

(define (check-events) (action-spec 'active-events '()))

(define (check-raids) (action-spec 'raids '()))

(define (give-gold #:to [to #f] #:qty [qty #f] . rest)
  (define-values (t q)
    (if (null? rest)
        (values to qty)
        (values (car rest) (cadr rest))))
  (action-spec 'give-gold (list (hasheq 'name t 'quantity q))))

(define (give-item #:to [to #f] #:code [code #f] #:qty [qty #f] . rest)
  (define-values (t c q)
    (if (null? rest)
        (values to code qty)
        (values (car rest) (cadr rest) (caddr rest))))
  (action-spec 'give-item (list (hasheq 'name t 'code (item-code c) 'quantity q))))

(define (claim-item id) (action-spec 'claim-item (list id)))

(define (delete-item #:code [code #f] #:qty [qty #f] . rest)
  (define-values (c q)
    (if (null? rest)
        (values code qty)
        (values (car rest) (cadr rest))))
  (action-spec 'delete-item (list (qty-item c q))))

(define (change-skin #:skin [skin #f] . rest)
  (define s (if (null? rest) skin (car rest)))
  (action-spec 'change-skin (list (hasheq 'skin (item-code s)))))
