#lang racket

;; One-shot official-API roster watch. Polls /my/characters and /my/logs so
;; a live harmony run can be observed without the 3D client.
;;
;;   racket tools/watch-roster.rkt
;;
;; Auth is the same cascade as the bot (bridge -> ~/.artifacts/token -> env).
;; Never prints the token. Writes a human snapshot to logs/roster-watch.txt.

(require artifacts/auth
         artifacts/http
         artifacts/planner
         racket/string)

(current-config (make-bridge-config))

(define repo-root
  (simplify-path (build-path (path-only (path->complete-path (find-system-path 'run-file))) "..")))

(define snapshot-path (build-path repo-root "logs" "roster-watch.txt"))

(define (jget h key [default #f])
  (if (hash? h) (hash-ref h key default) default))

(define (response-rows response)
  (define data (jget response 'data '()))
  (if (list? data) data '()))

(define (safe-call thunk [fallback #f])
  (with-handlers ([exn:fail:artifacts-api?
                   (lambda (exn)
                     (define err (exn:fail:artifacts-api-error exn))
                     (eprintf "watch-roster: API ~a ~a\n"
                              (api-error-code err)
                              (api-error-message err))
                     fallback)]
                  [exn:fail?
                   (lambda (exn)
                     (eprintf "watch-roster: ~a\n" (exn-message exn))
                     fallback)])
    (thunk)))

(define (bag-summary char [n 4])
  (define slots
    (sort (filter (lambda (slot)
                    (and (hash? slot) (positive? (hash-ref slot 'quantity 0))))
                  (inventory-items char))
          >
          #:key (lambda (slot) (hash-ref slot 'quantity 0))))
  (if (null? slots)
      "-"
      (string-join
       (for/list ([slot (in-list slots)] [_ (in-range n)])
         (format "~a×~a" (hash-ref slot 'code "?") (hash-ref slot 'quantity 0)))
       " ")))

(define (task-summary char)
  (define task (jget char 'task #f))
  (cond
    [(and (hash? task) (jget task 'code #f))
     (format "~a ~a/~a"
             (jget task 'code "?")
             (jget char 'task_progress (jget task 'progress 0))
             (jget char 'task_total (jget task 'total 0)))]
    [(and (string? task) (non-empty-string? task)) task]
    [else "-"]))

(define (log-line entry)
  (define who (or (jget entry 'character) (jget entry 'name) "?"))
  (define kind (or (jget entry 'type) (jget entry 'action_type) (jget entry 'action) "?"))
  (define desc (or (jget entry 'description) (jget entry 'log) (jget entry 'message) ""))
  (define when (or (jget entry 'created_at) (jget entry 'createdAt) ""))
  (string-trim (format "~a  ~a  ~a  ~a" when who kind desc)))

(define (format-character char)
  (format "~a  lv~a  hp ~a/~a  @~a,~a  gold ~a  bag ~a/~a  cd ~as  task ~a  ~a"
          (jget char 'name "?")
          (jget char 'level 0)
          (jget char 'hp 0)
          (jget char 'max_hp 0)
          (jget char 'x 0)
          (jget char 'y 0)
          (jget char 'gold 0)
          (inventory-used char)
          (jget char 'inventory_max_items 0)
          (cooldown-remaining char)
          (task-summary char)
          (bag-summary char)))

(define chars-response (safe-call (lambda () (get-my-characters #:size 50))))
(define logs-response (safe-call (lambda () (get-account-logs #:size 20))))
(define balance-response (safe-call (lambda () (get-my-balance))))

(define characters (response-rows chars-response))
(define logs (response-rows logs-response))
(define bank-gold
  (cond
    [(hash? balance-response)
     (or (jget (jget balance-response 'data balance-response) 'gold)
         (jget (jget balance-response 'data balance-response) 'balance)
         "-")]
    [else "-"]))

(define stamp
  (parameterize ([date-display-format 'iso-8601])
    (date->string (seconds->date (current-seconds) #f) #t)))

(define body
  (string-append
   (format "watch-roster ~a  bank/gold ~a  chars ~a\n" stamp bank-gold (length characters))
   (if (null? characters)
       "  (no characters — missing token or empty account)\n"
       (string-join (for/list ([char characters])
                      (string-append "  " (format-character char) "\n"))
                    ""))
   "recent logs:\n"
   (if (null? logs)
       "  (none)\n"
       (string-join (for/list ([entry logs])
                      (string-append "  " (log-line entry) "\n"))
                    ""))))

(make-directory* (build-path repo-root "logs"))
(call-with-output-file snapshot-path
  (lambda (out) (display body out))
  #:exists 'truncate)

(display body)
(flush-output)
