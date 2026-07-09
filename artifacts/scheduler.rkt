#lang racket

(provide (struct-out job)
         (struct-out character-runtime)
         make-job
         job-ready?
         next-ready-jobs
         soonest-ready-at
         suggested-wait-seconds)

(struct job (character action payload ready-at priority) #:transparent)
(struct character-runtime (name cooldown-expiration current-job) #:transparent)

(define (make-job #:character character
                  #:action action
                  #:payload [payload #hasheq()]
                  #:ready-at [ready-at (current-seconds)]
                  #:priority [priority 0])
  (job character action payload ready-at priority))

(define (job-ready? item [now (current-seconds)])
  (<= (job-ready-at item) now))

(define (next-ready-jobs jobs [now (current-seconds)])
  (sort (filter (lambda (item) (job-ready? item now)) jobs)
        >
        #:key job-priority))

(define (soonest-ready-at jobs [now (current-seconds)])
  (define future
    (for/list ([item jobs]
               #:when (and (job? item)
                           (> (job-ready-at item) now)))
      (job-ready-at item)))
  (and (pair? future) (apply min future)))

;; Clamp wait so the loop stays responsive for visualizer publishes.
(define (suggested-wait-seconds jobs
                                #:now [now (current-seconds)]
                                #:min-seconds [min-seconds 1]
                                #:max-seconds [max-seconds 15]
                                #:default-seconds [default-seconds 2])
  (define ready-at (soonest-ready-at jobs now))
  (cond
    [(not ready-at) default-seconds]
    [else
     (define wait (- ready-at now))
     (max min-seconds (min max-seconds wait))]))
