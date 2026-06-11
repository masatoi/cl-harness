;;;; next/tests/policy-pack-test.lisp
;;;;
;;;; Unit tests for next/src/policy-pack.lisp: semver, hardened sexp
;;;; loading, schema validation, accessors, content fingerprint
;;;; (spec §10.1 — policy pack as versioned, fingerprinted data).

(defpackage #:cl-harness-next/tests/policy-pack-test
  (:use #:cl #:rove)
  (:import-from #:cl-harness-next/src/policy-pack
                #:parse-semver
                #:semver<
                #:load-policy-pack
                #:policy-pack-invalid
                #:pack-name
                #:pack-version
                #:pack-prompts))

(in-package #:cl-harness-next/tests/policy-pack-test)

(deftest semver-parses-to-integer-triple
  (ok (equal '(1 2 3) (parse-semver "1.2.3")))
  (ok (equal '(0 1 0) (parse-semver "0.1.0"))))

(deftest semver-rejects-non-semver
  (dolist (bad '("1.2" "1.2.3.4" "1.2.x" "" "v1.2.3"))
    (ok (handler-case (progn (parse-semver bad) nil)
          (error () t))
        (format nil "~S should not parse" bad))))

(deftest semver-comparison
  (ok (semver< "0.9.9" "0.10.0"))
  (ok (semver< "1.0.0" "2.0.0"))
  (ok (semver< "1.0.0" "1.0.1"))
  (ok (not (semver< "1.0.0" "1.0.0")))
  (ok (not (semver< "2.0.0" "1.9.9"))))

(defparameter *valid-pack-text*
  "(:name \"default\"
    :version \"0.1.0\"
    :prompts ((:id :agent-system :text \"You are the agent.\"))
    :budgets ((:id :max-turns :value 20))
    :oracle-profiles ((:id :review-tests :strictness :strict))
    :dial-rules ((:id :default-dial :value :scripted)))")

(defun write-pack-file (path text)
  (with-open-file (out path :direction :output :if-exists :supersede
                            :external-format :utf-8)
    (write-string text out)))

(defmacro with-pack-file ((path text) &body body)
  `(uiop:with-temporary-file (:pathname ,path :type "sexp")
     (write-pack-file ,path ,text)
     ,@body))

(deftest valid-pack-loads
  (with-pack-file (path *valid-pack-text*)
    (let ((pack (load-policy-pack path)))
      (ok (equal "default" (pack-name pack)))
      (ok (equal "0.1.0" (pack-version pack)))
      (ok (= 1 (length (pack-prompts pack)))))))

(deftest minimal-pack-loads
  ;; Sections are optional; only :name and :version are required.
  (with-pack-file (path "(:name \"tiny\" :version \"0.1.0\")")
    (let ((pack (load-policy-pack path)))
      (ok (equal "tiny" (pack-name pack)))
      (ok (null (pack-prompts pack))))))

(deftest missing-version-is-invalid
  (with-pack-file (path "(:name \"x\")")
    (ok (handler-case (progn (load-policy-pack path) nil)
          (policy-pack-invalid () t)))))

(deftest non-semver-version-is-invalid
  (with-pack-file (path "(:name \"x\" :version \"1.2\")")
    (ok (handler-case (progn (load-policy-pack path) nil)
          (policy-pack-invalid () t)))))

(deftest unknown-top-level-key-is-invalid
  (with-pack-file (path "(:name \"x\" :version \"0.1.0\" :surprise 1)")
    (ok (handler-case (progn (load-policy-pack path) nil)
          (policy-pack-invalid () t)))))

(deftest entry-without-id-is-invalid
  (with-pack-file (path "(:name \"x\" :version \"0.1.0\"
                          :budgets ((:value 20)))")
    (ok (handler-case (progn (load-policy-pack path) nil)
          (policy-pack-invalid () t)))))

(deftest read-eval-is-rejected
  (with-pack-file (path "(:name \"x\" :version \"0.1.0\"
                          :budgets ((:id :n :value #.(+ 1 2))))")
    (ok (handler-case (progn (load-policy-pack path) nil)
          (policy-pack-invalid () t)))))

(deftest trailing-form-is-invalid
  (with-pack-file (path "(:name \"x\" :version \"0.1.0\") (:extra)")
    (ok (handler-case (progn (load-policy-pack path) nil)
          (policy-pack-invalid () t)))))
