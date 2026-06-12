;;;; next/src/llm-policies.lisp
;;;;
;;;; The LLM-driven dial levels (spec §6). LLM-STEP-POLICY is the
;;;; shared loop: one constrained-JSON LLM call per step; a
;;;; finish-fixed claim ALWAYS passes through the clean-verification
;;;; gate (the universal final truth, spec §7). GUIDED-POLICY adds the
;;;; harness-held agenda — subgoal labels with world-model predicates
;;;; rendered [DONE]/[OPEN] (progress derived from structured state,
;;;; spec §6 guided dial) — plus invariants. SELF-DIRECTED-POLICY
;;;; (Task 3) strips all scaffolding: the agent owns its plan.

(defpackage #:cl-harness-next/src/llm-policies
  (:use #:cl)
  (:import-from #:cl-harness-next/src/kernel
                #:control-policy
                #:decide
                #:make-decision
                #:kernel-last-verdict
                #:kernel-last-action-error
                #:kernel-world-model)
  (:import-from #:cl-harness-next/src/oracle
                #:verdict-pass-p)
  (:import-from #:cl-harness-next/src/verification-oracle
                #:verification-oracle)
  (:import-from #:cl-harness-next/src/context-compiler
                #:compile-context)
  (:import-from #:cl-harness-next/src/action
                #:parse-action
                #:action-parse-error
                #:agent-action-type
                #:agent-action-tool
                #:agent-action-arguments
                #:agent-action-thought
                #:agent-action-status
                #:agent-action-summary
                #:agent-action-hypothesis
                #:agent-action-probe
                #:agent-action-finding
                #:agent-action-decision)
  (:import-from #:cl-harness-next/src/world-model
                #:world-model-projection)
  (:import-from #:cl-harness-next/src/verification-ledger
                #:last-test
                #:test-run-failed
                #:clean-verified-p)
  (:import-from #:cl-harness-next/src/change-ledger
                #:patches)
  (:export #:llm-step-policy
           #:guided-policy
           #:self-directed-policy
           #:policy-system
           #:policy-test-system
           #:policy-agenda
           #:policy-invariants
           #:make-subgoal
           #:subgoal-label
           #:subgoal-predicate
           #:default-fix-agenda
           #:+guided-system-prompt+
           #:+self-directed-system-prompt+))

(in-package #:cl-harness-next/src/llm-policies)

(alexandria:define-constant +action-schema-text+
    (concatenate
     'string
     "Respond with EXACTLY one JSON object and nothing else:"
     (string #\Newline)
     "{\"type\":\"tool_call\",\"tool\":\"...\",\"arguments\":{...},"
     "\"thought\":\"...\"} to act with a tool;"
     (string #\Newline)
     "{\"type\":\"finding\",\"hypothesis\":\"...\",\"probe\":\"...\","
     "\"finding\":\"...\",\"decision\":\"...\"} to record a REPL"
     " insight;"
     (string #\Newline)
     "{\"type\":\"finish\",\"status\":\"fixed\"} when done (the harness"
     " will clean-verify before accepting);"
     (string #\Newline)
     "{\"type\":\"finish\",\"status\":\"give_up\",\"summary\":\"...\"}"
     " when stuck.")
  :test #'equal
  :documentation "Shared action-schema instructions.")

(alexandria:define-constant +guided-system-prompt+
    (concatenate
     'string
     "You work inside a guided harness on a Common Lisp project. Each"
     " turn you see the harness-maintained agenda ([DONE]/[OPEN]"
     " subgoals), invariants you must never violate, and a compressed"
     " state view. Choose the single best next step yourself."
     (string #\Newline) (string #\Newline)
     +action-schema-text+)
  :test #'equal
  :documentation "System prompt for the guided dial; pair with
MAKE-JUDGE-FN to build a :step-fn from a provider.")

(alexandria:define-constant +self-directed-system-prompt+
    (concatenate
     'string
     "You own this Common Lisp run end to end: form your own plan,"
     " probe the runtime, patch source, and verify — the harness only"
     " provides tools, records everything, and clean-verifies your"
     " finish claim. Record important insights as findings."
     (string #\Newline) (string #\Newline)
     +action-schema-text+)
  :test #'equal
  :documentation "System prompt for the self-directed dial.")

(defclass llm-step-policy (control-policy)
  ((step-fn :initarg :step-fn :reader policy-step-fn
            :documentation "Function (prompt string) → raw LLM
response. Build from a provider with MAKE-JUDGE-FN + the dial's
system prompt; tests inject canned functions.")
   (system :initarg :system :reader policy-system)
   (test-system :initarg :test-system :reader policy-test-system)
   (state :initform :stepping :accessor %policy-state)
   (clean-oracle :accessor %clean-oracle))
  (:documentation "Shared LLM-per-step loop for the guided and
self-directed dials, with the mandatory clean gate on finish."))

(defmethod initialize-instance :after ((policy llm-step-policy) &key)
  (setf (%clean-oracle policy)
        (make-instance 'verification-oracle
                       :system (policy-system policy)
                       :test-system (policy-test-system policy)
                       :mode :clean)))

(defgeneric policy-prompt-sections (policy kernel)
  (:documentation "Dial-specific prompt sections rendered above the
context view, or NIL."))

(defun %step-prompt (policy kernel)
  (format nil "~@[~A~%~%~]~A~@[~%~%Last action error: ~A~]"
          (policy-prompt-sections policy kernel)
          (compile-context (kernel-world-model kernel))
          (kernel-last-action-error kernel)))

(defun %give-up (control &rest arguments)
  (make-decision :kind :give-up
                 :reason (apply #'format nil control arguments)))

(defun %llm-step (policy kernel)
  (let* ((response
           (handler-case (funcall (policy-step-fn policy)
                                  (%step-prompt policy kernel))
             (error (condition)
               (return-from %llm-step
                 (%give-up "step call failed: ~A" condition)))))
         (action
           (handler-case (parse-action response)
             (action-parse-error (condition)
               (return-from %llm-step
                 (%give-up "unparseable action: ~A" condition))))))
    (ecase (agent-action-type action)
      (:tool-call
       (make-decision :kind :act
                      :tool (agent-action-tool action)
                      :arguments (agent-action-arguments action)
                      :reason (or (agent-action-thought action)
                                  "agent-chosen step")))
      (:finding
       (make-decision :kind :record
                      :payload (alexandria:plist-hash-table
                                (list "kind" "finding"
                                      "hypothesis"
                                      (agent-action-hypothesis action)
                                      "probe" (agent-action-probe action)
                                      "finding"
                                      (agent-action-finding action)
                                      "decision"
                                      (agent-action-decision action))
                                :test #'equal)
                      :reason "record a finding"))
      (:finish
       (if (eq :fixed (agent-action-status action))
           (progn
             (setf (%policy-state policy) :clean-gate)
             (make-decision :kind :consult
                            :oracle (%clean-oracle policy)
                            :reason "mandatory clean gate on finish"))
           (%give-up "model gave up: ~A"
                     (or (agent-action-summary action)
                         "(no summary)")))))))

(defmethod decide ((policy llm-step-policy) kernel)
  (ecase (%policy-state policy)
    (:stepping (%llm-step policy kernel))
    (:clean-gate
     (let ((verdict (kernel-last-verdict kernel)))
       (if (and verdict (verdict-pass-p verdict))
           (make-decision :kind :finish
                          :reason "clean verification green")
           (progn
             (setf (%policy-state policy) :stepping)
             (%llm-step policy kernel)))))))

;; --- Guided dial ------------------------------------------------------------

(defstruct (subgoal (:conc-name subgoal-))
  label predicate)

(defun default-fix-agenda ()
  "The fix-mission agenda: each subgoal's completion is DERIVED from
the world model, never asserted by the agent."
  (list
   (make-subgoal
    :label "observe the failing baseline"
    :predicate (lambda (world-model)
                 (and (last-test (world-model-projection world-model
                                                         :verification))
                      t)))
   (make-subgoal
    :label "apply a source patch"
    :predicate (lambda (world-model)
                 (plusp (length (patches (world-model-projection
                                          world-model :changes))))))
   (make-subgoal
    :label "make the tests green"
    :predicate (lambda (world-model)
                 (let ((run (last-test (world-model-projection
                                        world-model :verification))))
                   (and run (eql 0 (test-run-failed run))))))
   (make-subgoal
    :label "pass clean verification"
    :predicate (lambda (world-model)
                 (clean-verified-p (world-model-projection
                                    world-model :verification))))))

(defclass guided-policy (llm-step-policy)
  ((agenda :initarg :agenda :initform nil :reader policy-agenda
           :documentation "List of SUBGOALs; defaults to
DEFAULT-FIX-AGENDA.")
   (invariants :initarg :invariants :initform nil
               :reader policy-invariants
               :documentation "Strings rendered as hard constraints."))
  (:documentation "The guided dial (spec §6): the harness holds the
agenda and invariants; the agent chooses each step."))

(defmethod initialize-instance :after ((policy guided-policy) &key)
  (unless (policy-agenda policy)
    (setf (slot-value policy 'agenda) (default-fix-agenda))))

(defmethod policy-prompt-sections ((policy guided-policy) kernel)
  (let ((world-model (kernel-world-model kernel)))
    (format nil "## Agenda~%~{~A~%~}~@[## Invariants~%~{- ~A~%~}~]"
            (mapcar (lambda (subgoal)
                      (format nil "- [~:[OPEN~;DONE~]] ~A"
                              (funcall (subgoal-predicate subgoal)
                                       world-model)
                              (subgoal-label subgoal)))
                    (policy-agenda policy))
            (policy-invariants policy))))
