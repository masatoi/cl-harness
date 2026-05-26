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

(deftest review-system-prompts-are-stage-aware
  ;; Backlog #55: 2026-05-25 #54 verification bench observed 102-counter-class
  ;; regression (2/3 → 0/3) — approve-by-default let weak planner test stubs
  ;; through, agent could not satisfy them, all 3 trials hit MAX-REPLANS.
  ;; Solution: keep #54 soft prompt for plan/implementation reviews (where
  ;; agent can iterate) but apply a stricter prompt to TESTS review (where
  ;; stub quality determines whether the agent can ever pass).
  (testing "review-system-prompt-for dispatches by kind"
    (let ((plan-p (cl-harness/src/review::review-system-prompt-for :plan))
          (tests-p (cl-harness/src/review::review-system-prompt-for :tests))
          (impl-p (cl-harness/src/review::review-system-prompt-for :implementation)))
      (testing "plan and implementation reuse the approve-by-default prompt"
        (ok (search "APPROVE BY DEFAULT" plan-p))
        (ok (search "APPROVE BY DEFAULT" impl-p)))
      (testing "tests prompt is stricter — demands behavior coverage"
        (ok (search "BEHAVIOR coverage" tests-p)
            "explicitly requires test to assert behavior, not just structure")
        (ok (search "trivially satisfy" tests-p)
            "warns against tests an implementation could pass with NIL"))
      (testing "tests prompt still uses falsifiable criteria"
        (ok (search "CONCRETE" tests-p)
            "rejection still requires concrete citation"))
      (testing "tests prompt remains JSON-shaped"
        (ok (search "\"status\"" tests-p))
        (ok (search "\"feedback\"" tests-p)))))
  (testing "default-review-system-prompt is the fallback for any kind"
    ;; Unknown kinds fall back to the soft default so adding a new review
    ;; kind in the future doesn't crash review-development-artifact.
    (ok (search "APPROVE BY DEFAULT"
                (cl-harness/src/review::review-system-prompt-for :unknown-kind)))))

(deftest test-change-review-uses-strict-prompt
  ;; Finding 2 (design review 2026-05-27): :test-change is at least as
  ;; safety-critical as :tests — the agent is asking to MUTATE the test
  ;; suite, which directly affects the source-of-truth for verify.
  ;; #55 introduced stage-aware prompts but :test-change fell through to
  ;; the soft approve-by-default default. Lift it to a dedicated strict
  ;; prompt that demands additive-only proof.
  (testing "review-system-prompt-for dispatches :test-change to a strict prompt"
    (let ((p (cl-harness/src/review::review-system-prompt-for :test-change)))
      (testing ":test-change prompt is NOT the soft approve-by-default"
        (ok (not (search "APPROVE BY DEFAULT" p))
            "uses a strict prompt instead of the soft default"))
      (testing ":test-change prompt demands additive-only justification"
        (ok (search "additive" p)
            "rejection criteria reference additive semantics"))
      (testing ":test-change prompt names weakening as a reject reason"
        (ok (search "weaken" p)
            "explicitly names test-weakening as grounds for rejection"))
      (testing ":test-change prompt still returns JSON shape"
        (ok (search "\"status\"" p))
        (ok (search "\"feedback\"" p))))))
