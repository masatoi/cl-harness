;;;; next/tests/variant-test.lisp
;;;;
;;;; Tests for next/src/variant.lisp (spec §10.2 stage 3, §10.4
;;;; safety): fail-closed proposal parsing (LLM-supplied names are
;;;; never interned), exactly-one-mutation application, pack-form
;;;; reconstruction with a version bump.

(defpackage #:cl-harness-next/tests/variant-test
  (:use #:cl #:rove)
  (:import-from #:cl-harness-next/src/policy-pack
                #:load-policy-pack
                #:pack-name
                #:pack-version
                #:pack-prompt
                #:pack-budget
                #:pack-fingerprint)
  (:import-from #:cl-harness-next/src/variant
                #:variant
                #:variant-kind
                #:variant-target
                #:variant-value
                #:variant-hypothesis
                #:parse-variant
                #:pack-form
                #:apply-variant
                #:write-pack-form
                #:propose-variant))

(in-package #:cl-harness-next/tests/variant-test)

(defparameter *pack-text*
  "(:name \"p\"
    :version \"1.2.3\"
    :prompts ((:id :agent-system :text \"You are the agent.\"))
    :budgets ((:id :max-actions :value 20)
              (:id :max-patches :value 5)))")

(defmacro with-pack ((pack) &body body)
  `(uiop:with-temporary-file (:pathname pack-path :type "sexp")
     (with-open-file (out pack-path :direction :output
                                    :if-exists :supersede
                                    :external-format :utf-8)
       (write-string *pack-text* out))
     (let ((,pack (load-policy-pack pack-path)))
       ,@body)))

(deftest parse-variant-accepts-the-three-kinds
  (let ((budget (parse-variant
                 (concatenate 'string
                              "{\"kind\":\"budget\",\"target\":\"max-actions\","
                              "\"value\":40,\"hypothesis\":\"more room\"}"))))
    (ok (eq :budget (variant-kind budget)))
    (ok (equal "max-actions" (variant-target budget)))
    (ok (= 40 (variant-value budget)))
    (ok (equal "more room" (variant-hypothesis budget))))
  (ok (eq :prompt (variant-kind (parse-variant
                                 (concatenate 'string
                                              "{\"kind\":\"prompt\","
                                              "\"target\":\"agent-system\","
                                              "\"value\":\"Be terse.\","
                                              "\"hypothesis\":\"h\"}")))))
  (ok (eq :code (variant-kind (parse-variant
                               "{\"kind\":\"code\",\"hypothesis\":\"h\"}")))))

(deftest parse-variant-fails-closed
  (dolist (bad '("not json" "{\"kind\":\"magic\",\"hypothesis\":\"h\"}"
                 "{\"kind\":\"budget\",\"target\":\"x\"}"))
    (ok (null (parse-variant bad))
        (format nil "~S should not parse" bad))))

(deftest pack-form-roundtrips-with-a-version-bump
  (with-pack (pack)
    (uiop:with-temporary-file (:pathname new-path :type "sexp")
      (write-pack-form (pack-form pack) new-path)
      (let ((reloaded (load-policy-pack new-path)))
        (ok (equal "p" (pack-name reloaded)))
        (ok (equal "1.2.4" (pack-version reloaded)))
        (ok (equal "You are the agent." (pack-prompt reloaded
                                                     :agent-system)))
        (ok (= 20 (pack-budget reloaded :max-actions)))
        (ok (not (equal (pack-fingerprint pack)
                        (pack-fingerprint reloaded))))))))

(deftest apply-variant-changes-exactly-one-entry
  (with-pack (pack)
    (uiop:with-temporary-file (:pathname new-path :type "sexp")
      (write-pack-form
       (apply-variant pack (parse-variant
                            (concatenate 'string
                                         "{\"kind\":\"budget\","
                                         "\"target\":\"max-actions\","
                                         "\"value\":40,"
                                         "\"hypothesis\":\"h\"}")))
       new-path)
      (let ((challenger (load-policy-pack new-path)))
        (ok (= 40 (pack-budget challenger :max-actions)))
        (ok (= 5 (pack-budget challenger :max-patches)))
        (ok (equal "You are the agent."
                   (pack-prompt challenger :agent-system)))))))

(deftest apply-variant-rejects-unknown-targets
  (with-pack (pack)
    (ok (handler-case
            (progn (apply-variant pack
                                  (parse-variant
                                   (concatenate 'string
                                                "{\"kind\":\"budget\","
                                                "\"target\":\"nope\","
                                                "\"value\":1,"
                                                "\"hypothesis\":\"h\"}")))
                   nil)
          (error () t)))))

(deftest propose-variant-builds-the-prompt-and-parses
  (with-pack (pack)
    (let* ((captured (list nil))
           (variant (propose-variant
                     pack
                     '((:tool-errors . 6) (:failed-patches . 4))
                     (lambda (prompt)
                       (push prompt (car captured))
                       (concatenate 'string
                                    "{\"kind\":\"budget\","
                                    "\"target\":\"max-patches\","
                                    "\"value\":8,\"hypothesis\":\"h\"}")))))
      (ok (eq :budget (variant-kind variant)))
      (let ((prompt (first (car captured))))
        (ok (search "tool-errors" prompt))
        (ok (search "max-patches" prompt))
        (ok (search "exactly ONE" prompt))))))

(deftest propose-variant-threads-evidence-into-the-prompt
  (with-pack (pack)
    (let ((seen nil))
      (propose-variant pack '((:tool-errors . 3))
                       (lambda (prompt) (setf seen prompt) "not json")
                       :evidence "EVIDENCE-MARKER-42")
      (ok (search "EVIDENCE-MARKER-42" seen))
      (ok (search "Evidence from the transcripts" seen))
      ;; Without evidence the section is omitted entirely.
      (propose-variant pack '((:tool-errors . 3))
                       (lambda (prompt) (setf seen prompt) "not json"))
      (ok (not (search "EVIDENCE-MARKER-42" seen)))
      (ok (not (search "Evidence from the transcripts" seen))))))
