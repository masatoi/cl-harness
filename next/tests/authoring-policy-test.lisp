;;;; next/tests/authoring-policy-test.lisp

(defpackage #:cl-harness-next/tests/authoring-policy-test
  (:use #:cl #:rove)
  (:import-from #:cl-harness-next/src/authoring-policy
                #:extract-deftest-forms
                #:authoring-policy
                #:policy-state
                #:policy-authored-names)
  (:import-from #:cl-harness-next/src/mcp-client
                #:mcp-transport
                #:transport-send-request
                #:make-mcp-client)
  (:import-from #:cl-harness-next/src/environment
                #:make-cl-mcp-environment)
  (:import-from #:cl-harness-next/src/event-log
                #:open-event-log)
  (:import-from #:cl-harness-next/src/review-oracle
                #:review-oracle)
  (:import-from #:cl-harness-next/src/kernel
                #:make-kernel
                #:run-kernel
                #:control-policy
                #:decide
                #:make-decision))

(in-package #:cl-harness-next/tests/authoring-policy-test)

(deftest extract-deftest-accepts-one-form
  (multiple-value-bind (text names)
      (extract-deftest-forms "(deftest add-adds (ok (= 5 (add 2 3))))")
    (ok (stringp text))
    (ok (search "deftest" text))
    (ok (equal '("ADD-ADDS") names))))

(deftest extract-deftest-accepts-multiple-forms
  (multiple-value-bind (text names)
      (extract-deftest-forms
       "(deftest a (ok t))
(deftest b (ok t))")
    (ok (stringp text))
    (ok (equal '("A" "B") names))))

(deftest extract-deftest-strips-fence-and-trims
  (multiple-value-bind (text names)
      (extract-deftest-forms
       (format nil "```lisp~%(deftest c (ok (= 1 (f))))~%```"))
    (ok (search "deftest" text))
    (ok (equal '("C") names))))

(deftest extract-deftest-rejects-non-deftest
  (multiple-value-bind (text reason)
      (extract-deftest-forms "(defun add (a b) (+ a b))")
    (ok (null text))
    (ok (and (stringp reason) (search "deftest" reason)))))

(deftest extract-deftest-rejects-empty-and-prose
  (ok (null (extract-deftest-forms "   ")))
  (ok (null (extract-deftest-forms "I cannot help with that"))))

(deftest extract-deftest-rejects-unbalanced
  (ok (null (extract-deftest-forms "(deftest oops (ok (= 1 1))"))))

(deftest author-prompt-includes-goal-and-surface
  (let ((p (make-instance 'cl-harness-next/src/authoring-policy::authoring-policy
                          :goal "add must return a+b"
                          :system "s" :test-system "s/tests"
                          :test-file "tests/main-test.lisp"
                          :test-package "s/tests/main-test"
                          :author-fn (lambda (x) (declare (ignore x)) "")
                          :reviewer nil
                       :fix-policy (make-instance 'fake-fix-policy
                                                  :transport nil))))
    (setf (cl-harness-next/src/authoring-policy::policy-sut-package p) "S/SRC/MAIN"
          (cl-harness-next/src/authoring-policy::policy-sut-surface p)
          "(defun add (a b) 0)")
    (let ((prompt (cl-harness-next/src/authoring-policy::%author-prompt p)))
      (ok (search "add must return a+b" prompt))
      (ok (search "S/SRC/MAIN" prompt))
      (ok (search "(defun add (a b) 0)" prompt)))))

(defclass tdd-transport (mcp-transport)
  ((src :initarg :src :reader tt-src)
   (test-content :initform "" :accessor tt-test-content)
   (impl-done-p :initform nil :accessor tt-impl-done-p)
   (load-bad-p :initform nil :accessor tt-load-bad-p)
   (test-edits :initform 0 :accessor tt-test-edits)
   (edit-forms :initform nil :accessor tt-edit-forms)
   (red-name :initform "CL-HARNESS-AUTHORED-TESTS" :accessor tt-red-name)
   (extra-failure :initform nil :accessor tt-extra-failure)
   (run-test-arg :initform nil :accessor tt-run-test-arg)
   (kill-count :initform 0 :accessor tt-kill-count)))

(defun %h (&rest plist) (alexandria:plist-hash-table plist :test 'equal))

(defun %enc (id result)
  (with-output-to-string (s)
    (yason:encode (%h "jsonrpc" "2.0" "id" id "result" result) s)))

(defun %text-result (text)
  (%h "content" (list (%h "type" "text" "text" text))))

(defun %ok () (%h "content" nil))

(defun %err (text)
  (%h "isError" t "content" (list (%h "type" "text" "text" text))))

(defun %deftest-name-in (content)
  "Upcased name of the first (deftest NAME …) in CONTENT, or NIL."
  (let ((p (search "(deftest " content :test #'char-equal)))
    (when p
      (let* ((start (+ p (length "(deftest ")))
             (rest (string-left-trim '(#\Space #\Tab #\Newline) (subseq content start)))
             (end (position-if (lambda (c) (member c '(#\Space #\Tab #\Newline #\) #\())) rest)))
        (when (and end (plusp end)) (string-upcase (subseq rest 0 end)))))))

(defun %tdd-tests-result (transport)
  (cond
    ((tt-extra-failure transport)
     ;; Authored tests pass (code is correct), but an UNRELATED test fails:
     ;; aggregate failed=1 with a non-authored test_name. Positive-evidence
     ;; green-first must not read this as green.
     (%h "passed" 1 "failed" 1
         "failed_tests"
         (list (%h "test_name" (tt-extra-failure transport)
                   "form" "(unrelated)" "reason" "unrelated failure"))))
    ((tt-impl-done-p transport)
     (%h "passed" 1 "failed" 0))
    (t
     (%h "passed" 0 "failed" 1
         "failed_tests"
         (list (%h "test_name" (tt-red-name transport)
                   "form" "(= 5 (ADD 2 3))" "reason" "stub"))))))

(defmethod transport-send-request ((tr tdd-transport) body)
  (let* ((p (yason:parse body)) (id (gethash "id" p))
         (method (gethash "method" p)))
    (cond
      ((null id) "")
      ((equal method "initialize") (%enc id (%h)))
      ((equal method "tools/list")
       (%enc id (%h "tools"
                    (mapcar (lambda (n) (%h "name" n))
                            '("fs-read-file" "fs-write-file" "lisp-edit-form"
                              "load-system" "run-tests" "pool-kill-worker")))))
      ((equal method "tools/call")
       (let* ((params (gethash "params" p))
              (tool (gethash "name" params))
              (args (gethash "arguments" params))
              (path (and (hash-table-p args) (gethash "path" args))))
         (cond
           ((equal tool "fs-read-file")
            (%enc id (%text-result
                      (if (search "src" (or path ""))
                          (tt-src tr) (tt-test-content tr)))))
           ((equal tool "fs-write-file")
            (let ((wp (gethash "path" args)))
              (cond
                ((and wp (search "test" wp) (plusp (length (tt-test-content tr))))
                 (%enc id (%err "Cannot overwrite existing .lisp; use lisp-edit-form")))
                ((and wp (search "test" wp))
                 (incf (tt-test-edits tr))
                 (setf (tt-test-content tr) (or (gethash "content" args) ""))
                 (%enc id (%ok)))
                (t (%enc id (%ok))))))
           ((equal tool "lisp-edit-form")
            (let ((fp (gethash "file_path" args)))
              (when (and fp (search "test" fp))
                (incf (tt-test-edits tr))
                (push (cons (gethash "operation" args) (gethash "form_name" args))
                      (tt-edit-forms tr))
                (alexandria:when-let
                    ((n (%deftest-name-in (or (gethash "content" args) ""))))
                  (setf (tt-red-name tr) n))
                (setf (tt-test-content tr)
                      (format nil "~A~%~A"
                              (tt-test-content tr) (or (gethash "content" args) "")))))
            (%enc id (%ok)))
           ((equal tool "pool-kill-worker")
            (incf (tt-kill-count tr)) (%enc id (%ok)))
           ((equal tool "load-system")
            (if (tt-load-bad-p tr)
                (%enc id (%err "compile error")) (%enc id (%ok))))
           ((equal tool "run-tests")
            (setf (tt-run-test-arg tr) (gethash "test" args))
            (if (tt-load-bad-p tr)
                (%enc id (%err "test system failed to load"))
                (%enc id (%tdd-tests-result tr))))
           (t (%enc id (%ok))))))
      (t (error "unexpected method ~S" method)))))

(defclass fake-fix-policy (control-policy)
  ((transport :initarg :transport :reader ff-transport)
   (state :initform :go :accessor ff-state)))

(defmethod decide ((policy fake-fix-policy) kernel)
  (declare (ignore kernel))
  (ecase (ff-state policy)
    (:go
     (setf (tt-impl-done-p (ff-transport policy)) t
           (ff-state policy) :verified)
     (make-decision :kind :act :tool "run-tests"
                    :arguments (%h "system" "s/tests")
                    :reason "fake fix: verify"))
    (:verified
     (make-decision :kind :finish :reason "clean verification green"))))

(defparameter *tdd-test-package* "S/TESTS/MAIN-TEST")

(eval-when (:compile-toplevel :load-toplevel :execute)
  ;; The default judges for WITH-TDD-KERNEL. The macro's &key default is the
  ;; quoted form '#'approve-judge (not #'approve-judge), so it splices a
  ;; function reference rather than dumping a live function into the fasl;
  ;; the eval-when keeps both available at compile time for direct callers.
  (defun approve-judge (prompt) (declare (ignore prompt)) "APPROVE: looks good")

  (defun reject-judge (prompt) (declare (ignore prompt)) "REJECT: too weak"))

(defmacro with-tdd-kernel ((kernel &key author-fn (judge '#'approve-judge)
                                        (mode :tdd)
                                        (supersedes "cl-harness-authored-tests")
                                        (src "(defpackage #:s/src/main (:use #:cl) (:export #:add))
(in-package #:s/src/main)
(defun add (a b) (declare (ignore a b)) 0)")
                                        (initial-test "")
                                        impl-done
                                        transport-var)
                           &body body)
  (let ((tr (or transport-var (gensym "TR"))))
    `(uiop:with-temporary-file (:pathname log-path :type "jsonl")
       (uiop:delete-file-if-exists log-path)
       (let* ((,tr (make-instance 'tdd-transport :src ,src))
              (log (progn (setf (tt-test-content ,tr) ,initial-test)
                          (when ,impl-done (setf (tt-impl-done-p ,tr) t))
                          (open-event-log log-path)))
              (env (make-cl-mcp-environment
                    :client (make-mcp-client ,tr)
                    :condition :runtime-native :event-log log))
              (reviewer (make-instance 'review-oracle :judge-fn ,judge
                                       :profile (list :id :tests-review
                                                      :strictness :strict)))
              (,kernel (make-kernel
                        :environment env :event-log log
                        :policy (make-instance 'authoring-policy
                                               :mode ,mode
                                               :supersedes ,supersedes
                                               :goal "add must return a+b"
                                               :system "s" :test-system "s/tests"
                                               :test-file "tests/main-test.lisp"
                                               :test-package *tdd-test-package*
                                               :author-fn ,author-fn
                                               :reviewer reviewer
                                               :fix-policy
                                               (make-instance 'fake-fix-policy
                                                              :transport ,tr)
                                               :clear-fasls t :k 3))))
         (declare (ignorable ,tr))
         ,@body))))

(defparameter *good-deftest*
  "(deftest add-adds (ok (= 5 (add 2 3))) (ok (= 0 (add 0 0))))")

(deftest init-derives-sut-package-and-reaches-author
  (with-tdd-kernel (kernel :author-fn (lambda (p) (declare (ignore p))
                                         *good-deftest*)
                           :transport-var tr)
    (let ((policy (cl-harness-next/src/kernel::kernel-policy kernel)))
      (dotimes (_ 6) (cl-harness-next/src/kernel::kernel-step kernel))
      (ok (equal "S/SRC/MAIN"
                 (cl-harness-next/src/authoring-policy::policy-sut-package policy)))
      (ok (search "(in-package #:s/tests/main-test)" (tt-test-content tr)))
      (ok (search "cl-harness-authored-tests" (tt-test-content tr))))))

(deftest author-writes-validated-deftests-then-loads
  (let ((calls 0))
    (with-tdd-kernel (kernel
                      :author-fn (lambda (p) (declare (ignore p))
                                   (incf calls) *good-deftest*)
                      :transport-var tr)
      (let ((policy (cl-harness-next/src/kernel::kernel-policy kernel)))
        (dotimes (_ 9) (cl-harness-next/src/kernel::kernel-step kernel))
        (ok (>= calls 1))
        (ok (equal '("CL-HARNESS-AUTHORED-TESTS") (policy-authored-names policy)))
        (ok (search "cl-harness-authored-tests" (tt-test-content tr)))
        (ok (search "(in-package" (tt-test-content tr)))))))

(deftest red-first-vacuous-test-is-regenerated
  ;; The authored tests pass on the unfixed code (vacuous): RED-first must
  ;; reject every attempt and the run gives up after K author calls — not
  ;; advance to review/fix.
  (let ((calls 0))
    (with-tdd-kernel (kernel :transport-var tr
                      :author-fn (lambda (p) (declare (ignore p))
                                   (incf calls)
                                   (setf (tt-impl-done-p tr) t)
                                   *good-deftest*))
      (multiple-value-bind (status reason) (run-kernel kernel :max-steps 60)
        (ok (eq :given-up status))
        (ok (and (stringp reason) (search "author" reason))))
      (ok (>= calls 3)))))

(deftest review-reject-regenerates-then-gives-up
  (let ((calls 0))
    (with-tdd-kernel (kernel :judge #'reject-judge
                      :author-fn (lambda (p) (declare (ignore p))
                                   (incf calls) *good-deftest*))
      (multiple-value-bind (status reason) (run-kernel kernel :max-steps 60)
        (ok (eq :given-up status))
        (ok (and (stringp reason) (search "author" reason))))
      (ok (>= calls 3)))))

(deftest review-approve-advances-to-fix
  (with-tdd-kernel (kernel :judge #'approve-judge
                    :author-fn (lambda (p) (declare (ignore p)) *good-deftest*))
    (let ((policy (cl-harness-next/src/kernel::kernel-policy kernel)))
      (dotimes (_ 12) (cl-harness-next/src/kernel::kernel-step kernel))
      (ok (eq :fix (policy-state policy))))))

(deftest authoring-happy-path-reaches-done
  (with-tdd-kernel (kernel :judge #'approve-judge
                    :author-fn (lambda (p) (declare (ignore p)) *good-deftest*)
                    :transport-var tr)
    (multiple-value-bind (status reason) (run-kernel kernel :max-steps 60)
      (ok (eq :done status))
      (ok (and (stringp reason) (search "clean" reason))))))

(deftest fix-phase-never-edits-the-test-file
  ;; Phase separation / oracle integrity: the gated tests are frozen — after
  ;; the gate, the fix dial issues no test-file write. A first-try success
  ;; makes exactly 2 test-file writes total: the defpackage skeleton + the one
  ;; authored-tests write. The fake fix dial adds none.
  (with-tdd-kernel (kernel :judge #'approve-judge
                    :author-fn (lambda (p) (declare (ignore p)) *good-deftest*)
                    :transport-var tr)
    (run-kernel kernel :max-steps 60)
    (ok (= 2 (tt-test-edits tr)))))

(deftest rerun-with-existing-authored-test-replaces-not-duplicates
  ;; A file already containing the fixed-name deftest (a prior run) must make
  ;; the first author REPLACE it — authored-written-p is seeded from the file,
  ;; not the (fresh) policy instance.
  (with-tdd-kernel (kernel
                    :author-fn (lambda (p) (declare (ignore p)) *good-deftest*)
                    :initial-test "(defpackage #:s/tests/main-test
  (:use #:cl #:rove #:s/src/main))

(in-package #:s/tests/main-test)

(deftest cl-harness-authored-tests
  (ok nil))")
    (let ((policy (cl-harness-next/src/kernel::kernel-policy kernel)))
      ;; step exactly through :ensure-skeleton (step 3), where the fix seeds
      ;; the flag from the file — BEFORE %author-written would set it anyway.
      (dotimes (_ 3) (cl-harness-next/src/kernel::kernel-step kernel))
      (ok (cl-harness-next/src/authoring-policy::policy-authored-written-p policy)))))

(deftest existing-test-file-without-in-package-gives-up-cleanly
  ;; A non-empty test file lacking (in-package …) can't be skeleton-written
  ;; (fs-write-file refuses to overwrite an existing .lisp), and there is no
  ;; in-package anchor to insert after — give up with a clear reason instead
  ;; of looping on failed edits.
  (with-tdd-kernel (kernel
                    :author-fn (lambda (p) (declare (ignore p)) *good-deftest*)
                    :initial-test ";;; a stray comment, no defpackage/in-package
")
    (multiple-value-bind (status reason) (run-kernel kernel :max-steps 40)
      (ok (eq :given-up status))
      (ok (and (stringp reason)
               (or (search "skeleton" reason) (search "in-package" reason)))))))

(deftest uppercase-in-package-anchor-is-recognized
  ;; A test file written with uppercase (IN-PACKAGE …) is a valid existing
  ;; file: it must be recognized case-insensitively and authored into via
  ;; lisp-edit-form — NOT fall through to fs-write-file (which cl-mcp refuses
  ;; on an existing .lisp) and give up.
  (with-tdd-kernel (kernel
                    :author-fn (lambda (p) (declare (ignore p)) *good-deftest*)
                    :initial-test "(DEFPACKAGE #:S/TESTS/MAIN-TEST (:USE #:CL #:ROVE #:S/SRC/MAIN))
(IN-PACKAGE #:S/TESTS/MAIN-TEST)")
    (multiple-value-bind (status reason) (run-kernel kernel :max-steps 60)
      (ok (eq :done status))
      (ok (and (stringp reason) (search "clean" reason))))))

(deftest spec-change-replaces-superseded-deftest
  ;; :spec-change re-specs an existing project: the first authored write
  ;; REPLACES the named old-spec deftest (turning it into the fixed-name
  ;; tests) rather than inserting — so old-spec assertions don't survive to
  ;; block clean-verify.
  (with-tdd-kernel (kernel
                    :mode :spec-change
                    :supersedes "old-add-test"
                    :author-fn (lambda (p) (declare (ignore p)) *good-deftest*)
                    :initial-test "(defpackage #:s/tests/main-test (:use #:cl #:rove #:s/src/main))
(in-package #:s/tests/main-test)
(deftest old-add-test (ok (= 5 (add 2 3))))"
                    :transport-var tr)
    (multiple-value-bind (status reason) (run-kernel kernel :max-steps 60)
      (ok (eq :done status))
      (ok (and (stringp reason) (search "clean" reason))))
    ;; the first authored edit was a REPLACE of the superseded deftest
    (ok (member '("replace" . "old-add-test") (tt-edit-forms tr) :test #'equal))
    ;; and NOT an insert_after of the in-package form
    (ok (not (member "insert_after" (tt-edit-forms tr)
                     :key #'car :test #'equal)))))

(deftest spec-change-without-supersedes-target-gives-up
  ;; :spec-change with the DEFAULT :supersedes (the tool's fixed name) on a
  ;; project that has no such deftest can't replace anything — give up
  ;; immediately with a clear reason, not after K author attempts on a
  ;; guaranteed edit error.
  (let ((calls 0))
    (with-tdd-kernel (kernel
                      :mode :spec-change
                      :author-fn (lambda (p) (declare (ignore p))
                                   (incf calls) *good-deftest*)
                      :initial-test "(defpackage #:s/tests/main-test (:use #:cl #:rove #:s/src/main))
(in-package #:s/tests/main-test)
(deftest some-other-test (ok t))")
      (multiple-value-bind (status reason) (run-kernel kernel :max-steps 40)
        (ok (eq :given-up status))
        (ok (and (stringp reason) (search "supersedes" reason))))
      (ok (<= calls 1)))))

(deftest spec-change-honors-supersedes-over-existing-fixed-name
  ;; The file has BOTH the tool's fixed-name deftest (a prior authoring) AND a
  ;; separate old-spec deftest. An explicit :supersedes must win — the
  ;; idempotent seeding of authored-written-p (for the fixed name) must not
  ;; override it, or the user's old-spec assertions survive and block clean.
  (with-tdd-kernel (kernel
                    :mode :spec-change
                    :supersedes "old-add-test"
                    :author-fn (lambda (p) (declare (ignore p)) *good-deftest*)
                    :initial-test "(defpackage #:s/tests/main-test (:use #:cl #:rove #:s/src/main))
(in-package #:s/tests/main-test)
(deftest cl-harness-authored-tests (ok nil))
(deftest old-add-test (ok (= 5 (add 2 3))))"
                    :transport-var tr)
    (run-kernel kernel :max-steps 60)
    (ok (member '("replace" . "old-add-test") (tt-edit-forms tr) :test #'equal))
    ;; no fixed-name edit is ever issued: the authored bodies are re-wrapped
    ;; under the :supersedes name and replaced in place, so a second
    ;; cl-harness-authored-tests deftest is structurally impossible.
    (ok (not (member '("replace" . "cl-harness-authored-tests")
                     (tt-edit-forms tr) :test #'equal)))))

(deftest spec-change-manages-the-supersedes-name
  ;; managed-name: :spec-change owns the :supersedes deftest name. The authored
  ;; bodies are re-wrapped under that name (so authored-names tracks it for the
  ;; RED-first check), and the lisp-edit-form content carries (deftest
  ;; old-add-test …) — never the fixed name.
  (with-tdd-kernel (kernel
                    :mode :spec-change
                    :supersedes "old-add-test"
                    :author-fn (lambda (p) (declare (ignore p)) *good-deftest*)
                    :initial-test "(defpackage #:s/tests/main-test (:use #:cl #:rove #:s/src/main))
(in-package #:s/tests/main-test)
(deftest old-add-test (ok (= 5 (add 2 3))))"
                    :transport-var tr)
    (let ((policy (cl-harness-next/src/kernel::kernel-policy kernel)))
      (run-kernel kernel :max-steps 60)
      (ok (equal '("OLD-ADD-TEST") (policy-authored-names policy)))
      (ok (search "(deftest old-add-test" (tt-test-content tr)))
      (ok (not (search "deftest cl-harness-authored-tests" (tt-test-content tr)))))))

(deftest spec-change-supersedes-symbol-is-coerced
  ;; :supersedes may be passed as a SYMBOL (the natural Lisp way to name a
  ;; deftest); it must be coerced to a string before the MCP form_name arg, or
  ;; YASON cannot encode it and the edit action errors → give-up.
  (with-tdd-kernel (kernel
                    :mode :spec-change
                    :supersedes 'old-add-test
                    :author-fn (lambda (p) (declare (ignore p)) *good-deftest*)
                    :initial-test "(defpackage #:s/tests/main-test (:use #:cl #:rove #:s/src/main))
(in-package #:s/tests/main-test)
(deftest old-add-test (ok (= 5 (add 2 3))))")
    (multiple-value-bind (status reason) (run-kernel kernel :max-steps 60)
      (ok (eq :done status))
      (ok (and (stringp reason) (search "clean" reason))))))

(deftest coverage-authors-passing-tests-and-finishes
  ;; :coverage adds tests for existing CORRECT code: they must LOAD and PASS
  ;; (green-first), the judge gates non-vacuity, and there is NO fix phase —
  ;; the mission finishes once the tests are authored and green.
  (with-tdd-kernel (kernel
                    :mode :coverage
                    :impl-done t          ; code is correct → authored tests pass
                    :judge #'approve-judge
                    :author-fn (lambda (p) (declare (ignore p)) *good-deftest*))
    (multiple-value-bind (status reason) (run-kernel kernel :max-steps 60)
      (ok (eq :done status))
      (ok (and (stringp reason) (search "coverage" reason))))))

(deftest coverage-failing-test-is-regenerated
  ;; A coverage test that FAILS against the existing code is wrong (or the code
  ;; lacks the behavior) — green-first rejects it and the run regenerates to K.
  (let ((calls 0))
    (with-tdd-kernel (kernel
                      :mode :coverage   ; impl-done NIL → authored test reported failing
                      :judge #'approve-judge
                      :author-fn (lambda (p) (declare (ignore p))
                                   (incf calls) *good-deftest*))
      (multiple-value-bind (status reason) (run-kernel kernel :max-steps 60)
        (declare (ignore reason))
        (ok (eq :given-up status)))
      (ok (>= calls 3)))))

(deftest coverage-review-reject-regenerates
  ;; Green-first can't prove non-vacuity, so the judge is the integrity gate:
  ;; a rejected (e.g. tautological) coverage test regenerates to give-up.
  (let ((calls 0))
    (with-tdd-kernel (kernel
                      :mode :coverage :impl-done t :judge #'reject-judge
                      :author-fn (lambda (p) (declare (ignore p))
                                   (incf calls) *good-deftest*))
      (multiple-value-bind (status reason) (run-kernel kernel :max-steps 60)
        (ok (eq :given-up status))
        ;; the give-up is BECAUSE the judge rejected — green-first passed
        ;; (impl-done), so the review oracle is demonstrably the gate.
        (ok (and (stringp reason) (search "review rejected" reason))))
      (ok (>= calls 3)))))

(deftest non-coverage-requires-fix-policy
  ;; :tdd / :spec-change delegate the fix to the inner dial; constructing one
  ;; without a :fix-policy is a configuration error and must fail FAST at
  ;; construction, not as a late (decide nil ...) no-applicable-method.
  (ok (handler-case
          (progn
            (make-instance 'authoring-policy
                           :mode :tdd :goal "g" :system "s"
                           :test-system "s/tests" :test-file "t.lisp"
                           :test-package "P"
                           :author-fn (lambda (p) p) :reviewer nil)
            nil)
        (error () t))))

(deftest coverage-allows-missing-fix-policy
  ;; :coverage never reaches the fix dial, so a missing :fix-policy is fine —
  ;; the construction check must not over-restrict it.
  (ok (handler-case
          (progn
            (make-instance 'authoring-policy
                           :mode :coverage :goal "g" :system "s"
                           :test-system "s/tests" :test-file "t.lisp"
                           :test-package "P"
                           :author-fn (lambda (p) p) :reviewer nil)
            t)
        (error () nil))))

(deftest coverage-unrelated-failure-is-not-green
  ;; P1: green-first must rest on positive evidence. Here the authored tests
  ;; pass (impl-done) but an UNRELATED test fails — aggregate failed=1 with a
  ;; non-authored test_name. The old gate ("no authored name in failed_tests")
  ;; read this as green and finished; the run is not green, so coverage must
  ;; refuse to finish and regenerate to give-up.
  (let ((calls 0))
    (with-tdd-kernel (kernel
                      :mode :coverage :impl-done t :judge #'approve-judge
                      :transport-var tr
                      :author-fn (lambda (p) (declare (ignore p))
                                   (incf calls) *good-deftest*))
      (setf (tt-extra-failure tr) "SOME-UNRELATED-TEST")
      (multiple-value-bind (status reason) (run-kernel kernel :max-steps 60)
        (declare (ignore reason))
        (ok (eq :given-up status)))
      (ok (>= calls 3)))))

(deftest coverage-author-prompt-asks-for-passing-tests
  ;; P2-prompt: in :coverage the code is already correct, so the per-attempt
  ;; author prompt must tell the author the tests MUST PASS as-is — not the
  ;; generic red-first "MUST fail".
  (let ((seen ""))
    (with-tdd-kernel (kernel
                      :mode :coverage :impl-done t :judge #'approve-judge
                      :author-fn (lambda (p) (setf seen p) *good-deftest*))
      (run-kernel kernel :max-steps 60)
      (ok (search "MUST PASS" (string-upcase seen)))
      (ok (not (search "MUST FAIL" (string-upcase seen)))))))

(deftest tdd-author-prompt-asks-for-failing-tests
  ;; :tdd / :spec-change are red-first — the per-attempt author prompt must tell
  ;; the author the tests MUST FAIL against the unfixed code.
  (let ((seen ""))
    (with-tdd-kernel (kernel
                      :mode :tdd :judge #'approve-judge
                      :author-fn (lambda (p) (setf seen p) *good-deftest*))
      (run-kernel kernel :max-steps 60)
      (ok (search "MUST FAIL" (string-upcase seen))))))

(deftest coverage-verify-run-is-scoped-by-name
  ;; P1 (deeper): green-first must rest on AUTHORED-scoped evidence, not the
  ;; whole-suite aggregate. The :coverage verify run scopes run-tests to the
  ;; authored test by name (the "test" arg = PACKAGE::NAME), so passed/failed
  ;; count only the authored test — a partial-vacuous run (authored test never
  ;; executed while the suite is otherwise green) cannot read as green.
  (with-tdd-kernel (kernel
                    :mode :coverage :impl-done t :judge #'approve-judge
                    :transport-var tr
                    :author-fn (lambda (p) (declare (ignore p)) *good-deftest*))
    (run-kernel kernel :max-steps 60)
    (ok (stringp (tt-run-test-arg tr)))
    (ok (search "CL-HARNESS-AUTHORED-TESTS" (string-upcase (tt-run-test-arg tr))))
    (ok (search "S/TESTS/MAIN-TEST" (string-upcase (tt-run-test-arg tr))))))

(deftest tdd-verify-run-is-whole-system
  ;; Red-first modes gate on authored names in failed_tests, which is robust to
  ;; other tests, so their verify run stays whole-system (no by-name scoping).
  ;; This locks in that the scoping change is confined to :coverage.
  (with-tdd-kernel (kernel
                    :mode :tdd :judge #'approve-judge
                    :transport-var tr
                    :author-fn (lambda (p) (declare (ignore p)) *good-deftest*))
    (run-kernel kernel :max-steps 60)
    (ok (null (tt-run-test-arg tr)))))

(deftest result-count-rejects-non-numeric
  ;; %result-count yields the count only for real numbers; a string or missing
  ;; key yields NIL, so the green gate fails closed rather than type-confusing a
  ;; non-numeric "failed" into a pass.
  (flet ((rc (h k) (cl-harness-next/src/authoring-policy::%result-count h k)))
    (ok (eql 0 (rc (%h "failed" 0) "failed")))
    (ok (eql 3 (rc (%h "passed" 3) "passed")))
    (ok (null (rc (%h "failed" "0") "failed")))
    (ok (null (rc (%h) "failed")))
    (ok (null (rc "not-a-hash-table" "failed")))))
