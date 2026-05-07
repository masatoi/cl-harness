;;;; src/repl-finding.lisp
;;;;
;;;; Phase H of the context-management refactor
;;;; (docs/context-management.md §3.6 + §6.2). One repl-finding
;;;; captures the structured (hypothesis probe finding decision)
;;;; tuple from one exploration episode, plus a "promoted to source"
;;;; flag distinguishing REPL success from shipped behaviour
;;;; ("REPL success != implemented", §3.6).
;;;;
;;;; Phase H only RECORDS findings. Phase C-style context-view
;;;; consumption surfaces them in :exploration / :implementation
;;;; views; promotion linkage is set by the orchestrator when a
;;;; patch lands matching a recorded hypothesis.

(defpackage #:cl-harness/src/repl-finding
  (:use #:cl)
  (:export #:repl-finding
           #:make-repl-finding
           #:repl-finding-hypothesis
           #:repl-finding-probe
           #:repl-finding-finding
           #:repl-finding-decision
           #:repl-finding-promoted-to-source-p
           #:repl-finding-linked-patch
           #:repl-finding-linked-source-fact
           #:repl-finding-related-step-index
           #:repl-finding-recorded-at
           #:repl-finding-mark-promoted))

(in-package #:cl-harness/src/repl-finding)

(defclass repl-finding ()
  ((hypothesis :initarg :hypothesis :reader repl-finding-hypothesis
               :documentation "The conjecture under test, as a
non-empty string.")
   (probe :initarg :probe :reader repl-finding-probe
          :documentation "Short description of the REPL probe used
to test the hypothesis (the action the agent took, not the raw
transcript).")
   (finding :initarg :finding :reader repl-finding-finding
            :documentation "The observed result of the probe — what
was learned. Non-empty.")
   (decision :initarg :decision :reader repl-finding-decision
             :documentation "The design decision the finding drives:
'promote ordinary function', 'reject macro approach', etc.
Non-empty.")
   (promoted-to-source-p :initform nil
                         :reader repl-finding-promoted-to-source-p
                         :documentation "T after a patch implementing
this finding has landed; NIL while the finding remains REPL-only.
Set via REPL-FINDING-MARK-PROMOTED.")
   (linked-patch :initform nil
                 :reader repl-finding-linked-patch
                 :documentation "PATCH-RECORD attributed for the
promotion, or NIL when no clear-cut attribution.")
   (linked-source-fact :initform nil
                       :reader repl-finding-linked-source-fact
                       :documentation "SOURCE-FACT attributed for
the promotion, or NIL.")
   (related-step-index :initarg :related-step-index
                       :reader repl-finding-related-step-index
                       :initform nil
                       :documentation "PLAN-STEP-INDEX of the active
step, or NIL outside a develop run.")
   (recorded-at :initarg :recorded-at :reader repl-finding-recorded-at
                :documentation "GET-UNIVERSAL-TIME at record time."))
  (:documentation
   "One structured exploration episode: a hypothesis, the probe used
to test it, the finding observed, and the decision that follows.
Promotion linkage tracks whether the decision has been shipped to
source."))

(defun %require-non-empty-string (name value)
  (unless (and (stringp value) (plusp (length value)))
    (error "repl-finding: :~A must be a non-empty string, got ~S"
           name value)))

(defun make-repl-finding (&key hypothesis probe finding decision
                            related-step-index
                            (recorded-at (get-universal-time)))
  "Construct a REPL-FINDING. All four text fields are required and
must be non-empty strings."
  (%require-non-empty-string "hypothesis" hypothesis)
  (%require-non-empty-string "probe" probe)
  (%require-non-empty-string "finding" finding)
  (%require-non-empty-string "decision" decision)
  (when related-step-index (check-type related-step-index integer))
  (make-instance 'repl-finding
                 :hypothesis hypothesis
                 :probe probe
                 :finding finding
                 :decision decision
                 :related-step-index related-step-index
                 :recorded-at recorded-at))

(defun repl-finding-mark-promoted (finding &key linked-patch
                                             linked-source-fact)
  "Flip FINDING's promoted-to-source-p flag and attach the patch /
source-fact reference. Idempotent: a second call on a finding whose
flag is already T is a no-op (existing linkage is preserved).
Returns FINDING."
  (when (repl-finding-promoted-to-source-p finding)
    (return-from repl-finding-mark-promoted finding))
  (setf (slot-value finding 'promoted-to-source-p) t
        (slot-value finding 'linked-patch) linked-patch
        (slot-value finding 'linked-source-fact) linked-source-fact)
  finding)
