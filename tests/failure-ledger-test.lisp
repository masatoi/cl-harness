;;;; tests/failure-ledger-test.lisp
;;;;
;;;; Phase B of the context-management refactor
;;;; (docs/context-management.md §3.9 + §8, docs/plans/2026-05-07-phase-b-source-patch-failure.md).

(defpackage #:cl-harness/tests/failure-ledger-test
  (:use #:cl #:rove)
  (:import-from #:alexandria
                #:alist-hash-table)
  (:import-from #:cl-harness/src/failure-ledger
                #:failure-record
                #:make-failure-record
                #:failure-record-kind
                #:failure-record-description
                #:failure-record-test-name
                #:failure-record-reason
                #:failure-record-related-step-index
                #:failure-record-related-patch
                #:failure-record-status
                #:failure-record-resolved-at
                #:failure-record-resolved-by-patch
                #:failure-record-verify-source
                #:failure-ledger
                #:make-failure-ledger
                #:failure-ledger-active
                #:failure-ledger-resolved
                #:record-failure
                #:mark-resolved-by
                #:parse-failure-records-from-test-result))

(in-package #:cl-harness/tests/failure-ledger-test)

(defun %fr (&rest overrides)
  ;; Overrides come first so they win the duplicate-keyword race
  ;; (CLHS 3.4.1.4: leftmost matching keyword wins).
  (apply #'make-failure-record
         (append overrides
                 (list :kind :test-failed
                       :description "greet returns wrong value"
                       :test-name "greet-returns-hello-name"
                       :verify-source :incremental))))

(deftest make-failure-record-accepts-required-args
  (let ((f (%fr)))
    (ok (typep f 'failure-record))
    (ok (eq :test-failed (failure-record-kind f)))
    (ok (string= "greet returns wrong value"
                 (failure-record-description f)))
    (ok (string= "greet-returns-hello-name"
                 (failure-record-test-name f)))
    (ok (eq :incremental (failure-record-verify-source f)))))

(deftest make-failure-record-defaults
  (let ((f (%fr)))
    (ok (null (failure-record-reason f)))
    (ok (null (failure-record-related-step-index f)))
    (ok (null (failure-record-related-patch f)))
    (ok (eq :active (failure-record-status f)))
    (ok (null (failure-record-resolved-at f)))
    (ok (null (failure-record-resolved-by-patch f)))))

(deftest make-failure-record-rejects-bad-kind
  (ok (handler-case
          (progn (make-failure-record :kind :nonsense
                                      :description "x"
                                      :verify-source :incremental)
                 nil)
        (error () t))))

(deftest make-failure-record-rejects-bad-verify-source
  (ok (handler-case
          (progn (make-failure-record :kind :test-failed
                                      :description "x"
                                      :verify-source :elsewhere)
                 nil)
        (error () t))))

(deftest make-failure-ledger-empty
  (let ((l (make-failure-ledger)))
    (ok (null (failure-ledger-active l)))
    (ok (null (failure-ledger-resolved l)))))

(deftest record-failure-appends-to-active
  (let ((l (make-failure-ledger))
        (f1 (%fr :test-name "a"))
        (f2 (%fr :test-name "b")))
    (record-failure l f1)
    (record-failure l f2)
    (let ((active (failure-ledger-active l)))
      (ok (= 2 (length active)))
      (ok (string= "a" (failure-record-test-name (first active))))
      (ok (string= "b" (failure-record-test-name (second active))))
      (ok (null (failure-ledger-resolved l))))))

(deftest mark-resolved-by-moves-from-active-to-resolved
  (let ((l (make-failure-ledger))
        (f (%fr :test-name "broken")))
    (record-failure l f)
    (mark-resolved-by l f :patch :sentinel-patch)
    (ok (null (failure-ledger-active l)))
    (let ((resolved (failure-ledger-resolved l)))
      (ok (= 1 (length resolved)))
      (let ((entry (first resolved)))
        (ok (eq :resolved (failure-record-status entry)))
        (ok (eq :sentinel-patch
                (failure-record-resolved-by-patch entry)))
        (ok (numberp (failure-record-resolved-at entry)))))))

(deftest mark-resolved-by-with-no-patch-is-allowed
  ;; A failure can be resolved without a clear-cut patch attribution
  ;; (e.g. a test-only fix elsewhere). resolved-by-patch then stays NIL.
  (let ((l (make-failure-ledger))
        (f (%fr :test-name "transient")))
    (record-failure l f)
    (mark-resolved-by l f :patch nil)
    (ok (null (failure-ledger-active l)))
    (let ((entry (first (failure-ledger-resolved l))))
      (ok (eq :resolved (failure-record-status entry)))
      (ok (null (failure-record-resolved-by-patch entry))))))

(deftest parse-failure-records-from-test-result-handles-empty
  ;; A clean run-tests returns an empty failed_tests array (or no key).
  (let ((tr (alist-hash-table
             '(("passed" . 5) ("failed" . 0))
             :test 'equal)))
    (ok (null (parse-failure-records-from-test-result
               tr :verify-source :incremental)))))

(deftest parse-failure-records-from-test-result-extracts-known-fields
  ;; Shape mirrors what cl-mcp's run-tests emits per failed assertion.
  (let* ((source-h (alist-hash-table
                    '(("file" . "/tmp/demo/tests/greet-test.lisp")
                      ("line" . 12))
                    :test 'equal))
         (entry-h (alist-hash-table
                   `(("test_name" . "greet-returns-hello-name")
                     ("description" . "greet returns Hello, NAME!")
                     ("form" . "(string= ...)")
                     ("reason" . "expected \"Hello, Alice\"")
                     ("source" . ,source-h))
                   :test 'equal))
         (tr (alist-hash-table
              `(("passed" . 0)
                ("failed" . 1)
                ("failed_tests" . #(,entry-h)))
              :test 'equal)))
    (let ((records (parse-failure-records-from-test-result
                    tr :verify-source :incremental
                    :related-step-index 1)))
      (ok (= 1 (length records)))
      (let ((r (first records)))
        (ok (eq :test-failed (failure-record-kind r)))
        (ok (string= "greet-returns-hello-name"
                     (failure-record-test-name r)))
        (ok (string= "greet returns Hello, NAME!"
                     (failure-record-description r)))
        (ok (string= "expected \"Hello, Alice\""
                     (failure-record-reason r)))
        (ok (= 1 (failure-record-related-step-index r)))
        (ok (eq :incremental (failure-record-verify-source r)))))))

(deftest parse-failure-records-handles-missing-keys-gracefully
  ;; A degenerate failed_tests entry missing reason / source -- we should
  ;; not crash; missing fields stay NIL on the record.
  (let* ((entry-h (alist-hash-table
                   '(("test_name" . "x")
                     ("description" . "y"))
                   :test 'equal))
         (tr (alist-hash-table
              `(("failed_tests" . #(,entry-h)))
              :test 'equal)))
    (let ((records (parse-failure-records-from-test-result
                    tr :verify-source :incremental)))
      (ok (= 1 (length records)))
      (let ((r (first records)))
        (ok (string= "x" (failure-record-test-name r)))
        (ok (null (failure-record-reason r)))))))
