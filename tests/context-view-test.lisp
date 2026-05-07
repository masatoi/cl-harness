;;;; tests/context-view-test.lisp
;;;;
;;;; Phase C of the context-management refactor
;;;; (docs/context-management.md §4-§5,
;;;; docs/plans/2026-05-07-phase-c-context-view.md).
;;;; Covers MAKE-CONTEXT-VIEW data-layer construction. Per-phase
;;;; CONTEXT-VIEW->STRING formatters are tested in their own
;;;; deftests (Tasks 3-5).

(defpackage #:cl-harness/tests/context-view-test
  (:use #:cl #:rove)
  (:import-from #:cl-harness/src/state
                #:make-develop-state
                #:develop-state-current-step-index
                #:develop-state-record-source-fact
                #:develop-state-record-patch-record
                #:develop-state-record-failure
                #:develop-state-record-runtime-vocab-fact
                #:develop-state-record-repl-finding
                #:develop-state-set-project-summary
                #:develop-state-mark-project-summary-dirty)
  (:import-from #:cl-harness/src/project-summary
                #:make-project-summary)
  (:import-from #:cl-harness/src/runtime-vocabulary
                #:make-runtime-vocab-fact)
  (:import-from #:cl-harness/src/repl-finding
                #:make-repl-finding
                #:repl-finding-mark-promoted)
  (:import-from #:cl-harness/src/source-fact
                #:make-source-fact)
  (:import-from #:cl-harness/src/patch-record
                #:make-patch-record)
  (:import-from #:cl-harness/src/failure-ledger
                #:make-failure-record)
  (:import-from #:cl-harness/src/planner
                #:plan-step
                #:investigation-target)
  (:import-from #:cl-harness/src/context-view
                #:context-view
                #:make-context-view
                #:context-view-phase
                #:context-view-goal
                #:context-view-current-step
                #:context-view-relevant-source-facts
                #:context-view-relevant-patch-records
                #:context-view-active-failures
                #:context-view-prior-plan
                #:context-view-failure-context
                #:context-view-project-inventory
                #:context-view->string))

(in-package #:cl-harness/tests/context-view-test)

(defun %state ()
  (let ((s (make-develop-state :goal "implement greet"
                               :project-root "/tmp/cv-test/"
                               :system "demo"
                               :test-system "demo/tests"
                               :project-inventory "demo .asd inventory")))
    (setf (develop-state-current-step-index s) 0)
    s))

(deftest make-context-view-rejects-bad-phase
  (ok (handler-case
          (progn (make-context-view (%state) :phase :nonsense) nil)
        (error () t))))

(deftest make-context-view-planning-fills-goal-and-inventory
  (let ((v (make-context-view (%state) :phase :planning)))
    (ok (typep v 'context-view))
    (ok (eq :planning (context-view-phase v)))
    (ok (string= "implement greet" (context-view-goal v)))
    (ok (string= "demo .asd inventory"
                 (context-view-project-inventory v)))
    (ok (null (context-view-current-step v)))))

(deftest make-context-view-planning-passes-replan-context
  (let* ((s (%state))
         (v (make-context-view s :phase :planning
                                 :prior-plan '(:dummy-plan)
                                 :failure-context "step 0 failed")))
    (ok (equal '(:dummy-plan) (context-view-prior-plan v)))
    (ok (string= "step 0 failed" (context-view-failure-context v)))))

(deftest make-context-view-implementation-filters-by-step
  ;; Only ledger entries with related-step-index = current-step-index
  ;; should appear in the relevant-* slots.
  (let ((s (%state)))
    (develop-state-record-source-fact
     s (make-source-fact :path "/tmp/a.lisp" :via-tool "lisp-read-file"
                         :related-step-index 0))
    (develop-state-record-source-fact
     s (make-source-fact :path "/tmp/b.lisp" :via-tool "lisp-read-file"
                         :related-step-index 1))
    (develop-state-record-patch-record
     s (make-patch-record :path "/tmp/a.lisp" :via-tool "lisp-edit-form"
                          :turn 1 :related-step-index 0))
    (develop-state-record-patch-record
     s (make-patch-record :path "/tmp/b.lisp" :via-tool "lisp-edit-form"
                          :turn 2 :related-step-index 1))
    (let ((v (make-context-view s :phase :implementation)))
      (ok (= 1 (length (context-view-relevant-source-facts v))))
      (ok (= 1 (length (context-view-relevant-patch-records v)))))))

(deftest make-context-view-implementation-includes-active-failures
  (let ((s (%state)))
    (develop-state-record-failure
     s (make-failure-record :kind :test-failed
                            :description "greet-test fails"
                            :verify-source :incremental
                            :related-step-index 0))
    (let ((v (make-context-view s :phase :implementation)))
      (ok (= 1 (length (context-view-active-failures v)))))))

(deftest make-context-view-exploration-uses-step-arg
  (let* ((s (%state))
         (step :sentinel-step)
         (v (make-context-view s :phase :exploration :step step)))
    (ok (eq :sentinel-step (context-view-current-step v)))))

(deftest make-context-view-implementation-uses-step-arg
  (let* ((s (%state))
         (step :sentinel-step)
         (v (make-context-view s :phase :implementation :step step)))
    (ok (eq :sentinel-step (context-view-current-step v)))))

(deftest make-context-view-planning-ignores-step-arg
  (let* ((s (%state))
         (v (make-context-view s :phase :planning :step :sentinel-step)))
    (ok (null (context-view-current-step v)))))

(defun %render-planning (s &key prior-plan failure-context)
  (let ((v (make-context-view s :phase :planning
                                :prior-plan prior-plan
                                :failure-context failure-context)))
    (context-view->string v :planning)))

(deftest planning-formatter-includes-goal
  (let ((out (%render-planning (%state))))
    (ok (search "implement greet" out))))

(deftest planning-formatter-includes-project-inventory
  (let ((out (%render-planning (%state))))
    (ok (search "demo .asd inventory" out))))

(deftest planning-formatter-omits-replan-block-on-initial
  (let ((out (%render-planning (%state))))
    (ok (not (search "Prior plan" out)))
    (ok (not (search "Prior failure" out)))))

(deftest planning-formatter-includes-replan-block-on-replan
  (let ((out (%render-planning (%state)
                               :prior-plan '(:dummy)
                               :failure-context "step 0 failed")))
    (ok (search "Prior plan" out))
    (ok (search "step 0 failed" out))))

(defun %step (&key (index 0)
                (issue "Add greet function.")
                (test-name "greet-returns-hello")
                (test-source "(rove:deftest greet-returns-hello (rove:ok t))")
                (investigation-targets nil))
  (make-instance 'cl-harness/src/planner:plan-step
                 :index index
                 :issue issue
                 :test-name test-name
                 :test-source test-source
                 :investigation-targets investigation-targets))

(deftest exploration-formatter-includes-step-issue
  (let* ((s (%state))
         (v (make-context-view s :phase :exploration
                                 :step (%step :issue "Add greet."))))
    (ok (search "Add greet."
                (context-view->string v :exploration)))))

(deftest exploration-formatter-includes-investigation-targets
  (let* ((s (%state))
         (target (make-instance 'cl-harness/src/planner:investigation-target
                                :kind :function :name "existing-greeter"
                                :intent "check signature"))
         (v (make-context-view s :phase :exploration
                                 :step (%step :investigation-targets
                                              (list target)))))
    (let ((out (context-view->string v :exploration)))
      (ok (search "existing-greeter" out))
      (ok (search "check signature" out)))))

(deftest exploration-formatter-handles-no-step-gracefully
  ;; Defensive: caller passed :phase :exploration but no :step. The
  ;; formatter should not crash; it emits a "no current step" notice.
  (let* ((s (%state))
         (v (make-context-view s :phase :exploration)))
    (ok (stringp (context-view->string v :exploration)))))

(deftest exploration-formatter-summarises-relevant-source-facts
  (let ((s (%state)))
    (cl-harness/src/state:develop-state-record-source-fact
     s (cl-harness/src/source-fact:make-source-fact
        :path "/tmp/cv-test/src/greet.lisp"
        :via-tool "lisp-read-file"
        :related-step-index 0))
    (let* ((v (make-context-view s :phase :exploration
                                   :step (%step :index 0)))
           (out (context-view->string v :exploration)))
      (ok (search "greet.lisp" out)))))

(deftest exploration-formatter-source-fact-with-form-target-renders-readable
  ;; Locks in the readable form-type / form-name rendering — without
  ;; the space separator, "defun" + "greet" would smash into
  ;; "defungreet" in the LLM-facing output.
  (let ((s (%state)))
    (cl-harness/src/state:develop-state-record-source-fact
     s (cl-harness/src/source-fact:make-source-fact
        :path "/tmp/cv-test/src/greet.lisp"
        :via-tool "lisp-read-file"
        :form-type "defun"
        :form-name "greet"
        :related-step-index 0))
    (let* ((v (make-context-view s :phase :exploration
                                   :step (%step :index 0)))
           (out (context-view->string v :exploration)))
      (ok (search "defun greet" out))
      (ok (not (search "defungreet" out))))))

(deftest implementation-formatter-includes-step-issue
  (let* ((s (%state))
         (v (make-context-view s :phase :implementation
                                 :step (%step :issue "Add greet."))))
    (ok (search "Add greet."
                (context-view->string v :implementation)))))

(deftest implementation-formatter-summarises-relevant-patches
  (let ((s (%state)))
    (cl-harness/src/state:develop-state-record-patch-record
     s (cl-harness/src/patch-record:make-patch-record
        :path "/tmp/cv-test/src/greet.lisp"
        :via-tool "lisp-edit-form"
        :form-type "defun"
        :form-name "greet"
        :related-step-index 0
        :turn 1))
    (let* ((v (make-context-view s :phase :implementation
                                   :step (%step :index 0)))
           (out (context-view->string v :implementation)))
      (ok (search "greet.lisp" out))
      (ok (search "lisp-edit-form" out)))))

(deftest implementation-formatter-includes-active-failures
  (let ((s (%state)))
    (cl-harness/src/state:develop-state-record-failure
     s (cl-harness/src/failure-ledger:make-failure-record
        :kind :test-failed
        :description "greet returned wrong"
        :test-name "greet-returns-hello"
        :verify-source :incremental
        :related-step-index 0))
    (let* ((v (make-context-view s :phase :implementation
                                   :step (%step :index 0)))
           (out (context-view->string v :implementation)))
      (ok (search "greet returned wrong" out))
      (ok (search "greet-returns-hello" out)))))

(deftest implementation-formatter-omits-failure-section-when-clean
  (let* ((s (%state))
         (v (make-context-view s :phase :implementation
                                 :step (%step :index 0))))
    (ok (not (search "Active failures" (context-view->string
                                        v :implementation))))))

(deftest exploration-formatter-renders-stale-prefix-on-stale-fact
  ;; Construct a temp file, record a source-fact with an OLDER baseline
  ;; mtime, then generate the :exploration view and verify the bullet
  ;; for that fact has the [STALE] prefix.
  (let ((path #P"/tmp/cl-harness-cv-stale-test.lisp")
        (s (%state)))
    (with-open-file (out path :direction :output :if-exists :supersede
                              :if-does-not-exist :create)
      (write-string "(defun greet () 1)" out))
    (unwind-protect
         (progn
           (cl-harness/src/state:develop-state-record-source-fact
            s (cl-harness/src/source-fact:make-source-fact
               :path path
               :via-tool "lisp-read-file"
               :related-step-index 0
               :mtime-at-read 100))
           (let* ((v (make-context-view s :phase :exploration
                                          :step (%step :index 0)))
                  (out-str (context-view->string v :exploration)))
             (ok (search "[STALE]" out-str))
             (ok (search (namestring path) out-str))))
      (when (probe-file path) (delete-file path)))))

(deftest exploration-formatter-omits-stale-prefix-on-fresh-fact
  ;; Construct a temp file, record a source-fact whose mtime-at-read
  ;; equals the current file mtime (fresh); verify [STALE] is absent.
  (let ((path #P"/tmp/cl-harness-cv-fresh-test.lisp")
        (s (%state)))
    (with-open-file (out path :direction :output :if-exists :supersede
                              :if-does-not-exist :create)
      (write-string "(defun greet () 1)" out))
    (unwind-protect
         (progn
           (cl-harness/src/state:develop-state-record-source-fact
            s (cl-harness/src/source-fact:make-source-fact
               :path path
               :via-tool "lisp-read-file"
               :related-step-index 0
               :mtime-at-read (file-write-date path)))
           (let* ((v (make-context-view s :phase :exploration
                                          :step (%step :index 0)))
                  (out-str (context-view->string v :exploration)))
             (ok (search (namestring path) out-str))
             (ok (not (search "[STALE]" out-str)))))
      (when (probe-file path) (delete-file path)))))

(deftest exploration-formatter-renders-mixed-stale-and-fresh
  ;; Two facts on different files: one stale, one fresh. Both render,
  ;; but only the stale one has the [STALE] prefix.
  (let ((stale-path #P"/tmp/cl-harness-cv-mix-stale.lisp")
        (fresh-path #P"/tmp/cl-harness-cv-mix-fresh.lisp")
        (s (%state)))
    (with-open-file (out stale-path :direction :output :if-exists :supersede
                                    :if-does-not-exist :create)
      (write-string "(defun a () 1)" out))
    (with-open-file (out fresh-path :direction :output :if-exists :supersede
                                    :if-does-not-exist :create)
      (write-string "(defun b () 2)" out))
    (unwind-protect
         (progn
           (cl-harness/src/state:develop-state-record-source-fact
            s (cl-harness/src/source-fact:make-source-fact
               :path stale-path :via-tool "lisp-read-file"
               :related-step-index 0
               :mtime-at-read 100))
           (cl-harness/src/state:develop-state-record-source-fact
            s (cl-harness/src/source-fact:make-source-fact
               :path fresh-path :via-tool "lisp-read-file"
               :related-step-index 0
               :mtime-at-read (file-write-date fresh-path)))
           (let* ((v (make-context-view s :phase :exploration
                                          :step (%step :index 0)))
                  (out-str (context-view->string v :exploration)))
             ;; Stale fact gets the prefix; fresh fact does not.
             (ok (search (format nil "[STALE] ~A" (namestring stale-path))
                         out-str))
             (ok (search (namestring fresh-path) out-str))
             ;; The fresh fact's bullet should not be preceded by [STALE]
             ;; (within ~10 chars of its path occurrence).
             (let ((fresh-pos (search (namestring fresh-path) out-str)))
               (ok (or (not fresh-pos)
                       (not (search "[STALE]"
                                    (subseq out-str
                                            (max 0 (- fresh-pos 10))
                                            fresh-pos))))))))
      (when (probe-file stale-path) (delete-file stale-path))
      (when (probe-file fresh-path) (delete-file fresh-path)))))

(deftest exploration-formatter-renders-runtime-vocab-bullet
  (let ((s (make-develop-state :goal "g" :project-root "/tmp/p"
                               :system "x" :test-system "x/tests"))
        (step (make-instance 'cl-harness/src/planner:plan-step
                             :index 0 :test-name "t"
                             :test-source "(deftest t)"
                             :issue "explore the failure mode")))
    (setf (cl-harness/src/state:develop-state-current-plan s) (list step))
    (setf (develop-state-current-step-index s) 0)
    (develop-state-record-runtime-vocab-fact
     s (make-runtime-vocab-fact
        :kind :function :name "foo" :package "CL-USER"
        :via-tool "code-describe"
        :related-step-index 0))
    (let* ((view (make-context-view s :phase :exploration :step step))
           (str (context-view->string view :exploration)))
      (ok (search "Runtime vocabulary probed in this step" str))
      (ok (search "[function] CL-USER:foo" str)))))

(deftest exploration-formatter-marks-stale-runtime-vocab-fact
  (let ((path (uiop:tmpize-pathname
               (merge-pathnames "rv-cv-stale.lisp"
                                (uiop:default-temporary-directory))))
        (s (make-develop-state :goal "g" :project-root "/tmp/p"
                               :system "x" :test-system "x/tests"))
        (step (make-instance 'cl-harness/src/planner:plan-step
                             :index 0 :test-name "t"
                             :test-source "(deftest t)"
                             :issue "explore")))
    (unwind-protect
         (progn
           (with-open-file (out path :direction :output
                                     :if-does-not-exist :create
                                     :if-exists :supersede)
             (format out ";; placeholder~%"))
           (setf (cl-harness/src/state:develop-state-current-plan s) (list step))
           (setf (develop-state-current-step-index s) 0)
           (develop-state-record-runtime-vocab-fact
            s (make-runtime-vocab-fact
               :kind :function :name "foo"
               :source-file path :probed-at 100
               :via-tool "code-describe"
               :related-step-index 0))
           (let* ((view (make-context-view s :phase :exploration :step step))
                  (str (context-view->string view :exploration)))
             (ok (search "[STALE]" str))))
      (when (probe-file path) (delete-file path)))))

(deftest planning-formatter-emits-runtime-vocab-summary-when-non-empty
  (let ((s (make-develop-state :goal "g" :project-root "/tmp/p"
                               :system "x" :test-system "x/tests")))
    (develop-state-record-runtime-vocab-fact
     s (make-runtime-vocab-fact
        :kind :package :name "CL-USER" :via-tool "code-find"))
    (let* ((view (make-context-view s :phase :planning))
           (str (context-view->string view :planning)))
      (ok (search "Runtime vocabulary observed so far" str))
      (ok (search "[package] CL-USER" str)))))

(deftest planning-formatter-omits-runtime-vocab-section-when-empty
  (let* ((s (make-develop-state :goal "g" :project-root "/tmp/p"
                                :system "x" :test-system "x/tests"))
         (view (make-context-view s :phase :planning))
         (str (context-view->string view :planning)))
    (ok (null (search "Runtime vocabulary observed so far" str)))))

(deftest exploration-formatter-renders-findings-bullet
  (let ((s (make-develop-state :goal "g" :project-root "/tmp/p"
                               :system "x" :test-system "x/tests"))
        (step (make-instance 'cl-harness/src/planner:plan-step
                             :index 0 :test-name "t"
                             :test-source "(deftest t)"
                             :issue "explore the failure mode"))
        (finding (make-repl-finding
                  :hypothesis "pure function suffices"
                  :probe "(reduce #'+ '(1 2 3))"
                  :finding "returns 6"
                  :decision "promote ordinary function"
                  :related-step-index 0)))
    (setf (cl-harness/src/state:develop-state-current-plan s) (list step))
    (setf (develop-state-current-step-index s) 0)
    (develop-state-record-repl-finding s finding)
    (let* ((view (make-context-view s :phase :exploration :step step))
           (str (context-view->string view :exploration)))
      (ok (search "Findings observed in this step" str))
      (ok (search "pure function suffices" str))
      (ok (search "promote ordinary function" str))
      ;; Unpromoted findings do NOT have [PROMOTED] prefix.
      (ok (null (search "[PROMOTED]" str))))))

(deftest exploration-formatter-marks-promoted-findings
  (let ((s (make-develop-state :goal "g" :project-root "/tmp/p"
                               :system "x" :test-system "x/tests"))
        (step (make-instance 'cl-harness/src/planner:plan-step
                             :index 0 :test-name "t"
                             :test-source "(deftest t)"
                             :issue "explore"))
        (finding (make-repl-finding
                  :hypothesis "h" :probe "p" :finding "f" :decision "d"
                  :related-step-index 0)))
    (repl-finding-mark-promoted finding :linked-patch :sentinel)
    (setf (cl-harness/src/state:develop-state-current-plan s) (list step))
    (setf (develop-state-current-step-index s) 0)
    (develop-state-record-repl-finding s finding)
    (let* ((view (make-context-view s :phase :exploration :step step))
           (str (context-view->string view :exploration)))
      (ok (search "[PROMOTED]" str)))))

(deftest implementation-formatter-lists-only-unpromoted-findings
  (let ((s (make-develop-state :goal "g" :project-root "/tmp/p"
                               :system "x" :test-system "x/tests"))
        (step (make-instance 'cl-harness/src/planner:plan-step
                             :index 0 :test-name "t"
                             :test-source "(deftest t)"
                             :issue "implement"))
        (promoted (make-repl-finding
                   :hypothesis "implement greet"
                   :probe "p" :finding "f" :decision "d"
                   :related-step-index 0))
        (unpromoted (make-repl-finding
                     :hypothesis "implement zonk"
                     :probe "p" :finding "f" :decision "d"
                     :related-step-index 0)))
    (repl-finding-mark-promoted promoted :linked-patch :sentinel)
    (setf (cl-harness/src/state:develop-state-current-plan s) (list step))
    (setf (develop-state-current-step-index s) 0)
    (develop-state-record-repl-finding s promoted)
    (develop-state-record-repl-finding s unpromoted)
    (let* ((view (make-context-view s :phase :implementation :step step))
           (str (context-view->string view :implementation)))
      ;; Unpromoted hypothesis appears.
      (ok (search "implement zonk" str))
      ;; Promoted hypothesis does NOT appear in :implementation.
      (ok (null (search "implement greet" str))))))

(deftest implementation-formatter-omits-findings-section-when-all-promoted
  (let ((s (make-develop-state :goal "g" :project-root "/tmp/p"
                               :system "x" :test-system "x/tests"))
        (step (make-instance 'cl-harness/src/planner:plan-step
                             :index 0 :test-name "t"
                             :test-source "(deftest t)"
                             :issue "implement"))
        (finding (make-repl-finding
                  :hypothesis "h" :probe "p" :finding "f" :decision "d"
                  :related-step-index 0)))
    (repl-finding-mark-promoted finding :linked-patch :sentinel)
    (setf (cl-harness/src/state:develop-state-current-plan s) (list step))
    (setf (develop-state-current-step-index s) 0)
    (develop-state-record-repl-finding s finding)
    (let* ((view (make-context-view s :phase :implementation :step step))
           (str (context-view->string view :implementation)))
      ;; Section header should be absent when only promoted findings exist.
      (ok (null (search "Findings to implement" str))))))

(deftest planning-formatter-renders-project-summary-when-present
  (let ((s (cl-harness/src/state:make-develop-state
            :goal "g" :project-root "/tmp/p"
            :system "x" :test-system "x/tests"))
        (sum (cl-harness/src/project-summary:make-project-summary
              :project-root "/tmp/p/" :system "x"
              :test-system "x/tests"
              :asd-files (list "x.asd")
              :source-files (list "src/main.lisp")
              :test-files (list "tests/main-test.lisp")
              :text "raw inventory text")))
    (cl-harness/src/state:develop-state-set-project-summary s sum)
    (let* ((view (cl-harness/src/context-view:make-context-view
                  s :phase :planning))
           (str (cl-harness/src/context-view:context-view->string
                 view :planning)))
      (ok (search "## Project summary" str))
      (ok (search "x.asd" str))
      (ok (search "src/main.lisp" str))
      (ok (search "tests/main-test.lisp" str))
      ;; Not stale -- no [STALE] prefix.
      (ok (null (search "[STALE]" str))))))

(deftest planning-formatter-marks-dirty-summary-as-stale
  (let ((s (cl-harness/src/state:make-develop-state
            :goal "g" :project-root "/tmp/p"
            :system "x" :test-system "x/tests"))
        (sum (cl-harness/src/project-summary:make-project-summary
              :project-root "/tmp/p/" :system "x"
              :test-system "x/tests"
              :asd-files (list "x.asd"))))
    (cl-harness/src/state:develop-state-set-project-summary s sum)
    (cl-harness/src/state:develop-state-mark-project-summary-dirty s)
    (let* ((view (cl-harness/src/context-view:make-context-view
                  s :phase :planning))
           (str (cl-harness/src/context-view:context-view->string
                 view :planning)))
      (ok (search "[STALE]" str))
      (ok (search "Project summary" str)))))

(deftest planning-formatter-emits-both-summary-and-text-inventory
  ;; develop-state with both project-summary AND project-inventory text
  ;; populated -> structured summary first, then text inventory block.
  (let ((s (cl-harness/src/state:make-develop-state
            :goal "g" :project-root "/tmp/p"
            :system "x" :test-system "x/tests"
            :project-inventory "free-text inventory line"))
        (sum (cl-harness/src/project-summary:make-project-summary
              :project-root "/tmp/p/" :system "x"
              :test-system "x/tests"
              :asd-files (list "x.asd"))))
    (cl-harness/src/state:develop-state-set-project-summary s sum)
    (let* ((view (cl-harness/src/context-view:make-context-view
                  s :phase :planning))
           (str (cl-harness/src/context-view:context-view->string
                 view :planning))
           (sum-pos (search "Project summary" str))
           (inv-pos (search "Project inventory" str)))
      (ok (and sum-pos inv-pos))
      ;; Summary appears before inventory (structured first).
      (ok (< sum-pos inv-pos)))))

(deftest planning-formatter-omits-summary-section-when-absent
  (let* ((s (cl-harness/src/state:make-develop-state
             :goal "g" :project-root "/tmp/p"
             :system "x" :test-system "x/tests"))
         (view (cl-harness/src/context-view:make-context-view
                s :phase :planning))
         (str (cl-harness/src/context-view:context-view->string
               view :planning)))
    (ok (null (search "Project summary" str)))))

(deftest implementation-formatter-renders-completed-subtask-summaries
  ;; Build develop-state with one completed step + a patch on that
  ;; step + a current step. :implementation view should include
  ;; "## Completed subtask summaries" with one bullet for the prior
  ;; step (we only render a step when it appears in step-results
  ;; AND status :passed).
  (let ((s (cl-harness/src/state:make-develop-state
            :goal "g" :project-root "/tmp/p"
            :system "x" :test-system "x/tests"))
        (prior-step (make-instance 'cl-harness/src/planner:plan-step
                                   :index 0 :test-name "first-test"
                                   :test-source "(deftest first-test)"
                                   :issue "first thing"))
        (current-step (make-instance 'cl-harness/src/planner:plan-step
                                     :index 1 :test-name "current-test"
                                     :test-source "(deftest current-test)"
                                     :issue "current thing"))
        (prior-result (make-instance
                       'cl-harness/src/orchestrator:develop-step-result
                       :step-index 0 :test-name "first-test"
                       :run-config nil :status :passed))
        (patch (cl-harness/src/patch-record:make-patch-record
                :path "src/foo.lisp" :via-tool "lisp-edit-form"
                :form-type "defun" :form-name "bar"
                :related-step-index 0 :turn 1)))
    (cl-harness/src/state:develop-state-record-step-result s prior-result)
    (cl-harness/src/state:develop-state-record-patch-record s patch)
    (setf (cl-harness/src/state:develop-state-current-plan s)
          (list prior-step current-step))
    (setf (cl-harness/src/state:develop-state-current-step-index s) 1)
    (let* ((view (cl-harness/src/context-view:make-context-view
                  s :phase :implementation :step current-step))
           (str (cl-harness/src/context-view:context-view->string
                 view :implementation)))
      (ok (search "Completed subtask summaries" str))
      (ok (search "step 0" str))
      (ok (search "first-test" str))
      (ok (search "src/foo.lisp" str)))))

(deftest implementation-formatter-omits-summaries-when-no-prior-steps
  (let ((s (cl-harness/src/state:make-develop-state
            :goal "g" :project-root "/tmp/p"
            :system "x" :test-system "x/tests"))
        (current-step (make-instance 'cl-harness/src/planner:plan-step
                                     :index 0 :test-name "t"
                                     :test-source "(deftest t)"
                                     :issue "x")))
    (setf (cl-harness/src/state:develop-state-current-plan s)
          (list current-step))
    (setf (cl-harness/src/state:develop-state-current-step-index s) 0)
    (let* ((view (cl-harness/src/context-view:make-context-view
                  s :phase :implementation :step current-step))
           (str (cl-harness/src/context-view:context-view->string
                 view :implementation)))
      (ok (null (search "Completed subtask summaries" str))))))

(deftest implementation-formatter-renders-recently-resolved-failures
  ;; Build develop-state, push one failure-record onto the ledger,
  ;; mark it resolved, build the :implementation view, assert
  ;; "Recently resolved failures (regression watch)" appears.
  (let* ((s (cl-harness/src/state:make-develop-state
             :goal "g" :project-root "/tmp/p"
             :system "x" :test-system "x/tests"))
         (current-step (make-instance 'cl-harness/src/planner:plan-step
                                      :index 0 :test-name "t"
                                      :test-source "(deftest t)"
                                      :issue "x"))
         (failure (cl-harness/src/failure-ledger:make-failure-record
                   :kind :test-failed :description "reduced segfault"
                   :test-name "reduces-segfault"
                   :verify-source :incremental))
         (ledger (cl-harness/src/state:develop-state-failure-ledger s)))
    (cl-harness/src/failure-ledger:record-failure ledger failure)
    (cl-harness/src/failure-ledger:mark-resolved-by ledger failure)
    (setf (cl-harness/src/state:develop-state-current-plan s)
          (list current-step))
    (setf (cl-harness/src/state:develop-state-current-step-index s) 0)
    (let* ((view (cl-harness/src/context-view:make-context-view
                  s :phase :implementation :step current-step))
           (str (cl-harness/src/context-view:context-view->string
                 view :implementation)))
      (ok (search "Recently resolved failures" str))
      (ok (search "reduces-segfault" str)))))

(deftest implementation-formatter-caps-resolved-failures-at-limit
  ;; Push 5 resolved failures. Default limit is 3; only the 3 most
  ;; recent should appear.
  (let* ((s (cl-harness/src/state:make-develop-state
             :goal "g" :project-root "/tmp/p"
             :system "x" :test-system "x/tests"))
         (current-step (make-instance 'cl-harness/src/planner:plan-step
                                      :index 0 :test-name "t"
                                      :test-source "(deftest t)"
                                      :issue "x"))
         (ledger (cl-harness/src/state:develop-state-failure-ledger s)))
    (loop for i from 1 to 5
          for f = (cl-harness/src/failure-ledger:make-failure-record
                   :kind :test-failed
                   :description (format nil "failure ~D" i)
                   :test-name (format nil "test-~D" i)
                   :verify-source :incremental)
          do (cl-harness/src/failure-ledger:record-failure ledger f)
             (cl-harness/src/failure-ledger:mark-resolved-by ledger f))
    (setf (cl-harness/src/state:develop-state-current-plan s)
          (list current-step))
    (setf (cl-harness/src/state:develop-state-current-step-index s) 0)
    (let* ((view (cl-harness/src/context-view:make-context-view
                  s :phase :implementation :step current-step))
           (str (cl-harness/src/context-view:context-view->string
                 view :implementation)))
      ;; Most-recent 3 (test-3, test-4, test-5) should be present;
      ;; oldest 2 (test-1, test-2) should NOT be.
      (ok (search "test-5" str))
      (ok (search "test-4" str))
      (ok (search "test-3" str))
      (ok (null (search "test-1" str)))
      (ok (null (search "test-2" str))))))

(deftest implementation-formatter-omits-resolved-failures-when-empty
  (let ((s (cl-harness/src/state:make-develop-state
            :goal "g" :project-root "/tmp/p"
            :system "x" :test-system "x/tests"))
        (current-step (make-instance 'cl-harness/src/planner:plan-step
                                     :index 0 :test-name "t"
                                     :test-source "(deftest t)"
                                     :issue "x")))
    (setf (cl-harness/src/state:develop-state-current-plan s)
          (list current-step))
    (setf (cl-harness/src/state:develop-state-current-step-index s) 0)
    (let* ((view (cl-harness/src/context-view:make-context-view
                  s :phase :implementation :step current-step))
           (str (cl-harness/src/context-view:context-view->string
                 view :implementation)))
      (ok (null (search "Recently resolved failures" str))))))
