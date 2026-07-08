#lang racket

(provide (struct-out artifacts-config)
         current-config
         make-config
         production-config
         sandbox-config
         beta-config)

(struct artifacts-config (base-url realtime-url token) #:transparent)

(define production-config
  (artifacts-config "https://api.artifactsmmo.com"
                    "wss://realtime.artifactsmmo.com"
                    #f))

(define sandbox-config
  (artifacts-config "https://api.sandbox.artifactsmmo.com"
                    "wss://realtime.sandbox.artifactsmmo.com"
                    #f))

(define beta-config
  (artifacts-config "https://api.beta.artifactsmmo.com"
                    "wss://realtime.beta.artifactsmmo.com"
                    #f))

(define (make-config #:base-url [base-url (artifacts-config-base-url production-config)]
                     #:realtime-url [realtime-url (artifacts-config-realtime-url production-config)]
                     #:token [token (getenv "ARTIFACTS_TOKEN")])
  (artifacts-config base-url realtime-url token))

(define current-config
  (make-parameter (make-config)))
