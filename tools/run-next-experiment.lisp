;;;; run-next-experiment.lisp — cl-harness-next dogfood runner
;;;;
;;;; Drives one mission against an ASDF project and exits 0 on :done.
;;;; Used to dogfood cl-harness-next on harder-than-trivial tasks; see
;;;; docs/notes/2026-06-13-next-complex-task-experiment.md.
;;;;
;;;; Required env: CL_HARNESS_LLM_{BASE_URL,API_KEY,MODEL}, MCP_PROJECT_ROOT,
;;;;   CLH_SYSTEM, CLH_TEST_SYSTEM, CLH_GOAL, CLH_DIAL (scripted|guided|adaptive).
;;;; Optional env (all opt-in): CLH_ROBUST (caller-side parse retry — now
;;;;   redundant with the in-harness obtain-action), CLH_APPENDIX (prepend a
;;;;   manual tool-schema hint), CLH_SOURCE_HINT (inject source/workspace text).
;;;; Run as a STANDALONE process, never under cl-mcp repl-eval:
;;;;   ros run --load run-next-experiment.lisp

(require :asdf)
(asdf:load-system :cl-harness-next)

(defpackage #:run-next-experiment
  (:use #:cl #:cl-harness-next))
(in-package #:run-next-experiment)

(defun env-or-die (name)
  (or (uiop:getenv name) (error "env var ~A is not set" name)))

(defparameter *project-root* (env-or-die "MCP_PROJECT_ROOT"))
(defparameter *system* (env-or-die "CLH_SYSTEM"))
(defparameter *test-system* (env-or-die "CLH_TEST_SYSTEM"))
(defparameter *goal* (env-or-die "CLH_GOAL"))
(defparameter *dial* (string-downcase (env-or-die "CLH_DIAL")))

;;; --- LLM provider (thinking off) ------------------------------------------
(defun thinking-off-extra-body ()
  (let ((ctk (make-hash-table :test 'equal))
        (top (make-hash-table :test 'equal)))
    (setf (gethash "enable_thinking" ctk) 'yason:false)
    (setf (gethash "chat_template_kwargs" top) ctk)
    top))

(defparameter *provider*
  (make-openai-provider
   :base-url   (env-or-die "CL_HARNESS_LLM_BASE_URL")
   :api-key    (env-or-die "CL_HARNESS_LLM_API_KEY")
   :model      (env-or-die "CL_HARNESS_LLM_MODEL")
   :max-tokens 8192
   :extra-body (thinking-off-extra-body)))

;;; --- shared schema appendix (patch-tool schemas + defmethod specializers) --
(defun schema-appendix (root)
  (concatenate 'string
   (string #\Newline) (string #\Newline)
   "PATCH TOOL ARGUMENT SCHEMAS — use these EXACT argument keys:" (string #\Newline)
   "- lisp-edit-form (PREFER THIS): {\"file_path\":..., \"form_type\":\"defmethod\" or "
   "\"defun\", \"form_name\":..., \"operation\":\"replace\", \"content\":\"<complete form>\"}"
   (string #\Newline)
   "- lisp-patch-form: {\"file_path\":..., \"form_type\":..., \"form_name\":..., "
   "\"old_text\":..., \"new_text\":...}" (string #\Newline)
   "For a defmethod, form_name MUST include the specializer list, e.g. "
   "\"observe ((h histogram) key)\"." (string #\Newline)
   "Use an ABSOLUTE file_path. The project root is " root
   " ; source is under " root "/src/ ." (string #\Newline)
   "You are filling in stub methods. Fix ONE failing form per turn; derive each "
   "body from the goal and the failing test values. Emit the COMPLETE form via "
   "lisp-edit-form replace." (string #\Newline)
   "Worked example (UNRELATED, do not copy literally):" (string #\Newline)
   "{\"type\":\"tool_call\",\"tool\":\"lisp-edit-form\",\"arguments\":{\"file_path\":\""
   root "/src/main.lisp\",\"form_type\":\"defmethod\",\"form_name\":\"area ((s square))\","
   "\"operation\":\"replace\",\"content\":\"(defmethod area ((s square)) (* (side s) (side s)))\"},"
   "\"thought\":\"area of a square is side squared\"}"))

;;; Optional workspace/source context. Simulates a view that carries the
;;; source file path + relevant definitions (the missing-context finding).
(defparameter *source-hint*
  (let ((h (uiop:getenv "CLH_SOURCE_HINT")))
    (if h (concatenate 'string (string #\Newline) (string #\Newline) h) "")))

;; Appendix is opt-in (CLH_APPENDIX): with the N1 harness change the tool
;; schemas are injected into the view automatically, so the bare built-in
;; prompts should suffice. Set CLH_APPENDIX=1 to also prepend the manual hint.
(defparameter *appendix*
  (if (uiop:getenv "CLH_APPENDIX") (schema-appendix *project-root*) ""))
(defparameter *scripted-prompt*
  (concatenate 'string +scripted-fix-system-prompt+ *appendix* *source-hint*))
(defparameter *guided-prompt*
  (concatenate 'string +guided-system-prompt+ *appendix* *source-hint*))

;;; Caller-side robustness: retry the LLM up to MAX-TRIES until the reply
;;; parses as a valid action. Returns the first parseable reply, or the last
;;; raw reply if all tries fail (the policy then gives up as usual). This is
;;; the mitigation proposed for the harness's fail-closed action parser.
(defun parses-p (s)
  (handler-case (progn (cl-harness-next:parse-action s) t) (error () nil)))

(defun try-normalize (raw)
  "If RAW is a JSON object with a non-empty 'tool' string but a 'type'
that is not a known action type (the model put the tool name in 'type'),
rewrite 'type' to 'tool_call' and re-encode. Returns the normalized
string when it then parses, else NIL. This is the lenient-parser
behavior proposed for the harness."
  (handler-case
      (let ((tbl (yason:parse raw)))
        (when (and (hash-table-p tbl)
                   (stringp (gethash "tool" tbl))
                   (plusp (length (gethash "tool" tbl)))
                   (not (member (gethash "type" tbl)
                                '("tool_call" "finish" "finding") :test #'equal)))
          (setf (gethash "type" tbl) "tool_call")
          (let ((s (with-output-to-string (o) (yason:encode tbl o))))
            (and (parses-p s) s))))
    (error () nil)))

(defun make-robust-judge (provider system-prompt &key (max-tries 4))
  (let ((base (make-judge-fn provider :system-prompt system-prompt)))
    (lambda (prompt)
      (let ((last ""))
        (dotimes (i max-tries last)
          (let ((resp (funcall base
                               (if (zerop i)
                                   prompt
                                   (concatenate 'string prompt (string #\Newline)
                                     "IMPORTANT: your previous reply was not a valid action. "
                                     "Reply with EXACTLY ONE valid JSON object and nothing else. "
                                     "The \"type\" field MUST be the literal string \"tool_call\" "
                                     "(NOT the tool name). No markdown fences; escape newlines as \\n.")))))
            (setf last resp)
            (cond
              ((parses-p resp) (return resp))
              ((try-normalize resp) (return (try-normalize resp))))))))))

(defparameter *robust* (uiop:getenv "CLH_ROBUST"))

(defparameter *diagnose-fn*
  (if *robust*
      (make-robust-judge *provider* *scripted-prompt*)
      (make-judge-fn *provider* :system-prompt *scripted-prompt*)))
(defparameter *step-fn*
  (if *robust*
      (make-robust-judge *provider* *guided-prompt*)
      (make-judge-fn *provider* :system-prompt *guided-prompt*)))

;;; --- factories -------------------------------------------------------------
(defun environment-factory (mission log)
  (declare (ignore mission))
  (make-cl-mcp-environment :condition :runtime-native :event-log log))

(defun make-scripted ()
  (make-instance 'scripted-fix-policy
                 :system *system* :test-system *test-system*
                 :diagnose-fn *diagnose-fn* :clear-fasls t))

(defun make-guided ()
  (make-instance 'guided-policy
                 :system *system* :test-system *test-system*
                 :step-fn *step-fn* :clear-fasls t))

(defun policy-factory (mission)
  (declare (ignore mission))
  (cond
    ((string= *dial* "scripted") (make-scripted))
    ((string= *dial* "guided") (make-guided))
    ((string= *dial* "adaptive")
     (make-instance 'adaptive-policy :levels (list (make-guided) (make-scripted))))
    (t (error "unknown CLH_DIAL ~S (use scripted|guided|adaptive)" *dial*))))

(defun governor-factory (mission)
  (declare (ignore mission))
  (make-instance 'governor
                 :max-actions 80
                 :max-consecutive-failed-patches 4
                 :max-consecutive-identical-actions 5))

;;; --- run -------------------------------------------------------------------
(defun main ()
  (let* ((log-path (merge-pathnames
                    (format nil "clh-exp-~A-~A.jsonl" *dial* (get-universal-time))
                    (uiop:temporary-directory)))
         (mission (make-instance 'mission
                                 :id (format nil "histogram-~A" *dial*)
                                 :goal *goal*
                                 :acceptance-criteria (list (format nil "~A is green" *test-system*))
                                 :log-path log-path))
         (queue (make-instance 'mission-queue)))
    (enqueue-mission queue mission)
    (format t "~&;;; dial: ~A~%;;; event log: ~A~%" *dial* log-path)
    (finish-output)
    (multiple-value-bind (status reason)
        (run-mission mission queue
                     :environment-factory #'environment-factory
                     :policy-factory #'policy-factory
                     :governor-factory #'governor-factory
                     :max-steps 150)
      (format t "~&;;; ============================================~%")
      (format t ";;; dial   : ~A~%" *dial*)
      (format t ";;; status : ~A~%" status)
      (format t ";;; reason : ~A~%" reason)
      (format t ";;; ============================================~%")
      (finish-output)
      (uiop:quit (if (eq status :done) 0 1)))))

(main)
