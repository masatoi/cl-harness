;;;; next/tests/exploration-ledger-test.lisp
;;;;
;;;; Unit tests for next/src/exploration-ledger.lisp (§3.6 exploration
;;;; context, §9 staleness, Phase-H promotion heuristic).

(defpackage #:cl-harness-next/tests/exploration-ledger-test
  (:use #:cl #:rove)
  (:import-from #:cl-harness-next/src/event
                #:make-harness-event)
  (:import-from #:cl-harness-next/src/projection
                #:apply-event
                #:apply-interaction
                #:interaction)
  (:import-from #:cl-harness-next/src/exploration-ledger
                #:exploration-ledger
                #:findings
                #:probes
                #:finding-hypothesis
                #:finding-text
                #:finding-promoted-p
                #:probe-tool
                #:probe-code
                #:probe-summary
                #:probe-seq
                #:probe-stale-p))

(in-package #:cl-harness-next/tests/exploration-ledger-test)

(defun %hash (&rest plist)
  (alexandria:plist-hash-table plist :test #'equal))

(defun %interaction (tool &key arguments result error
                              (action-seq 1) (observation-seq 2))
  (make-instance 'interaction
                 :tool tool
                 :arguments arguments
                 :result result
                 :error-message error
                 :action-seq action-seq
                 :observation-seq observation-seq))

(defun %finding-event (seq hypothesis)
  (make-harness-event :decision
                      (%hash "kind" "finding"
                             "hypothesis" hypothesis
                             "probe" "tried it in the REPL"
                             "finding" "it works"
                             "decision" "promote to source")
                      :seq seq))

(deftest finding-events-are-recorded
  (let ((ledger (make-instance 'exploration-ledger)))
    (apply-event ledger (%finding-event 3 "pure function suffices"))
    (let ((finding (first (findings ledger))))
      (ok (equal "pure function suffices" (finding-hypothesis finding)))
      (ok (equal "it works" (finding-text finding)))
      (ok (not (finding-promoted-p finding))))))

(deftest probe-interactions-are-recorded
  (let ((ledger (make-instance 'exploration-ledger)))
    (apply-interaction
     ledger
     (%interaction "repl-eval"
                   :arguments (%hash "code" "(+ 1 2)")
                   :result (%hash "content"
                                  (list (%hash "type" "text" "text" "3")))
                   :observation-seq 5))
    (let ((probe (first (probes ledger))))
      (ok (equal "repl-eval" (probe-tool probe)))
      (ok (equal "(+ 1 2)" (probe-code probe)))
      (ok (equal "3" (probe-summary probe)))
      (ok (= 5 (probe-seq probe)))
      (ok (not (probe-stale-p probe ledger))))))

(deftest patch-invalidates-earlier-probes
  (let ((ledger (make-instance 'exploration-ledger)))
    (apply-interaction ledger (%interaction "repl-eval" :observation-seq 3))
    (apply-interaction
     ledger (%interaction "lisp-edit-form"
                          :arguments (%hash "content" "(defun f ())")
                          :observation-seq 6))
    (apply-interaction ledger (%interaction "repl-eval" :observation-seq 9))
    (let ((newest (first (probes ledger)))
          (oldest (first (last (probes ledger)))))
      (ok (probe-stale-p oldest ledger))
      (ok (not (probe-stale-p newest ledger))))))

(deftest load-system-invalidates-earlier-probes
  (let ((ledger (make-instance 'exploration-ledger)))
    (apply-interaction ledger (%interaction "repl-eval" :observation-seq 3))
    (apply-interaction ledger (%interaction "load-system" :observation-seq 4))
    (ok (probe-stale-p (first (probes ledger)) ledger))))

(deftest promotion-matches-hypothesis-case-folded
  (let ((ledger (make-instance 'exploration-ledger)))
    (apply-event ledger (%finding-event 2 "Pure Function"))
    (apply-interaction
     ledger
     (%interaction "lisp-patch-form"
                   :arguments (%hash "new_text" "a pure function body")
                   :observation-seq 8))
    (ok (finding-promoted-p (first (findings ledger))))))

(deftest promotion-skips-unrelated-patches-and-failures
  (let ((ledger (make-instance 'exploration-ledger)))
    (apply-event ledger (%finding-event 2 "memoization table"))
    ;; Unrelated content.
    (apply-interaction
     ledger (%interaction "lisp-edit-form"
                          :arguments (%hash "content" "(defun g ())")
                          :observation-seq 4))
    (ok (not (finding-promoted-p (first (findings ledger)))))
    ;; Matching content but the patch FAILED.
    (apply-interaction
     ledger (%interaction "lisp-edit-form"
                          :arguments (%hash "content" "memoization table v2")
                          :error "form not found"
                          :observation-seq 6))
    (ok (not (finding-promoted-p (first (findings ledger)))))))

(deftest worker-reset-invalidates-earlier-probes
  ;; Final-review fix: a fresh worker has none of the probed state, so
  ;; pool-kill-worker invalidates like a reload does.
  (let ((ledger (make-instance 'exploration-ledger)))
    (apply-interaction ledger (%interaction "repl-eval" :observation-seq 3))
    (apply-interaction ledger (%interaction "pool-kill-worker"
                                            :observation-seq 4))
    (ok (probe-stale-p (first (probes ledger)) ledger))))
