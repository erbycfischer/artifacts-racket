#lang racket

(provide best-sell-price
         best-buy-price
         order-spread
         profitable-spread?)

(define (order-price order)
  (hash-ref order 'price +inf.0))

(define (best-sell-price sell-orders)
  (and (pair? sell-orders)
       (order-price (argmin order-price sell-orders))))

(define (best-buy-price buy-orders)
  (and (pair? buy-orders)
       (order-price (argmax order-price buy-orders))))

(define (order-spread buy-orders sell-orders)
  (define buy (best-buy-price buy-orders))
  (define sell (best-sell-price sell-orders))
  (and buy sell (- buy sell)))

(define (profitable-spread? buy-orders sell-orders #:minimum-margin [minimum-margin 1])
  (define spread (order-spread buy-orders sell-orders))
  (and spread (>= spread minimum-margin)))
