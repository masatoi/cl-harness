;;;; src/review.lisp
;;;;
;;;; Goal-backed review gate support for `develop`.
;;;; The key invariant is: generated tests are evidence, not the source
;;;; of truth. The source of truth is a DEVELOP-SPEC derived from the
;;;; user's goal and reviewed against the plan, tests, implementation,
;;;; and any additive test-change requests.

(defpackage #:cl-harness/src/review
  (:use #:cl)
  (:import-from #:cl-harness/src/model
                #:complete-chat
                #:make-chat-message
                #:chat-response-content)
  (:import-from #:cl-harness/src/planner
                #:plan-step-index
                #:plan-step-issue
                #:plan-step-test-name
                #:plan-step-test-source
                #:plan-step-acceptance-criteria)
  (:export #:develop-spec
           #:make-develop-spec
           #:develop-spec-goal
           #:develop-spec-acceptance-criteria
           #:develop-spec-non-goals
           #:develop-spec-risks
           #:review-decision
           #:make-review-decision
           #:review-decision-kind
           #:review-decision-status
           #:review-decision-feedback
           #:review-decision-related-step-index
           #:review-decision-approved-p
           #:test-record
           #:make-test-record
           #:test-record-step-index
           #:test-record-test-name
           #:test-record-source
           #:test-record-criteria
           #:test-change-record
           #:make-test-change-record
           #:test-change-record-step-index
           #:test-change-record-criteria
           #:test-change-record-rationale
           #:test-change-record-test-source
           #:generate-develop-spec
           #:review-development-artifact
           #:format-review-decision
           #:review-error))

(in-package #:cl-harness/src/review)

(define-condition review-error (error)
  ((message :initarg :message :reader review-error-message)
   (raw :initarg :raw :initform nil :reader review-error-raw))
  (:report (lambda (c stream)
             (format stream "review-error: ~A" (review-error-message c)))))

(defclass develop-spec ()
  ((goal :initarg :goal :reader develop-spec-goal)
   (acceptance-criteria :initarg :acceptance-criteria
                        :initform nil
                        :reader develop-spec-acceptance-criteria)
   (non-goals :initarg :non-goals :initform nil
              :reader develop-spec-non-goals)
   (risks :initarg :risks :initform nil
          :reader develop-spec-risks))
  (:documentation "Goal-derived source of truth for one DEVELOP run."))

(defun make-develop-spec (&key goal acceptance-criteria non-goals risks)
  (check-type goal string)
  (make-instance 'develop-spec
                 :goal goal
                 :acceptance-criteria (or acceptance-criteria (list goal))
                 :non-goals non-goals
                 :risks risks))

(defclass review-decision ()
  ((kind :initarg :kind :reader review-decision-kind)
   (status :initarg :status :reader review-decision-status)
   (feedback :initarg :feedback :initform "" :reader review-decision-feedback)
   (related-step-index :initarg :related-step-index :initform nil
                       :reader review-decision-related-step-index))
  (:documentation "One review gate outcome. STATUS is :APPROVED or :REJECTED."))

(defun make-review-decision (&key kind (status :approved) feedback
                                  related-step-index)
  (unless (member status '(:approved :rejected))
    (error "review-decision: bad status ~S" status))
  (make-instance 'review-decision
                 :kind kind
                 :status status
                 :feedback (or feedback "")
                 :related-step-index related-step-index))

(defun review-decision-approved-p (decision)
  (eq :approved (review-decision-status decision)))

(defclass test-record ()
  ((step-index :initarg :step-index :reader test-record-step-index)
   (test-name :initarg :test-name :reader test-record-test-name)
   (source :initarg :source :reader test-record-source)
   (criteria :initarg :criteria :initform nil :reader test-record-criteria))
  (:documentation "Generated test materialized after review approval."))

(defun make-test-record (&key step-index test-name source criteria)
  (make-instance 'test-record
                 :step-index step-index
                 :test-name test-name
                 :source source
                 :criteria criteria))

(defclass test-change-record ()
  ((step-index :initarg :step-index :reader test-change-record-step-index)
   (criteria :initarg :criteria :initform nil :reader test-change-record-criteria)
   (rationale :initarg :rationale :initform ""
              :reader test-change-record-rationale)
   (test-source :initarg :test-source :reader test-change-record-test-source))
  (:documentation "Additive test change requested by the implementer."))

(defun make-test-change-record (&key step-index criteria rationale test-source)
  (make-instance 'test-change-record
                 :step-index step-index
                 :criteria criteria
                 :rationale (or rationale "")
                 :test-source test-source))

(defun %strip-code-fence (text)
  (let ((open (and (stringp text) (search "```" text))))
    (if (null open)
        text
        (let* ((after-open (+ open 3))
               (close (search "```" text :start2 after-open))
               (inner (if close
                          (subseq text after-open close)
                          (subseq text after-open)))
               (nl (position #\Newline inner))
               (lang (and nl (string-trim '(#\Space #\Tab)
                                          (subseq inner 0 nl)))))
          (if (and lang (plusp (length lang)) (every #'alpha-char-p lang))
              (subseq inner (1+ nl))
              inner)))))

(defun %coerce-spec-entry (item field raw)
  "Return ITEM as a string. Accept either a plain string or a single-string
hash-table value (some reasoning models wrap each list entry in
`{\"criterion\": \"...\"}` etc.). Signal REVIEW-ERROR otherwise."
  (cond
    ((stringp item) item)
    ((hash-table-p item)
     (let ((strings '()))
       (maphash (lambda (k v)
                  (declare (ignore k))
                  (when (stringp v) (push v strings)))
                item)
       (cond
         ((= 1 (length strings)) (first strings))
         (t (error 'review-error
                   :message (format nil
                                    "~A entries must be strings (found object with ~D string value~:P)"
                                    field (length strings))
                   :raw raw)))))
    (t (error 'review-error
              :message (format nil "~A entries must be strings" field)
              :raw raw))))

(defun %json-list-of-strings (raw field)
  (cond
    ((null raw) nil)
    ((or (vectorp raw) (listp raw))
     (let ((items (if (vectorp raw) (coerce raw 'list) raw)))
       (mapcar (lambda (item) (%coerce-spec-entry item field raw)) items)))
    (t (error 'review-error
              :message (format nil "~A must be an array of strings" field)
              :raw raw))))

(defun %parse-develop-spec (goal text)
  (let ((parsed (handler-case (yason:parse (%strip-code-fence text))
                  (error (c)
                    (error 'review-error
                           :message (format nil "spec JSON decode failed: ~A" c)
                           :raw text)))))
    (unless (hash-table-p parsed)
      (error 'review-error :message "spec response must be an object" :raw parsed))
    (let ((criteria (%json-list-of-strings
                     (gethash "acceptance_criteria" parsed)
                     "acceptance_criteria")))
      (make-develop-spec
       :goal goal
       :acceptance-criteria (or criteria (list goal))
       :non-goals (%json-list-of-strings (gethash "non_goals" parsed)
                                         "non_goals")
       :risks (%json-list-of-strings (gethash "risks" parsed) "risks")))))

(defun generate-develop-spec (goal &key provider &allow-other-keys)
  "Return a DEVELOP-SPEC for GOAL.

When PROVIDER is NIL, return a deterministic single-criterion spec so
stub-driven tests and external callers without a live LLM keep working."
  (if (null provider)
      (make-develop-spec :goal goal :acceptance-criteria (list goal))
      (let* ((prompt
               (format nil
                       "Extract acceptance criteria for this Common Lisp development goal.~%~
Return exactly JSON: {\"acceptance_criteria\":[\"...\",\"...\"],\"non_goals\":[\"...\"],\"risks\":[\"...\"]}~%~
Each list entry MUST be a plain JSON string, not an object. Example: \"acceptance_criteria\":[\"function FOO exists\",\"FOO(1) returns 2\"]. Do NOT wrap entries in objects like {\"criterion\":\"...\"}.~%~
Rules: acceptance criteria must be directly entailed by the goal and observable by tests. Do not invent extra examples, immutability requirements, allocation requirements, error signaling, type validation, or edge cases unless the goal explicitly requires them. For a phrase like \"takes one string argument\", require the positive string-input behavior and exported callable signature; do not require non-string or wrong-arity error tests unless requested. Put plausible but unstated behavior in non_goals or risks, not acceptance_criteria.~%~
Goal: ~A"
                       goal))
             (resp (complete-chat
                    provider
                    (list (make-chat-message
                          "system"
                           "You convert development goals into concise, non-invented acceptance criteria.")
                          (make-chat-message "user" prompt))))
             (content (chat-response-content resp)))
        (unless (and (stringp content) (plusp (length content)))
          (error 'review-error :message "spec generator returned empty content"))
        (%parse-develop-spec goal content))))

(defun %format-spec (spec)
  (with-output-to-string (s)
    (format s "Goal: ~A~%" (develop-spec-goal spec))
    (format s "Acceptance criteria:~%")
    (loop for ac in (develop-spec-acceptance-criteria spec)
          for i from 1
          do (format s "- AC-~D: ~A~%" i ac))
    (when (develop-spec-non-goals spec)
      (format s "Non-goals: ~{~A~^; ~}~%" (develop-spec-non-goals spec)))
    (when (develop-spec-risks spec)
      (format s "Risks: ~{~A~^; ~}~%" (develop-spec-risks spec)))))

(defun %format-plan (plan)
  (with-output-to-string (s)
    (dolist (step plan)
      (format s "Step ~D: ~A~%Test: ~A~%Criteria hint: ~{~A~^; ~}~%~A~%~%"
              (plan-step-index step)
              (plan-step-issue step)
              (plan-step-test-name step)
              (plan-step-acceptance-criteria step)
              (plan-step-test-source step)))))

(defun %artifact-text (kind &key develop-spec plan step test-change-action
                            implementation-summary)
  (with-output-to-string (s)
    (format s "Review kind: ~A~%~%" kind)
    (when develop-spec
      (format s "Develop spec:~%~A~%" (%format-spec develop-spec)))
    (when plan
      (format s "Plan and generated tests:~%~A~%" (%format-plan plan)))
    (when step
      (format s "Current step: ~D ~A~%"
              (plan-step-index step)
              (plan-step-test-name step)))
    (when test-change-action
      (format s "Test change request:~%~A~%" test-change-action))
    (when implementation-summary
      (format s "Implementation summary:~%~A~%" implementation-summary))))

(defun %parse-review-decision (kind text &key related-step-index)
  (let ((parsed (handler-case (yason:parse (%strip-code-fence text))
                  (error (c)
                    (error 'review-error
                           :message (format nil "review JSON decode failed: ~A" c)
                           :raw text)))))
    (unless (hash-table-p parsed)
      (error 'review-error :message "review response must be an object" :raw parsed))
    (let* ((status-raw (gethash "status" parsed))
           (status (cond
                     ((equal status-raw "approved") :approved)
                     ((equal status-raw "rejected") :rejected)
                     (t (error 'review-error
                               :message "review status must be approved or rejected"
                               :raw parsed)))))
      (make-review-decision
       :kind kind
       :status status
       :feedback (or (gethash "feedback" parsed) "")
       :related-step-index related-step-index))))

(defparameter +default-review-system-prompt+
  ;; Backlog #54: prior prompt was "You are a strict development reviewer"
  ;; + 4 negative criteria with no positive lift, which biased Qwen3.6
  ;; toward rejection (2026-05-24 #48+#50 verification bench saw
  ;; :MAX-REVIEW-REPLANS jump 1→4 after patch quality improved). New
  ;; prompt is balanced: approve-by-default, require concrete defects
  ;; to reject, enumerate non-grounds.
  (concatenate
   'string
   "You are a development reviewer. Return exactly JSON: "
   "{\"status\":\"approved\"|\"rejected\",\"feedback\":\"...\"}."
   (string #\Newline) (string #\Newline)
   "APPROVE BY DEFAULT. Only reject when you can cite a CONCRETE defect "
   "in the artifact against the provided acceptance criteria. The four "
   "rejection criteria, each requiring a citation in feedback:"
   (string #\Newline)
   "  1. A test directly checks the inverse of what an acceptance "
   "criterion asks for (e.g. asserts the function FAILS when the goal "
   "says it returns a value)."
   (string #\Newline)
   "  2. A step's plan adds a feature that the acceptance criteria and "
   "non-goals do not mention (scope drift)."
   (string #\Newline)
   "  3. A test was weakened — assertions removed or relaxed without "
   "the goal explicitly relaxing them."
   (string #\Newline)
   "  4. An implementation summary admits skipping a listed acceptance "
   "criterion or a non-goal it should have honored."
   (string #\Newline) (string #\Newline)
   "Do NOT reject for: stylistic preferences, missing comments / "
   "docstrings, alternative-but-equivalent designs, choice of "
   "single-symbol vs multi-symbol patches, optional CL features "
   "(use of CLOS vs structs vs cons), or hypothetical \"could be "
   "improved\" suggestions. Do not invent acceptance criteria the "
   "goal did not state."
   (string #\Newline) (string #\Newline)
   "If unsure, approve and leave feedback empty. The agent loop has "
   "limited review budget; a wrongful reject costs an entire replan "
   "cycle, while a wrongful approve still gets caught by the next "
   "verify pass.")
  "Default system prompt for REVIEW-DEVELOPMENT-ARTIFACT. Pinned by
`default-review-system-prompt-is-approve-by-default' test (#54).")

(defun review-development-artifact (kind &key provider develop-spec plan step
                                           test-change-action
                                           implementation-summary
                                           &allow-other-keys)
  "Review one DEVELOP artifact. Returns a REVIEW-DECISION.

When PROVIDER is NIL, approve deterministically. This preserves
stub-driven unit tests and lets callers opt into the state plumbing
before enabling live review calls."
  (if (null provider)
      (make-review-decision :kind kind :status :approved)
      (let* ((prompt (%artifact-text
                      kind
                      :develop-spec develop-spec
                      :plan plan
                      :step step
                      :test-change-action test-change-action
                      :implementation-summary implementation-summary))
             (resp (complete-chat
                    provider
                    (list
                     (make-chat-message "system"
                                        +default-review-system-prompt+)
                     (make-chat-message "user" prompt))))
             (content (chat-response-content resp)))
        (unless (and (stringp content) (plusp (length content)))
          (error 'review-error :message "reviewer returned empty content"))
        (%parse-review-decision
         kind content
         :related-step-index (and step (plan-step-index step))))))

(defun format-review-decision (decision)
  (format nil "~(~A~): ~(~A~)~@[ - ~A~]"
          (review-decision-kind decision)
          (review-decision-status decision)
          (let ((feedback (review-decision-feedback decision)))
            (and feedback (plusp (length feedback)) feedback))))
