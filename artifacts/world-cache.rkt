#lang racket

(require json
         racket/file
         "config.rkt"
         "http.rkt"
         "world.rkt")

(provide response-data
         fetch-all-pages
         load-world-index
         load-encyclopedia)

(define (response-data response)
  (cond
    [(and (hash? response) (hash-has-key? response 'data))
     (hash-ref response 'data)]
    [else response]))

(define (fetch-all-pages getter #:config [config (current-config)] #:size [size 100])
  (let loop ([page 1] [acc '()])
    (define response (getter #:page page #:size size #:config config))
    (define data (response-data response))
    (define items (if (list? data) data '()))
    (define pages (and (hash? response) (hash-ref response 'pages #f)))
    (define next (append acc items))
    (cond
      [(or (null? items)
           (and (number? pages) (>= page pages))
           (< (length items) size))
       next]
      [else (loop (add1 page) next)])))

(define world-cache-seconds
  (let ([v (getenv "ARTIFACTS_WORLD_CACHE_SECONDS")])
    (or (and v (string->number v)) 900)))

(define (world-cache-path)
  (define root (or (getenv "ARTIFACTS_CACHE_DIR")
                   (build-path (find-system-path 'temp-dir) "artifacts-racket-cache")))
  (make-directory* root)
  (build-path root "world-maps.json"))

(define (read-world-cache)
  (define path (world-cache-path))
  (and (file-exists? path)
       (< (- (current-seconds) (file-or-directory-modify-seconds path))
          world-cache-seconds)
       (with-handlers ([exn:fail? (lambda (_exn) #f)])
         (define data (call-with-input-file path read-json))
         (and (list? data) (pair? data) data))))

(define (write-world-cache! maps)
  (with-handlers ([exn:fail? (lambda (_exn) (void))])
    (call-with-output-file (world-cache-path)
      (lambda (out) (write-json maps out))
      #:exists 'replace)))

(define (load-world-index #:config [config (current-config)]
                          #:use-cache? [use-cache? #t])
  (define maps
    (or (and use-cache? (read-world-cache))
        (let ([fresh (fetch-all-pages get-maps #:config config #:size 100)])
          (when use-cache?
            (write-world-cache! fresh))
          fresh)))
  (build-world-index maps))

(define encyclopedia-cache-seconds
  (let ([v (getenv "ARTIFACTS_ENCYCLOPEDIA_CACHE_SECONDS")])
    (or (and v (string->number v)) 900)))

(define (encyclopedia-cache-path)
  (define root (or (getenv "ARTIFACTS_CACHE_DIR")
                   (build-path (find-system-path 'temp-dir) "artifacts-racket-cache")))
  (make-directory* root)
  (build-path root "encyclopedia.json"))

(define (read-encyclopedia-cache)
  (define path (encyclopedia-cache-path))
  (and (file-exists? path)
       (< (- (current-seconds) (file-or-directory-modify-seconds path))
          encyclopedia-cache-seconds)
       (with-handlers ([exn:fail? (lambda (_exn) #f)])
         (define data (call-with-input-file path read-json))
         (and (hash? data)
              (hash-has-key? data 'monsters)
              (hash-has-key? data 'resources)
              data))))

(define (write-encyclopedia-cache! data)
  (with-handlers ([exn:fail? (lambda (_exn) (void))])
    (call-with-output-file (encyclopedia-cache-path)
      (lambda (out) (write-json data out))
      #:exists 'replace)))

(define (load-encyclopedia #:config [config (current-config)]
                           #:use-cache? [use-cache? #t])
  (or (and use-cache? (read-encyclopedia-cache))
      (let ([fresh (hasheq 'monsters (fetch-all-pages get-monsters #:config config)
                           'resources (fetch-all-pages get-resources #:config config)
                           'items (fetch-all-pages get-items #:config config))])
        (when use-cache?
          (write-encyclopedia-cache! fresh))
        fresh)))
