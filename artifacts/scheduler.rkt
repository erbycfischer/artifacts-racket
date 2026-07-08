#lang racket

(provide (struct-out job)
         (struct-out character-runtime)
         make-job
         job-ready?
         next-ready-jobs)

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
