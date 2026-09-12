#lang racket

;; Combat and task-board helpers. hunt pins a monster; farm-xp is the combat
;; auto-level alias; ruthless-grind fights the best safe monster and banks
;; classified loot; task-loop cycles the task master while the role default
;; keeps fighting/gathering when no task step is actionable.

(require "../../dsl-forms.rkt"
         "../../planner.rkt"
         "../../game-data.rkt"
         "../actions.rkt"
         "logistics.rkt")

(provide hunt
         farm-xp
         task-loop
         ruthless-grind)

(define (bank-when-full-guard)
  (guard-spec (lambda (char) (when-inventory-full char))
              (list (deposit-all))))

;; Fight a specific monster, rest on low HP, bank when the bag fills. The
;; planner walks to that monster's tile; the rest guard sits first so a hurt
;; character recovers before the next pull.
(define (hunt #:code monster-code #:max-hp-ratio [ratio 0.5])
  (goal-spec 'hunt
             (list (guard-spec (lambda (char) (when-low-hp char ratio))
                               (list (rest)))
                   (action-spec 'fight (list (hasheq 'code (item-code monster-code))))
                   (bank-when-full-guard))))

;; Alias of auto-level for combat: grind toward `target` level, resting when
;; hurt and banking when full, then go dormant once the level is reached.
(define (farm-xp #:target level #:max-hp-ratio [ratio 0.5])
  (guard-spec (lambda (char) (when-below-level char level))
              (list (goal-spec 'combat-loop
                               (list (guard-spec (lambda (char) (when-low-hp char ratio))
                                                 (list (rest)))
                                     (fight)
                                     (bank-when-full-guard))))))

;; Cycle the task board: complete, exchange rewards, then accept a new task.
;; All three steps wait for a tasks_master or NPC tile so the planner can
;; route there; when none of the steps is actionable the role default keeps
;; the character on its combat/gather loop.
(define (task-loop #:max-hp-ratio [ratio 0.5])
  (goal-spec 'task-loop
             (list (guard-spec (lambda (char)
                                 (or (when-on-content char "tasks_master")
                                     (when-on-content char "npc")))
                               (list (task-complete) (task-exchange) (task-start)))
                   (guard-spec (lambda (char) (when-low-hp char ratio))
                               (list (rest))))))

;; Fight the highest safe monster for the character's current combat level
;; (planner `best-safe-monster` — the target climbs as the fighter does).
;; Classified loot is banked, never NPC-sold; rares stay in the rare bucket.
;; expand-guards / plan-from-preferred take the *last* body form first, so
;; classified deposits sit after fight — otherwise fight always plans and
;; raw_chicken never reaches the smith.
;;
;;   (ruthless-grind)
;;   (ruthless-grind #:soft soft-loot-codes #:rare rare-loot-codes)
(define (ruthless-grind #:max-hp-ratio [ratio 0.5]
                        #:reserve [reserve 1]
                        #:soft [soft soft-loot-codes]
                        #:premium [premium premium-loot-codes]
                        #:rare [rare rare-loot-codes])
  (define classified
    (goal-spec-actions
     (bank-classified-loot #:soft soft #:premium premium #:rare rare)))
  (goal-spec 'ruthless-grind
             (append (list (guard-spec (lambda (char) (when-low-hp char ratio))
                                       (list (rest)))
                           (fight)
                           (guard-spec (lambda (char)
                                         (when-inventory-full char #:reserve reserve))
                                       (list (deposit-all))))
                     classified)))
