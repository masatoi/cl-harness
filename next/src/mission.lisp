;;;; next/src/mission.lisp
;;;;
;;;; Mission data for the L4 layer (spec §9): a mission is a goal with
;;;; acceptance criteria and ONE event log; its lifecycle is
;;;; created → running → {parked, done, failed}, parked → running.
;;;; The queue holds missions and the asynchronous human requests —
;;;; escalations park the mission and queue a request; the human
;;;; resolves it and resumes (人間は同期的なゲート係ではなく非同期な
;;;; 承認者).

(defpackage #:cl-harness-next/src/mission
  (:use #:cl)
  (:export #:mission
           #:mission-id
           #:mission-goal
           #:mission-acceptance-criteria
           #:mission-non-goals
           #:mission-log-path
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
           #:human-request
           #:human-request-mission
           #:human-request-reason
           #:human-request-resolved-p
           #:human-request-response))

(in-package #:cl-harness-next/src/mission)

(defclass mission ()
  ((id :initarg :id :reader mission-id)
   (goal :initarg :goal :reader mission-goal)
   (acceptance-criteria :initarg :acceptance-criteria :initform nil
                        :reader mission-acceptance-criteria)
   (non-goals :initarg :non-goals :initform nil
              :reader mission-non-goals)
   (log-path :initarg :log-path :reader mission-log-path
             :documentation "This mission's event log — its single
source of truth; suspend/resume needs nothing else (spec §9).")
   (status :initform :created :reader mission-status)
   (reason :initform nil :reader mission-reason))
  (:documentation "One unit of work for the L4 queue (spec §9)."))

(alexandria:define-constant +mission-transitions+
    '((:created . (:running))
      (:running . (:parked :done :failed))
      (:parked . (:running))
      (:done . ())
      (:failed . ()))
  :test #'equal
  :documentation "Allowed lifecycle edges; :done/:failed are terminal.")

(defun mission-transition (mission status &key reason)
  "Move MISSION to STATUS (recording REASON), enforcing the lifecycle
edges. Signals an ERROR on an illegal transition."
  (let ((allowed (cdr (assoc (mission-status mission)
                             +mission-transitions+))))
    (unless (member status allowed)
      (error "mission ~A: illegal transition ~A → ~A"
             (mission-id mission) (mission-status mission) status))
    (setf (slot-value mission 'status) status
          (slot-value mission 'reason) reason)
    mission))

(defclass mission-queue ()
  ((missions :initform nil :accessor %missions
             :documentation "Newest last (FIFO).")
   (human-requests :initform nil :accessor %human-requests
                   :documentation "Newest last."))
  (:documentation "The L4 backlog plus the asynchronous human port."))

(defun enqueue-mission (queue mission)
  "Append MISSION to QUEUE's backlog. Returns MISSION."
  (setf (%missions queue) (append (%missions queue) (list mission)))
  mission)

(defun mission-queue-missions (queue)
  "All missions in FIFO order."
  (%missions queue))

(defun next-runnable-mission (queue)
  "The first :created mission, or NIL. Parked missions are not
auto-runnable — resuming one is an explicit human decision."
  (find :created (%missions queue) :key #'mission-status))

(defstruct (human-request (:conc-name human-request-))
  mission reason (resolved-p nil) response)

(defun queue-human-request (queue mission reason)
  "Queue an asynchronous escalation for the human port. Returns the
request."
  (let ((request (make-human-request :mission mission :reason reason)))
    (setf (%human-requests queue)
          (append (%human-requests queue) (list request)))
    request))

(defun pending-human-requests (queue)
  "Unresolved requests, FIFO."
  (remove-if #'human-request-resolved-p (%human-requests queue)))

(defun resolve-human-request (queue request &key response)
  "Mark REQUEST resolved with RESPONSE. Resuming the parked mission is
a separate, explicit RUN-MISSION call."
  (declare (ignore queue))
  (setf (human-request-resolved-p request) t
        (human-request-response request) response)
  request)
