;;;; run-template.lisp — drive the template-fix dial against clh-histogram.
;;;; The LLM only fills method bodies; the harness FSM owns everything else.
;;;;   CL_HARNESS_LLM_* + MCP_PROJECT_ROOT(=clh-histogram) + CLH_TEMPLATE_SET(easy3|full5)
;;;;   ros run --load run-template.lisp

(require :asdf)
(asdf:load-system :cl-harness-next)
;; template-policy is reached only via the test system today (adaptive
;; wiring is a follow-up), so pull its package in explicitly.
(asdf:load-system "cl-harness-next/src/template-policy")

(defpackage #:run-template (:use #:cl #:cl-harness-next))
(in-package #:run-template)

(defun env (n) (or (uiop:getenv n) (error "missing ~A" n)))

(defun thinking-off ()
  (let ((ctk (make-hash-table :test 'equal)) (top (make-hash-table :test 'equal)))
    (setf (gethash "enable_thinking" ctk) 'yason:false
          (gethash "chat_template_kwargs" top) ctk)
    top))

(defparameter *provider*
  (make-openai-provider :base-url (env "CL_HARNESS_LLM_BASE_URL")
                        :api-key (env "CL_HARNESS_LLM_API_KEY")
                        :model (env "CL_HARNESS_LLM_MODEL")
                        :max-tokens 2048
                        :extra-body (thinking-off)))

(defparameter *snippet-fn*
  (make-judge-fn *provider*
                 :system-prompt
                 cl-harness-next/src/template-policy:+template-snippet-system-prompt+))

(defparameter *class-text*
  "(defclass histogram () ((table :initform (make-hash-table :test 'eql) :accessor histogram-table)))")

(defun tgt (sym head contract)
  (cl-harness-next/src/template-policy:make-fix-target
   :symbol sym :file "src/main.lisp" :form-type "defmethod"
   :form-name head :head head :contract contract))

(defparameter *easy3*
  (list (tgt "OBSERVE" "observe ((h histogram) key)"
             "Increment KEY's count in the histogram and return the new count.")
        (tgt "COUNT-OF" "count-of ((h histogram) key)"
             "Return KEY's count, or 0 if never observed.")
        (tgt "DISTINCT" "distinct ((h histogram))"
             "Return the number of distinct keys observed.")))

(defparameter *full5*
  (append *easy3*
          (list (tgt "TOTAL" "total ((h histogram))"
                     "Return the sum of all counts.")
                (tgt "TOP-KEY" "top-key ((h histogram))"
                     "Return the key with the highest count (any one on a tie)."))))

(defun targets ()
  (if (equal (uiop:getenv "CLH_TEMPLATE_SET") "full5") *full5* *easy3*))

(defun env-factory (mission log)
  (declare (ignore mission))
  (make-cl-mcp-environment :condition :runtime-native :event-log log))

(defun policy-factory (mission)
  (declare (ignore mission))
  (if (uiop:getenv "CLH_DISCOVER")
      ;; B2: no injected targets — the FSM reads src/main.lisp and discovers
      ;; the stubs + class + package itself.
      (make-instance 'cl-harness-next/src/template-policy:template-fix-policy
                     :system "clh-histogram" :test-system "clh-histogram/tests"
                     :snippet-fn *snippet-fn*
                     :source-files (list "src/main.lisp")
                     :clear-fasls t :k 3)
      (make-instance 'cl-harness-next/src/template-policy:template-fix-policy
                     :system "clh-histogram" :test-system "clh-histogram/tests"
                     :sut-package "CLH-HISTOGRAM/SRC/MAIN"
                     :snippet-fn *snippet-fn* :class-text *class-text*
                     :targets (targets) :clear-fasls t :k 3)))

(defun governor-factory (mission)
  (declare (ignore mission))
  ;; The FSM's own K+park bounds futility; relax the governor's guards.
  (make-instance 'governor :max-actions 300
                 :max-consecutive-failed-patches nil
                 :max-stalled-verify-cycles nil
                 :max-consecutive-identical-actions nil))

(defun main ()
  (let* ((log-path (merge-pathnames (format nil "tmpl-~A.jsonl" (get-universal-time))
                                    (uiop:temporary-directory)))
         (mission (make-instance 'mission :id "tmpl-histogram"
                                 :goal "Implement the histogram method stubs."
                                 :log-path log-path))
         (queue (make-instance 'mission-queue)))
    (enqueue-mission queue mission)
    (format t "~&;;; template log: ~A~%;;; mode: ~A~%"
            log-path (if (uiop:getenv "CLH_DISCOVER") "discover-from-source" "injected-targets"))
    (finish-output)
    (multiple-value-bind (status reason)
        (run-mission mission queue
                     :environment-factory #'env-factory
                     :policy-factory #'policy-factory
                     :governor-factory #'governor-factory
                     :max-steps 300)
      (format t "~&;;; ============================================~%")
      (format t ";;; STATUS: ~A~%;;; REASON: ~A~%" status reason)
      (format t ";;; ============================================~%")
      (finish-output)
      (uiop:quit (if (eq status :done) 0 1)))))

(main)
