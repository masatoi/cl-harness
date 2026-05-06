;;;; tests/abstraction-test.lisp
;;;;
;;;; v0.4 Phase 4 unit tests for src/abstraction.lisp.

(defpackage #:cl-harness/tests/abstraction-test
  (:use #:cl #:rove)
  (:import-from #:cl-harness/src/abstraction
                #:abstraction-decision-kind
                #:abstraction-decision-name
                #:abstraction-decision-rationale
                #:abstraction-decision-step-index
                #:make-abstraction-decision
                #:parse-abstraction-decisions
                #:format-abstraction-ledger-markdown))

(in-package #:cl-harness/tests/abstraction-test)

(deftest make-abstraction-decision-validates-kind
  (let ((d (make-abstraction-decision :adopted "defun greet"
                                      :rationale "1 caller")))
    (ok (eq :adopted (abstraction-decision-kind d)))
    (ok (equal "defun greet" (abstraction-decision-name d)))
    (ok (equal "1 caller" (abstraction-decision-rationale d))))
  (ok (handler-case (progn (make-abstraction-decision :nonsense "x") nil)
        (error () t))))

(deftest parse-extracts-adopted-rejected-deferred
  (let* ((memo "Found these:
ADOPTED: defclass logger — fits stream-event design
REJECTED: defmacro with-log-context — only one call site
DEFERRED: defgeneric log-event — only one class today")
         (ds (parse-abstraction-decisions memo)))
    (ok (= 3 (length ds)))
    (let ((kinds (mapcar #'abstraction-decision-kind ds)))
      (ok (equal '(:adopted :rejected :deferred) kinds)))
    (let ((d (first ds)))
      (ok (search "defclass logger" (abstraction-decision-name d)))
      (ok (search "stream-event" (abstraction-decision-rationale d))))))

(deftest parse-handles-em-dash-en-dash-colon-as-separators
  (let* ((memo "ADOPTED: a — em-dash
ADOPTED: b – en-dash
ADOPTED: c: colon
ADOPTED: d - hyphen surround")
         (ds (parse-abstraction-decisions memo)))
    (ok (= 4 (length ds)))
    (ok (every (lambda (d) (eq :adopted (abstraction-decision-kind d))) ds))
    (let ((rs (mapcar #'abstraction-decision-rationale ds)))
      (ok (equal '("em-dash" "en-dash" "colon" "hyphen surround") rs)))))

(deftest parse-tolerates-leading-bullet-and-indentation
  (let* ((memo "  - ADOPTED: defun foo — short
* REJECTED: defmacro bar — too clever
+ DEFERRED: defgeneric baz — only 1 class")
         (ds (parse-abstraction-decisions memo)))
    (ok (= 3 (length ds)))))

(deftest parse-skips-none-sentinels-and-non-marker-lines
  (let* ((memo "Some commentary unrelated.
ADOPTED: (none)
REJECTED: (none)
ADOPTED: real-thing — keeps")
         (ds (parse-abstraction-decisions memo)))
    (ok (= 1 (length ds)))
    (ok (equal "real-thing"
               (abstraction-decision-name (first ds))))))

(deftest parse-stamps-step-index-when-supplied
  (let ((ds (parse-abstraction-decisions "ADOPTED: x — y"
                                         :step-index 3)))
    (ok (= 3 (abstraction-decision-step-index (first ds))))))

(deftest parse-handles-empty-and-nil-memo
  (ok (null (parse-abstraction-decisions "")))
  (ok (null (parse-abstraction-decisions nil))))

(deftest format-markdown-groups-by-kind-and-skips-empty
  (let* ((ds (list (make-abstraction-decision :adopted "x" :rationale "good")
                   (make-abstraction-decision :rejected "y" :rationale "noisy")))
         (md (format-abstraction-ledger-markdown ds)))
    (ok (search "## Adopted abstractions" md))
    (ok (search "## Rejected abstractions" md))
    (ok (not (search "## Deferred abstractions" md))
        "the empty deferred group is omitted")
    (ok (search "x — good" md))
    (ok (search "y — noisy" md))))

(deftest format-markdown-honours-header-level
  (let ((md (format-abstraction-ledger-markdown
             (list (make-abstraction-decision :adopted "x"))
             :header-level 3)))
    (ok (search "### Adopted abstractions" md))))
