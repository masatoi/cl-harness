;;;; next/tests/template-policy-test.lisp
;;;;
;;;; Tests for next/src/template-policy.lisp. Increment A: the
;;;; reader-based body extractor (extract-method-body).

(defpackage #:cl-harness-next/tests/template-policy-test
  (:use #:cl #:rove)
  (:import-from #:cl-harness-next/src/template-policy
                #:extract-method-body
                #:template-fix-policy
                #:make-fix-target)
  (:import-from #:cl-harness-next/src/mcp-client
                #:mcp-transport
                #:transport-send-request
                #:make-mcp-client)
  (:import-from #:cl-harness-next/src/environment
                #:make-cl-mcp-environment)
  (:import-from #:cl-harness-next/src/event-log
                #:open-event-log)
  (:import-from #:cl-harness-next/src/kernel
                #:make-kernel
                #:run-kernel))

(in-package #:cl-harness-next/tests/template-policy-test)

(deftest body-extraction-bare-body-wraps
  ;; A bare body s-expression is wrapped under the FSM-owned head.
  (multiple-value-bind (form reason)
      (extract-method-body "(incf (gethash key (histogram-table h) 0))"
                           :head "observe ((h histogram) key)"
                           :form-type "defmethod")
    (ok (null reason))
    (ok (stringp form))
    (ok (and form (search "(defmethod observe ((h histogram) key)" form)))
    (ok (and form (search "(incf (gethash key (histogram-table h) 0))" form)))))

(deftest body-extraction-strips-fence-and-prose
  (multiple-value-bind (form reason)
      (extract-method-body (format nil "```lisp~%(gethash key (histogram-table h) 0)~%```")
                           :head "count-of ((h histogram) key)")
    (ok (null reason))
    (ok (and form (search "(gethash key (histogram-table h) 0)" form))))
  (multiple-value-bind (form reason)
      (extract-method-body "The body is: (gethash key (histogram-table h) 0)"
                           :head "count-of ((h histogram) key)")
    (ok (null reason))
    (ok (and form (search "(gethash key (histogram-table h) 0)" form)))))

(deftest body-extraction-rewraps-whole-defmethod
  ;; A whole-defmethod reply has its header discarded and the body re-wrapped
  ;; under the FSM-owned canonical head.
  (multiple-value-bind (form reason)
      (extract-method-body
       "(defmethod observe ((h histogram) key) (incf (gethash key (histogram-table h) 0)))"
       :head "observe ((h histogram) key)")
    (ok (null reason))
    (ok (and form (search "(defmethod observe ((h histogram) key)" form)))
    (ok (and form (search "(incf (gethash key (histogram-table h) 0))" form)))))

(deftest body-extraction-accepts-multiple-body-forms
  ;; A body may legitimately be several forms (reader-based, not a
  ;; reject-multiple-forms char scanner).
  (multiple-value-bind (form reason)
      (extract-method-body
       "(setf (gethash key (histogram-table h)) (1+ (gethash key (histogram-table h) 0))) (gethash key (histogram-table h))"
       :head "observe ((h histogram) key)")
    (ok (null reason))
    (ok (and form (search "(setf (gethash key (histogram-table h))" form)))
    (ok (and form (search "(gethash key (histogram-table h))" form)))))

(deftest body-extraction-rejects-nested-definition
  (multiple-value-bind (form reason)
      (extract-method-body "(defun helper () 1) (helper)"
                           :head "observe ((h histogram) key)")
    (ok (null form))
    (ok (eq :nested-definition reason))))

(deftest body-extraction-rejects-degenerate-and-malformed
  (ok (eq :empty (nth-value 1 (extract-method-body "" :head "observe ((h histogram) key)"))))
  (ok (eq :empty (nth-value 1 (extract-method-body (format nil "```lisp~%```")
                                                   :head "observe ((h histogram) key)"))))
  (ok (eq :degenerate (nth-value 1 (extract-method-body "nil" :head "observe ((h histogram) key)"))))
  (ok (eq :degenerate (nth-value 1 (extract-method-body "0" :head "observe ((h histogram) key)"))))
  (ok (eq :malformed (nth-value 1 (extract-method-body "(incf (gethash key"
                                                       :head "observe ((h histogram) key)")))))

;;; --- FSM full-loop tests over a canned cl-mcp transport -------------------
;;; The transport tracks which form_names have been patched correctly (a
;;; patch is "correct" unless its content contains the marker BAD) and
;;; answers run-tests with one failed entry per still-unresolved symbol.

(defclass template-transport (mcp-transport)
  ((symbols :initarg :symbols :initform nil :reader tt-symbols)
   (resolved :initform (make-hash-table :test 'equal) :reader tt-resolved)
   (kill-count :initform 0 :accessor tt-kill-count)))

(defun %tt-run-tests-result (transport)
  (let ((unresolved (loop for (fn . sym) in (tt-symbols transport)
                          unless (gethash fn (tt-resolved transport))
                            collect sym)))
    (if unresolved
        (alexandria:plist-hash-table
         (list "passed" 0 "failed" 1
               "failed_tests"
               (mapcar (lambda (sym)
                         (alexandria:plist-hash-table
                          (list "test_name" "histogram-counts"
                                "form" (format nil "(= 1 (~A H A))" sym)
                                "reason" "stub")
                          :test 'equal))
                       unresolved))
         :test 'equal)
        (alexandria:plist-hash-table (list "passed" 1 "failed" 0) :test 'equal))))

(defun %tt-encode (id result-hash)
  (with-output-to-string (s)
    (yason:encode
     (alexandria:plist-hash-table
      (list "jsonrpc" "2.0" "id" id "result" result-hash) :test 'equal)
     s)))

(defun %tt-ok () (alexandria:plist-hash-table (list "content" nil) :test 'equal))

(defmethod transport-send-request ((transport template-transport) body)
  (let* ((parsed (yason:parse body))
         (id (gethash "id" parsed))
         (method (gethash "method" parsed)))
    (cond
      ((null id) "")
      ((equal method "initialize")
       (%tt-encode id (make-hash-table :test 'equal)))
      ((equal method "tools/list")
       (%tt-encode
        id (alexandria:plist-hash-table
            (list "tools"
                  (mapcar (lambda (n)
                            (alexandria:plist-hash-table (list "name" n) :test 'equal))
                          '("lisp-edit-form" "lisp-patch-form" "load-system"
                            "run-tests" "pool-kill-worker" "lisp-read-file"
                            "clgrep-search")))
            :test 'equal)))
      ((equal method "tools/call")
       (let* ((params (gethash "params" parsed))
              (tool (gethash "name" params))
              (args (gethash "arguments" params)))
         (cond
           ((member tool '("lisp-edit-form" "lisp-patch-form") :test #'equal)
            (let ((fn (gethash "form_name" args))
                  (content (or (gethash "content" args) (gethash "new_text" args) "")))
              (when fn
                (setf (gethash fn (tt-resolved transport))
                      (not (search "BAD" content)))))
            (%tt-encode id (%tt-ok)))
           ((equal tool "pool-kill-worker")
            (incf (tt-kill-count transport))
            (%tt-encode id (%tt-ok)))
           ((equal tool "run-tests")
            (%tt-encode id (%tt-run-tests-result transport)))
           (t (%tt-encode id (%tt-ok))))))
      (t (error "unexpected method ~S" method)))))

(defmacro with-template-kernel ((kernel &key targets class-text snippet-fn
                                        (sut-package "CL-USER") symbols
                                        transport-var (k 3))
                                &body body)
  (let ((transport (or transport-var (gensym "TR"))))
    `(uiop:with-temporary-file (:pathname log-path :type "jsonl")
       (uiop:delete-file-if-exists log-path)
       (let* ((,transport (make-instance 'template-transport :symbols ,symbols))
              (log (open-event-log log-path))
              (environment (make-cl-mcp-environment
                            :client (make-mcp-client ,transport)
                            :condition :runtime-native
                            :event-log log))
              (,kernel (make-kernel
                        :environment environment
                        :event-log log
                        :policy (make-instance 'template-fix-policy
                                               :system "s" :test-system "s/tests"
                                               :sut-package ,sut-package
                                               :snippet-fn ,snippet-fn
                                               :class-text ,class-text
                                               :k ,k
                                               :targets ,targets))))
         (declare (ignorable ,transport))
         ,@body))))

(defparameter *hist-class*
  "(defclass histogram () ((table :initform (make-hash-table :test 'eql) :accessor histogram-table)))")

(defun %hist-targets ()
  (flet ((tg (sym head)
           (make-fix-target :symbol sym :file "src/main.lisp"
                            :form-type "defmethod" :form-name head :head head
                            :contract (format nil "implement ~A" sym))))
    (list (tg "OBSERVE"  "observe ((h histogram) key)")
          (tg "COUNT-OF" "count-of ((h histogram) key)")
          (tg "TOTAL"    "total ((h histogram))")
          (tg "DISTINCT" "distinct ((h histogram))")
          (tg "TOP-KEY"  "top-key ((h histogram))"))))

(defparameter *hist-symbols*
  '(("observe ((h histogram) key)" . "OBSERVE")
    ("count-of ((h histogram) key)" . "COUNT-OF")
    ("total ((h histogram))" . "TOTAL")
    ("distinct ((h histogram))" . "DISTINCT")
    ("top-key ((h histogram))" . "TOP-KEY")))

(defparameter *hist-bodies*
  '(("OBSERVE" . "(incf (gethash key (histogram-table h) 0))")
    ("COUNT-OF" . "(gethash key (histogram-table h) 0)")
    ("TOTAL" . "(let ((s 0)) (maphash (lambda (k v) (declare (ignore k)) (incf s v)) (histogram-table h)) s)")
    ("DISTINCT" . "(hash-table-count (histogram-table h))")
    ("TOP-KEY" . "(let ((best nil) (n -1)) (maphash (lambda (k v) (when (> v n) (setf best k n v))) (histogram-table h)) best)")))

(defun %snippet (bodies)
  "A snippet-fn that returns the body whose symbol appears in the prompt."
  (lambda (prompt)
    (loop for (sym . body) in bodies
          when (search sym prompt :test #'char-equal)
            return body)))

(deftest template-happy-path-canned-oracle-drives-to-done
  (with-template-kernel (kernel :targets (%hist-targets)
                                :class-text *hist-class*
                                :symbols *hist-symbols*
                                :snippet-fn (%snippet *hist-bodies*)
                                :transport-var tr)
    (multiple-value-bind (status reason) (run-kernel kernel :max-steps 100)
      (ok (eq :done status))
      (ok (and (stringp reason) (search "clean" reason))))
    (ok (= 1 (tt-kill-count tr)))))

(deftest template-malformed-snippet-recovers-within-k
  ;; The first reply is junk; the in-decide re-sample yields a valid body
  ;; and the mission still reaches :done.
  (let ((calls 0))
    (flet ((snip (prompt)
             (incf calls)
             (if (= calls 1)
                 "I cannot help with that"
                 (funcall (%snippet *hist-bodies*) prompt))))
      (with-template-kernel (kernel :targets (%hist-targets)
                                    :class-text *hist-class*
                                    :symbols *hist-symbols*
                                    :snippet-fn #'snip)
        (multiple-value-bind (status reason) (run-kernel kernel :max-steps 100)
          (ok (eq :done status))
          (ok (and (stringp reason) (search "clean" reason))))
        (ok (>= calls 6))))))

(deftest template-unfixable-form-parks-then-gives-up
  ;; A persistently wrong body for one form (marker BAD keeps it red) is
  ;; parked after K tries; the other four are patched; the run gives up
  ;; naming the parked form. Partial progress, not 0/5.
  (flet ((snip (prompt)
           (if (search "TOP-KEY" prompt :test #'char-equal)
               "(progn 'BAD nil)"
               (funcall (%snippet *hist-bodies*) prompt))))
    (with-template-kernel (kernel :targets (%hist-targets)
                                  :class-text *hist-class*
                                  :symbols *hist-symbols*
                                  :snippet-fn #'snip
                                  :transport-var tr)
      (multiple-value-bind (status reason) (run-kernel kernel :max-steps 120)
        (ok (eq :given-up status))
        (ok (and (stringp reason) (search "TOP-KEY" reason))))
      ;; the four easy forms did get patched (resolved in the transport)
      (ok (= 4 (loop for (fn . sym) in *hist-symbols*
                     count (gethash fn (tt-resolved tr))))))))
