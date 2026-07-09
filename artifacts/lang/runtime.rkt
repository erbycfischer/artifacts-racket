#lang racket

(require "../core.rkt")

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
         known-action?
         execute-action
         execute-goal
         (struct-out bot-spec)
         (struct-out character-spec)
         (struct-out strategy-spec)
         (struct-out goal-spec)
         (struct-out action-spec)
         (all-from-out "../core.rkt"))

(struct bot-spec (name forms) #:transparent)
(struct character-spec (name role forms) #:transparent)
(struct strategy-spec (name forms) #:transparent)
(struct goal-spec (target actions) #:transparent)
(struct action-spec (name payload) #:transparent)

(define known-action-names
  '(move
    transition
    rest
    equip
    unequip
    use
    fight
    gather
    craft
    recycle
    bank-deposit-item
    bank-deposit-gold
    bank-withdraw-item
    bank-withdraw-gold
    bank-buy-expansion
    npc-buy
    npc-sell
    grand-exchange-orders
    grand-exchange-buy
    grand-exchange-create-sell-order
    grand-exchange-create-buy-order
    grand-exchange-cancel
    grand-exchange-fill
    task-new
    task-complete
    task-cancel
    task-exchange
    task-trade
    give-gold
    give-item
    claim-item
    delete-item
    change-skin
    active-events
    raids))

(define (known-action? name)
  (and (symbol? name) (memq name known-action-names) #t))

(define (validate-action-form who form)
  (unless (action-spec? form)
    (error who "expected action form, got ~v" form))
  form)

(define (validate-character-form form)
  (unless (or (goal-spec? form) (action-spec? form))
    (error 'character "expected goal or action form, got ~v" form))
  form)

(define (validate-bot-form form)
  (unless (or (character-spec? form) (strategy-spec? form))
    (error 'bot "expected character or strategy form, got ~v" form))
  form)

(define (make-bot-spec name forms)
  (bot-spec name (map validate-bot-form forms)))

(define (make-character-spec name role forms)
  (character-spec name role (map validate-character-form forms)))

(define (make-strategy-spec name forms)
  (strategy-spec name (map (lambda (form) (validate-action-form 'strategy form)) forms)))

(define-syntax-rule (artifacts-module-begin form ...)
  (#%module-begin form ...))

(define-syntax-rule (bot name form ...)
  (begin
    (provide name)
    (define name (make-bot-spec 'name (list form ...)))))

(define-syntax-rule (character name #:role role form ...)
  (make-character-spec 'name role (list form ...)))

(define-syntax-rule (strategy name form ...)
  (make-strategy-spec 'name (list form ...)))

(define (goal target . body)
  (unless (symbol? target)
    (error 'goal "expected symbolic target, got ~v" target))
  (goal-spec target (map (lambda (form) (validate-action-form 'goal form)) body)))

(define (action name . payload)
  (unless (symbol? name)
    (error 'action "expected symbolic action name, got ~v" name))
  (unless (known-action? name)
    (error 'action "unknown Artifacts action ~v" name))
  (action-spec name payload))

(define (first-payload spec [default #hasheq()])
  (define payload (action-spec-payload spec))
  (if (pair? payload) (car payload) default))

(define (move-action character-name spec config)
  (define payload (first-payload spec))
  (cond
    [(hash-has-key? payload 'map_id)
     (action-move character-name #:map-id (hash-ref payload 'map_id) #:config config)]
    [(and (hash-has-key? payload 'x) (hash-has-key? payload 'y))
     (action-move character-name
                  #:x (hash-ref payload 'x)
                  #:y (hash-ref payload 'y)
                  #:config config)]
    [else
     (error 'execute-action "move requires payload with map_id or x/y, got ~v" payload)]))

(define (execute-action character-name spec #:config [config (current-config)])
  (validate-action-form 'execute-action spec)
  (case (action-spec-name spec)
    [(move) (move-action character-name spec config)]
    [(transition) (action-transition character-name #:config config)]
    [(rest) (action-rest character-name #:config config)]
    [(equip) (action-equip character-name (first-payload spec '()) #:config config)]
    [(unequip) (action-unequip character-name (first-payload spec '()) #:config config)]
    [(use) (action-use character-name (first-payload spec) #:config config)]
    [(fight) (action-fight character-name #:participants (first-payload spec '()) #:config config)]
    [(gather) (action-gather character-name #:config config)]
    [(craft) (action-craft character-name (first-payload spec) #:config config)]
    [(recycle) (action-recycle character-name (first-payload spec) #:config config)]
    [(bank-deposit-item) (action-bank-deposit-item character-name (first-payload spec '()) #:config config)]
    [(bank-deposit-gold) (action-bank-deposit-gold character-name (first-payload spec 0) #:config config)]
    [(bank-withdraw-item) (action-bank-withdraw-item character-name (first-payload spec '()) #:config config)]
    [(bank-withdraw-gold) (action-bank-withdraw-gold character-name (first-payload spec 0) #:config config)]
    [(bank-buy-expansion) (action-bank-buy-expansion character-name #:config config)]
    [(npc-buy) (action-npc-buy character-name (first-payload spec) #:config config)]
    [(npc-sell) (action-npc-sell character-name (first-payload spec) #:config config)]
    [(grand-exchange-buy) (action-grand-exchange-buy character-name (first-payload spec) #:config config)]
    [(grand-exchange-create-sell-order) (action-grand-exchange-create-sell-order character-name (first-payload spec) #:config config)]
    [(grand-exchange-create-buy-order) (action-grand-exchange-create-buy-order character-name (first-payload spec) #:config config)]
    [(grand-exchange-cancel) (action-grand-exchange-cancel character-name (first-payload spec) #:config config)]
    [(grand-exchange-fill) (action-grand-exchange-fill character-name (first-payload spec) #:config config)]
    [(task-new) (action-task-new character-name #:config config)]
    [(task-complete) (action-task-complete character-name #:config config)]
    [(task-cancel) (action-task-cancel character-name #:config config)]
    [(task-exchange) (action-task-exchange character-name #:config config)]
    [(task-trade) (action-task-trade character-name (first-payload spec) #:config config)]
    [(give-gold) (action-give-gold character-name (first-payload spec) #:config config)]
    [(give-item) (action-give-item character-name (first-payload spec) #:config config)]
    [(claim-item) (action-claim-item character-name (first-payload spec) #:config config)]
    [(delete-item) (action-delete-item character-name (first-payload spec) #:config config)]
    [(change-skin) (action-change-skin character-name (first-payload spec) #:config config)]
    [(grand-exchange-orders) (get-grand-exchange-orders #:config config)]
    [(active-events) (get-active-events #:config config)]
    [(raids) (get-raids #:config config)]
    [else (error 'execute-action "unknown Artifacts action ~v" (action-spec-name spec))]))

(define (execute-goal character-name spec #:config [config (current-config)])
  (unless (goal-spec? spec)
    (error 'execute-goal "expected goal spec, got ~v" spec))
  (for/list ([item (goal-spec-actions spec)])
    (execute-action character-name item #:config config)))
