#lang racket

(require "world.rkt")

(provide (struct-out planned-action)
         character-field
         inventory-items
         inventory-used
         inventory-full?
         hp-ratio
         cooldown-ready?
         cooldown-remaining
         content-at-character
         on-content?
         nearest-typed-content
         plan-character
         best-safe-monster
         best-gather-resource
         role-skill)

(struct planned-action (name payload reason priority) #:transparent)

(define (character-field char key [default #f])
  (if (hash? char) (hash-ref char key default) default))

(define (inventory-items char)
  (define inv (character-field char 'inventory '()))
  (if (list? inv) inv '()))

(define (inventory-used char)
  (for/sum ([slot (inventory-items char)])
    (if (hash? slot) (hash-ref slot 'quantity 0) 0)))

(define (inventory-full? char #:reserve [reserve 1])
  (define max-items (character-field char 'inventory_max_items 0))
  (>= (inventory-used char) (max 0 (- max-items reserve))))

(define (hp-ratio char)
  (define hp (character-field char 'hp 0))
  (define max-hp (character-field char 'max_hp 1))
  (if (zero? max-hp) 0 (/ hp max-hp)))

(define (parse-cooldown-expiration value now)
  (cond
    [(and (number? value) (> value 1000000000)) value] ; unix seconds
    [(and (number? value) (>= value 0)) (+ now value)] ; relative seconds mistaken as expiration
    [(string? value)
     ;; Accept ISO-ish "YYYY-MM-DDTHH:MM:SSZ" by falling back to remaining field only.
     #f]
    [else #f]))

(define (cooldown-remaining char [now (current-seconds)])
  (define remaining (character-field char 'cooldown 0))
  (define expiration (parse-cooldown-expiration
                      (character-field char 'cooldown_expiration #f)
                      now))
  (define from-remaining
    (if (and (number? remaining) (> remaining 0)) remaining 0))
  (define from-expiration
    (if expiration (max 0 (- expiration now)) 0))
  (max from-remaining from-expiration))

(define (cooldown-ready? char [now (current-seconds)])
  (<= (cooldown-remaining char now) 0))

(define (content-at-character char)
  (define interactions (character-field char 'interactions #f))
  (cond
    [(hash? interactions) (hash-ref interactions 'content #f)]
    [else #f]))

(define (on-content? char type [code #f])
  (define content (content-at-character char))
  (and (hash? content)
       (equal? (hash-ref content 'type #f) type)
       (or (not code) (equal? (hash-ref content 'code #f) code))))

(define (character-map char)
  (hasheq 'map_id (character-field char 'map_id)
          'layer (character-field char 'layer)
          'x (character-field char 'x)
          'y (character-field char 'y)))

(define (role-skill role)
  (case role
    [(mining) 'mining]
    [(woodcutting) 'woodcutting]
    [(fishing) 'fishing]
    [(alchemy) 'alchemy]
    [else #f]))

(define (skill-level char skill)
  (case skill
    [(mining) (character-field char 'mining_level 1)]
    [(woodcutting) (character-field char 'woodcutting_level 1)]
    [(fishing) (character-field char 'fishing_level 1)]
    [(alchemy) (character-field char 'alchemy_level 1)]
    [else 1]))

(define (depositable-items char)
  (for/list ([slot (inventory-items char)]
             #:when (and (hash? slot)
                         (hash-ref slot 'code #f)
                         (positive? (hash-ref slot 'quantity 0))))
    (hasheq 'code (hash-ref slot 'code)
            'quantity (hash-ref slot 'quantity))))

(define (move-to map reason #:priority [priority 50])
  (planned-action 'move
                  (hasheq 'map_id (hash-ref map 'map_id))
                  reason
                  priority))

(define (best-safe-monster char monsters)
  (define level (character-field char 'level 1))
  (define candidates
    (for/list ([monster monsters]
               #:when (and (hash? monster)
                           (<= (hash-ref monster 'level 999) (+ level 1))))
      monster))
  (and (pair? candidates)
       (argmax (lambda (monster) (hash-ref monster 'level 0)) candidates)))

(define (resource-matches-skill? resource skill)
  (define skill-value (hash-ref resource 'skill #f))
  (or (equal? skill-value skill)
      (equal? skill-value (symbol->string skill))))

(define (best-gather-resource char resources skill)
  (define level (skill-level char skill))
  (define candidates
    (for/list ([resource resources]
               #:when (and (hash? resource)
                           (resource-matches-skill? resource skill)
                           (<= (hash-ref resource 'level 999) level)))
      resource))
  (and (pair? candidates)
       (argmax (lambda (resource) (hash-ref resource 'level 0)) candidates)))

(define (nearest-typed-content world char type)
  (define from (character-map char))
  (define nodes
    (filter (lambda (map)
              (define interactions (hash-ref map 'interactions #f))
              (define content (and interactions (hash-ref interactions 'content #f)))
              (and (hash? content) (equal? (hash-ref content 'type #f) type)))
            (world-index-maps world)))
  (and (pair? nodes)
       (argmin (lambda (map)
                 (+ (abs (- (hash-ref from 'x 0) (hash-ref map 'x 0)))
                    (abs (- (hash-ref from 'y 0) (hash-ref map 'y 0)))))
               nodes)))

(define (plan-bank-trip char world)
  (cond
    [(on-content? char "bank")
     (define items (depositable-items char))
     (and (pair? items)
          (planned-action 'bank-deposit-item items "Deposit loot before continuing." 90))]
    [else
     (define bank (nearest-typed-content world char "bank"))
     (and bank (move-to bank "Travel to bank; inventory is tight." #:priority 85))]))

(define (plan-combat char world monsters)
  (define monster (best-safe-monster char monsters))
  (cond
    [(not monster) #f]
    [(on-content? char "monster" (hash-ref monster 'code #f))
     (planned-action 'fight '() (format "Fight ~a for XP and loot." (hash-ref monster 'code)) 70)]
    [else
     (define target
       (nearest-content-map world (character-map char) "monster" (hash-ref monster 'code)))
     (and target
          (move-to target
                   (format "Move to ~a (level ~a)."
                           (hash-ref monster 'code)
                           (hash-ref monster 'level))
                   #:priority 65))]))

(define (plan-gather char world resources skill)
  (define resource (best-gather-resource char resources skill))
  (cond
    [(not resource) #f]
    [(on-content? char "resource" (hash-ref resource 'code #f))
     (planned-action 'gather '() (format "Gather ~a." (hash-ref resource 'code)) 70)]
    [else
     (define target
       (nearest-content-map world (character-map char) "resource" (hash-ref resource 'code)))
     (and target
          (move-to target
                   (format "Move to ~a for ~a."
                           (hash-ref resource 'code)
                           skill)
                   #:priority 65))]))

(define (plan-trade char world)
  (cond
    [(on-content? char "grand_exchange")
     (planned-action 'grand-exchange-orders
                     '()
                     "Scan Grand Exchange spreads while at the market."
                     55)]
    [else
     (define ge (nearest-typed-content world char "grand_exchange"))
     (and ge (move-to ge "Travel to Grand Exchange for trading." #:priority 50))]))

(define (plan-event-intercept char world events)
  (define active (if (list? events) events '()))
  (define from (character-map char))
  (define scored
    (for/list ([event active]
               #:when (hash? event))
      (define map (hash-ref event 'map #f))
      (and (hash? map)
           (cons (+ (abs (- (hash-ref from 'x 0) (hash-ref map 'x 0)))
                    (abs (- (hash-ref from 'y 0) (hash-ref map 'y 0))))
                 map))))
  (define valid (filter values scored))
  (and (pair? valid)
       (let* ([best (argmin car valid)]
              [distance (car best)]
              [map (cdr best)])
         (and (<= distance 12)
              (move-to map "Intercept nearby active event." #:priority 80)))))

(define (plan-character char
                        world
                        #:role role
                        #:monsters [monsters '()]
                        #:resources [resources '()]
                        #:events [events '()])
  (cond
    [(not (cooldown-ready? char))
     #f]
    [(< (hp-ratio char) 0.45)
     (planned-action 'rest '() "Recover HP before the next fight." 100)]
    [(inventory-full? char #:reserve 2)
     (plan-bank-trip char world)]
    [(plan-event-intercept char world events)]
    [else
     (case role
       [(combat fighter)
        (or (plan-combat char world monsters)
            (plan-bank-trip char world))]
       [(mining woodcutting fishing alchemy gatherer)
        (define skill (or (role-skill role) 'mining))
        (or (plan-gather char world resources skill)
            (plan-bank-trip char world))]
       [(trader market)
        (or (plan-trade char world)
            (plan-bank-trip char world))]
       [else
        (or (plan-combat char world monsters)
            (plan-gather char world resources 'mining))])]))
