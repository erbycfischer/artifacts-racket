#lang racket

(require json
         net/uri-codec
         net/url
         racket/string
         "config.rkt")

(provide api-get
         api-post
         get-server-details
         get-maps
         get-items
         get-monsters
         get-resources
         get-grand-exchange-orders
         action-move
         action-fight
         action-gather)

(define (->query-value value)
  (cond
    [(symbol? value) (symbol->string value)]
    [else (format "~a" value)]))

(define (request-url config path params)
  (define query
    (and (pair? params)
         (alist->form-urlencoded
          (for/list ([item params])
            (cons (symbol->string (car item)) (->query-value (cdr item)))))))
  (string->url
   (string-append (string-trim (artifacts-config-base-url config) "/" #:right? #t)
                  path
                  (if query (string-append "?" query) ""))))

(define (request-headers config)
  (filter values
          (list "Accept: application/json"
                "Content-Type: application/json"
                (and (artifacts-config-token config)
                     (string-append "Authorization: Bearer "
                                    (artifacts-config-token config))))))

(define (read-response port)
  (read-json port))

(define (api-get path #:params [params '()] #:config [config (current-config)])
  (define url (request-url config path params))
  (call/input-url url
                  (lambda (target-url)
                    (get-pure-port target-url (request-headers config)))
                  read-response))

(define (api-post path #:body [body #hasheq()] #:config [config (current-config)])
  (define url (request-url config path '()))
  (define payload (jsexpr->bytes body))
  (call/input-url url
                  (lambda (target-url)
                    (post-pure-port target-url payload (request-headers config)))
                  read-response))

(define (get-server-details #:config [config (current-config)])
  (api-get "/" #:config config))

(define (get-maps #:page [page 1] #:size [size 100] #:config [config (current-config)])
  (api-get "/maps" #:params `((page . ,page) (size . ,size)) #:config config))

(define (get-items #:page [page 1] #:size [size 100] #:config [config (current-config)])
  (api-get "/items" #:params `((page . ,page) (size . ,size)) #:config config))

(define (get-monsters #:page [page 1] #:size [size 100] #:config [config (current-config)])
  (api-get "/monsters" #:params `((page . ,page) (size . ,size)) #:config config))

(define (get-resources #:page [page 1] #:size [size 100] #:config [config (current-config)])
  (api-get "/resources" #:params `((page . ,page) (size . ,size)) #:config config))

(define (get-grand-exchange-orders #:code [code #f]
                                   #:type [type #f]
                                   #:page [page 1]
                                   #:size [size 100]
                                   #:config [config (current-config)])
  (define params
    (filter values
            (list (and code (cons 'code code))
                  (and type (cons 'type type))
                  (cons 'page page)
                  (cons 'size size))))
  (api-get "/grandexchange/orders" #:params params #:config config))

(define (character-action-path name action)
  (format "/my/~a/action/~a" name action))

(define (action-move name #:map-id [map-id #f] #:x [x #f] #:y [y #f] #:config [config (current-config)])
  (define body
    (cond
      [map-id (hasheq 'map_id map-id)]
      [(and x y) (hasheq 'x x 'y y)]
      [else (error 'action-move "expected either #:map-id or both #:x and #:y")]))
  (api-post (character-action-path name "move") #:body body #:config config))

(define (action-fight name #:participants [participants '()] #:config [config (current-config)])
  (api-post (character-action-path name "fight")
            #:body (hasheq 'participants participants)
            #:config config))

(define (action-gather name #:config [config (current-config)])
  (api-post (character-action-path name "gathering") #:config config))
