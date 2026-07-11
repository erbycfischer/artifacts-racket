#lang racket

(provide best-sell-price
         best-buy-price
         order-spread
         profitable-spread?
         order-quantity
         side-depth
         score-spread
         ge-book
         best-bid
         best-ask
         mid-price
         spread-margin
         profitable?)

(define (order-price order)
  (hash-ref order 'price +inf.0))

(define (order-quantity order)
  (or (hash-ref order 'quantity #f)
      (hash-ref order 'amount #f)
      1))

(define (best-sell-price sell-orders)
  (and (pair? sell-orders)
       (order-price (argmin order-price sell-orders))))

(define (best-buy-price buy-orders)
  (and (pair? buy-orders)
       (order-price (argmax order-price buy-orders))))

(define (order-spread buy-orders sell-orders)
  (define buy (best-buy-price buy-orders))
  (define sell (best-sell-price sell-orders))
  ;; Margin a maker captures is the ask minus the bid (sell price minus buy
  ;; price), so a profitable book (bid below ask) yields a positive number.
  (and buy sell (- sell buy)))

(define (profitable-spread? buy-orders sell-orders #:minimum-margin [minimum-margin 1])
  (define spread (order-spread buy-orders sell-orders))
  (and spread (>= spread minimum-margin)))

(define (side-depth orders)
  (for/sum ([o orders] #:when (hash? o))
    (define q (order-quantity o))
    (if (number? q) q 0)))

;; Score in [0,1]: spread strength + thin-book bonus when both sides have depth.
(define (score-spread buy-orders sell-orders #:spread-scale [spread-scale 20.0])
  (define spread (order-spread buy-orders sell-orders))
  (and spread
       (> spread 0)
       (let* ([buy-depth (side-depth buy-orders)]
              [sell-depth (side-depth sell-orders)]
              [depth (min buy-depth sell-depth)]
              [spread-part (min 1.0 (/ (abs spread) spread-scale))]
              [depth-part (min 0.25 (/ (log (add1 (max 0 depth))) 10.0))]
              [raw (+ (* 0.85 spread-part) depth-part)])
         (min 1.0 raw))))

;; Split a mixed GE book into (values buys sells) by each order's 'type field.
;; Orders that aren't hashes or lack a recognized type are dropped rather than
;; crashing the caller, so a half-parsed API response never takes the book down.
(define (ge-book orders)
  (define buys '())
  (define sells '())
  (for ([o orders])
    (when (hash? o)
      (define side (hash-ref o 'type #f))
      (cond
        [(equal? side "buy") (set! buys (cons o buys))]
        [(equal? side "sell") (set! sells (cons o sells))])))
  (values (reverse buys) (reverse sells)))

;; Best bid/ask read a mixed book directly, filtering on type instead of forcing
;; the caller to pre-split. They are convenience wrappers over best-buy-price /
;; best-sell-price, which still take a single side.
(define (best-bid orders)
  (define-values (buys sells) (ge-book orders))
  (void sells)
  (best-buy-price buys))

(define (best-ask orders)
  (define-values (buys sells) (ge-book orders))
  (void buys)
  (best-sell-price sells))

;; Fair-value midpoint between best bid and best ask; #f when either side is
;; missing so callers never average a phantom number into a price.
(define (mid-price orders)
  (define bid (best-bid orders))
  (define ask (best-ask orders))
  (and bid ask (/ (+ bid ask) 2.0)))

;; Numeric margin from best ask down to best bid, the same sign as
;; order-spread so it agrees with profitable?. A positive result is the spread
;; a maker captures (buy at the bid, sell into the ask); #f when the book is too
;; thin. minimum-margin floors the result so a sub-threshold gap returns #f
;; instead of a misleading sliver.
(define (spread-margin orders #:minimum-margin [minimum-margin 0])
  (define bid (best-bid orders))
  (define ask (best-ask orders))
  (define gap (and bid ask (- ask bid)))
  (and gap (>= gap minimum-margin) gap))

;; Boolean convenience over profitable-spread? that swallows the two-side split:
;; hand it a mixed book and a threshold, get a yes/no.
(define (profitable? orders #:minimum-margin [minimum-margin 1])
  (define-values (buys sells) (ge-book orders))
  (profitable-spread? buys sells #:minimum-margin minimum-margin))
