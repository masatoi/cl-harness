;;;; next/tests/llm-policies-test.lisp
;;;;
;;;; Tests for next/src/llm-policies.lisp: the guided and (Task 3)
;;;; self-directed dials over a real environment with a configurable
;;;; canned transport. The agenda is rendered from world-model
;;;; predicates ([DONE]/[OPEN]) — progress from structured state.

(defpackage #:cl-harness-next/tests/llm-policies-test
  (:use #:cl #:rove)
  (:import-from #:cl-harness-next/src/mcp-client
                #:mcp-transport
                #:transport-send-request
                #:make-mcp-client)
  (:import-from #:cl-harness-next/src/environment
                #:make-cl-mcp-environment)
  (:import-from #:cl-harness-next/src/event-log
                #:open-event-log)
  (:import-from #:cl-harness-next/src/world-model
                #:world-model-projection)
  (:import-from #:cl-harness-next/src/verification-ledger
                #:clean-verified-p)
  (:import-from #:cl-harness-next/src/exploration-ledger
                #:findings
                #:finding-hypothesis)
  (:import-from #:cl-harness-next/src/kernel
                #:make-kernel
                #:kernel-world-model
                #:run-kernel)
  (:import-from #:cl-harness-next/src/llm-policies
                #:guided-policy
                #:self-directed-policy
                #:%clean-oracle)
  (:import-from #:cl-harness-next/src/verification-oracle
                #:oracle-clear-fasls-p))

(in-package #:cl-harness-next/tests/llm-policies-test)

(defclass dial-transport (mcp-transport)
  ((fixable-p :initarg :fixable-p :initform t :reader dial-fixable-p)
   (kill-resets-p :initarg :kill-resets-p :initform nil
                  :reader dial-kill-resets-p)
   (edit-fails-p :initarg :edit-fails-p :initform nil
                 :reader dial-edit-fails-p)
   (fixed-p :initarg :fixed-p :initform nil :accessor dial-fixed-p)
   (no-counts-p :initarg :no-counts-p :initform nil :reader dial-no-counts-p)
   (kill-count :initform 0 :accessor dial-kill-count)))

(defmethod transport-send-request ((transport dial-transport) body)
  (let* ((parsed (yason:parse body))
         (id (gethash "id" parsed))
         (method (gethash "method" parsed)))
    (cond
      ((null id) "")
      ((equal method "initialize")
       (format nil "{\"jsonrpc\":\"2.0\",\"id\":~A,\"result\":{}}" id))
      ((equal method "tools/list")
       (format nil "{\"jsonrpc\":\"2.0\",\"id\":~A,~A}" id
               (concatenate 'string
                            "\"result\":{\"tools\":["
                            "{\"name\":\"pool-kill-worker\"},"
                            "{\"name\":\"load-system\"},"
                            "{\"name\":\"run-tests\"},"
                            "{\"name\":\"lisp-edit-form\"},"
                            "{\"name\":\"lisp-patch-form\"}]}")))
      ((equal method "tools/call")
       (let ((tool (gethash "name" (gethash "params" parsed))))
         (format nil "{\"jsonrpc\":\"2.0\",\"id\":~A,\"result\":~A}" id
                 (cond
                   ((equal tool "lisp-edit-form")
                    (if (dial-edit-fails-p transport)
                        (concatenate 'string
                                     "{\"isError\":true,\"content\":"
                                     "[{\"type\":\"text\","
                                     "\"text\":\"form not found\"}]}")
                        (progn
                          (when (dial-fixable-p transport)
                            (setf (dial-fixed-p transport) t))
                          "{\"content\":[]}")))
                   ((equal tool "lisp-patch-form")
                    (when (dial-fixable-p transport)
                      (setf (dial-fixed-p transport) t))
                    "{\"content\":[]}")
                   ((equal tool "run-tests")
                    (cond
                      ((dial-no-counts-p transport)
                       "{\"content\":[{\"type\":\"text\",\"text\":\"ran\"}]}")
                      ((dial-fixed-p transport) "{\"passed\":3,\"failed\":0}")
                      (t (concatenate 'string
                                      "{\"passed\":2,\"failed\":1,"
                                      "\"failed_tests\":[{\"test_name\":"
                                      "\"t-x\",\"reason\":\"boom\"}]}"))))
                   ((equal tool "pool-kill-worker")
                    (incf (dial-kill-count transport))
                    (when (dial-kill-resets-p transport)
                      (setf (dial-fixed-p transport) nil))
                    "{\"content\":[]}")
                   (t "{\"content\":[]}")))))
      (t (error "unexpected method ~S" method)))))

(defun %canned-step-fn (responses &optional prompts-box)
  "Pop RESPONSES per call (last repeats); capture prompts when a box
(a one-cell list) is supplied."
  (lambda (prompt)
    (when prompts-box (push prompt (car prompts-box)))
    (if (rest responses)
        (pop responses)
        (first responses))))

(defparameter *run-tests-json*
  "{\"type\":\"tool_call\",\"tool\":\"run-tests\",\"arguments\":{\"system\":\"s/tests\"}}")

(defparameter *edit-json*
  (concatenate 'string
               "{\"type\":\"tool_call\",\"tool\":\"lisp-edit-form\","
               "\"arguments\":{\"file_path\":\"a.lisp\","
               "\"content\":\"fix\"}}"))

(defparameter *finish-json*
  "{\"type\":\"finish\",\"status\":\"fixed\",\"summary\":\"done\"}")

(defparameter *give-up-json*
  "{\"type\":\"finish\",\"status\":\"give_up\",\"summary\":\"stuck\"}")

(defparameter *finding-json*
  (concatenate 'string
               "{\"type\":\"finding\",\"hypothesis\":\"h\","
               "\"probe\":\"p\",\"finding\":\"f\",\"decision\":\"d\"}"))

(defmacro with-dial-kernel ((kernel &key (policy-class ''guided-policy)
                                         responses prompts-box
                                         transport-var
                                         (transport-args 'nil)
                                         policy-extra-args)
                            &body body)
  (let ((transport (or transport-var (gensym "TRANSPORT"))))
    `(uiop:with-temporary-file (:pathname log-path :type "jsonl")
       (uiop:delete-file-if-exists log-path)
       (let* ((,transport (apply #'make-instance 'dial-transport
                                 ,transport-args))
              (log (open-event-log log-path))
              (environment (make-cl-mcp-environment
                            :client (make-mcp-client ,transport)
                            :condition :runtime-native
                            :event-log log))
              (,kernel (make-kernel
                        :environment environment
                        :event-log log
                        :policy (apply #'make-instance ,policy-class
                                       :system "s" :test-system "s/tests"
                                       :step-fn (%canned-step-fn
                                                 ,responses ,prompts-box)
                                       ,policy-extra-args))))
         (declare (ignorable ,transport))
         ,@body))))

(deftest guided-happy-path-passes-the-clean-gate
  (with-dial-kernel (kernel :responses (list *run-tests-json* *edit-json*
                                             *run-tests-json* *finish-json*)
                            :transport-var transport)
    (multiple-value-bind (status reason) (run-kernel kernel)
      (ok (eq :done status))
      (ok (search "clean" reason)))
    (ok (clean-verified-p
         (world-model-projection (kernel-world-model kernel)
                                 :verification)))
    (ok (= 1 (dial-kill-count transport)))))

(deftest guided-agenda-renders-progress-and-invariants
  (let ((prompts (list nil)))
    (with-dial-kernel (kernel :responses (list *run-tests-json* *edit-json*
                                               *run-tests-json*
                                               *finish-json*)
                              :prompts-box prompts
                              :policy-extra-args
                              (list :invariants
                                    (list "never edit test files")))
      (ok (eq :done (run-kernel kernel)))
      (let* ((chronological (reverse (car prompts)))
             (first-prompt (first chronological))
             (last-prompt (first (last chronological))))
        (ok (search "[OPEN] apply a source patch" first-prompt))
        (ok (search "- never edit test files" first-prompt))
        (ok (search "[DONE] apply a source patch" last-prompt))
        (ok (search "[DONE] make the tests green" last-prompt))))))

(deftest guided-failed-clean-gate-resumes-stepping
  (with-dial-kernel (kernel :responses (list *edit-json* *run-tests-json*
                                             *finish-json* *give-up-json*)
                            :transport-args (list :kill-resets-p t)
                            :transport-var transport)
    (multiple-value-bind (status reason) (run-kernel kernel)
      (ok (eq :given-up status))
      (ok (search "stuck" reason)))
    (ok (= 1 (dial-kill-count transport)))))

(deftest guided-green-stop-finishes-at-green-without-model-finish
  ;; With :green-stop t, once the world model shows the tests green the harness
  ;; drives straight to the mandatory clean gate and finishes — it does NOT wait
  ;; for the agent's :finish.  Here the agent reaches green (edit -> run-tests)
  ;; and would then GIVE UP; green-stop must finish before that give-up is read.
  (with-dial-kernel (kernel :responses (list *edit-json* *run-tests-json*
                                             *give-up-json*)
                            :policy-extra-args (list :green-stop t)
                            :transport-var transport)
    (multiple-value-bind (status reason) (run-kernel kernel)
      (ok (eq :done status))
      (ok (search "clean" reason)))
    (ok (clean-verified-p
         (world-model-projection (kernel-world-model kernel) :verification)))
    (ok (= 1 (dial-kill-count transport)))))

(deftest guided-without-green-stop-needs-model-finish
  ;; Default (green-stop off): the same green-then-give-up script does NOT
  ;; finish — the harness waits for the agent, which gives up.  Pins the opt-in
  ;; nature of green-stop (the default dial is unchanged).
  (with-dial-kernel (kernel :responses (list *edit-json* *run-tests-json*
                                             *give-up-json*))
    (ok (eq :given-up (run-kernel kernel)))))

(deftest guided-green-stop-failed-clean-gate-resumes-and-stays-fire-once
  ;; green-stop fires at green, but the clean gate FAILS (kill-resets-p t resets
  ;; the fix when the worker is killed).  The policy must resume stepping, must
  ;; NOT loop, and must NOT report a false done: the fire-once guard keeps
  ;; green-stop from re-firing on the still-green incremental projection, so the
  ;; agent's give-up is reached.  Exactly one clean gate ran (one worker kill).
  (with-dial-kernel (kernel :responses (list *edit-json* *run-tests-json*
                                             *give-up-json*)
                            :policy-extra-args (list :green-stop t)
                            :transport-args (list :kill-resets-p t)
                            :transport-var transport)
    (ok (eq :given-up (run-kernel kernel)))
    (ok (= 1 (dial-kill-count transport)))))

(deftest guided-green-stop-fires-on-a-green-baseline
  ;; If the tests are already green at baseline (nothing to fix), green-stop
  ;; fires on the first run-tests and finishes via the clean gate — the mission
  ;; is trivially satisfied, so this is correct.  Documents that green-stop is
  ;; gated on the tests being green, NOT on whether a patch was applied.
  (with-dial-kernel (kernel :responses (list *run-tests-json* *give-up-json*)
                            :policy-extra-args (list :green-stop t)
                            :transport-args (list :fixed-p t)
                            :transport-var transport)
    (multiple-value-bind (status reason) (run-kernel kernel)
      (ok (eq :done status))
      (ok (search "clean" reason)))
    (ok (= 1 (dial-kill-count transport)))))

(deftest guided-green-stop-ignores-a-run-with-no-counts
  ;; A run-tests result carrying no structured pass/fail counts (failed=NIL) must
  ;; NOT be read as green: %preempt-finish-p requires (eql 0 failed) AND a
  ;; positive passed count.  green-stop stays silent, no clean gate runs, and the
  ;; agent's give-up is reached (no false done on a count-less run).
  (with-dial-kernel (kernel :responses (list *edit-json* *run-tests-json*
                                             *give-up-json*)
                            :policy-extra-args (list :green-stop t)
                            :transport-args (list :no-counts-p t)
                            :transport-var transport)
    (ok (eq :given-up (run-kernel kernel)))
    (ok (= 0 (dial-kill-count transport)))))

(deftest guided-findings-fold-into-the-ledger
  (with-dial-kernel (kernel :responses (list *finding-json* *give-up-json*))
    (ok (eq :given-up (run-kernel kernel)))
    (let ((ledger (world-model-projection (kernel-world-model kernel)
                                          :exploration)))
      (ok (= 1 (length (findings ledger))))
      (ok (equal "h" (finding-hypothesis (first (findings ledger))))))))

(deftest guided-unparseable-action-gives-up
  (with-dial-kernel (kernel :responses (list "certainly! here is my plan"))
    (multiple-value-bind (status reason) (run-kernel kernel)
      (ok (eq :given-up status))
      (ok (search "unparseable" reason)))))

(deftest guided-transient-unparseable-action-recovers
  ;; A leading malformed reply must be re-sampled (obtain-action), not fatal:
  ;; the mission still reaches :done once a valid action follows.
  (with-dial-kernel (kernel :responses (list "garbage not json"
                                             *run-tests-json* *edit-json*
                                             *run-tests-json* *finish-json*)
                            :transport-var transport)
    (multiple-value-bind (status reason) (run-kernel kernel)
      (ok (eq :done status))
      (ok (search "clean" reason)))))

(deftest guided-prompt-includes-tool-schemas
  ;; The allowed tools' schemas are injected into the step prompt so the
  ;; model uses the right argument keys instead of guessing.
  (let ((prompts (list nil)))
    (with-dial-kernel (kernel :responses (list *give-up-json*)
                              :prompts-box prompts)
      (run-kernel kernel)
      (let ((prompt (first (car prompts))))
        (ok (search "lisp-edit-form" prompt))
        (ok (search "TOOLS" prompt))))))

(deftest self-directed-happy-path
  (with-dial-kernel (kernel :policy-class 'self-directed-policy
                            :responses (list *edit-json* *run-tests-json*
                                             *finish-json*))
    (multiple-value-bind (status reason) (run-kernel kernel)
      (ok (eq :done status))
      (ok (search "clean" reason)))
    (ok (clean-verified-p
         (world-model-projection (kernel-world-model kernel)
                                 :verification)))))

(deftest self-directed-prompt-has-no-scaffolding
  (let ((prompts (list nil)))
    (with-dial-kernel (kernel :policy-class 'self-directed-policy
                              :responses (list *give-up-json*)
                              :prompts-box prompts)
      (ok (eq :given-up (run-kernel kernel)))
      (let ((prompt (first (car prompts))))
        (ok (not (search "## Agenda" prompt)))
        (ok (not (search "## Invariants" prompt)))))))

(deftest self-directed-give-up-passthrough
  (with-dial-kernel (kernel :policy-class 'self-directed-policy
                            :responses (list *give-up-json*))
    (multiple-value-bind (status reason) (run-kernel kernel)
      (ok (eq :given-up status))
      (ok (search "stuck" reason)))))

(deftest shared-policy-readers-dispatch-across-dials
  ;; Final-review fix: policy-system/policy-test-system are ONE
  ;; generic shared with scripted-policy (facade symbol identity),
  ;; so the facade reader works on every dial level.
  (let ((policy (make-instance 'guided-policy
                               :system "s" :test-system "s/tests"
                               :step-fn (constantly ""))))
    (ok (equal "s" (cl-harness-next/src/scripted-policy:policy-system
                    policy)))
    (ok (equal "s/tests"
               (cl-harness-next/src/scripted-policy:policy-test-system
                policy)))))

(deftest clear-fasls-threads-to-the-clean-oracle
  (let ((policy (make-instance 'guided-policy
                               :system "s" :test-system "s/tests"
                               :step-fn (constantly "")
                               :clear-fasls t)))
    (ok (oracle-clear-fasls-p (%clean-oracle policy))))
  ;; Default stays off.
  (let ((policy (make-instance 'self-directed-policy
                               :system "s" :test-system "s/tests"
                               :step-fn (constantly ""))))
    (ok (not (oracle-clear-fasls-p (%clean-oracle policy))))))
