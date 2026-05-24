;;;; tests/review-test.lisp

(defpackage #:cl-harness/tests/review-test
  (:use #:cl #:rove)
  (:import-from #:cl-harness/src/review
                #:develop-spec
                #:make-develop-spec
                #:develop-spec-goal
                #:develop-spec-acceptance-criteria
                #:review-decision
                #:make-review-decision
                #:review-decision-kind
                #:review-decision-status
                #:review-decision-approved-p
                #:test-record
                #:make-test-record
                #:test-record-test-name
                #:test-change-record
                #:make-test-change-record
                #:test-change-record-rationale
                #:generate-develop-spec
                #:review-development-artifact))

(in-package #:cl-harness/tests/review-test)

(deftest make-develop-spec-defaults-criterion-to-goal
  (let ((spec (make-develop-spec :goal "Add greet.")))
    (ok (typep spec 'develop-spec))
    (ok (string= "Add greet." (develop-spec-goal spec)))
    (ok (equal '("Add greet.") (develop-spec-acceptance-criteria spec)))))

(deftest make-review-decision-records-status
  (let ((d (make-review-decision :kind :plan
                                 :status :rejected
                                 :feedback "missing AC-2")))
    (ok (typep d 'review-decision))
    (ok (eq :plan (review-decision-kind d)))
    (ok (eq :rejected (review-decision-status d)))
    (ok (not (review-decision-approved-p d)))))

(deftest make-test-record-captures-generated-test
  (let ((r (make-test-record :step-index 0
                             :test-name "greet-test"
                             :source "(deftest greet-test)"
                             :criteria '("AC-1"))))
    (ok (typep r 'test-record))
    (ok (string= "greet-test" (test-record-test-name r)))))

(deftest make-test-change-record-captures-rationale
  (let ((r (make-test-change-record :step-index 1
                                    :criteria '("AC-2")
                                    :rationale "missing nil case"
                                    :test-source "(deftest nil-case)")))
    (ok (typep r 'test-change-record))
    (ok (string= "missing nil case" (test-change-record-rationale r)))))

(deftest generate-develop-spec-approves-without-provider
  (let ((spec (generate-develop-spec "Add double." :provider nil)))
    (ok (typep spec 'develop-spec))
    (ok (equal '("Add double.") (develop-spec-acceptance-criteria spec)))))

(deftest parse-develop-spec-accepts-object-wrapped-entries
  ;; Some reasoning models (e.g. gpt-oss-20b on Groq) return each list entry
  ;; wrapped in a single-key object like {"criterion":"..."}. The parser must
  ;; coerce these back to plain strings rather than erroring.
  (let* ((raw "{\"acceptance_criteria\":[{\"criterion\":\"A class FOO exists.\"},{\"criterion\":\"FOO has slot X.\"}],\"non_goals\":[{\"non_goal\":\"thread safety\"}],\"risks\":[{\"risk\":\"race condition\"}]}")
         (spec (cl-harness/src/review::%parse-develop-spec "g" raw)))
    (ok (equal '("A class FOO exists." "FOO has slot X.")
               (develop-spec-acceptance-criteria spec)))
    (ok (equal '("thread safety")
               (cl-harness/src/review:develop-spec-non-goals spec)))
    (ok (equal '("race condition")
               (cl-harness/src/review:develop-spec-risks spec)))))

(deftest review-development-artifact-approves-without-provider
  (let ((decision (review-development-artifact
                   :plan
                   :provider nil
                   :develop-spec (make-develop-spec :goal "g"))))
    (ok (review-decision-approved-p decision))
    (ok (eq :plan (review-decision-kind decision)))))

(deftest default-review-system-prompt-is-approve-by-default
  ;; Backlog #54: 2026-05-24 #48+#50 verification bench observed
  ;; :MAX-REVIEW-REPLANS jumping from 1 to 4 (4/7 failures) after patch
  ;; quality improved. Root cause hypothesis: prior prompt said "strict
  ;; reviewer" + listed 4 reject reasons with no positive guidance,
  ;; biasing Qwen3.6 toward rejection. Soften prompt to approve-by-default
  ;; semantics while keeping the 4 rejection criteria as concrete signals.
  (let ((p cl-harness/src/review::+default-review-system-prompt+))
    (testing "prompt prefers approval as the default decision"
      (ok (search "APPROVE BY DEFAULT" p)
          "explicit approve-by-default rule")
      (ok (search "If unsure, approve" p)
          "tie-breaker biases toward approve"))
    (testing "prompt demands concrete defect for rejection"
      (ok (search "CONCRETE defect" p)
          "rejection requires citing a concrete defect"))
    (testing "prompt enumerates non-grounds for rejection"
      (ok (search "Do NOT reject" p))
      (ok (search "stylistic" p)
          "stylistic preferences are not grounds for rejection"))
    (testing "prompt no longer uses the priming word 'strict'"
      (ok (not (search "strict" p))
          "removing 'strict' lowers reviewer aggressiveness on Qwen3.6"))))
