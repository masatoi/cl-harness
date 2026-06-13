;;;; next/src/scripted-policy.lisp
;;;;
;;;; The scripted dial level (spec §6): the FSM owns the sequence —
;;;; verify → diagnose → patch → verify → clean-verify — and the LLM
;;;; only fills patch content. One constrained LLM call per diagnose;
;;;; non-patch proposals are policy violations (give up; the governor
;;;; bounds futile cycles). Build a :diagnose-fn from a provider with
;;;; SP5a's MAKE-JUDGE-FN and +SCRIPTED-FIX-SYSTEM-PROMPT+.

(defpackage #:cl-harness-next/src/scripted-policy
  (:use #:cl)
  (:import-from #:cl-harness-next/src/kernel
                #:control-policy
                #:decide
                #:make-decision
                #:kernel-last-verdict
                #:kernel-world-model
                #:kernel-environment)
  (:import-from #:cl-harness-next/src/oracle
                #:verdict-pass-p)
  (:import-from #:cl-harness-next/src/verification-oracle
                #:verification-oracle)
  (:import-from #:cl-harness-next/src/context-compiler
                #:compile-context
                #:render-tool-schemas)
  (:import-from #:cl-harness-next/src/environment
                #:environment-action-space)
  (:import-from #:cl-harness-next/src/action
                #:obtain-action
                #:agent-action-type
                #:agent-action-tool
                #:agent-action-arguments
                #:agent-action-thought
                #:agent-action-summary)
  (:import-from #:cl-harness-next/src/projection
                #:+patch-tool-names+)
  (:export #:scripted-fix-policy
           #:policy-state
           #:policy-system
           #:policy-test-system
           #:+scripted-fix-system-prompt+))

(in-package #:cl-harness-next/src/scripted-policy)

(alexandria:define-constant +scripted-fix-system-prompt+
    (concatenate
     'string
     "You are a Common Lisp bug fixer inside a scripted harness. "
     "You will be shown a failure-analysis view of the current "
     "state. Respond with EXACTLY one JSON object and nothing else:"
     (string #\Newline)
     "{\"type\":\"tool_call\",\"tool\":\"lisp-edit-form\" or "
     "\"lisp-patch-form\",\"arguments\":{...},\"thought\":\"...\"}"
     (string #\Newline)
     "to patch source, or "
     "{\"type\":\"finish\",\"status\":\"give_up\",\"summary\":\"...\"} "
     "when you cannot make progress.")
  :test #'equal
  :documentation "System prompt for the diagnose call; pair with
MAKE-JUDGE-FN to build a :diagnose-fn from a provider.")

(defclass scripted-fix-policy (control-policy)
  ((diagnose-fn :initarg :diagnose-fn :reader policy-diagnose-fn
    :documentation "Function (failure-analysis view string)
→ raw LLM response string.")
   (system :initarg :system :reader policy-system)
   (test-system :initarg :test-system :reader policy-test-system)
   (clear-fasls-p :initarg :clear-fasls :initform nil
    :reader %clear-fasls-p
    :documentation "Threaded into both verification oracles — see
ORACLE-CLEAR-FASLS-P.")
   (state :initform :init :accessor policy-state)
   (incremental-oracle :accessor %incremental-oracle)
   (clean-oracle :accessor %clean-oracle))
  (:documentation "Scripted fix loop (PRD §11.2 distilled): the FSM
owns WHAT happens next; the LLM only proposes patch content."))

(defmethod initialize-instance :after ((policy scripted-fix-policy) &key)
  (setf (%incremental-oracle policy)
          (make-instance 'verification-oracle :system (policy-system policy)
                         :test-system (policy-test-system policy)
                         :mode :incremental
                         :clear-fasls (%clear-fasls-p policy))
        (%clean-oracle policy)
          (make-instance 'verification-oracle :system (policy-system policy)
                         :test-system (policy-test-system policy)
                         :mode :clean
                         :clear-fasls (%clear-fasls-p policy))))

(defun %give-up (control &rest arguments)
  (make-decision :kind :give-up
                 :reason (apply #'format nil control arguments)))

(defun %diagnose (policy kernel)
  "Ask the LLM for exactly one patch action against the
failure-analysis view, re-sampling up to OBTAIN-ACTION's MAX-TRIES on a
malformed reply. Anything other than a patch tool gives up (the scripted
dial does not negotiate)."
  (let* ((tools (render-tool-schemas
                 ;; Scripted only accepts patch tools — advertise only those,
                 ;; so the model is not tempted into a rejected non-patch call.
                 (remove-if-not
                  (lambda (descriptor)
                    (member (gethash "name" descriptor) +patch-tool-names+
                            :test #'string=))
                  (environment-action-space (kernel-environment kernel)))))
         (context (compile-context (kernel-world-model kernel)
                                   :decision-point :failure-analysis))
         (view (if tools
                   (format nil "~A~2%~A" tools context)
                   context)))
    (multiple-value-bind (action err)
        (obtain-action (policy-diagnose-fn policy) view)
      (when (null action)
        (return-from %diagnose (%give-up "unparseable diagnosis: ~A" err)))
      (cond
        ((and (eq :tool-call (agent-action-type action))
              (member (agent-action-tool action) +patch-tool-names+
                      :test #'string=))
         (setf (policy-state policy) :verify)
         (make-decision :kind :act
                        :tool (agent-action-tool action)
                        :arguments (agent-action-arguments action)
                        :reason (or (agent-action-thought action)
                                    "apply diagnosed patch")))
        ((eq :finish (agent-action-type action))
         (%give-up "model stopped: ~A"
                   (or (agent-action-summary action) "(no summary)")))
        (t
         (%give-up "scripted policy accepts only patch tools, got ~A"
                   (agent-action-tool action)))))))

(defmethod decide ((policy scripted-fix-policy) kernel)
  (ecase (policy-state policy)
    (:init
     (setf (policy-state policy) :check)
     (make-decision :kind :consult
                    :oracle (%incremental-oracle policy)
                    :reason "establish the verification baseline"))
    (:check
     (let ((verdict (kernel-last-verdict kernel)))
       (if (and verdict (verdict-pass-p verdict))
           (progn
             (setf (policy-state policy) :clean-check)
             (make-decision :kind :consult
                            :oracle (%clean-oracle policy)
                            :reason "confirm on a clean image"))
           (%diagnose policy kernel))))
    (:verify
     (setf (policy-state policy) :check)
     (make-decision :kind :consult
                    :oracle (%incremental-oracle policy)
                    :reason "verify the patch"))
    (:clean-check
     (let ((verdict (kernel-last-verdict kernel)))
       (if (and verdict (verdict-pass-p verdict))
           (make-decision :kind :finish
                          :reason "clean verification green")
           (%diagnose policy kernel))))))
