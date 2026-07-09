#lang racket

(provide (struct-out world-index)
         build-world-index
         maps-with-content
         nearest-content-map)

(struct world-index (maps by-id by-layer by-content) #:transparent)

(define (hash-ref/list hash key)
  (hash-ref hash key '()))

(define (map-field map key)
  (hash-ref map key #f))

(define (json-object? v)
  (and (hash? v) (not (eq? v 'null))))

(define (map-content map)
  (define interactions (map-field map 'interactions))
  (cond
    [(not (json-object? interactions)) #f]
    [else
     (define content (hash-ref interactions 'content #f))
     (and (json-object? content) content)]))

(define (content-code map)
  (define content (map-content map))
  (and content (hash-ref content 'code #f)))

(define (content-type map)
  (define content (map-content map))
  (and content (hash-ref content 'type #f)))

(define (require-map-field map key)
  (define value (map-field map key))
  (unless value
    (error 'build-world-index "map is missing required field ~a: ~v" key map))
  value)

(define (build-world-index maps)
  (define by-id (make-hash))
  (define by-layer (make-hash))
  (define by-content (make-hash))
  (for ([map maps])
    (define map-id (require-map-field map 'map_id))
    (define layer (require-map-field map 'layer))
    (require-map-field map 'x)
    (require-map-field map 'y)
    (hash-set! by-id map-id map)
    (hash-update! by-layer layer (lambda (items) (cons map items)) '())
    (when (content-code map)
      (hash-update! by-content
                    (cons (content-type map) (content-code map))
                    (lambda (items) (cons map items))
                    '())))
  (world-index maps by-id by-layer by-content))

(define (maps-with-content index type code)
  (hash-ref/list (world-index-by-content index) (cons type code)))

(define (manhattan-distance from to)
  (+ (abs (- (map-field from 'x) (map-field to 'x)))
     (abs (- (map-field from 'y) (map-field to 'y)))))

(define (nearest-content-map index from-map type code)
  (define candidates (maps-with-content index type code))
  (and (pair? candidates)
       (argmin (lambda (map) (manhattan-distance from-map map)) candidates)))
