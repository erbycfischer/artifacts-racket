#lang racket

(require "config.rkt"
         "http.rkt")

(provide dispatch-action-name)

(define (dispatch-action-name character-name action-name payload #:config [config (current-config)])
  (case action-name
    [(move)
     (cond
       [(and (hash? payload) (hash-has-key? payload 'map_id))
        (action-move character-name #:map-id (hash-ref payload 'map_id) #:config config)]
       [(and (hash? payload) (hash-has-key? payload 'x) (hash-has-key? payload 'y))
        (action-move character-name
                     #:x (hash-ref payload 'x)
                     #:y (hash-ref payload 'y)
                     #:config config)]
       [else (error 'dispatch-action-name "move payload needs map_id or x/y, got ~v" payload)])]
    [(transition) (action-transition character-name #:config config)]
    [(rest) (action-rest character-name #:config config)]
    [(equip) (action-equip character-name (if (list? payload) payload '()) #:config config)]
    [(unequip) (action-unequip character-name (if (list? payload) payload '()) #:config config)]
    [(use) (action-use character-name payload #:config config)]
    [(fight) (action-fight character-name #:participants (if (list? payload) payload '()) #:config config)]
    [(gather) (action-gather character-name #:config config)]
    [(craft) (action-craft character-name payload #:config config)]
    [(recycle) (action-recycle character-name payload #:config config)]
    [(bank-deposit-item) (action-bank-deposit-item character-name (if (list? payload) payload '()) #:config config)]
    [(bank-deposit-gold) (action-bank-deposit-gold character-name (if (number? payload) payload 0) #:config config)]
    [(bank-withdraw-item) (action-bank-withdraw-item character-name (if (list? payload) payload '()) #:config config)]
    [(bank-withdraw-gold) (action-bank-withdraw-gold character-name (if (number? payload) payload 0) #:config config)]
    [(bank-buy-expansion) (action-bank-buy-expansion character-name #:config config)]
    [(npc-buy) (action-npc-buy character-name payload #:config config)]
    [(npc-sell) (action-npc-sell character-name payload #:config config)]
    [(grand-exchange-buy) (action-grand-exchange-buy character-name payload #:config config)]
    [(grand-exchange-create-sell-order) (action-grand-exchange-create-sell-order character-name payload #:config config)]
    [(grand-exchange-create-buy-order) (action-grand-exchange-create-buy-order character-name payload #:config config)]
    [(grand-exchange-cancel) (action-grand-exchange-cancel character-name payload #:config config)]
    [(grand-exchange-fill) (action-grand-exchange-fill character-name payload #:config config)]
    [(task-new) (action-task-new character-name #:config config)]
    [(task-complete) (action-task-complete character-name #:config config)]
    [(task-cancel) (action-task-cancel character-name #:config config)]
    [(task-exchange) (action-task-exchange character-name #:config config)]
    [(task-trade) (action-task-trade character-name payload #:config config)]
    [(give-gold) (action-give-gold character-name payload #:config config)]
    [(give-item) (action-give-item character-name payload #:config config)]
    [(claim-item) (action-claim-item character-name payload #:config config)]
    [(delete-item) (action-delete-item character-name payload #:config config)]
    [(change-skin) (action-change-skin character-name payload #:config config)]
    [(grand-exchange-orders) (get-grand-exchange-orders #:config config)]
    [(active-events) (get-active-events #:config config)]
    [(raids) (get-raids #:config config)]
    [else (error 'dispatch-action-name "unsupported action ~v" action-name)]))
