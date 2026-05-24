;;;; develop-benchmarks/104-cache-simple/fixture/src/main.lisp

(defpackage #:cache/src/main
  (:nicknames #:cache)
  (:use #:cl)
  (:export #:simple-cache
           #:make-cache
           #:cache-put
           #:cache-get))

(in-package #:cache/src/main)
