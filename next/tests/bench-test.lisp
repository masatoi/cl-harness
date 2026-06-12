;;;; next/tests/bench-test.lisp
;;;;
;;;; Tests for next/src/bench.lisp (spec §10.2 stages 1+4): paired
;;;; champion/challenger trials and the v1 sign-test judge.

(defpackage #:cl-harness-next/tests/bench-test
  (:use #:cl #:rove)
  (:import-from #:cl-harness-next/src/bench
                #:make-trial
                #:trial-index
                #:trial-pack-fingerprint
                #:run-paired-trials
                #:judge-trials))

(in-package #:cl-harness-next/tests/bench-test)

(defun %trial-fn (success-by-fingerprint &optional calls-box)
  "TRIAL-FN whose success per pack is looked up in an alist
fingerprint → list of per-index booleans."
  (lambda (pack index)
    (when calls-box (push (cons pack index) (car calls-box)))
    (let ((successes (cdr (assoc pack success-by-fingerprint
                                 :test #'equal))))
      (make-trial :index index
                  :pack-fingerprint pack
                  :success-p (elt successes index)
                  :actions (+ 10 index)))))

(deftest paired-runner-pairs-by-index
  (let* ((calls (list nil))
         (trial-fn (%trial-fn (list (cons "champ" '(t t t))
                                    (cons "chall" '(t t t)))
                              calls)))
    (multiple-value-bind (champion-trials challenger-trials)
        (run-paired-trials trial-fn "champ" "chall" 3)
      (ok (= 3 (length champion-trials)))
      (ok (= 3 (length challenger-trials)))
      (ok (equal '(0 1 2) (mapcar #'trial-index champion-trials)))
      (ok (equal '("chall" "chall" "chall")
                 (mapcar #'trial-pack-fingerprint challenger-trials)))
      ;; Each index ran for BOTH packs (paired design).
      (ok (= 6 (length (car calls)))))))

(deftest judge-promotes-on-net-wins
  (multiple-value-bind (champion-trials challenger-trials)
      (run-paired-trials (%trial-fn (list (cons "champ" '(nil nil t))
                                          (cons "chall" '(t t t))))
                         "champ" "chall" 3)
    (multiple-value-bind (verdict summary)
        (judge-trials champion-trials challenger-trials
                      :min-net-wins 2)
      (ok (eq :promote verdict))
      (ok (search "wins 2" summary)))))

(deftest judge-rejects-on-net-losses
  (multiple-value-bind (champion-trials challenger-trials)
      (run-paired-trials (%trial-fn (list (cons "champ" '(t t t))
                                          (cons "chall" '(nil t nil))))
                         "champ" "chall" 3)
    (ok (eq :reject (judge-trials champion-trials challenger-trials)))))

(deftest judge-is-inconclusive-below-threshold
  (multiple-value-bind (champion-trials challenger-trials)
      (run-paired-trials (%trial-fn (list (cons "champ" '(nil t t))
                                          (cons "chall" '(t t t))))
                         "champ" "chall" 3)
    (ok (eq :inconclusive
            (judge-trials champion-trials challenger-trials
                          :min-net-wins 2)))))
