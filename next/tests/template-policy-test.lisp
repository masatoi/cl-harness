;;;; next/tests/template-policy-test.lisp
;;;;
;;;; Tests for next/src/template-policy.lisp. Increment A: the
;;;; reader-based body extractor (extract-method-body).

(defpackage #:cl-harness-next/tests/template-policy-test
  (:use #:cl #:rove)
  (:import-from #:cl-harness-next/src/template-policy
                #:extract-method-body
                #:template-fix-policy
                #:make-fix-target
                #:discover-targets
                #:target-symbol
                #:target-form-type
                #:target-form-name
                #:target-head
                #:target-contract)
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

(deftest body-extraction-rejects-non-method-definitions
  ;; A whole defgeneric/defclass/defmacro is NOT a method to unwrap;
  ;; extracting a "body" from it is meaningless — reject as a definition.
  (dolist (def '("(defgeneric foo (x))"
                 "(defclass c () ((s :initarg :s)))"
                 "(defmacro foo (x) (list '1+ x))"))
    (ok (eq :nested-definition
            (nth-value 1 (extract-method-body def :head "foo ((x bar))")))
        (format nil "~S should be rejected as a definition" def))))

(deftest body-extraction-preserves-leading-reader-prefix
  ;; A body that begins with a quote / function reader macro must keep it;
  ;; the prose-skip must not drop the ' / #' .
  (let ((form (extract-method-body "'(:a :b)" :head "tags ((x foo))")))
    (ok (and form (search "'(:a :b)" form))))
  (let ((form (extract-method-body "#'(lambda (e) e)" :head "fn ((x foo))")))
    (ok (and form (search "#'(lambda (e) e)" form)))))

(deftest body-extraction-rejects-declare-docstring-constant
  ;; A stub-equivalent body with a leading docstring + declarations is
  ;; still degenerate after they are stripped.
  (ok (eq :degenerate
          (nth-value 1 (extract-method-body "(declare (ignore x)) \"doc\" 0"
                                            :head "m ((x c))")))))

(deftest discover-finds-stub-defmethods
  ;; Stub defmethods (constant / declare+constant body) are discovered from
  ;; source; real methods and defuns are not; the class + package + contract
  ;; are captured.
  (let* ((lines (list
                 "(defpackage #:demo/main (:use #:cl) (:export #:observe #:total))"
                 "(in-package #:demo/main)"
                 "(defclass histogram () ((table :initform (make-hash-table :test 'eql) :accessor histogram-table)))"
                 "(defgeneric observe (h key) (:documentation \"Increment KEY count and return it.\"))"
                 "(defmethod observe ((h histogram) key) (declare (ignore key)) 0)"
                 "(defgeneric total (h) (:documentation \"Sum of counts.\"))"
                 "(defmethod total ((h histogram)) 0)"
                 "(defmethod done-method ((h histogram)) (hash-table-count (histogram-table h)))"
                 "(defun helper (x) x)"))
         (source (format nil "~{~A~%~}" lines)))
    (multiple-value-bind (targets class-text pkg)
        (discover-targets source "src/main.lisp")
      (ok (= 2 (length targets)))
      (ok (equal "DEMO/MAIN" pkg))
      (ok (search "defclass histogram" class-text))
      (let ((obs (find "OBSERVE" targets :key #'target-symbol :test #'equal)))
        (ok obs)
        (ok (equal "defmethod" (target-form-type obs)))
        (ok (equal "observe ((h histogram) key)" (target-form-name obs)))
        (ok (equal "observe ((h histogram) key)" (target-head obs)))
        (ok (and (target-contract obs) (search "Increment" (target-contract obs)))))
      (ok (find "TOTAL" targets :key #'target-symbol :test #'equal))
      (ok (not (find "DONE-METHOD" targets :key #'target-symbol :test #'equal)))
      (ok (not (find "HELPER" targets :key #'target-symbol :test #'equal))))))

(deftest discover-handles-overloaded-methods
  ;; Form-by-form parsing means an overloaded generic's two stub methods
  ;; become two distinct targets (distinct specializer form-names) — no
  ;; symbol->form ambiguity to resolve.
  (let ((source (format nil "~{~A~%~}"
                        (list "(in-package #:cl-user)"
                              "(defclass shape () ())"
                              "(defclass circle (shape) ())"
                              "(defgeneric area (s))"
                              "(defmethod area ((s shape)) 0)"
                              "(defmethod area ((s circle)) nil)"))))
    (let ((targets (discover-targets source "f.lisp")))
      (ok (= 2 (length targets)))
      (ok (find "area ((s shape))" targets :key #'target-form-name :test #'equal))
      (ok (find "area ((s circle))" targets :key #'target-form-name :test #'equal)))))

;;; --- FSM full-loop tests over a canned cl-mcp transport -------------------
;;; The transport tracks which form_names have been patched correctly (a
;;; patch is "correct" unless its content contains the marker BAD) and
;;; answers run-tests with one failed entry per still-unresolved symbol.

(defclass template-transport (mcp-transport)
  ((symbols :initarg :symbols :initform nil :reader tt-symbols)
   (source :initarg :source :initform nil :reader tt-source)
   (resolved :initform (make-hash-table :test 'equal) :reader tt-resolved)
   (bad-p :initform nil :accessor tt-bad-p)
   (load-fail-p :initform nil :accessor tt-load-fail-p)
   (aggregate-only-p :initform nil :accessor tt-aggregate-only-p)
   (kill-count :initform 0 :accessor tt-kill-count)))

(defun %tt-run-tests-result (transport)
  (let ((unresolved (loop for (fn . sym) in (tt-symbols transport)
                          unless (gethash fn (tt-resolved transport))
                            collect sym)))
    (cond
      ((null unresolved)
       (alexandria:plist-hash-table (list "passed" 1 "failed" 0) :test 'equal))
      ((tt-aggregate-only-p transport)
       ;; red, but with no per-test detail (failed_tests omitted)
       (alexandria:plist-hash-table (list "passed" 0 "failed" 1) :test 'equal))
      (t
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
        :test 'equal)))))

(defun %tt-encode (id result-hash)
  (with-output-to-string (s)
    (yason:encode
     (alexandria:plist-hash-table
      (list "jsonrpc" "2.0" "id" id "result" result-hash) :test 'equal)
     s)))

(defun %tt-ok () (alexandria:plist-hash-table (list "content" nil) :test 'equal))

(defun %tt-error (text)
  (alexandria:plist-hash-table
   (list "isError" t "content"
         (list (alexandria:plist-hash-table
                (list "type" "text" "text" text) :test 'equal)))
   :test 'equal))

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
                            "fs-read-file" "clgrep-search")))
            :test 'equal)))
      ((equal method "tools/call")
       (let* ((params (gethash "params" parsed))
              (tool (gethash "name" params))
              (args (gethash "arguments" params)))
         (cond
           ((member tool '("lisp-edit-form" "lisp-patch-form") :test #'equal)
            (let ((fn (gethash "form_name" args))
                  (content (or (gethash "content" args) (gethash "new_text" args) "")))
              (setf (tt-bad-p transport) (and (search "NOCOMPILE" content) t)
                    (tt-load-fail-p transport) (and (search "STALEGREEN" content) t)
                    (tt-aggregate-only-p transport) (and (search "NODETAIL" content) t))
              (when fn
                (setf (gethash fn (tt-resolved transport))
                      (not (or (search "BAD" content) (search "NOCOMPILE" content)
                               (search "NODETAIL" content))))))
            (%tt-encode id (%tt-ok)))
           ((equal tool "pool-kill-worker")
            (incf (tt-kill-count transport))
            (%tt-encode id (%tt-ok)))
           ((equal tool "load-system")
            ;; NOCOMPILE breaks load AND tests; STALEGREEN breaks only the
            ;; load (run-tests still reports the form passing — sub-case b).
            (if (or (tt-bad-p transport) (tt-load-fail-p transport))
                (%tt-encode id (%tt-error "compile error in source"))
                (%tt-encode id (%tt-ok))))
           ((equal tool "run-tests")
            (if (tt-bad-p transport)
                (%tt-encode id (%tt-error "test system failed to load"))
                (%tt-encode id (%tt-run-tests-result transport))))
           ((equal tool "fs-read-file")
            (%tt-encode
             id (alexandria:plist-hash-table
                 (list "content"
                       (list (alexandria:plist-hash-table
                              (list "type" "text" "text" (or (tt-source transport) ""))
                              :test 'equal)))
                 :test 'equal)))
           (t (%tt-encode id (%tt-ok))))))
      (t (error "unexpected method ~S" method)))))

(defmacro with-template-kernel ((kernel &key targets class-text snippet-fn
                                        (sut-package "CL-USER") symbols source
                                        transport-var (k 3))
                                &body body)
  (let ((transport (or transport-var (gensym "TR"))))
    `(uiop:with-temporary-file (:pathname log-path :type "jsonl")
       (uiop:delete-file-if-exists log-path)
       (let* ((,transport (make-instance 'template-transport
                                         :symbols ,symbols :source ,source))
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

(defparameter *hist-source*
  (format nil "~{~A~%~}"
          (list "(defpackage #:clh-histogram/src/main (:use #:cl) (:export #:observe #:count-of #:total #:distinct #:top-key))"
                "(in-package #:clh-histogram/src/main)"
                "(defclass histogram () ((table :initform (make-hash-table :test 'eql) :accessor histogram-table)))"
                "(defgeneric observe (h key) (:documentation \"Increment KEY count and return it.\"))"
                "(defmethod observe ((h histogram) key) (declare (ignore key)) 0)"
                "(defgeneric count-of (h key) (:documentation \"Count of KEY (0 if unseen).\"))"
                "(defmethod count-of ((h histogram) key) (declare (ignore key)) 0)"
                "(defgeneric total (h) (:documentation \"Sum of counts.\"))"
                "(defmethod total ((h histogram)) 0)"
                "(defgeneric distinct (h) (:documentation \"Number of distinct keys.\"))"
                "(defmethod distinct ((h histogram)) 0)"
                "(defgeneric top-key (h) (:documentation \"Key with the highest count.\"))"
                "(defmethod top-key ((h histogram)) nil)")))

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

(deftest template-discovery-drives-to-done
  ;; No injected :targets — the FSM reads the source (fs-read-file),
  ;; discovers the 5 stub defmethods + the class, and drives to :done.
  (with-template-kernel (kernel :class-text ""
                                :source *hist-source*
                                :symbols *hist-symbols*
                                :snippet-fn (%snippet *hist-bodies*)
                                :transport-var tr)
    (multiple-value-bind (status reason) (run-kernel kernel :max-steps 120)
      (ok (eq :done status))
      (ok (and (stringp reason) (search "clean" reason))))
    (ok (= 1 (tt-kill-count tr)))
    (ok (= 5 (loop for (fn . sym) in *hist-symbols*
                   count (gethash fn (tt-resolved tr)))))))

(deftest discovery-cross-check-skips-untested-stubs
  ;; A stub no test exercises ('unused', absent from the run-tests
  ;; failures) is filtered out of the work queue; only the tested stubs
  ;; are fixed, and the run still reaches :done.
  (let ((source (format nil "~{~A~%~}"
                         (list "(defpackage #:cc/main (:use #:cl) (:export #:observe #:count-of #:unused))"
                               "(in-package #:cc/main)"
                               "(defclass histogram () ((table :initform (make-hash-table) :accessor histogram-table)))"
                               "(defmethod observe ((h histogram) key) (declare (ignore key)) 0)"
                               "(defmethod count-of ((h histogram) key) (declare (ignore key)) 0)"
                               "(defmethod unused ((h histogram)) nil)")))
         (symbols '(("observe ((h histogram) key)" . "OBSERVE")
                    ("count-of ((h histogram) key)" . "COUNT-OF")))
         (bodies '(("OBSERVE" . "(incf (gethash key (histogram-table h) 0))")
                   ("COUNT-OF" . "(gethash key (histogram-table h) 0)"))))
    (with-template-kernel (kernel :class-text "" :source source
                                  :symbols symbols :snippet-fn (%snippet bodies)
                                  :transport-var tr)
      (multiple-value-bind (status reason) (run-kernel kernel :max-steps 120)
        (ok (eq :done status))
        (ok (and (stringp reason) (search "clean" reason))))
      (ok (not (gethash "unused ((h histogram))" (tt-resolved tr)))))))

(deftest template-tool-error-is-not-treated-as-resolved
  ;; A first body that breaks the build (load-system AND run-tests return a
  ;; tool error with no failure detail) must NOT be read as "this form is
  ;; fixed" — that empty failed_tests would make notany vacuously true. The
  ;; policy retries within K on the missing positive signal and reaches :done.
  (let ((calls 0))
    (flet ((snip (prompt)
             (incf calls)
             (if (= calls 1)
                 "(NOCOMPILE)"
                 (funcall (%snippet *hist-bodies*) prompt))))
      (with-template-kernel (kernel :targets (%hist-targets)
                                    :class-text *hist-class*
                                    :symbols *hist-symbols*
                                    :snippet-fn #'snip
                                    :transport-var tr)
        (multiple-value-bind (status reason) (run-kernel kernel :max-steps 120)
          (ok (eq :done status))
          (ok (and (stringp reason) (search "clean" reason))))
        (ok (= 5 (loop for (fn . sym) in *hist-symbols*
                       count (gethash fn (tt-resolved tr)))))))))

(deftest template-overloaded-generic-resolves-each-method
  ;; Two stubs of the same generic (different specializers) share one symbol.
  ;; Per-form done-detection keys off the operator symbol, which cannot tell
  ;; the overloads apart, so it must not retry/park an already-patched overload
  ;; just because a sibling overload still mentions the shared symbol. Both are
  ;; patched exactly once and the run reaches :done.
  (let ((calls 0))
    (flet ((snip (prompt)
             (incf calls)
             (funcall (%snippet '(("AREA" . "(* 2 2)"))) prompt)))
      (let ((targets (list (make-fix-target :symbol "AREA" :file "src/main.lisp"
                                            :form-type "defmethod"
                                            :form-name "area ((s square))"
                                            :head "area ((s square))"
                                            :contract "area of a square")
                           (make-fix-target :symbol "AREA" :file "src/main.lisp"
                                            :form-type "defmethod"
                                            :form-name "area ((s circle))"
                                            :head "area ((s circle))"
                                            :contract "area of a circle")))
            (symbols '(("area ((s square))" . "AREA")
                       ("area ((s circle))" . "AREA"))))
        (with-template-kernel (kernel :targets targets
                                      :class-text "(defclass shape () ())"
                                      :symbols symbols
                                      :snippet-fn #'snip
                                      :transport-var tr)
          (multiple-value-bind (status reason) (run-kernel kernel :max-steps 100)
            (ok (eq :done status))
            (ok (and (stringp reason) (search "clean" reason))))
          (ok (= 2 (loop for (fn . sym) in symbols
                         count (gethash fn (tt-resolved tr)))))
          ;; one edit per overload — no spurious retries on the shared symbol
          (ok (= 2 calls)))))))

(deftest template-overloaded-wrong-body-is-retried-not-advanced
  ;; A *compiling but semantically wrong* body for one overload (marker BAD:
  ;; the build is clean but the shared symbol's assertion still fails) must
  ;; consume the per-form retry budget — it must NOT be advanced just because
  ;; run-tests returned without a tool error. A correct retry then drives :done.
  (let ((square-calls 0))
    (flet ((snip (prompt)
             (cond
               ((search "SQUARE" prompt :test #'char-equal)
                (incf square-calls)
                (if (= square-calls 1)
                    "(progn 'BAD 0)"   ; compiles, wrong → AREA stays failing
                    "(* 2 2)"))         ; correct on retry
               (t "(* 3 3)"))))         ; circle: correct first try
      (let ((targets (list (make-fix-target :symbol "AREA" :file "src/main.lisp"
                                            :form-type "defmethod"
                                            :form-name "area ((s square))"
                                            :head "area ((s square))"
                                            :contract "area of a square")
                           (make-fix-target :symbol "AREA" :file "src/main.lisp"
                                            :form-type "defmethod"
                                            :form-name "area ((s circle))"
                                            :head "area ((s circle))"
                                            :contract "area of a circle")))
            (symbols '(("area ((s square))" . "AREA")
                       ("area ((s circle))" . "AREA"))))
        (with-template-kernel (kernel :targets targets
                                      :class-text "(defclass shape () ())"
                                      :symbols symbols
                                      :snippet-fn #'snip
                                      :transport-var tr)
          (multiple-value-bind (status reason) (run-kernel kernel :max-steps 120)
            (ok (eq :done status))
            (ok (and (stringp reason) (search "clean" reason))))
          (ok (= 2 (loop for (fn . sym) in symbols
                         count (gethash fn (tt-resolved tr)))))
          ;; the wrong square body was retried, not advanced on a clean build
          (ok (>= square-calls 2)))))))

(deftest template-load-failure-is-not-treated-as-resolved
  ;; A body that EDITS cleanly but makes load-system return isError must be
  ;; fed back and retried — NOT silently followed by run-tests, which clears
  ;; the load error. Even when run-tests would then report the symbol passing
  ;; (a stale image — the load did not take), the form must not advance as
  ;; resolved. STALEGREEN models exactly that: edit OK, load isError, but the
  ;; form's symbol is marked resolved so run-tests would call it green.
  (let ((observe-calls 0))
    (flet ((snip (prompt)
             (if (search "OBSERVE" prompt :test #'char-equal)
                 (progn
                   (incf observe-calls)
                   (if (= observe-calls 1)
                       "(STALEGREEN 0)"
                       (funcall (%snippet *hist-bodies*) prompt)))
                 (funcall (%snippet *hist-bodies*) prompt))))
      (with-template-kernel (kernel :targets (%hist-targets)
                                    :class-text *hist-class*
                                    :symbols *hist-symbols*
                                    :snippet-fn #'snip
                                    :transport-var tr)
        (multiple-value-bind (status reason) (run-kernel kernel :max-steps 120)
          (ok (eq :done status))
          (ok (and (stringp reason) (search "clean" reason))))
        ;; the load failure was retried (≥2 OBSERVE calls), not advanced on
        ;; the first attempt despite run-tests reporting it green
        (ok (>= observe-calls 2))
        (ok (= 5 (loop for (fn . sym) in *hist-symbols*
                       count (gethash fn (tt-resolved tr)))))))))

(deftest template-overload-detail-less-red-is-not-resolved
  ;; Re-review: %symbol-fail-count returns 0 when failed_tests is missing, so a
  ;; detail-less red run ({passed:0,failed:1}, no failed_tests) made the overload
  ;; path read now=0 and advance as resolved despite a red suite. An overloaded
  ;; target must require positive evidence too: NODETAIL keeps the form red with
  ;; no per-test detail, so it must be retried, not advanced.
  (let ((square-calls 0))
    (flet ((snip (prompt)
             (cond
               ((search "SQUARE" prompt :test #'char-equal)
                (incf square-calls)
                (if (= square-calls 1) "(NODETAIL 0)" "(* 2 2)"))
               (t "(* 3 3)"))))
      (let ((targets (list (make-fix-target :symbol "AREA" :file "src/main.lisp"
                                            :form-type "defmethod"
                                            :form-name "area ((s square))"
                                            :head "area ((s square))"
                                            :contract "area of a square")
                           (make-fix-target :symbol "AREA" :file "src/main.lisp"
                                            :form-type "defmethod"
                                            :form-name "area ((s circle))"
                                            :head "area ((s circle))"
                                            :contract "area of a circle")))
            (symbols '(("area ((s square))" . "AREA")
                       ("area ((s circle))" . "AREA"))))
        (with-template-kernel (kernel :targets targets
                                      :class-text "(defclass shape () ())"
                                      :symbols symbols
                                      :snippet-fn #'snip
                                      :transport-var tr)
          (multiple-value-bind (status reason) (run-kernel kernel :max-steps 120)
            (ok (eq :done status))
            (ok (and (stringp reason) (search "clean" reason))))
          ;; the detail-less red attempt was retried, not advanced as resolved
          (ok (>= square-calls 2))
          (ok (= 2 (loop for (fn . sym) in symbols
                         count (gethash fn (tt-resolved tr))))))))))
