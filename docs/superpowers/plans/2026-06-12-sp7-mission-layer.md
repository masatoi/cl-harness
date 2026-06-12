# SP7: L4 Mission Layer Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the L4 mission layer (spec §9): missions (goal + acceptance criteria + one event log each) in a queue with a `created → running → {parked, done, failed}` lifecycle, asynchronous human-request escalation, and suspend/resume that rebuilds everything from the log — absorbing SP6's deferred replay-coherence fixes (governor stall reset and adaptive dial level become log-derived).

**Architecture:** Task 1 makes resume honest: the governor's `apply-event` consumes logged `"dial"` decision events (stall reset replays), `adaptive-policy` becomes a projection whose level-index is derived ABSOLUTELY from the count of dial events seen (the imperative demote-time update and the later fold agree, so live runs don't double-count and cold replays restore the level), and the kernel gains a `:parked` status (`:park-mission`/`:ask-human` restarts are resumable stops, not failures). `mission.lisp` is data: mission, queue, human requests. `mission-runner.lisp` assembles a kernel per run from caller factories, emits `:run-start` only on a fresh log, rebuilds the world model (with governor and policy-as-projection folded in) from the mission's log, and wraps the policy so an inner `:abort-run` becomes park + a queued human request (spec §9: エスカレーションは人間ポートへ). Resume = run again on a parked mission; spent budgets replay as spent, the human raises the envelope via a new governor. Spec: §9, §6.1, §11.

**Tech Stack:** SBCL, rove, alexandria, yason. No new dependencies.

**Conventions** (same as SP1–SP6, incl. `elt`-not-`first`, macro-arg quoting lesson): 2-space indent, ≤100 cols, blank lines, docstrings, no `:local-nicknames`, `%`-internals unexported. cl-mcp tools; `mallet` before commits; tests via `run-tests` `{"system": "cl-harness-next/tests"}`; worker-restart recovery `(asdf:load-asd "/home/wiz/.roswell/local-projects/cl-harness/cl-harness-next.asd")`. Unused test imports flagged by mallet get removed (note it).

---

## File Structure

```text
next/src/kernel.lisp          MOD  :parked status for :park-mission/:ask-human
next/src/governor.lisp        MOD  apply-event consumes "dial" events (stall reset)
next/src/adaptive-policy.lisp MOD  projection; level-index derived from dial events
next/src/mission.lisp         NEW  mission, lifecycle transitions, queue, human requests
next/src/mission-runner.lisp  NEW  run-mission: kernel assembly, resume, park-to-human
next/src/main.lisp            MOD  facade re-exports
next/tests/kernel-test.lisp        MOD (+1 new, 1 modified)
next/tests/governor-test.lisp      MOD (+1)
next/tests/adaptive-policy-test.lisp MOD (+2)
next/tests/mission-test.lisp       NEW (+4)
next/tests/mission-runner-test.lisp NEW (+4)
next/tests/main-test.lisp          MOD (+1 acceptance)
cl-harness-next.asd           MOD  + 2 test files
README.md                     MOD  one sentence
```

Test-count checkpoints: 196 → T1 200 → T2 204 → T3 208 → T4 209.

---

### Task 1: Replay coherence (kernel `:parked`, log-derived governor reset + dial level)

**Files:**
- Modify: `next/src/kernel.lisp`, `next/src/governor.lisp`, `next/src/adaptive-policy.lisp`
- Modify: `next/tests/kernel-test.lisp`, `next/tests/governor-test.lisp`, `next/tests/adaptive-policy-test.lisp`

- [ ] **Step 1: Write the failing tests**

`next/tests/kernel-test.lisp` — REPLACE the existing
`unknown-restart-choice-halts` deftest (its parking-policy now parks
instead of halting) with these two:

```lisp
(deftest park-restart-parks-the-kernel
  (with-log (log path)
    (declare (ignorable path))
    (let* ((governor (make-instance 'governor
                                    :max-stalled-verify-cycles 1))
           (kernel (make-kernel
                    :environment (make-instance 'fake-environment :log log)
                    :event-log log
                    :governor governor
                    :policy (make-instance
                             'parking-policy
                             :decisions
                             (list (make-decision :kind :finish
                                                  :reason "never"))))))
      (apply-interaction governor (%stall-interaction))
      (multiple-value-bind (status reason) (run-kernel kernel)
        (ok (eq :parked status))
        (ok (search "PARK-MISSION" reason))))))

(defclass replanning-policy (script-policy) ())

(defmethod cl-harness-next/src/kernel:handle-intervention
    ((policy replanning-policy) condition)
  (declare (ignore condition))
  :replan)

(deftest kernel-unhandled-restart-halts
  (with-log (log path)
    (declare (ignorable path))
    (let* ((governor (make-instance 'governor
                                    :max-stalled-verify-cycles 1))
           (kernel (make-kernel
                    :environment (make-instance 'fake-environment :log log)
                    :event-log log
                    :governor governor
                    :policy (make-instance
                             'replanning-policy
                             :decisions
                             (list (make-decision :kind :finish
                                                  :reason "never"))))))
      (apply-interaction governor (%stall-interaction))
      (multiple-value-bind (status reason) (run-kernel kernel)
        (ok (eq :given-up status))
        (ok (search "REPLAN" reason))))))
```

(Note: the parking-policy class and its `handle-intervention` method
already exist in this file from SP6 — only the deftest changes.)

`next/tests/governor-test.lisp` — extend imports: add `#:apply-event`
to the projection clause and a NEW clause:

```lisp
  (:import-from #:cl-harness-next/src/event
                #:make-harness-event)
```

Append:

```lisp
(deftest dial-events-reset-stalls-on-fold
  ;; SP7 replay coherence (SP6 final-review deferred item): a logged
  ;; dial demotion grants the fresh stall allowance on replay too.
  (let ((governor (make-instance 'governor)))
    (apply-interaction governor (%interaction "run-tests" :seq 1
                                              :result (%hash "failed" 1)))
    (ok (= 1 (governor-stalled-verify-cycles governor)))
    (apply-event governor
                 (make-harness-event :decision
                                     (%hash "kind" "dial"
                                            "text" "demoted")
                                     :seq 2))
    (ok (zerop (governor-stalled-verify-cycles governor)))))
```

`next/tests/adaptive-policy-test.lisp` — extend imports with NEW
clauses:

```lisp
  (:import-from #:cl-harness-next/src/event
                #:make-harness-event)
  (:import-from #:cl-harness-next/src/projection
                #:apply-event)
  (:import-from #:cl-harness-next/src/world-model
                #:make-world-model
                #:build-world-model)
```

and `#:open-event-log` plus `#:emit-event` in the event-log clause.
Append:

```lisp
(defun %dial-event (seq)
  (make-harness-event :decision
                      (alexandria:plist-hash-table
                       (list "kind" "dial" "text" "demoted")
                       :test #'equal)
                      :seq seq))

(deftest replay-restores-the-dial-level
  ;; SP7 resume coherence: a cold rebuild over a log with two dial
  ;; demotions puts a fresh adaptive policy at level 2.
  (uiop:with-temporary-file (:pathname path :type "jsonl")
    (uiop:delete-file-if-exists path)
    (let ((log (open-event-log path)))
      (emit-event log :decision
                  (alexandria:plist-hash-table
                   (list "kind" "dial" "text" "demoted") :test #'equal))
      (emit-event log :decision
                  (alexandria:plist-hash-table
                   (list "kind" "dial" "text" "demoted") :test #'equal)))
    (let ((adaptive (make-instance 'adaptive-policy
                                   :levels (%levels :a :b :c))))
      (build-world-model path
                         :world-model (make-world-model
                                       :projections (list :policy adaptive)))
      (ok (= 2 (policy-level-index adaptive))))))

(deftest live-demotion-does-not-double-count
  ;; The imperative demote-time update and the later event fold must
  ;; agree (absolute derivation, not double increment).
  (let ((adaptive (make-instance 'adaptive-policy
                                 :levels (%levels :a :b :c))))
    (ok (eq :demote-dial
            (handle-intervention adaptive
                                 (make-condition 'progress-stalled))))
    (ok (= 1 (policy-level-index adaptive)))
    (apply-event adaptive (%dial-event 5))
    (ok (= 1 (policy-level-index adaptive)))))
```

Run — red: `apply-event` has no method for governor/adaptive (the
governor/adaptive tests fail on behavior), and the kernel tests fail
(`:parked` not produced).

- [ ] **Step 2: Implement**

`next/src/kernel.lisp` — in `%governor-gate`'s `case`, insert before
the `(t ...)` clause:

```lisp
          ((:park-mission :ask-human)
           (setf (kernel-status kernel) :parked
                 (kernel-reason kernel)
                 (format nil "governor intervention: ~A" outcome))
           t)
```

and update `run-kernel`'s docstring first line to mention parking:

```lisp
  "Drive KERNEL until the policy finishes or gives up, the governor
intervenes (parking on :park-mission/:ask-human), or MAX-STEPS is
exhausted. Returns (values status reason); status is :done, :parked,
or :given-up."
```

`next/src/governor.lisp` — extend the projection `:import-from` with
`#:apply-event`; add a NEW clause:

```lisp
  (:import-from #:cl-harness-next/src/event
                #:event-type
                #:event-payload)
```

Append after `reset-governor-progress`:

```lisp
(defmethod apply-event ((governor governor) event)
  "A logged dial demotion grants the next level a fresh stall
allowance on replay too (SP7 resume coherence). Live runs reset twice
— imperatively at demote time and again when the dial event folds —
which is idempotent."
  (let ((payload (event-payload event)))
    (when (and (eq :decision (event-type event))
               (hash-table-p payload)
               (equal "dial" (gethash "kind" payload)))
      (reset-governor-progress governor)))
  governor)
```

`next/src/adaptive-policy.lisp` — make it a projection with an
absolutely-derived level. Extend the defpackage with NEW clauses:

```lisp
  (:import-from #:cl-harness-next/src/projection
                #:projection
                #:apply-event)
  (:import-from #:cl-harness-next/src/event
                #:event-type
                #:event-payload)
```

Replace the class definition:

```lisp
(defclass adaptive-policy (control-policy projection)
  ((levels :initarg :levels :reader policy-levels
           :documentation "Policies ordered highest autonomy first,
e.g. (self-directed guided scripted).")
   (level-index :initform 0 :accessor policy-level-index)
   (dial-events-seen :initform 0 :accessor %dial-events-seen
                     :documentation "Logged dial demotions folded so
far; LEVEL-INDEX is derived absolutely from this count, so the
imperative demote-time update and the fold agree, and a cold replay
restores the level (SP7 resume coherence)."))
  (:documentation "Spec §6.1 adaptive dial: capability-adaptive
demotion driven by governor stall interventions. Also a projection —
include it in the world model's :extra-projections so resume rebuilds
the dial level from the log."))
```

Replace `handle-intervention`'s progress-stalled branch (the whole
defmethod, keeping everything else identical):

```lisp
(defmethod handle-intervention ((policy adaptive-policy) condition)
  (typecase condition
    (budget-exhausted :abort-run)
    (progress-stalled
     (if (< (1+ (policy-level-index policy))
            (length (policy-levels policy)))
         (progn
           ;; Immediate (the kernel decides with the new level this
           ;; very step); the logged dial event re-derives the same
           ;; value when it folds.
           (setf (policy-level-index policy)
                 (min (1+ (policy-level-index policy))
                      (1- (length (policy-levels policy)))))
           (alexandria:when-let
               ((governor (intervention-governor condition)))
             (reset-governor-progress governor))
           :demote-dial)
         :abort-run))
    (t :abort-run)))
```

Append:

```lisp
(defmethod apply-event ((policy adaptive-policy) event)
  "Derive the dial level from the logged demotions (absolute, not
incremental relative to the imperative update — the two agree)."
  (let ((payload (event-payload event)))
    (when (and (eq :decision (event-type event))
               (hash-table-p payload)
               (equal "dial" (gethash "kind" payload)))
      (incf (%dial-events-seen policy))
      (setf (policy-level-index policy)
            (min (%dial-events-seen policy)
                 (1- (length (policy-levels policy)))))))
  policy)
```

- [ ] **Step 3: Green** — expect **200 / 0** (196 − 1 replaced + 1 new
kernel + 1 governor + 2 adaptive + the replacement = net +4).

- [ ] **Step 4: Lint and commit**

```bash
mallet next/src/kernel.lisp next/src/governor.lisp next/src/adaptive-policy.lisp next/tests/kernel-test.lisp next/tests/governor-test.lisp next/tests/adaptive-policy-test.lisp
git add next/src/kernel.lisp next/src/governor.lisp next/src/adaptive-policy.lisp next/tests/kernel-test.lisp next/tests/governor-test.lisp next/tests/adaptive-policy-test.lisp
git commit -m "feat(next): parked kernels and log-derived dial/governor state"
```

---

### Task 2: Mission data + queue + human requests

**Files:**
- Create: `next/tests/mission-test.lisp`
- Create: `next/src/mission.lisp`
- Modify: `cl-harness-next.asd` (add test file)

- [ ] **Step 1: Write the failing tests**

Create `next/tests/mission-test.lisp`:

```lisp
;;;; next/tests/mission-test.lisp
;;;;
;;;; Tests for next/src/mission.lisp (spec §9): mission lifecycle,
;;;; queue, asynchronous human requests.

(defpackage #:cl-harness-next/tests/mission-test
  (:use #:cl #:rove)
  (:import-from #:cl-harness-next/src/mission
                #:mission
                #:mission-id
                #:mission-goal
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
```

Add `"cl-harness-next/tests/mission-test"` to the tests system. Run —
red: load failure (missing package).

- [ ] **Step 2: Create `next/src/mission.lisp`**

```lisp
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
```

- [ ] **Step 3: Green** — expect **204 / 0**.

- [ ] **Step 4: Lint and commit**

```bash
mallet next/src/mission.lisp next/tests/mission-test.lisp
git add next/src/mission.lisp next/tests/mission-test.lisp cl-harness-next.asd
git commit -m "feat(next): mission lifecycle, queue, and async human requests"
```

---

### Task 3: Mission runner (assemble, run, park-to-human, resume)

**Files:**
- Create: `next/tests/mission-runner-test.lisp`
- Create: `next/src/mission-runner.lisp`
- Modify: `cl-harness-next.asd` (add test file)

- [ ] **Step 1: Write the failing tests**

Create `next/tests/mission-runner-test.lisp`:

```lisp
;;;; next/tests/mission-runner-test.lisp
;;;;
;;;; Tests for next/src/mission-runner.lisp (spec §9): run to done,
;;;; park with a queued human request on budget exhaustion, resume
;;;; from the log with a raised envelope.

(defpackage #:cl-harness-next/tests/mission-runner-test
  (:use #:cl #:rove)
  (:import-from #:cl-harness-next/src/mcp-client
                #:mcp-transport
                #:transport-send-request
                #:make-mcp-client)
  (:import-from #:cl-harness-next/src/environment
                #:make-cl-mcp-environment)
  (:import-from #:cl-harness-next/src/event
                #:event-type
                #:event-payload)
  (:import-from #:cl-harness-next/src/event-log
                #:read-events)
  (:import-from #:cl-harness-next/src/governor
                #:governor)
  (:import-from #:cl-harness-next/src/scripted-policy
                #:scripted-fix-policy)
  (:import-from #:cl-harness-next/src/mission
                #:mission
                #:mission-status
                #:mission-reason
                #:mission-queue
                #:enqueue-mission
                #:pending-human-requests
                #:resolve-human-request
                #:human-request-mission
                #:human-request-reason)
  (:import-from #:cl-harness-next/src/mission-runner
                #:run-mission))

(in-package #:cl-harness-next/tests/mission-runner-test)

(defclass runner-fix-transport (mcp-transport)
  ((fixed-p :initform nil :accessor runner-fixed-p)))

(defmethod transport-send-request ((transport runner-fix-transport)
                                   body)
  (let* ((parsed (yason:parse body))
         (id (gethash "id" parsed))
         (method (gethash "method" parsed)))
    (cond
      ((null id) "")
      ((equal method "initialize")
       (format nil "{\"jsonrpc\":\"2.0\",\"id\":~A,\"result\":{}}" id))
      ((equal method "tools/list")
       (format nil "{\"jsonrpc\":\"2.0\",\"id\":~A,~A}" id
               (concatenate 'string
                            "\"result\":{\"tools\":["
                            "{\"name\":\"pool-kill-worker\"},"
                            "{\"name\":\"load-system\"},"
                            "{\"name\":\"run-tests\"},"
                            "{\"name\":\"lisp-edit-form\"}]}")))
      ((equal method "tools/call")
       (let ((tool (gethash "name" (gethash "params" parsed))))
         (format nil "{\"jsonrpc\":\"2.0\",\"id\":~A,\"result\":~A}" id
                 (cond
                   ((equal tool "lisp-edit-form")
                    (setf (runner-fixed-p transport) t)
                    "{\"content\":[]}")
                   ((equal tool "run-tests")
                    (if (runner-fixed-p transport)
                        "{\"passed\":3,\"failed\":0}"
                        "{\"passed\":2,\"failed\":1}"))
                   (t "{\"content\":[]}")))))
      (t (error "unexpected method ~S" method)))))

(defparameter *patch-json*
  (concatenate 'string
               "{\"type\":\"tool_call\",\"tool\":\"lisp-edit-form\","
               "\"arguments\":{\"file_path\":\"a.lisp\","
               "\"content\":\"fix\"}}"))

(defun %environment-factory (mission log)
  (declare (ignore mission))
  (make-cl-mcp-environment
   :client (make-mcp-client (make-instance 'runner-fix-transport))
   :condition :runtime-native
   :event-log log))

(defun %policy-factory (mission)
  (declare (ignore mission))
  (make-instance 'scripted-fix-policy
                 :system "s" :test-system "s/tests"
                 :diagnose-fn (lambda (view)
                                (declare (ignore view))
                                *patch-json*)))

(defun %governor-factory (max-actions)
  (lambda (mission)
    (declare (ignore mission))
    (make-instance 'governor :max-actions max-actions)))

(defmacro with-mission ((mission queue) &body body)
  `(uiop:with-temporary-file (:pathname log-path :type "jsonl")
     (uiop:delete-file-if-exists log-path)
     (let ((,mission (make-instance 'mission :id "m1"
                                    :goal "fix evict"
                                    :acceptance-criteria (list "green")
                                    :log-path log-path))
           (,queue (make-instance 'mission-queue)))
       (enqueue-mission ,queue ,mission)
       ,@body)))

(deftest mission-runs-to-done
  (with-mission (mission queue)
    (multiple-value-bind (status reason)
        (run-mission mission queue
                     :environment-factory #'%environment-factory
                     :policy-factory #'%policy-factory)
      (ok (eq :done status))
      (ok (search "clean" reason)))
    (ok (eq :done (mission-status mission)))
    (let ((events (read-events log-path)))
      (ok (= 1 (count :run-start (mapcar #'event-type events))))
      (let ((start (find :run-start events :key #'event-type)))
        (ok (equal "fix evict" (gethash "goal" (event-payload start))))
        (ok (equal '("green")
                   (gethash "acceptance_criteria"
                            (event-payload start))))))))

(deftest budget-exhaustion-parks-and-asks-the-human
  (with-mission (mission queue)
    (multiple-value-bind (status reason)
        (run-mission mission queue
                     :environment-factory #'%environment-factory
                     :policy-factory #'%policy-factory
                     :governor-factory (%governor-factory 2))
      (ok (eq :parked status))
      (ok (search "PARK-MISSION" reason)))
    (ok (eq :parked (mission-status mission)))
    (let ((requests (pending-human-requests queue)))
      (ok (= 1 (length requests)))
      (ok (eq mission (human-request-mission (first requests))))
      (ok (search "actions" (human-request-reason (first requests)))))))

(deftest resume-completes-with-a-raised-envelope
  (with-mission (mission queue)
    (run-mission mission queue
                 :environment-factory #'%environment-factory
                 :policy-factory #'%policy-factory
                 :governor-factory (%governor-factory 2))
    (ok (eq :parked (mission-status mission)))
    (resolve-human-request queue
                           (first (pending-human-requests queue))
                           :response "raise to 50")
    (multiple-value-bind (status reason)
        (run-mission mission queue
                     :environment-factory #'%environment-factory
                     :policy-factory #'%policy-factory
                     :governor-factory (%governor-factory 50))
      (ok (eq :done status))
      (ok (search "clean" reason)))
    (ok (eq :done (mission-status mission)))
    ;; Resume did not re-emit run-start.
    (ok (= 1 (count :run-start (mapcar #'event-type
                                       (read-events log-path)))))))

(deftest terminal-missions-refuse-to-run
  (with-mission (mission queue)
    (run-mission mission queue
                 :environment-factory #'%environment-factory
                 :policy-factory #'%policy-factory)
    (ok (eq :done (mission-status mission)))
    (ok (handler-case
            (progn (run-mission mission queue
                                :environment-factory
                                #'%environment-factory
                                :policy-factory #'%policy-factory)
                   nil)
          (error () t)))))
```

Add `"cl-harness-next/tests/mission-runner-test"` to the tests system.
Run — red: load failure (missing package).

- [ ] **Step 2: Create `next/src/mission-runner.lisp`**

```lisp
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
      (multiple-value-bind (status reason)
          (run-kernel kernel :max-steps max-steps)
        (ecase status
          (:done (mission-transition mission :done :reason reason))
          (:parked (mission-transition mission :parked :reason reason))
          (:given-up (mission-transition mission :failed
                                         :reason reason)))
        (values (mission-status mission) reason)))))
```

- [ ] **Step 3: Green** — expect **208 / 0**.

- [ ] **Step 4: Lint and commit**

```bash
mallet next/src/mission-runner.lisp next/tests/mission-runner-test.lisp
git add next/src/mission-runner.lisp next/tests/mission-runner-test.lisp cl-harness-next.asd
git commit -m "feat(next): mission runner — assemble, park to the human port, resume"
```

---

### Task 4: Facade, acceptance, docs

**Files:**
- Modify: `next/src/main.lisp`
- Modify: `next/tests/main-test.lisp`
- Modify: `README.md`

- [ ] **Step 1: Write the failing acceptance test**

Append to `next/tests/main-test.lisp` (facade symbols only; reuses the
`%sp5b-fix-transport` class already defined in this file):

```lisp
(deftest sp7-mission-queue-acceptance
  ;; SP7 capstone: two missions in a queue — one completes, one parks
  ;; on budget exhaustion with a human request; the human resolves and
  ;; resumes it with a raised envelope; both end :done. All through
  ;; the facade; resume rebuilds everything from the mission's log.
  (uiop:with-temporary-file (:pathname log-1 :type "jsonl")
    (uiop:with-temporary-file (:pathname log-2 :type "jsonl")
      (uiop:delete-file-if-exists log-1)
      (uiop:delete-file-if-exists log-2)
      (let* ((patch-json
               (concatenate 'string
                            "{\"type\":\"tool_call\","
                            "\"tool\":\"lisp-edit-form\","
                            "\"arguments\":{\"file_path\":\"a.lisp\","
                            "\"content\":\"fix\"}}"))
             (environment-factory
               (lambda (mission log)
                 (declare (ignore mission))
                 (cl-harness-next:make-cl-mcp-environment
                  :client (cl-harness-next:make-mcp-client
                           (make-instance '%sp5b-fix-transport))
                  :condition :runtime-native
                  :event-log log)))
             (policy-factory
               (lambda (mission)
                 (declare (ignore mission))
                 (make-instance 'cl-harness-next:scripted-fix-policy
                                :system "s" :test-system "s/tests"
                                :diagnose-fn (lambda (view)
                                               (declare (ignore view))
                                               patch-json))))
             (queue (make-instance 'cl-harness-next:mission-queue))
             (m1 (make-instance 'cl-harness-next:mission
                                :id "m1" :goal "fix one"
                                :log-path log-1))
             (m2 (make-instance 'cl-harness-next:mission
                                :id "m2" :goal "fix two"
                                :log-path log-2)))
        (cl-harness-next:enqueue-mission queue m1)
        (cl-harness-next:enqueue-mission queue m2)
        (ok (eq :done (cl-harness-next:run-mission
                       m1 queue
                       :environment-factory environment-factory
                       :policy-factory policy-factory)))
        (ok (eq :parked (cl-harness-next:run-mission
                         m2 queue
                         :environment-factory environment-factory
                         :policy-factory policy-factory
                         :governor-factory
                         (lambda (mission)
                           (declare (ignore mission))
                           (make-instance 'cl-harness-next:governor
                                          :max-actions 2)))))
        (let ((request (first (cl-harness-next:pending-human-requests
                               queue))))
          (ok request)
          (cl-harness-next:resolve-human-request queue request
                                                 :response "raise"))
        (ok (eq :done (cl-harness-next:run-mission
                       m2 queue
                       :environment-factory environment-factory
                       :policy-factory policy-factory
                       :governor-factory
                       (lambda (mission)
                         (declare (ignore mission))
                         (make-instance 'cl-harness-next:governor
                                        :max-actions 50)))))
        (ok (eq :done (cl-harness-next:mission-status m2)))
        (ok (null (cl-harness-next:pending-human-requests queue)))))))
```

- [ ] **Step 2: Red** — facade exports missing.

- [ ] **Step 3: Extend the facade**

Add `:import-from` clauses (after the adaptive-policy one), preserving
all existing clauses:

```lisp
  (:import-from #:cl-harness-next/src/mission
                #:mission
                #:mission-id
                #:mission-goal
                #:mission-acceptance-criteria
                #:mission-non-goals
                #:mission-log-path
                #:mission-status
                #:mission-reason
                #:mission-queue
                #:enqueue-mission
                #:mission-queue-missions
                #:next-runnable-mission
                #:pending-human-requests
                #:resolve-human-request
                #:human-request
                #:human-request-mission
                #:human-request-reason
                #:human-request-resolved-p
                #:human-request-response)
  (:import-from #:cl-harness-next/src/mission-runner
                #:run-mission)
```

Add them all to `:export` (groups `;; mission`, `;; mission-runner`).

- [ ] **Step 4: Green** — expect **209 / 0**.

- [ ] **Step 5: Force-compile + columns** — no warnings from next/
sources; awk column check clean.

- [ ] **Step 6: Document** — extend the README next/ subsection: after
"...adaptive demotion on stalls)" insert "; SP7 adds the L4 mission
layer (queue, suspend/resume from the log, async human escalation)"
before ". It does not affect".

- [ ] **Step 7: Lint and commit**

```bash
mallet next/src/*.lisp next/tests/*.lisp
git add next/src/main.lisp next/tests/main-test.lisp README.md
git commit -m "feat(next): facade exports + SP7 mission-queue acceptance"
```

---

## Verification checklist (whole sub-project)

- Clean image: fresh worker → load-asd → `run-tests
  cl-harness-next/tests` 209/0.
- Legacy untouched: `git status --short src/ tests/` empty; `run-tests
  cl-harness/tests` 498/0.
- `mallet next/src/*.lisp next/tests/*.lisp` clean; no lines >100 cols.

## Deferred (SP8+ — do NOT build now)

- Queue persistence / reconstruction from a directory of mission logs
  (mission logs ARE durable; the in-memory queue is enough for v1).
- `drain-mission-queue` convenience loop (callers iterate
  next-runnable-mission; add sugar when a consumer exists).
- Mission-level park/resume EVENTS in the log (:checkpoint) — the
  mission status lives outside the log today; record transitions as
  events when L5's miner wants them.
- Concurrency (parallel missions; the SP1 event-log is
  single-writer-per-run by contract).
- :ask-human as a distinct flow from :park-mission (today both park;
  differentiate when the human port grows a UI).
- Pack-driven mission construction (budgets/dial from a policy pack).
