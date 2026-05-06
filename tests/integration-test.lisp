;;;; tests/integration-test.lisp
;;;;
;;;; v0.4 Phase 5 unit tests for src/integration.lisp.
;;;; The static integration check is filesystem-driven, so the tests
;;;; build small temporary project trees on disk and walk them.

(defpackage #:cl-harness/tests/integration-test
  (:use #:cl #:rove)
  (:import-from #:cl-harness/src/integration
                #:package-info-name
                #:package-info-exports
                #:package-info-imports
                #:integration-issue-kind
                #:integration-issue-package
                #:integration-issue-description
                #:gather-package-graph
                #:find-integration-issues
                #:format-integration-issues-markdown))

(in-package #:cl-harness/tests/integration-test)

(defun %tmp-dir ()
  (let ((root (merge-pathnames
               (format nil "cl-harness-integration-test-~A/"
                       (get-internal-real-time))
               (uiop:temporary-directory))))
    (ensure-directories-exist root)
    root))

(defun %write-lisp (root rel content)
  (let ((p (merge-pathnames rel root)))
    (ensure-directories-exist p)
    (with-open-file (out p :direction :output
                           :if-exists :supersede
                           :if-does-not-exist :create)
      (write-string content out))
    p))

(defmacro with-tmp-project ((root-var) &body body)
  `(let ((,root-var (%tmp-dir)))
     (unwind-protect
          (progn ,@body)
       (uiop:delete-directory-tree
        (uiop:ensure-directory-pathname ,root-var)
        :validate t :if-does-not-exist :ignore))))

;; --- gather-package-graph -------------------------------------------------

(deftest gather-finds-defpackage-forms
  (with-tmp-project (root)
    (%write-lisp root "src/a.lisp"
                 "(defpackage #:proj/src/a
  (:use #:cl)
  (:export #:foo #:bar))
(in-package #:proj/src/a)
(defun foo () 1)
(defun bar () 2)
")
    (%write-lisp root "src/b.lisp"
                 "(defpackage #:proj/src/b
  (:use #:cl)
  (:import-from #:proj/src/a #:foo))
(in-package #:proj/src/b)
")
    (let ((graph (gather-package-graph root)))
      (ok (= 2 (length graph)))
      (ok (find "PROJ/SRC/A" graph
                :test #'string-equal :key #'package-info-name))
      (ok (find "PROJ/SRC/B" graph
                :test #'string-equal :key #'package-info-name))
      (let ((a (find "PROJ/SRC/A" graph
                     :test #'string-equal :key #'package-info-name)))
        (ok (member "FOO" (package-info-exports a) :test #'string-equal))
        (ok (member "BAR" (package-info-exports a) :test #'string-equal))))))

(deftest gather-extracts-import-from-pairs
  (with-tmp-project (root)
    (%write-lisp root "src/b.lisp"
                 "(defpackage #:proj/src/b
  (:use #:cl)
  (:import-from #:proj/src/a #:foo #:bar)
  (:import-from #:alexandria #:hash-table-keys))
(in-package #:proj/src/b)
")
    (let* ((graph (gather-package-graph root))
           (b (first graph))
           (imports (package-info-imports b)))
      (ok (= 2 (length imports)))
      (let ((from-a (find "PROJ/SRC/A" imports
                          :test #'string-equal :key #'car)))
        (ok from-a)
        (ok (equal '("FOO" "BAR") (cdr from-a)))))))

(deftest gather-survives-unreadable-files
  (with-tmp-project (root)
    (%write-lisp root "src/good.lisp"
                 "(defpackage #:proj/src/good
  (:use #:cl)
  (:export #:ok))
(in-package #:proj/src/good)
")
    (%write-lisp root "src/broken.lisp"
                 "(defpackage #:proj/src/broken
  (:use #:cl
;; missing closing paren below — file parses partially")
    (let ((graph (gather-package-graph root)))
      ;; broken file is skipped silently; the good one is still picked up
      (ok (find "PROJ/SRC/GOOD" graph
                :test #'string-equal :key #'package-info-name)))))

;; --- find-integration-issues ----------------------------------------------

(deftest issues-flag-unknown-in-project-package
  (with-tmp-project (root)
    (%write-lisp root "src/a.lisp"
                 "(defpackage #:proj/src/a
  (:use #:cl)
  (:export #:foo))
(in-package #:proj/src/a)
")
    (%write-lisp root "src/b.lisp"
                 "(defpackage #:proj/src/b
  (:use #:cl)
  (:import-from #:proj/src/missing #:bar))
(in-package #:proj/src/b)
")
    (let* ((graph (gather-package-graph root))
           (issues (find-integration-issues graph)))
      (ok (= 1 (length issues)))
      (ok (eq :unknown-package (integration-issue-kind (first issues))))
      (ok (string-equal "PROJ/SRC/B"
                        (integration-issue-package (first issues)))))))

(deftest issues-skip-out-of-project-imports
  (with-tmp-project (root)
    (%write-lisp root "src/a.lisp"
                 "(defpackage #:proj/src/a
  (:use #:cl)
  (:import-from #:alexandria #:hash-table-keys)
  (:import-from #:rove #:deftest))
(in-package #:proj/src/a)
")
    (let* ((graph (gather-package-graph root))
           (issues (find-integration-issues graph)))
      ;; alexandria/rove are not in-project — must not be flagged
      (ok (null issues)))))

(deftest issues-flag-unexported-symbols
  (with-tmp-project (root)
    (%write-lisp root "src/a.lisp"
                 "(defpackage #:proj/src/a
  (:use #:cl)
  (:export #:exported-only))
(in-package #:proj/src/a)
")
    (%write-lisp root "src/b.lisp"
                 "(defpackage #:proj/src/b
  (:use #:cl)
  (:import-from #:proj/src/a #:exported-only #:secret-internal))
(in-package #:proj/src/b)
")
    (let* ((graph (gather-package-graph root))
           (issues (find-integration-issues graph)))
      (ok (= 1 (length issues)))
      (ok (eq :unexported-symbol (integration-issue-kind (first issues))))
      (ok (search "SECRET-INTERNAL"
                  (integration-issue-description (first issues)))))))

(deftest issues-empty-on-clean-project
  (with-tmp-project (root)
    (%write-lisp root "src/a.lisp"
                 "(defpackage #:proj/src/a
  (:use #:cl)
  (:export #:foo #:bar))
(in-package #:proj/src/a)
")
    (%write-lisp root "src/b.lisp"
                 "(defpackage #:proj/src/b
  (:use #:cl)
  (:import-from #:proj/src/a #:foo #:bar))
(in-package #:proj/src/b)
")
    (let* ((graph (gather-package-graph root))
           (issues (find-integration-issues graph)))
      (ok (null issues)))))

(deftest issues-resolve-by-nickname
  (with-tmp-project (root)
    (%write-lisp root "src/main.lisp"
                 "(defpackage #:proj/src/main
  (:nicknames #:proj)
  (:use #:cl)
  (:export #:foo))
(in-package #:proj/src/main)
")
    (%write-lisp root "src/b.lisp"
                 "(defpackage #:proj/src/b
  (:use #:cl)
  (:import-from #:proj #:foo))
(in-package #:proj/src/b)
")
    (let* ((graph (gather-package-graph root))
           (issues (find-integration-issues graph)))
      (ok (null issues)))))

;; --- format-integration-issues-markdown -----------------------------------

(deftest format-markdown-clean-emits-success-line
  (let ((md (format-integration-issues-markdown nil)))
    (ok (search "Integration check" md))
    (ok (search "All package exports / imports consistent" md))))

(deftest format-markdown-issues-list-each-with-kind
  (with-tmp-project (root)
    (%write-lisp root "src/a.lisp"
                 "(defpackage #:proj/src/a
  (:use #:cl)
  (:export #:foo))
(in-package #:proj/src/a)
")
    (%write-lisp root "src/b.lisp"
                 "(defpackage #:proj/src/b
  (:use #:cl)
  (:import-from #:proj/src/a #:foo #:not-exported)
  (:import-from #:proj/src/missing #:gone))
(in-package #:proj/src/b)
")
    (let* ((graph (gather-package-graph root))
           (issues (find-integration-issues graph))
           (md (format-integration-issues-markdown issues)))
      (ok (= 2 (length issues)))
      (ok (search "Integration issues (2)" md))
      (ok (search "unknown-package" md))
      (ok (search "unexported-symbol" md)))))

(deftest format-markdown-honours-header-level
  (let ((md (format-integration-issues-markdown nil :header-level 3)))
    (ok (search "### Integration check" md))))
