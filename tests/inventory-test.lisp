;;;; tests/inventory-test.lisp
;;;;
;;;; v0.4 Phase 2 unit tests for src/inventory.lisp.

(defpackage #:cl-harness/tests/inventory-test
  (:use #:cl #:rove)
  (:import-from #:cl-harness/src/inventory
                #:gather-project-inventory
                #:+default-inventory-byte-budget+))

(in-package #:cl-harness/tests/inventory-test)

(defun %tmp-dir (name)
  (uiop:ensure-directory-pathname
   (merge-pathnames (format nil "cl-harness-inv-test-~A-~A/"
                            name (get-universal-time))
                    (uiop:temporary-directory))))

(defun %write-file (path content)
  (ensure-directories-exist path)
  (with-open-file (s path :direction :output :if-exists :supersede)
    (write-string content s))
  path)

(defun %scaffold-fake-project (root &key asd src tests)
  "Lay out a tiny on-disk project under ROOT. ASD is the .asd file
content (or NIL); SRC and TESTS are alists of ((relative-path . content)
...) under src/ and tests/ respectively. Returns ROOT."
  (when asd
    (%write-file (merge-pathnames "demo.asd" root) asd))
  (dolist (pair src)
    (%write-file (merge-pathnames (concatenate 'string "src/" (car pair)) root)
                 (cdr pair)))
  (dolist (pair tests)
    (%write-file (merge-pathnames (concatenate 'string "tests/" (car pair)) root)
                 (cdr pair)))
  root)

(defmacro %with-fake-project ((root &key asd src tests) &body body)
  "Lay out a tiny on-disk project under ROOT and run BODY against it.
The directory is removed on exit so the test is hermetic."
  (let ((d (gensym "ROOT")))
    `(let* ((,d (%tmp-dir "fake-proj"))
            (,root (%scaffold-fake-project ,d :asd ,asd :src ,src :tests ,tests)))
       (declare (ignorable ,root))
       (unwind-protect (progn ,@body)
         (uiop:delete-directory-tree ,d :validate t :if-does-not-exist :ignore)))))

(deftest gather-inventory-emits-header-with-system-context
  (%with-fake-project
      (root :asd "(asdf:defsystem \"demo\" :class :package-inferred-system)~%"
            :src nil :tests nil)
    (let ((inv (gather-project-inventory
                :project-root root
                :system "demo"
                :test-system "demo/tests")))
      (ok (search "Project Inventory" inv))
      (ok (search "Project root:" inv))
      (ok (search "System: demo" inv))
      (ok (search "Test system: demo/tests" inv)))))

(deftest gather-inventory-includes-asd-file-content
  (%with-fake-project
      (root :asd (format nil "(asdf:defsystem \"demo\"~%  :depends-on (\"alexandria\"))")
            :src nil :tests nil)
    (let ((inv (gather-project-inventory :project-root root)))
      (ok (search "ASDF systems (.asd)" inv))
      (ok (search "demo.asd" inv))
      (ok (search "alexandria" inv)
          "the .asd dependency list is exposed verbatim"))))

(deftest gather-inventory-includes-source-and-test-files
  (%with-fake-project
      (root :asd "(asdf:defsystem \"demo\")"
            :src '(("main.lisp"
                    . "(defpackage #:demo/src/main (:use #:cl) (:export #:foo))~%(in-package #:demo/src/main)~%"))
            :tests '(("main-test.lisp"
                      . "(defpackage #:demo/tests/main-test (:use #:cl #:rove))~%(in-package #:demo/tests/main-test)~%")))
    (let ((inv (gather-project-inventory :project-root root)))
      (ok (search "Source files (src/*.lisp)" inv))
      (ok (search "src/main.lisp" inv))
      (ok (search "demo/src/main" inv))
      (ok (search "Test files (tests/*.lisp)" inv))
      (ok (search "tests/main-test.lisp" inv)))))

(deftest gather-inventory-skips-empty-sections
  ;; A project with neither src/ nor tests/ should not emit those
  ;; section headers — they'd just be noise.
  (%with-fake-project
      (root :asd "(asdf:defsystem \"demo\")" :src nil :tests nil)
    (let ((inv (gather-project-inventory :project-root root)))
      (ok (not (search "Source files" inv)))
      (ok (not (search "Test files" inv))))))

(deftest gather-inventory-respects-byte-budget
  ;; A tight budget produces a truncation footer rather than ballooning.
  (%with-fake-project
      (root :asd "(asdf:defsystem \"demo\" :description \"a long description x x x x x\")"
            :src '(("a.lisp" . "(defpackage #:demo/src/a (:use #:cl))")
                   ("b.lisp" . "(defpackage #:demo/src/b (:use #:cl))"))
            :tests '(("c.lisp" . "(defpackage #:demo/tests/c (:use #:cl #:rove))")))
    (let ((inv (gather-project-inventory :project-root root
                                         :byte-budget 200)))
      (ok (<= (length inv) 280) ; 200 + the truncation footer
          (format nil "expected ~A truncated to ~A bytes" (length inv) 200))
      (ok (search "inventory truncated" inv)))))

(deftest gather-inventory-default-budget-is-five-thousand
  (ok (= 5000 +default-inventory-byte-budget+)))
