;;;; next/tests/world-model-test.lisp
;;;;
;;;; Unit tests for next/src/world-model.lisp: action/observation
;;;; pairing (exactly once), standard projections, replay (spec §8.2).

(defpackage #:cl-harness-next/tests/world-model-test
  (:use #:cl #:rove)
  (:import-from #:cl-harness-next/src/event
                #:make-harness-event)
  (:import-from #:cl-harness-next/src/event-log
                #:open-event-log
                #:emit-event)
  (:import-from #:cl-harness-next/src/projection
                #:projection
                #:apply-event
                #:apply-interaction)
  (:import-from #:cl-harness-next/src/goal-projection
                #:goal-text)
  (:import-from #:cl-harness-next/src/exploration-ledger
                #:probes
                #:findings)
  (:import-from #:cl-harness-next/src/world-model
                #:make-world-model
                #:make-standard-world-model
                #:world-model-projection
                #:world-model-last-seq
                #:update-world-model
                #:build-world-model
                #:refresh-world-model))

(in-package #:cl-harness-next/tests/world-model-test)

(defun %hash (&rest plist)
  (alexandria:plist-hash-table plist :test #'equal))

(defclass counting-projection (projection)
  ((events :initform 0 :accessor counted-events)
   (interactions :initform 0 :accessor counted-interactions)))

(defmethod apply-event ((projection counting-projection) event)
  (declare (ignore event))
  (incf (counted-events projection))
  projection)

(defmethod apply-interaction ((projection counting-projection) interaction)
  (declare (ignore interaction))
  (incf (counted-interactions projection))
  projection)

(deftest pairing-delivers-interaction-exactly-once
  (let* ((counter (make-instance 'counting-projection))
         (world-model (make-world-model :projections (list :count counter))))
    (update-world-model world-model
                        (make-harness-event
                         :action (%hash "tool" "repl-eval"
                                        "arguments" (%hash "code" "1"))
                         :seq 1))
    (update-world-model world-model
                        (make-harness-event
                         :observation (%hash "tool" "repl-eval"
                                             "result" (%hash "x" 1))
                         :seq 2))
    (ok (= 1 (counted-interactions counter)))
    (ok (= 2 (counted-events counter)))
    (ok (= 2 (world-model-last-seq world-model)))))

(deftest unmatched-observation-yields-no-interaction
  (let* ((counter (make-instance 'counting-projection))
         (world-model (make-world-model :projections (list :count counter))))
    (update-world-model world-model
                        (make-harness-event
                         :observation (%hash "tool" "run-tests") :seq 1))
    (update-world-model world-model
                        (make-harness-event
                         :action (%hash "tool" "repl-eval") :seq 2))
    (update-world-model world-model
                        (make-harness-event
                         :observation (%hash "tool" "OTHER-tool") :seq 3))
    (ok (zerop (counted-interactions counter)))
    (ok (= 3 (counted-events counter)))))

(deftest standard-world-model-has-four-projections
  (let ((world-model (make-standard-world-model)))
    (dolist (key '(:goal :exploration :changes :verification))
      (ok (world-model-projection world-model key)))
    (ok (null (world-model-projection world-model :nope)))))

(deftest build-from-log-replays-everything
  (uiop:with-temporary-file (:pathname path :type "jsonl")
    (uiop:delete-file-if-exists path)
    (let ((log (open-event-log path)))
      (emit-event log :run-start (%hash "goal" "ship it"))
      (emit-event log :action (%hash "tool" "repl-eval"
                                     "arguments" (%hash "code" "(f)")))
      (emit-event log :observation (%hash "tool" "repl-eval"
                                          "result" (%hash "ok" t)))
      (emit-event log :decision (%hash "kind" "finding"
                                       "hypothesis" "h" "probe" "p"
                                       "finding" "f" "decision" "d")))
    (let ((world-model (build-world-model path)))
      (ok (equal "ship it"
                 (goal-text (world-model-projection world-model :goal))))
      (ok (= 1 (length (probes (world-model-projection world-model
                                                       :exploration)))))
      (ok (= 1 (length (findings (world-model-projection world-model
                                                         :exploration)))))
      (ok (= 4 (world-model-last-seq world-model))))))

(deftest mismatched-observation-clears-pending
  ;; Final-review fix: a mismatched observation must not leave a stale
  ;; pending action that pairs with a later same-tool observation.
  (let* ((counter (make-instance 'counting-projection))
         (world-model (make-world-model :projections (list :count counter))))
    (update-world-model world-model
                        (make-harness-event
                         :action (%hash "tool" "repl-eval") :seq 1))
    (update-world-model world-model
                        (make-harness-event
                         :observation (%hash "tool" "other") :seq 2))
    (update-world-model world-model
                        (make-harness-event
                         :observation (%hash "tool" "repl-eval") :seq 3))
    (ok (zerop (counted-interactions counter)))))

(deftest refresh-applies-only-new-events
  (uiop:with-temporary-file (:pathname path :type "jsonl")
    (uiop:delete-file-if-exists path)
    (let ((log (open-event-log path))
          (counter (make-instance 'counting-projection)))
      (emit-event log :note nil)
      (emit-event log :note nil)
      (let ((world-model (build-world-model
                          path
                          :world-model (make-world-model
                                        :projections (list :count counter)))))
        (ok (= 2 (counted-events counter)))
        (emit-event log :note nil)
        (refresh-world-model world-model path)
        (ok (= 3 (counted-events counter)))
        ;; Idempotent: nothing new → nothing re-applied.
        (refresh-world-model world-model path)
        (ok (= 3 (counted-events counter)))))))

(deftest refresh-from-scratch-equals-build
  (uiop:with-temporary-file (:pathname path :type "jsonl")
    (uiop:delete-file-if-exists path)
    (let ((log (open-event-log path))
          (counter (make-instance 'counting-projection)))
      (emit-event log :note nil)
      (let ((world-model (make-world-model
                          :projections (list :count counter))))
        (refresh-world-model world-model path)
        (ok (= 1 (counted-events counter)))))))
