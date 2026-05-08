;;;; tools/chaos-probe.lisp
;;;;
;;;; Manual end-to-end failure-mode probe against a real LLM endpoint.
;;;; Verifies that cl-harness:develop terminates with the expected
;;;; :error / :give-up reason for each of three deliberately-broken
;;;; scenarios. Exits 0 if all pass; 1 otherwise.
;;;;
;;;; Usage (from the cl-harness repo root):
;;;;
;;;;   CL_HARNESS_LLM_BASE_URL=http://192.168.0.17:8000/v1   \
;;;;   CL_HARNESS_LLM_API_KEY=foo                             \
;;;;   CL_HARNESS_LLM_MODEL=Qwen/Qwen3.6-35B-A3B              \
;;;;   sbcl --noinform --non-interactive --load tools/chaos-probe.lisp
;;;;
;;;; The probe scenarios deliberately INHERIT the env's BASE-URL and
;;;; MODEL where appropriate (P1, P2-skipped); P3 (unreachable URL) and
;;;; P4 (bad API key) override their respective values to force the
;;;; failure mode regardless of the env config.
;;;;
;;;; P2 (length truncation) is hard to make deterministic across models —
;;;; documented for ad-hoc verification, not auto-asserted here.

(asdf:load-asd
 (merge-pathnames "../cl-harness.asd"
                  (or *load-pathname*
                      (error "tools/chaos-probe.lisp must be loaded by --load"))))
(ql:quickload :cl-harness :silent t)

(defun %tmp-fixture (label)
  "Create a fresh temp fixture directory mirroring 100-greet's shape.
Returns (values project-root test-file)."
  (let* ((root (uiop:ensure-directory-pathname
                (merge-pathnames
                 (format nil "chaos-probe-~A-~A/" label (get-universal-time))
                 (uiop:default-temporary-directory))))
         (src-dir (merge-pathnames "src/" root))
         (tests-dir (merge-pathnames "tests/" root))
         (asd (merge-pathnames "greet.asd" root))
         (src-main (merge-pathnames "main.lisp" src-dir))
         (test-file (merge-pathnames "main-test.lisp" tests-dir)))
    (uiop:ensure-all-directories-exist
     (list root src-dir tests-dir))
    (with-open-file (s asd :direction :output :if-does-not-exist :create
                           :if-exists :supersede)
      (format s "(asdf:defsystem \"greet\" :class :package-inferred-system~%")
      (format s "  :depends-on (\"greet/src/main\")~%")
      (format s "  :in-order-to ((test-op (test-op \"greet/tests\"))))~%~%")
      (format s "(asdf:defsystem \"greet/tests\" :class :package-inferred-system~%")
      (format s "  :depends-on (\"rove\" \"greet\" \"greet/tests/main-test\")~%")
      (format s "  :perform (test-op (o c) (declare (ignore o c))))~%"))
    (with-open-file (s src-main :direction :output :if-does-not-exist :create
                                :if-exists :supersede)
      (format s "(defpackage #:greet/src/main (:use #:cl) (:export #:greet))~%")
      (format s "(in-package #:greet/src/main)~%"))
    (with-open-file (s test-file :direction :output :if-does-not-exist :create
                                 :if-exists :supersede)
      (format s "(defpackage #:greet/tests/main-test (:use #:cl #:rove))~%")
      (format s "(in-package #:greet/tests/main-test)~%"))
    (values (namestring root) (namestring test-file))))

(defun %scenario-pass-p (label expected-status expected-reason result)
  (let ((status (cl-harness:develop-result-status result))
        (reason (cl-harness:develop-result-reason result)))
    (let ((pass (and (eq expected-status status)
                     (eq expected-reason reason))))
      (format t "[~:[FAIL~;PASS~]] ~A: status=~A reason=~A (expected ~A / ~A)~%"
              pass label status reason expected-status expected-reason)
      pass)))

(defun %p1-empty-content ()
  ;; max-tokens=1 forces content=null (or near-empty) on most models.
  ;; Expect :give-up :empty-content via the empty-content fast path.
  (multiple-value-bind (root test-file) (%tmp-fixture "p1")
    (handler-case
        (let ((result (cl-harness:develop
                       :goal "Add a greet function returning Hello, NAME!"
                       :project-root root
                       :system "greet" :test-system "greet/tests"
                       :test-file test-file
                       :max-tokens 1)))
          (%scenario-pass-p "P1 empty-content" :give-up :empty-content result))
      (error (c)
        (format t "[FAIL] P1 empty-content: uncaught condition ~A~%" c)
        nil))))

(defun %p3-transport-unavailable ()
  ;; Point at a port that's almost certainly not listening — expect
  ;; :error :transport-unavailable.
  (multiple-value-bind (root test-file) (%tmp-fixture "p3")
    (handler-case
        (let ((result (cl-harness:develop
                       :goal "anything"
                       :project-root root
                       :system "greet" :test-system "greet/tests"
                       :test-file test-file
                       :base-url "http://127.0.0.1:9999/v1")))
          (%scenario-pass-p "P3 transport-unavailable"
                            :error :transport-unavailable result))
      (error (c)
        (format t "[FAIL] P3 transport-unavailable: uncaught condition ~A~%" c)
        nil))))

(defun %p4-auth-failed ()
  ;; Bad API key against the real endpoint — expect :error :auth-failed.
  ;; (Some endpoints return 200 with an envelope instead of a real 401;
  ;; in that case the test will FAIL with reason=invalid_request_error
  ;; or similar. Documented as model-dependent.)
  (multiple-value-bind (root test-file) (%tmp-fixture "p4")
    (handler-case
        (let ((result (cl-harness:develop
                       :goal "anything"
                       :project-root root
                       :system "greet" :test-system "greet/tests"
                       :test-file test-file
                       :api-key "definitely-not-a-real-key")))
          (%scenario-pass-p "P4 auth-failed" :error :auth-failed result))
      (error (c)
        (format t "[FAIL] P4 auth-failed: uncaught condition ~A~%" c)
        nil))))

(let ((p1 (%p1-empty-content))
      (p3 (%p3-transport-unavailable))
      (p4 (%p4-auth-failed)))
  (let ((all (and p1 p3 p4)))
    (format t "~%[chaos-probe] overall ~:[FAIL~;PASS~]~%" all)
    (uiop:quit (if all 0 1))))
