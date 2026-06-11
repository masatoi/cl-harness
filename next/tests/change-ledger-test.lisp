;;;; next/tests/change-ledger-test.lisp
;;;;
;;;; Unit tests for next/src/change-ledger.lisp (§3.8 patch context,
;;;; §3.5 source context, §9 staleness of source facts).

(defpackage #:cl-harness-next/tests/change-ledger-test
  (:use #:cl #:rove)
  (:import-from #:cl-harness-next/src/projection
                #:apply-interaction
                #:interaction)
  (:import-from #:cl-harness-next/src/change-ledger
                #:change-ledger
                #:patches
                #:source-facts
                #:patch-entry-file
                #:patch-entry-form-type
                #:patch-entry-form-name
                #:patch-entry-operation
                #:patch-entry-ok-p
                #:patch-entry-seq
                #:source-fact-file
                #:source-fact-detail
                #:source-fact-seq
                #:source-fact-stale-p))

(in-package #:cl-harness-next/tests/change-ledger-test)

(defun %hash (&rest plist)
  (alexandria:plist-hash-table plist :test #'equal))

(defun %interaction (tool &key arguments error (observation-seq 2))
  (make-instance 'interaction
                 :tool tool
                 :arguments arguments
                 :error-message error
                 :action-seq (1- observation-seq)
                 :observation-seq observation-seq))

(deftest patch-entries-record-success-and-failure
  (let ((ledger (make-instance 'change-ledger)))
    (apply-interaction
     ledger (%interaction "lisp-edit-form"
                          :arguments (%hash "file_path" "src/a.lisp"
                                            "form_type" "defun"
                                            "form_name" "f"
                                            "operation" "replace")
                          :observation-seq 4))
    (apply-interaction
     ledger (%interaction "lisp-patch-form"
                          :arguments (%hash "file_path" "src/a.lisp"
                                            "form_name" "g")
                          :error "no match"
                          :observation-seq 6))
    (let ((failed (first (patches ledger)))
          (succeeded (second (patches ledger))))
      (ok (= 2 (length (patches ledger))))
      (ok (not (patch-entry-ok-p failed)))
      (ok (= 6 (patch-entry-seq failed)))
      (ok (patch-entry-ok-p succeeded))
      (ok (equal "src/a.lisp" (patch-entry-file succeeded)))
      (ok (equal "defun" (patch-entry-form-type succeeded)))
      (ok (equal "f" (patch-entry-form-name succeeded)))
      (ok (equal "replace" (patch-entry-operation succeeded))))))

(deftest read-tools-create-source-facts
  (let ((ledger (make-instance 'change-ledger)))
    (apply-interaction
     ledger (%interaction "lisp-read-file"
                          :arguments (%hash "path" "src/a.lisp"
                                            "name_pattern" "^f$")
                          :observation-seq 3))
    (let ((fact (first (source-facts ledger))))
      (ok (equal "src/a.lisp" (source-fact-file fact)))
      (ok (equal "^f$" (source-fact-detail fact)))
      (ok (= 3 (source-fact-seq fact))))))

(deftest clgrep-fact-has-pattern-without-file
  (let ((ledger (make-instance 'change-ledger)))
    (apply-interaction
     ledger (%interaction "clgrep-search"
                          :arguments (%hash "pattern" "defclass")
                          :observation-seq 3))
    (let ((fact (first (source-facts ledger))))
      (ok (null (source-fact-file fact)))
      (ok (equal "defclass" (source-fact-detail fact)))
      ;; File-less facts can never go stale by file matching.
      (ok (not (source-fact-stale-p fact ledger))))))

(deftest staleness-tracks-same-file-patches
  (let ((ledger (make-instance 'change-ledger)))
    (apply-interaction
     ledger (%interaction "lisp-read-file"
                          :arguments (%hash "path" "src/a.lisp")
                          :observation-seq 3))
    (apply-interaction
     ledger (%interaction "lisp-read-file"
                          :arguments (%hash "path" "src/b.lisp")
                          :observation-seq 4))
    (apply-interaction
     ledger (%interaction "lisp-edit-form"
                          :arguments (%hash "file_path" "src/a.lisp")
                          :observation-seq 8))
    (let ((fact-b (first (source-facts ledger)))
          (fact-a (second (source-facts ledger))))
      (ok (source-fact-stale-p fact-a ledger))
      (ok (not (source-fact-stale-p fact-b ledger))))))
