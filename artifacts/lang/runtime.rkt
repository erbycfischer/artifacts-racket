#lang racket

(require "../core.rkt"
         "../dispatch.rkt"
         "../dsl-forms.rkt"
         "../http.rkt"
         "../planner.rkt"
         "../runner.rkt"
         "./actions.rkt"
         "./helpers.rkt"
         (for-syntax syntax/parse))

(provide (rename-out [artifacts-module-begin #%module-begin])
         (except-out (all-from-out racket) #%module-begin)
         bot
         character
         strategy
         goal
         action
         guard
         guard?
         repeat
         loop
         pipeline
         routine
         known-action?
         execute-action
         execute-goal
         create-character
         ensure-characters
         play
         (all-from-out "./actions.rkt")
         (all-from-out "./helpers.rkt")
         (all-from-out "../dsl-forms.rkt")
         (all-from-out "../core.rkt")
         (all-from-out "../runner.rkt"))

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
  (unless (or (goal-spec? form) (action-spec? form) (guard-spec? form))
    (error 'character "expected goal, action, or guard form, got ~v" form))
  form)

(define (validate-bot-form form)
  (unless (or (character-spec? form) (strategy-spec? form))
    (error 'bot "expected character or strategy form, got ~v" form))
  form)

(define (make-bot-spec name forms)
  (bot-spec name (map validate-bot-form forms)))

(define (ensure-action-spec who form)
  (if (action-spec? form)
      form
      (validate-action-form who form)))

(define (make-character-spec tag role account-name forms)
  (character-spec tag
                  role
                  (normalize-account-name account-name)
                  (map validate-character-form forms)))

(define (make-strategy-spec name forms)
  (strategy-spec name (map (lambda (form) (ensure-action-spec 'strategy form)) forms)))

(define-syntax-rule (artifacts-module-begin form ...)
  (#%module-begin form ...))

(define-syntax-rule (bot name form ...)
  (begin
    (provide name)
    (define name (make-bot-spec 'name (list form ...)))))

(define-syntax (character stx)
  (syntax-parse stx
    [(character tag #:role role #:as account-name form ...)
     #'(make-character-spec 'tag 'role account-name (list form ...))]
    [(character tag #:role role form ...)
     #'(make-character-spec 'tag 'role #f (list form ...))]))

;; Guard a body of action/goal forms behind a predicate. At decision time the
;; predicate is applied to the live character; only when it answers true do the
;; wrapped forms reach the planner. The predicate runs per-tick, not at bot
;; definition time, so it sees the freshest character state.
(define-syntax (guard stx)
  (syntax-parse stx
    [(_ #:when predicate body ...)
     #'(guard-spec (lambda (char) predicate) (list body ...))]
    [(_ predicate body ...)
     #'(guard-spec (lambda (char) predicate) (list body ...))]))

;; Repeat a body of forms n times, useful for "do this N times then stop".
(define-syntax (repeat stx)
  (syntax-parse stx
    [(_ n body ...)
     #'(apply append (build-list n (lambda (_) (list body ...))))]))

;; Reactive goal conditions. Each expands to a guard whose predicate is one of
;; the planner's condition helpers, applied to the live character at decision
;; time. They let a goal body stay dormant until the world warrants the action:
;;
;;   (when-low-hp 0.5 (rest))              ; rest only while hurt
;;   (when-inventory-full (deposit-all))   ; bank only when full
;;   (when-on-content "bank" (deposit-all)); deposit only standing at the bank
;;
;; They are thin syntax over guard-spec, so they compose with repeat/loop and
;; resolve through the same expand-guards path as plain guards.
(define-syntax (when-low-hp stx)
  (syntax-parse stx
    [(_ ratio body ...)
     #'(guard-spec (lambda (char) (when-low-hp char ratio)) (list body ...))]))

(define-syntax (when-inventory-full stx)
  (syntax-parse stx
    [(_ #:reserve reserve body ...)
     #'(guard-spec (lambda (char) (when-inventory-full char #:reserve reserve)) (list body ...))]
    [(_ body ...)
     #'(guard-spec (lambda (char) (when-inventory-full char)) (list body ...))]))

(define-syntax (when-on-content stx)
  (syntax-parse stx
    [(_ type #:code code body ...)
     #'(guard-spec (lambda (char) (when-on-content char type code)) (list body ...))]
    [(_ type code body ...)
     #'(guard-spec (lambda (char) (when-on-content char type code)) (list body ...))]
    [(_ type body ...)
     #'(guard-spec (lambda (char) (when-on-content char type)) (list body ...))]))

(define (pipeline name . actions)
  (unless (symbol? name)
    (error 'pipeline "expected symbolic pipeline name, got ~v" name))
  (apply goal name actions))

(define loop pipeline)
(define routine pipeline)

(define-syntax-rule (strategy name form ...)
  (make-strategy-spec 'name (list form ...)))

(define (goal target . body)
  (unless (symbol? target)
    (error 'goal "expected symbolic target, got ~v" target))
  (goal-spec target (map (lambda (form) (ensure-goal-form 'goal form)) body)))

;; A goal body may mix plain actions and guards/conditionals. Both are kept as
;; specs; expand-guards resolves the guards against the live character later.
(define (ensure-goal-form who form)
  (cond
    [(guard-spec? form) form]
    [else (ensure-action-spec who form)]))

(define (action name . payload)
  (unless (symbol? name)
    (error 'action "expected symbolic action name, got ~v" name))
  (unless (known-action? name)
    (error 'action "unknown Artifacts action ~v" name))
  (action-spec name payload))

(define (first-payload spec [default #hasheq()])
  (define payload (action-spec-payload spec))
  (if (pair? payload) (car payload) default))

(define (payload-for-dispatch spec)
  (define name (action-spec-name spec))
  (define raw (action-spec-payload spec))
  (case name
    [(gather rest transition task-new task-complete task-cancel task-exchange
            bank-buy-expansion grand-exchange-orders active-events raids)
     #f]
    [(fight equip unequip bank-deposit-item bank-withdraw-item)
     (if (null? raw) '() (car raw))]
    [(bank-deposit-gold bank-withdraw-gold claim-item)
     (if (null? raw) 0 (car raw))]
    [else (if (null? raw) #hasheq() (car raw))]))

(define (execute-action character-name spec #:config [config (current-config)])
  (validate-action-form 'execute-action spec)
  (dispatch-action-name character-name
                        (action-spec-name spec)
                        (payload-for-dispatch spec)
                        #:config config))

(define (execute-goal character-name spec #:config [config (current-config)] #:char [char #f])
  (unless (goal-spec? spec)
    (error 'execute-goal "expected goal spec, got ~v" spec))
  (for/list ([item (expand-guards (goal-spec-actions spec) char)])
    (execute-action character-name item #:config config)))

(define (ensure-characters bot
                           #:config [config (current-config)]
                           #:skin [skin "men1"]
                           #:skins [skins #hasheq()]
                           #:dry-run? [dry-run? #f])
  (ensure-bot-characters bot
                         #:config config
                         #:skin skin
                         #:skins skins
                         #:dry-run? dry-run?))

(define (play bot
              #:config [config (current-config)]
              #:iterations [iterations +inf.0]
              #:sleep-seconds [sleep-seconds 2]
              #:dry-run? [dry-run? #f]
              #:ensure-characters? [ensure-characters? #f]
              #:skin [skin "men1"]
              #:skins [skins #hasheq()])
  (run-bot-loop bot
                #:config config
                #:iterations iterations
                #:sleep-seconds sleep-seconds
                #:dry-run? dry-run?
                #:ensure-characters? ensure-characters?
                #:skin skin
                #:skins skins))
