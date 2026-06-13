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
                #:make-decision)
  (:import-from #:cl-harness-next/src/mission
                #:mission
                #:mission-queue
                #:enqueue-mission)
  (:import-from #:cl-harness-next/src/mission-runner
                #:run-mission)
  (:import-from #:cl-harness-next/src/governor
                #:governor))

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
                          :reviewer nil :fix-policy nil)))
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

(defun %tdd-tests-result (transport)
  (if (tt-impl-done-p transport)
      (%h "passed" 1 "failed" 0)
      (%h "passed" 0 "failed" 1
          "failed_tests"
          (list (%h "test_name" "ADD-ADDS"
                    "form" "(= 5 (ADD 2 3))" "reason" "stub")))))

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
              (path (and (hash-table-p args) (gethash "path" args)))
              (fpath (and (hash-table-p args) (gethash "file_path" args))))
         (cond
           ((equal tool "fs-read-file")
            (%enc id (%text-result
                      (if (search "src" (or path ""))
                          (tt-src tr) (tt-test-content tr)))))
           ((member tool '("fs-write-file" "lisp-edit-form") :test #'equal)
            (when (search "test" (or fpath path ""))
              (incf (tt-test-edits tr))
              (setf (tt-test-content tr)
                    (or (gethash "content" args) (tt-test-content tr))))
            (%enc id (%ok)))
           ((equal tool "pool-kill-worker")
            (incf (tt-kill-count tr)) (%enc id (%ok)))
           ((equal tool "load-system")
            (if (tt-load-bad-p tr)
                (%enc id (%err "compile error")) (%enc id (%ok))))
           ((equal tool "run-tests")
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

(defun approve-judge (prompt) (declare (ignore prompt)) "APPROVE: looks good")

(defun reject-judge (prompt) (declare (ignore prompt)) "REJECT: too weak")

(defmacro with-tdd-kernel ((kernel &key author-fn (judge #'approve-judge)
                                        (src "(defpackage #:s/src/main (:use #:cl) (:export #:add))
(in-package #:s/src/main)
(defun add (a b) (declare (ignore a b)) 0)")
                                        transport-var)
                           &body body)
  (let ((tr (or transport-var (gensym "TR"))))
    `(uiop:with-temporary-file (:pathname log-path :type "jsonl")
       (uiop:delete-file-if-exists log-path)
       (let* ((,tr (make-instance 'tdd-transport :src ,src))
              (log (open-event-log log-path))
              (env (make-cl-mcp-environment
                    :client (make-mcp-client ,tr)
                    :condition :runtime-native :event-log log))
              (reviewer (make-instance 'review-oracle :judge-fn ,judge
                                       :profile (list :id :tests-review
                                                      :strictness :strict)))
              (,kernel (make-kernel
                        :environment env :event-log log
                        :policy (make-instance 'authoring-policy
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
