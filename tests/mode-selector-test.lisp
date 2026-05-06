;;;; tests/mode-selector-test.lisp
;;;;
;;;; v0.4 Phase 6 unit tests for the development MODE selector.
;;;; Covers:
;;;;   - planner.lisp: :MODE kwarg validation + Mode: line injection
;;;;     into the user prompt.
;;;;   - orchestrator.lisp: %APPLY-MODE-TO-PLAN normalises plan-step
;;;;     needs-exploration mechanically (independent of what the
;;;;     planner actually returned).
;;;;   - cli-main.lisp: PARSE-MODE maps shell strings to keywords.

(defpackage #:cl-harness/tests/mode-selector-test
  (:use #:cl #:rove)
  (:import-from #:cl-harness/src/planner
                #:plan-step
                #:plan-step-needs-exploration
                #:plan-development
                #:planner-error
                #:+supported-development-modes+)
  (:import-from #:cl-harness/src/model
                #:complete-chat
                #:chat-response)
  (:import-from #:cl-harness/src/orchestrator
                #:develop
                #:develop-result-status)
  (:import-from #:cl-harness/src/cli-main
                #:parse-mode))

(in-package #:cl-harness/tests/mode-selector-test)

;; --- planner :mode ------------------------------------------------------

(defclass capturing-provider (cl-harness/src/model:model-provider)
  ((captured-messages :accessor capturing-provider-messages :initform nil)
   (canned-content :initarg :canned-content :reader capturing-provider-canned)))

(defmethod complete-chat ((p capturing-provider) messages
                          &key temperature max-tokens reasoning-effort extra-body)
  (declare (ignore temperature max-tokens reasoning-effort extra-body))
  (setf (capturing-provider-messages p) messages)
  (make-instance 'chat-response
                 :content (capturing-provider-canned p)
                 :role "assistant"
                 :finish-reason "stop"
                 :prompt-tokens 0
                 :completion-tokens 0
                 :total-tokens 0))

(defun %fresh-capturing-provider ()
  (make-instance 'capturing-provider
                 :canned-content
                 "{\"steps\":[{\"issue\":\"i\",\"test_name\":\"t\",\"test_source\":\"(deftest t (ok t))\"}]}"))

(defun %user-content (provider)
  (let* ((messages (capturing-provider-messages provider))
         (user (find "user" messages
                     :test #'string=
                     :key (lambda (m) (gethash "role" m)))))
    (and user (gethash "content" user))))

(deftest plan-development-injects-top-down-mode-line
  (let ((p (%fresh-capturing-provider)))
    (plan-development "ship X" :provider p :mode :top-down)
    (let ((u (%user-content p)))
      (ok (search "Mode: top-down" u))
      (ok (search "implement-first" u)))))

(deftest plan-development-injects-bottom-up-mode-line
  (let ((p (%fresh-capturing-provider)))
    (plan-development "ship X" :provider p :mode :bottom-up)
    (let ((u (%user-content p)))
      (ok (search "Mode: bottom-up" u))
      (ok (search "explore-first" u)))))

(deftest plan-development-mixed-mode-omits-nudge
  (let ((p (%fresh-capturing-provider)))
    (plan-development "ship X" :provider p :mode :mixed)
    (let ((u (%user-content p)))
      (ok (not (search "Mode: top-down" u)))
      (ok (not (search "Mode: bottom-up" u))))))

(deftest plan-development-rejects-unsupported-mode
  (let ((p (%fresh-capturing-provider)))
    (ok (handler-case
            (progn (plan-development "ship X" :provider p :mode :ultra)
                   nil)
          (planner-error () t)))))

(deftest +supported-development-modes+-lists-three-keys
  (ok (equal '(:top-down :bottom-up :mixed)
             +supported-development-modes+)))

;; --- orchestrator mode normalisation ------------------------------------

(defun %make-test-file (path)
  (ensure-directories-exist path)
  (with-open-file (out path :direction :output
                            :if-exists :supersede
                            :if-does-not-exist :create)
    (format out "(defpackage #:demo/tests/main-test (:use #:cl #:rove))~%")
    (format out "(in-package #:demo/tests/main-test)~%")))

(defun %tmp-path (name)
  (merge-pathnames (format nil "cl-harness-mode-test-~A-~A"
                           name (get-internal-real-time))
                   (uiop:temporary-directory)))

(defun %make-step (index name needs)
  (make-instance 'plan-step
                 :index index
                 :issue (format nil "issue ~D" index)
                 :test-name name
                 :test-source (format nil "(deftest ~A (ok t))" name)
                 :needs-exploration needs))

(defun %canned-planner (plan)
  "Hand back PLAN unchanged on every planner call."
  (lambda (goal &key project-root system test-system provider
                     prior-plan failure-context system-prompt
                     project-inventory mode)
    (declare (ignore goal project-root system test-system provider
                     prior-plan failure-context system-prompt
                     project-inventory mode))
    plan))

(defun %recording-runner ()
  "Run-fn that always returns :passed. The test inspects the mutated
plan steps directly, not the runner's view of them."
  (lambda (config provider mcp-client policy logger
           &key clean-verify-p dry-run-p before-clean-verify-fn
                isolate-asdf-p)
    (declare (ignore config provider mcp-client policy logger
                     clean-verify-p dry-run-p
                     before-clean-verify-fn isolate-asdf-p))
    (alexandria:alist-hash-table
     `(("status" . :passed)
       ("turn" . 1)
       ("token-total" . 100))
     :test 'equal)))

(defun %recording-explorer (memo log)
  "Explore-fn that records the plan-steps it gets called with into LOG
(a cons cell) and returns a stub explore-result."
  (lambda (config provider mcp-client policy logger
           &key max-turns plan-step)
    (declare (ignore config provider mcp-client policy logger max-turns))
    (push plan-step (car log))
    (make-instance 'cl-harness/src/explore:explore-result
                   :status :reported :memo memo :turns 1 :token-total 0)))

(defmacro with-mode-fixture ((root-var test-file-var log-path-var) &body body)
  `(let* ((,root-var (uiop:temporary-directory))
          (,test-file-var (%tmp-path "tf"))
          (,log-path-var (%tmp-path "log")))
     (unwind-protect
          (progn (%make-test-file ,test-file-var) ,@body)
       (when (probe-file ,test-file-var) (delete-file ,test-file-var))
       (when (probe-file ,log-path-var) (delete-file ,log-path-var)))))

(deftest top-down-coerces-needs-exploration-to-none
  (let ((plan (list (%make-step 0 "a" :lightweight)
                    (%make-step 1 "b" :deep)))
        (explore-log (cons '() nil)))
    (with-mode-fixture (root tf log)
      (let ((result (develop "g"
                             :project-root (namestring root)
                             :system "demo" :test-system "demo/tests"
                             :test-file tf :log-path log
                             :mode :top-down
                             :planner-fn (%canned-planner plan)
                             :run-fn (%recording-runner)
                             :explore-fn (%recording-explorer "x" explore-log))))
        (ok (eq :passed (develop-result-status result))
            "top-down plan still passes")
        (ok (every (lambda (s) (eq :none (plan-step-needs-exploration s))) plan)
            "every step's needs-exploration mutated to :none")
        (ok (null (car explore-log))
            "no explore call happened — top-down skipped exploration")))))

(deftest bottom-up-promotes-none-to-lightweight
  (let ((plan (list (%make-step 0 "a" :none)
                    (%make-step 1 "b" nil)
                    (%make-step 2 "c" :deep)))
        (explore-log (cons '() nil)))
    (with-mode-fixture (root tf log)
      (let ((result (develop "g"
                             :project-root (namestring root)
                             :system "demo" :test-system "demo/tests"
                             :test-file tf :log-path log
                             :mode :bottom-up
                             :planner-fn (%canned-planner plan)
                             :run-fn (%recording-runner)
                             :explore-fn (%recording-explorer "x" explore-log))))
        (ok (eq :passed (develop-result-status result)))
        (ok (eq :lightweight (plan-step-needs-exploration (first plan))))
        (ok (eq :lightweight (plan-step-needs-exploration (second plan))))
        (ok (eq :deep (plan-step-needs-exploration (third plan)))
            "explicit :deep is preserved (not downgraded)")
        (ok (= 3 (length (car explore-log)))
            "all three steps invoked the explorer")))))

(deftest mixed-leaves-planner-choices-intact
  (let ((plan (list (%make-step 0 "a" :none)
                    (%make-step 1 "b" :lightweight)))
        (explore-log (cons '() nil)))
    (with-mode-fixture (root tf log)
      (let ((result (develop "g"
                             :project-root (namestring root)
                             :system "demo" :test-system "demo/tests"
                             :test-file tf :log-path log
                             :mode :mixed
                             :planner-fn (%canned-planner plan)
                             :run-fn (%recording-runner)
                             :explore-fn (%recording-explorer "x" explore-log))))
        (ok (eq :passed (develop-result-status result)))
        (ok (eq :none (plan-step-needs-exploration (first plan))))
        (ok (eq :lightweight (plan-step-needs-exploration (second plan))))
        (ok (= 1 (length (car explore-log)))
            "only the :lightweight step asked for exploration")))))

(deftest develop-rejects-unsupported-mode
  (with-mode-fixture (root tf log)
    (ok (handler-case
            (progn
              (develop "g"
                       :project-root (namestring root)
                       :system "demo" :test-system "demo/tests"
                       :test-file tf :log-path log
                       :mode :nonsense
                       :planner-fn (%canned-planner (list))
                       :run-fn (%recording-runner))
              nil)
          (error () t)))))

;; --- shell CLI parser ---------------------------------------------------

(deftest parse-mode-accepts-supported-strings
  (ok (eq :top-down (parse-mode "top-down")))
  (ok (eq :bottom-up (parse-mode "bottom-up")))
  (ok (eq :mixed (parse-mode "mixed")))
  (ok (eq :mixed (parse-mode nil)) "nil → :mixed default"))

(deftest parse-mode-is-case-insensitive
  (ok (eq :top-down (parse-mode "Top-Down")))
  (ok (eq :bottom-up (parse-mode "BOTTOM-UP"))))

(deftest parse-mode-rejects-unknown
  (ok (handler-case (progn (parse-mode "sideways") nil)
        (error () t))))
