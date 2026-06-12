;;;; next/tests/mission-test.lisp
;;;;
;;;; Tests for next/src/mission.lisp (spec §9): mission lifecycle,
;;;; queue, asynchronous human requests.

(defpackage #:cl-harness-next/tests/mission-test
  (:use #:cl #:rove)
  (:import-from #:cl-harness-next/src/mission
                #:mission
                #:mission-id
                #:mission-status
                #:mission-reason
                #:mission-transition
                #:mission-queue
                #:enqueue-mission
                #:mission-queue-missions
                #:next-runnable-mission
                #:queue-human-request
                #:pending-human-requests
                #:resolve-human-request
                #:human-request-mission
                #:human-request-reason
                #:human-request-resolved-p
                #:human-request-response))

(in-package #:cl-harness-next/tests/mission-test)

(defun %mission (id &key (goal "fix it"))
  (make-instance 'mission :id id :goal goal :log-path "/tmp/unused.jsonl"))

(deftest lifecycle-transitions
  (let ((mission (%mission "m1")))
    (ok (eq :created (mission-status mission)))
    (mission-transition mission :running)
    (mission-transition mission :parked :reason "out of budget")
    (ok (eq :parked (mission-status mission)))
    (ok (equal "out of budget" (mission-reason mission)))
    (mission-transition mission :running)
    (mission-transition mission :done :reason "clean")
    (ok (eq :done (mission-status mission)))))

(deftest invalid-transitions-error
  (let ((mission (%mission "m1")))
    ;; created → done skips running.
    (ok (handler-case (progn (mission-transition mission :done) nil)
          (error () t)))
    (mission-transition mission :running)
    (mission-transition mission :failed :reason "gave up")
    ;; failed is terminal.
    (ok (handler-case (progn (mission-transition mission :running) nil)
          (error () t)))))

(deftest queue-yields-created-missions-in-order
  (let ((queue (make-instance 'mission-queue))
        (m1 (%mission "m1"))
        (m2 (%mission "m2")))
    (enqueue-mission queue m1)
    (enqueue-mission queue m2)
    (ok (equal '("m1" "m2")
               (mapcar #'mission-id (mission-queue-missions queue))))
    (ok (eq m1 (next-runnable-mission queue)))
    (mission-transition m1 :running)
    (mission-transition m1 :done)
    (ok (eq m2 (next-runnable-mission queue)))
    (mission-transition m2 :running)
    (mission-transition m2 :parked :reason "waiting")
    ;; Parked missions are NOT auto-runnable; a human unparks them.
    (ok (null (next-runnable-mission queue)))))

(deftest human-requests-queue-and-resolve
  (let* ((queue (make-instance 'mission-queue))
         (mission (%mission "m1"))
         (request (queue-human-request queue mission "budget exhausted")))
    (ok (eq mission (human-request-mission request)))
    (ok (equal "budget exhausted" (human-request-reason request)))
    (ok (= 1 (length (pending-human-requests queue))))
    (resolve-human-request queue request :response "raise to 50")
    (ok (human-request-resolved-p request))
    (ok (equal "raise to 50" (human-request-response request)))
    (ok (null (pending-human-requests queue)))))
