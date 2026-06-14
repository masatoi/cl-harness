;;;; next/tests/review-oracle-test.lisp
;;;;
;;;; Tests for next/src/review-oracle.lisp: stage-aware strictness as
;;;; policy-pack data (PRD §19 soft/strict/strictest), injected judge
;;;; (LLM provider arrives in SP5), fail-closed parsing.

(defpackage #:cl-harness-next/tests/review-oracle-test
  (:use #:cl #:rove)
  (:import-from #:cl-harness-next/src/oracle
                #:evaluate
                #:verdict-pass-p
                #:verdict-reason
                #:verdict-oracle)
  (:import-from #:cl-harness-next/src/policy-pack
                #:load-policy-pack
                #:pack-oracle-profile)
  (:import-from #:cl-harness-next/src/review-oracle
                #:review-oracle))

(in-package #:cl-harness-next/tests/review-oracle-test)

(defun %canned-judge (response &optional capture)
  (lambda (prompt)
    (when capture (setf (car capture) prompt))
    response))

(deftest approve-passes
  (let ((verdict (evaluate
                  (make-instance 'review-oracle
                                 :profile '(:id :review-plan
                                            :strictness :soft)
                                 :judge-fn (%canned-judge
                                            "APPROVE solid plan"))
                  "the plan")))
    (ok (verdict-pass-p verdict))
    (ok (eq :review-plan (verdict-oracle verdict)))))

(deftest reject-carries-feedback
  (let ((verdict (evaluate
                  (make-instance 'review-oracle
                                 :profile '(:id :review-tests
                                            :strictness :strict)
                                 :judge-fn (%canned-judge
                                            "REJECT: missing edge case"))
                  "the tests")))
    (ok (not (verdict-pass-p verdict)))
    (ok (search "missing edge case" (verdict-reason verdict)))))

(deftest unparseable-fails-closed
  (let ((verdict (evaluate
                  (make-instance 'review-oracle
                                 :profile '(:id :r :strictness :soft)
                                 :judge-fn (%canned-judge "well, maybe"))
                  "x")))
    (ok (not (verdict-pass-p verdict)))
    (ok (search "unparseable" (verdict-reason verdict)))))

(deftest judge-errors-fail-closed
  (let ((verdict (evaluate
                  (make-instance 'review-oracle
                                 :profile '(:id :r)
                                 :judge-fn (lambda (prompt)
                                             (declare (ignore prompt))
                                             (error "api down")))
                  "x")))
    (ok (not (verdict-pass-p verdict)))
    (ok (search "judge error" (verdict-reason verdict)))))

(deftest prompt-carries-strictness-instructions-and-subject
  (let ((capture (list nil)))
    (evaluate (make-instance 'review-oracle
                             :profile '(:id :review-test-change
                                        :strictness :strictest
                                        :instructions "Additive only.")
                             :judge-fn (%canned-judge "APPROVE" capture))
              "the diff")
    (let ((prompt (car capture)))
      (ok (search "strictest" prompt))
      (ok (search "Additive only." prompt))
      (ok (search "the diff" prompt)))))

(deftest profile-from-policy-pack
  (uiop:with-temporary-file (:pathname path :type "sexp")
    (with-open-file (out path :direction :output :if-exists :supersede
                              :external-format :utf-8)
      (write-string "(:name \"p\" :version \"0.1.0\"
                      :oracle-profiles ((:id :review-tests
                                         :strictness :strict
                                         :instructions \"No skip.\")))"
                    out))
    (let* ((pack (load-policy-pack path))
           (oracle (make-instance 'review-oracle
                                  :profile (pack-oracle-profile
                                            pack :review-tests)
                                  :judge-fn (%canned-judge "REJECT: no"))))
      (ok (eq :review-tests (verdict-oracle (evaluate oracle "tests")))))))

(deftest reject-mentioning-approve-fails-closed
  ;; P2-parser: the verdict is the first non-blank line's leading token, NOT a
  ;; substring search. A REJECT whose prose merely mentions the word "approve"
  ;; must not be read as a pass. (Adversarial: the review oracle is the only
  ;; integrity gate in :coverage mode.)
  (let ((verdict (evaluate
                  (make-instance 'review-oracle
                                 :profile '(:id :r :strictness :strict)
                                 :judge-fn (%canned-judge
                                            "I cannot APPROVE. REJECT: tautological."))
                  "x")))
    (ok (not (verdict-pass-p verdict)))))

(deftest approve-after-blank-line-passes
  ;; The leading token is taken from the first NON-BLANK line, so an APPROVE
  ;; after a leading blank line still passes.
  (let ((verdict (evaluate
                  (make-instance 'review-oracle
                                 :profile '(:id :r :strictness :soft)
                                 :judge-fn (%canned-judge
                                            (format nil "~%APPROVE: ok")))
                  "x")))
    (ok (verdict-pass-p verdict))))

(deftest approve-in-markdown-decoration-passes
  ;; A real reviewer LLM may decorate the verdict (**APPROVE**, "> APPROVE",
  ;; "1. APPROVE"). Leading non-alphabetic characters are skipped before the
  ;; token match, so a genuine approval still passes (fail-closed only on real
  ;; ambiguity, not on decoration).
  (dolist (reply '("**APPROVE**: looks good" "> APPROVE" "1. APPROVE - solid"))
    (let ((verdict (evaluate
                    (make-instance 'review-oracle
                                   :profile '(:id :r :strictness :soft)
                                   :judge-fn (%canned-judge reply))
                    "x")))
      (ok (verdict-pass-p verdict)))))
