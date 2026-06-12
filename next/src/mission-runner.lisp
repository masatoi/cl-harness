;;;; next/src/mission-runner.lisp
;;;;
;;;; Runs missions (spec §9): assembles a kernel per run from caller
;;;; factories, emits :run-start only on a fresh log, rebuilds the
;;;; world model from the mission's log (governor and
;;;; policy-as-projection folded in — suspend/resume needs nothing but
;;;; the log), and wraps the policy so an inner :abort-run becomes
;;;; park + a queued human request. Resume = run a :parked mission
;;;; again; spent budgets replay as spent and the human raises the
;;;; envelope through a new governor.

(defpackage #:cl-harness-next/src/mission-runner
  (:use #:cl)
  (:import-from #:cl-harness-next/src/event-log
                #:open-event-log
                #:event-log-next-seq
                #:emit-event)
  (:import-from #:cl-harness-next/src/projection
                #:projection)
  (:import-from #:cl-harness-next/src/world-model
                #:make-standard-world-model
                #:build-world-model)
  (:import-from #:cl-harness-next/src/governor
                #:intervention-reason)
  (:import-from #:cl-harness-next/src/kernel
                #:control-policy
                #:decide
                #:handle-intervention
                #:make-kernel
                #:run-kernel)
  (:import-from #:cl-harness-next/src/mission
                #:mission-id
                #:mission-goal
                #:mission-acceptance-criteria
                #:mission-non-goals
                #:mission-log-path
                #:mission-status
                #:mission-transition
                #:queue-human-request)
  (:export #:run-mission))

(in-package #:cl-harness-next/src/mission-runner)

(defclass %mission-policy (control-policy)
  ((inner :initarg :inner :reader %inner)
   (mission :initarg :mission :reader %mission)
   (queue :initarg :queue :reader %queue))
  (:documentation "Wraps the mission's policy: DECIDE delegates; an
inner :abort-run intervention becomes park + a queued human request
(spec §9 escalation)."))

(defmethod decide ((policy %mission-policy) kernel)
  (decide (%inner policy) kernel))

(defmethod handle-intervention ((policy %mission-policy) condition)
  (let ((choice (handle-intervention (%inner policy) condition)))
    (if (eq :abort-run choice)
        (progn
          (queue-human-request (%queue policy) (%mission policy)
                               (intervention-reason condition))
          :park-mission)
        choice)))

(defun %run-start-payload (mission)
  (let ((payload (make-hash-table :test #'equal)))
    (setf (gethash "goal" payload) (mission-goal mission))
    (alexandria:when-let ((criteria (mission-acceptance-criteria mission)))
      (setf (gethash "acceptance_criteria" payload) criteria))
    (alexandria:when-let ((non-goals (mission-non-goals mission)))
      (setf (gethash "non_goals" payload) non-goals))
    payload))

(defun run-mission (mission queue &key environment-factory
                                       policy-factory
                                       governor-factory
                                       (max-steps 50))
  "Run (or resume) MISSION. ENVIRONMENT-FACTORY is (mission log) →
environment; POLICY-FACTORY is (mission) → control-policy;
GOVERNOR-FACTORY, optional, is (mission) → governor — pass a bigger
envelope on resume (spent budgets replay as spent). Only :created and
:parked missions run. Returns (values mission-status reason)."
  (unless (member (mission-status mission) '(:created :parked))
    (error "mission ~A is ~A; only created or parked missions run"
           (mission-id mission) (mission-status mission)))
  (let* ((log (open-event-log (mission-log-path mission)))
         (fresh-p (= 1 (event-log-next-seq log))))
    (when fresh-p
      (emit-event log :run-start (%run-start-payload mission)))
    (let* ((governor (when governor-factory
                       (funcall governor-factory mission)))
           (inner (funcall policy-factory mission))
           (extras (append (when governor (list :governor governor))
                           (when (typep inner 'projection)
                             (list :policy-projection inner))))
           (world-model (build-world-model
                         (mission-log-path mission)
                         :world-model (make-standard-world-model
                                       :extra-projections extras)))
           (kernel (make-kernel
                    :environment (funcall environment-factory mission
                                          log)
                    :event-log log
                    :policy (make-instance '%mission-policy
                                           :inner inner
                                           :mission mission
                                           :queue queue)
                    :governor governor
                    :world-model world-model)))
      (mission-transition mission :running)
      (unwind-protect
           (multiple-value-bind (status reason)
               (run-kernel kernel :max-steps max-steps)
             (ecase status
               (:done (mission-transition mission :done :reason reason))
               (:parked (mission-transition mission :parked
                                            :reason reason))
               (:given-up (mission-transition mission :failed
                                              :reason reason)))
             (values (mission-status mission) reason))
        ;; A non-local exit (an error escaping the kernel, e.g. a
        ;; policy bug) must not wedge the mission at :running — mark
        ;; it failed and let the condition propagate.
        (when (eq :running (mission-status mission))
          (mission-transition mission :failed
                              :reason "unhandled error during run"))))))
