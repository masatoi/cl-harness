;;;; tests/repl-finding-test.lisp

(defpackage #:cl-harness/tests/repl-finding-test
  (:use #:cl #:rove)
  (:import-from #:cl-harness/src/repl-finding
                #:repl-finding
                #:make-repl-finding
                #:repl-finding-hypothesis
                #:repl-finding-probe
                #:repl-finding-finding
                #:repl-finding-decision
                #:repl-finding-promoted-to-source-p
                #:repl-finding-linked-patch
                #:repl-finding-recorded-at
                #:repl-finding-mark-promoted))

(in-package #:cl-harness/tests/repl-finding-test)

(deftest make-repl-finding-records-required-fields
  (let ((f (make-repl-finding
            :hypothesis "aggregation as pure function suffices"
            :probe "(reduce #'+ '(1 2 3)) -> 6"
            :finding "pure function works for current scope"
            :decision "promote ordinary function, not macro")))
    (ok (typep f 'repl-finding))
    (ok (string= "aggregation as pure function suffices"
                 (repl-finding-hypothesis f)))
    (ok (string= "(reduce #'+ '(1 2 3)) -> 6"
                 (repl-finding-probe f)))
    (ok (string= "pure function works for current scope"
                 (repl-finding-finding f)))
    (ok (string= "promote ordinary function, not macro"
                 (repl-finding-decision f)))
    (ok (null (repl-finding-promoted-to-source-p f)))
    (ok (integerp (repl-finding-recorded-at f)))))

(deftest make-repl-finding-rejects-empty-hypothesis
  (ok (handler-case
          (progn
            (make-repl-finding :hypothesis "" :probe "p"
                               :finding "f" :decision "d")
            nil)
        (error () t))))

(deftest make-repl-finding-rejects-empty-probe
  (ok (handler-case
          (progn
            (make-repl-finding :hypothesis "h" :probe ""
                               :finding "f" :decision "d")
            nil)
        (error () t))))

(deftest make-repl-finding-rejects-empty-finding
  (ok (handler-case
          (progn
            (make-repl-finding :hypothesis "h" :probe "p"
                               :finding "" :decision "d")
            nil)
        (error () t))))

(deftest make-repl-finding-rejects-empty-decision
  (ok (handler-case
          (progn
            (make-repl-finding :hypothesis "h" :probe "p"
                               :finding "f" :decision "")
            nil)
        (error () t))))

(deftest mark-promoted-flips-flag-and-stores-patch
  (let ((f (make-repl-finding :hypothesis "h" :probe "p"
                              :finding "f" :decision "d")))
    (ok (null (repl-finding-promoted-to-source-p f)))
    (repl-finding-mark-promoted f :linked-patch :sentinel-patch)
    (ok (eq t (repl-finding-promoted-to-source-p f)))
    (ok (eq :sentinel-patch (repl-finding-linked-patch f)))))

(deftest mark-promoted-is-idempotent
  (let ((f (make-repl-finding :hypothesis "h" :probe "p"
                              :finding "f" :decision "d")))
    (repl-finding-mark-promoted f :linked-patch :patch1)
    (repl-finding-mark-promoted f :linked-patch :patch2)
    ;; The first call wins; second is a no-op.
    (ok (eq :patch1 (repl-finding-linked-patch f)))))
