# SP5b: L3 Agent Kernel + Scripted Fix Policy Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the L3 agent kernel — the minimal `observe → decide → act → record` loop with `decide` owned by a swappable control policy — and the first dial level: the scripted fix policy, an FSM that owns the verify→diagnose→patch→verify→clean-verify sequence while the LLM only fills patch content.

**Architecture:** `kernel.lisp` defines the `control-policy` protocol (`decide` → a `decision` struct: `:act`/`:consult`/`:finish`/`:give-up`), the kernel state (environment + event-log + world-model + optional governor), `kernel-step` (refresh world model → governor gate → decide → record the decision as an event → execute → refresh), and `run-kernel`. The governor's default kernel stance maps any intervention to `:abort-run` (mission-layer handlers arrive in SP7). `scripted-policy.lisp` is the `scripted` dial level (spec §6): oracles built from system names, diagnose calls via an injected `diagnose-fn` (build one from a provider with SP5a's `make-judge-fn` + the exported system prompt), non-patch proposals are policy violations. Everything SP1–SP5a built meets here: env actions/observations and oracle verdicts land in the event log; the world model derives clean-verify from the very trail the policy's oracles produce. Spec: `docs/superpowers/specs/2026-06-11-autonomous-harness-redesign-design.md` §6 (kernel + dial table), §7 (oracles consulted by the loop), §11 (restart stance).

**Tech Stack:** SBCL, rove, alexandria, yason. No new dependencies.

**Conventions** (same as SP1–SP5a, incl. the `elt`-not-`first` yason rule): 2-space indent, ≤100 cols, blank lines between forms, docstrings, no `:local-nicknames`, conditions/structs per house style, `%`-internals unexported. cl-mcp tools; `mallet` before commits; tests via `run-tests` `{"system": "cl-harness-next/tests"}`; worker-restart recovery `(asdf:load-asd "/home/wiz/.roswell/local-projects/cl-harness/cl-harness-next.asd")`. Unused test imports flagged by mallet get removed (note it).

**Scope note:** the spec's dial table glosses `scripted` as "現行 develop 相当の台本". This plan ships the scripted FIX loop (PRD §11.2 distilled); the develop-equivalent scripted pipeline (planner, test generation, staged review) is future work on top of this kernel — see Deferred.

---

## File Structure

```text
next/src/world-model.lisp     MOD  make-standard-world-model gains :extra-projections
next/src/kernel.lisp          NEW  control-policy protocol, decision struct, kernel,
                                   kernel-step / run-kernel
next/src/scripted-policy.lisp NEW  scripted dial level: FSM + diagnose via injected fn
next/src/main.lisp            MOD  facade re-exports
next/tests/world-model-test.lisp   MOD (+1)
next/tests/kernel-test.lisp        NEW (+6)
next/tests/scripted-policy-test.lisp NEW (+5)
next/tests/main-test.lisp          MOD (+1 acceptance)
cl-harness-next.asd           MOD  + 2 test files
README.md                     MOD  one sentence
```

Test-count checkpoints: 165 → T1 172 → T2 177 → T3 178.

---

### Task 1: Kernel (protocol + loop) and `:extra-projections`

**Files:**
- Modify: `next/src/world-model.lisp` (+ test in `next/tests/world-model-test.lisp`)
- Create: `next/src/kernel.lisp`
- Create: `next/tests/kernel-test.lisp`
- Modify: `cl-harness-next.asd` (add kernel-test)

- [ ] **Step 1: Write the failing world-model test**

Append to `next/tests/world-model-test.lisp`:

```lisp
(deftest standard-world-model-accepts-extra-projections
  (let* ((counter (make-instance 'counting-projection))
         (world-model (make-standard-world-model
                       :extra-projections (list :count counter))))
    (ok (eq counter (world-model-projection world-model :count)))
    (ok (world-model-projection world-model :goal))))
```

Run — red: `make-standard-world-model` rejects the keyword.

- [ ] **Step 2: Extend `make-standard-world-model`**

Replace the defun in `next/src/world-model.lisp`:

```lisp
(defun make-standard-world-model (&key extra-projections)
  "World model with the four standard SP3 projections (:goal,
:exploration, :changes, :verification). EXTRA-PROJECTIONS, a plist of
key → projection, is prepended — e.g. (:governor g) so the governor's
counters are folded from the same replayed events."
  (make-world-model
   :projections
   (append extra-projections
           (list :goal (make-instance 'goal-projection)
                 :exploration (make-instance 'exploration-ledger)
                 :changes (make-instance 'change-ledger)
                 :verification (make-instance 'verification-ledger)))))
```

Run — the new test passes (166 total at this point).

- [ ] **Step 3: Write the failing kernel tests**

Create `next/tests/kernel-test.lisp`:

```lisp
;;;; next/tests/kernel-test.lisp
;;;;
;;;; Tests for next/src/kernel.lisp: the L3 loop (spec §6) with a fake
;;;; environment that honors the real contract (records its
;;;; interactions into the event log) and local test policies.

(defpackage #:cl-harness-next/tests/kernel-test
  (:use #:cl #:rove)
  (:import-from #:cl-harness-next/src/event
                #:event-type)
  (:import-from #:cl-harness-next/src/event-log
                #:open-event-log
                #:emit-event
                #:read-events)
  (:import-from #:cl-harness-next/src/environment
                #:environment
                #:perform-action
                #:environment-close)
  (:import-from #:cl-harness-next/src/oracle
                #:oracle
                #:oracle-name
                #:evaluate
                #:make-verdict
                #:verdict-pass-p)
  (:import-from #:cl-harness-next/src/governor
                #:governor)
  (:import-from #:cl-harness-next/src/kernel
                #:control-policy
                #:decide
                #:make-decision
                #:make-kernel
                #:kernel-status
                #:kernel-reason
                #:kernel-step-count
                #:kernel-last-verdict
                #:kernel-last-result
                #:kernel-last-action-error
                #:run-kernel))

(in-package #:cl-harness-next/tests/kernel-test)

(defun %hash (&rest plist)
  (alexandria:plist-hash-table plist :test #'equal))

(defmacro with-log ((log path) &body body)
  `(uiop:with-temporary-file (:pathname ,path :type "jsonl")
     (uiop:delete-file-if-exists ,path)
     (let ((,log (open-event-log ,path)))
       ,@body)))

(defclass fake-environment (environment)
  ((log :initarg :log :reader fake-log)
   (handlers :initarg :handlers :initform nil :accessor fake-handlers
             :documentation "List of (tool args → result hash) fns,
consumed one per action; default returns {\"ok\":true}.")
   (closed-p :initform nil :accessor fake-closed-p))
  (:documentation "Honors the real environment contract: every action
and its observation are recorded into the event log."))

(defmethod perform-action ((env fake-environment) tool arguments)
  (emit-event (fake-log env) :action
              (%hash "tool" tool "arguments" (or arguments (%hash))))
  (let ((handler (or (pop (fake-handlers env))
                     (lambda (tool arguments)
                       (declare (ignore tool arguments))
                       (%hash "ok" t)))))
    (handler-case
        (let ((result (funcall handler tool arguments)))
          (emit-event (fake-log env) :observation
                      (%hash "tool" tool "result" result))
          result)
      (error (condition)
        (emit-event (fake-log env) :observation
                    (%hash "tool" tool
                           "error" (format nil "~A" condition)))
        (error condition)))))

(defmethod environment-close ((env fake-environment))
  (setf (fake-closed-p env) t))

(defclass script-policy (control-policy)
  ((decisions :initarg :decisions :accessor script-decisions)))

(defmethod decide ((policy script-policy) kernel)
  (declare (ignore kernel))
  (pop (script-decisions policy)))

(defclass yes-oracle (oracle) ())
(defmethod oracle-name ((oracle yes-oracle)) :yes)
(defmethod evaluate ((oracle yes-oracle) subject)
  (declare (ignore subject))
  (make-verdict :oracle :yes :pass-p t :reason nil))

(deftest finish-decision-completes-the-run
  (with-log (log path)
    (let ((kernel (make-kernel
                   :environment (make-instance 'fake-environment :log log)
                   :event-log log
                   :policy (make-instance
                            'script-policy
                            :decisions (list (make-decision
                                              :kind :finish
                                              :reason "done"))))))
      (multiple-value-bind (status reason) (run-kernel kernel)
        (ok (eq :done status))
        (ok (equal "done" reason)))
      (ok (= 1 (kernel-step-count kernel)))
      (ok (find :decision (read-events path) :key #'event-type)))))

(deftest act-performs-and-stores-result
  (with-log (log path)
    (let ((kernel (make-kernel
                   :environment (make-instance 'fake-environment :log log)
                   :event-log log
                   :policy (make-instance
                            'script-policy
                            :decisions
                            (list (make-decision :kind :act :tool "x"
                                                 :arguments (%hash "a" 1)
                                                 :reason "poke")
                                  (make-decision :kind :finish
                                                 :reason "ok"))))))
      (ok (eq :done (run-kernel kernel)))
      (ok (hash-table-p (kernel-last-result kernel)))
      (ok (= 2 (kernel-step-count kernel)))
      (let ((types (mapcar #'event-type (read-events path))))
        (ok (= 2 (count :decision types)))
        (ok (= 1 (count :action types)))
        (ok (= 1 (count :observation types)))))))

(deftest act-errors-are-captured-not-fatal
  (with-log (log path)
    (let ((kernel (make-kernel
                   :environment (make-instance
                                 'fake-environment :log log
                                 :handlers (list (lambda (tool arguments)
                                                   (declare (ignore tool
                                                                    arguments))
                                                   (error "denied"))))
                   :event-log log
                   :policy (make-instance
                            'script-policy
                            :decisions
                            (list (make-decision :kind :act :tool "x"
                                                 :reason "try")
                                  (make-decision :kind :finish
                                                 :reason "saw error"))))))
      (ok (eq :done (run-kernel kernel)))
      (ok (search "denied" (kernel-last-action-error kernel)))
      (ok (null (kernel-last-result kernel))))))

(deftest consult-stores-verdict-and-records-event
  (with-log (log path)
    (let ((kernel (make-kernel
                   :environment (make-instance 'fake-environment :log log)
                   :event-log log
                   :policy (make-instance
                            'script-policy
                            :decisions
                            (list (make-decision :kind :consult
                                                 :oracle (make-instance
                                                          'yes-oracle)
                                                 :reason "ask")
                                  (make-decision :kind :finish
                                                 :reason "ok"))))))
      (ok (eq :done (run-kernel kernel)))
      (ok (verdict-pass-p (kernel-last-verdict kernel)))
      (ok (find :oracle-result (read-events path) :key #'event-type)))))

(deftest governor-intervention-halts-the-run
  (with-log (log path)
    (let* ((governor (make-instance 'governor :max-actions 1))
           (kernel (make-kernel
                    :environment (make-instance 'fake-environment :log log)
                    :event-log log
                    :governor governor
                    :policy (make-instance
                             'script-policy
                             :decisions
                             (list (make-decision :kind :act :tool "x"
                                                  :reason "1")
                                   (make-decision :kind :act :tool "x"
                                                  :reason "2"))))))
      (multiple-value-bind (status reason) (run-kernel kernel)
        (ok (eq :given-up status))
        (ok (search "governor" reason)))
      (ok (= 1 (kernel-step-count kernel))))))

(deftest max-steps-exhaustion-gives-up
  (with-log (log path)
    (let ((kernel (make-kernel
                   :environment (make-instance 'fake-environment :log log)
                   :event-log log
                   :policy (make-instance
                            'script-policy
                            :decisions
                            (loop repeat 10
                                  collect (make-decision :kind :act
                                                         :tool "x"
                                                         :reason "spin"))))))
      (multiple-value-bind (status reason) (run-kernel kernel :max-steps 3)
        (ok (eq :given-up status))
        (ok (search "maximum steps" reason)))
      (ok (= 3 (kernel-step-count kernel)))
      ;; Every step's decision is on the record.
      (ok (= 3 (count :decision (mapcar #'event-type
                                        (read-events path))))))))
```

Add `"cl-harness-next/tests/kernel-test"` to the tests system. Run —
red: load failure (package `cl-harness-next/src/kernel` missing).

- [ ] **Step 4: Create `next/src/kernel.lisp`**

```lisp
;;;; next/src/kernel.lisp
;;;;
;;;; The L3 agent kernel (spec §6): the minimal observe → decide →
;;;; act → record loop. DECIDE is owned by a CONTROL-POLICY — the
;;;; autonomy dial swaps policies, never the kernel. The kernel's
;;;; governor stance is the strictest default (any intervention
;;;; aborts); mission-layer restart handlers arrive in SP7.

(defpackage #:cl-harness-next/src/kernel
  (:use #:cl)
  (:import-from #:cl-harness-next/src/event-log
                #:event-log-path
                #:emit-event)
  (:import-from #:cl-harness-next/src/world-model
                #:make-standard-world-model
                #:refresh-world-model)
  (:import-from #:cl-harness-next/src/environment
                #:perform-action)
  (:import-from #:cl-harness-next/src/oracle
                #:consult)
  (:import-from #:cl-harness-next/src/governor
                #:governor-intervention
                #:check-governor)
  (:export #:control-policy
           #:decide
           #:decision
           #:make-decision
           #:decision-kind
           #:decision-tool
           #:decision-arguments
           #:decision-oracle
           #:decision-subject
           #:decision-reason
           #:kernel
           #:make-kernel
           #:kernel-environment
           #:kernel-event-log
           #:kernel-world-model
           #:kernel-policy
           #:kernel-governor
           #:kernel-status
           #:kernel-reason
           #:kernel-step-count
           #:kernel-last-verdict
           #:kernel-last-result
           #:kernel-last-action-error
           #:kernel-step
           #:run-kernel))

(in-package #:cl-harness-next/src/kernel)

(defclass control-policy ()
  ()
  (:documentation "Abstract owner of DECIDE (spec §6). The dial levels
(scripted / guided / self-directed) are concrete subclasses; the
kernel never branches on which one it runs."))

(defgeneric decide (policy kernel)
  (:documentation "Return the next DECISION for KERNEL. Policies read
kernel state (world model, last verdict/result/error) and keep their
own internal state."))

(defstruct (decision (:conc-name decision-))
  kind        ; :act | :consult | :finish | :give-up
  tool        ; for :act — cl-mcp tool name string
  arguments   ; for :act — hash-table or NIL
  oracle      ; for :consult — an oracle instance
  subject     ; for :consult — defaults to the kernel's environment
  reason)     ; human-readable rationale (recorded; reason on finish/give-up)

(defclass kernel ()
  ((environment :initarg :environment :reader kernel-environment)
   (event-log :initarg :event-log :reader kernel-event-log)
   (world-model :initarg :world-model :reader kernel-world-model)
   (policy :initarg :policy :reader kernel-policy)
   (governor :initarg :governor :initform nil :reader kernel-governor)
   (status :initform :running :accessor kernel-status)
   (reason :initform nil :accessor kernel-reason)
   (step-count :initform 0 :accessor kernel-step-count)
   (last-verdict :initform nil :accessor kernel-last-verdict)
   (last-result :initform nil :accessor kernel-last-result)
   (last-action-error :initform nil :accessor kernel-last-action-error))
  (:documentation "One run's loop state (spec §6). All durable truth
lives in the event log; the kernel holds only loop bookkeeping."))

(defun make-kernel (&key environment event-log policy governor
                         world-model)
  "Build a KERNEL. WORLD-MODEL defaults to the standard projections,
with GOVERNOR folded in as the :governor projection when supplied (its
counters then rebuild from the same log on resume)."
  (make-instance 'kernel
                 :environment environment
                 :event-log event-log
                 :policy policy
                 :governor governor
                 :world-model
                 (or world-model
                     (make-standard-world-model
                      :extra-projections
                      (when governor (list :governor governor))))))

(defun %refresh (kernel)
  (refresh-world-model (kernel-world-model kernel)
                       (event-log-path (kernel-event-log kernel))))

(defun %emit-decision (kernel decision)
  (emit-event (kernel-event-log kernel) :decision
              (alexandria:plist-hash-table
               (list "kind" "step"
                     "text" (format nil "~A~@[ ~A~]~@[ — ~A~]"
                                    (string-downcase
                                     (symbol-name
                                      (decision-kind decision)))
                                    (decision-tool decision)
                                    (decision-reason decision)))
               :test #'equal)))

(defun %governor-halt-p (kernel)
  "Run CHECK-GOVERNOR under the kernel's default stance: any
intervention invokes :abort-run. True when the run was halted."
  (let ((governor (kernel-governor kernel)))
    (when governor
      (let ((outcome (handler-bind ((governor-intervention
                                      (lambda (condition)
                                        (declare (ignore condition))
                                        (invoke-restart :abort-run))))
                       (check-governor governor))))
        (unless (eq :continue outcome)
          (setf (kernel-status kernel) :given-up
                (kernel-reason kernel)
                (format nil "governor intervention: ~A" outcome))
          t)))))

(defun kernel-step (kernel)
  "One observe → decide → act → record iteration. Returns the status."
  (%refresh kernel)
  (when (%governor-halt-p kernel)
    (return-from kernel-step (kernel-status kernel)))
  (let ((decision (decide (kernel-policy kernel) kernel)))
    (%emit-decision kernel decision)
    (ecase (decision-kind decision)
      (:act
       (setf (kernel-last-action-error kernel) nil)
       (handler-case
           (setf (kernel-last-result kernel)
                 (perform-action (kernel-environment kernel)
                                 (decision-tool decision)
                                 (or (decision-arguments decision)
                                     (make-hash-table :test #'equal))))
         (error (condition)
           (setf (kernel-last-result kernel) nil
                 (kernel-last-action-error kernel)
                 (format nil "~A" condition)))))
      (:consult
       (setf (kernel-last-verdict kernel)
             (consult (decision-oracle decision)
                      (or (decision-subject decision)
                          (kernel-environment kernel))
                      :event-log (kernel-event-log kernel))))
      (:finish
       (setf (kernel-status kernel) :done
             (kernel-reason kernel) (decision-reason decision)))
      (:give-up
       (setf (kernel-status kernel) :given-up
             (kernel-reason kernel) (decision-reason decision)))))
  (incf (kernel-step-count kernel))
  (%refresh kernel)
  (kernel-status kernel))

(defun run-kernel (kernel &key (max-steps 50))
  "Drive KERNEL until the policy finishes or gives up, the governor
intervenes, or MAX-STEPS is exhausted. Returns (values status reason)."
  (loop while (and (eq :running (kernel-status kernel))
                   (< (kernel-step-count kernel) max-steps))
        do (kernel-step kernel))
  (when (eq :running (kernel-status kernel))
    (setf (kernel-status kernel) :given-up
          (kernel-reason kernel)
          (format nil "maximum steps (~A) exhausted" max-steps)))
  (values (kernel-status kernel) (kernel-reason kernel)))
```

- [ ] **Step 5: Green** — expect 172 / 0 (165 + 1 world-model + 6 kernel).

- [ ] **Step 6: Lint and commit**

```bash
mallet next/src/world-model.lisp next/src/kernel.lisp next/tests/world-model-test.lisp next/tests/kernel-test.lisp
git add next/src/world-model.lisp next/src/kernel.lisp next/tests/world-model-test.lisp next/tests/kernel-test.lisp cl-harness-next.asd
git commit -m "feat(next): L3 agent kernel with control-policy protocol"
```

---

### Task 2: Scripted fix policy

**Files:**
- Create: `next/tests/scripted-policy-test.lisp`
- Create: `next/src/scripted-policy.lisp`
- Modify: `cl-harness-next.asd` (add test file)

- [ ] **Step 1: Write the failing tests**

Create `next/tests/scripted-policy-test.lisp`:

```lisp
;;;; next/tests/scripted-policy-test.lisp
;;;;
;;;; Full-loop tests for next/src/scripted-policy.lisp over a REAL
;;;; cl-mcp environment with a stateful canned transport: red until a
;;;; patch lands, then green; clean-verify drives kill/load/test.

(defpackage #:cl-harness-next/tests/scripted-policy-test
  (:use #:cl #:rove)
  (:import-from #:cl-harness-next/src/mcp-client
                #:mcp-transport
                #:transport-send-request
                #:make-mcp-client)
  (:import-from #:cl-harness-next/src/environment
                #:make-cl-mcp-environment)
  (:import-from #:cl-harness-next/src/event-log
                #:open-event-log)
  (:import-from #:cl-harness-next/src/world-model
                #:world-model-projection)
  (:import-from #:cl-harness-next/src/verification-ledger
                #:clean-verified-p)
  (:import-from #:cl-harness-next/src/change-ledger
                #:patches)
  (:import-from #:cl-harness-next/src/governor
                #:governor)
  (:import-from #:cl-harness-next/src/kernel
                #:make-kernel
                #:kernel-world-model
                #:run-kernel)
  (:import-from #:cl-harness-next/src/scripted-policy
                #:scripted-fix-policy))

(in-package #:cl-harness-next/tests/scripted-policy-test)

(defclass fix-transport (mcp-transport)
  ((fixable-p :initarg :fixable-p :initform t :reader fix-fixable-p
              :documentation "When NIL, patches never turn the tests
green (stall scenarios).")
   (fixed-p :initform nil :accessor fix-fixed-p)
   (kill-count :initform 0 :accessor fix-kill-count)))

(defmethod transport-send-request ((transport fix-transport) body)
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
                            "{\"name\":\"lisp-edit-form\"},"
                            "{\"name\":\"lisp-patch-form\"}]}")))
      ((equal method "tools/call")
       (let ((tool (gethash "name" (gethash "params" parsed))))
         (format nil "{\"jsonrpc\":\"2.0\",\"id\":~A,\"result\":~A}" id
                 (cond
                   ((equal tool "lisp-edit-form")
                    (when (fix-fixable-p transport)
                      (setf (fix-fixed-p transport) t))
                    "{\"content\":[]}")
                   ((equal tool "run-tests")
                    (if (fix-fixed-p transport)
                        "{\"passed\":3,\"failed\":0}"
                        (concatenate 'string
                                     "{\"passed\":2,\"failed\":1,"
                                     "\"failed_tests\":[{\"test_name\":"
                                     "\"t-evict\",\"reason\":\"boom\"}]}")))
                   ((equal tool "pool-kill-worker")
                    (incf (fix-kill-count transport))
                    "{\"content\":[]}")
                   (t "{\"content\":[]}")))))
      (t (error "unexpected method ~S" method)))))

(defparameter *patch-json*
  (concatenate 'string
               "{\"type\":\"tool_call\",\"tool\":\"lisp-edit-form\","
               "\"arguments\":{\"file_path\":\"src/cache.lisp\","
               "\"form_type\":\"defun\",\"form_name\":\"evict\","
               "\"operation\":\"replace\","
               "\"content\":\"(defun evict () :fixed)\"},"
               "\"thought\":\"fix ordering\"}"))

(defmacro with-fix-kernel ((kernel &key (diagnose '*patch-json*)
                                        (fixable-p t) governor
                                        transport-var)
                           &body body)
  (let ((transport (or transport-var (gensym "TRANSPORT"))))
    `(uiop:with-temporary-file (:pathname log-path :type "jsonl")
       (uiop:delete-file-if-exists log-path)
       (let* ((,transport (make-instance 'fix-transport
                                         :fixable-p ,fixable-p))
              (log (open-event-log log-path))
              (environment (make-cl-mcp-environment
                            :client (make-mcp-client ,transport)
                            :condition :runtime-native
                            :event-log log))
              (,kernel (make-kernel
                        :environment environment
                        :event-log log
                        :governor ,governor
                        :policy (make-instance
                                 'scripted-fix-policy
                                 :system "s" :test-system "s/tests"
                                 :diagnose-fn
                                 (let ((response ,diagnose))
                                   (lambda (view)
                                     (declare (ignore view))
                                     response))))))
         (declare (ignorable ,transport))
         ,@body))))

(deftest happy-path-red-patch-green-clean
  (with-fix-kernel (kernel :transport-var transport)
    (multiple-value-bind (status reason) (run-kernel kernel)
      (ok (eq :done status))
      (ok (search "clean" reason)))
    (let ((world-model (kernel-world-model kernel)))
      (ok (clean-verified-p
           (world-model-projection world-model :verification)))
      (ok (= 1 (length (patches
                        (world-model-projection world-model :changes))))))
    (ok (= 1 (fix-kill-count transport)))))

(deftest unparseable-diagnosis-gives-up
  (with-fix-kernel (kernel :diagnose "this is not json")
    (multiple-value-bind (status reason) (run-kernel kernel)
      (ok (eq :given-up status))
      (ok (search "unparseable" reason)))))

(deftest model-give-up-is-respected
  (with-fix-kernel (kernel :diagnose
                           "{\"type\":\"finish\",\"status\":\"give_up\",\"summary\":\"stuck\"}")
    (multiple-value-bind (status reason) (run-kernel kernel)
      (ok (eq :given-up status))
      (ok (search "stuck" reason)))))

(deftest non-patch-tool-is-a-policy-violation
  (with-fix-kernel (kernel :diagnose
                           "{\"type\":\"tool_call\",\"tool\":\"repl-eval\",\"arguments\":{\"code\":\"1\"}}")
    (multiple-value-bind (status reason) (run-kernel kernel)
      (ok (eq :given-up status))
      (ok (search "patch tools" reason)))))

(deftest governor-stops-futile-patching
  (with-fix-kernel (kernel :fixable-p nil
                           :governor (make-instance 'governor
                                                    :max-patches 1))
    (multiple-value-bind (status reason) (run-kernel kernel)
      (ok (eq :given-up status))
      (ok (search "governor" reason)))))
```

Add `"cl-harness-next/tests/scripted-policy-test"` to the tests
system. Run — red: load failure (missing package).

- [ ] **Step 2: Create `next/src/scripted-policy.lisp`**

```lisp
;;;; next/src/scripted-policy.lisp
;;;;
;;;; The scripted dial level (spec §6): the FSM owns the sequence —
;;;; verify → diagnose → patch → verify → clean-verify — and the LLM
;;;; only fills patch content. One constrained LLM call per diagnose;
;;;; non-patch proposals are policy violations (give up; the governor
;;;; bounds futile cycles). Build a :diagnose-fn from a provider with
;;;; SP5a's MAKE-JUDGE-FN and +SCRIPTED-FIX-SYSTEM-PROMPT+.

(defpackage #:cl-harness-next/src/scripted-policy
  (:use #:cl)
  (:import-from #:cl-harness-next/src/kernel
                #:control-policy
                #:decide
                #:make-decision
                #:kernel-last-verdict
                #:kernel-world-model)
  (:import-from #:cl-harness-next/src/oracle
                #:verdict-pass-p)
  (:import-from #:cl-harness-next/src/verification-oracle
                #:verification-oracle)
  (:import-from #:cl-harness-next/src/context-compiler
                #:compile-context)
  (:import-from #:cl-harness-next/src/action
                #:parse-action
                #:action-parse-error
                #:agent-action-type
                #:agent-action-tool
                #:agent-action-arguments
                #:agent-action-thought
                #:agent-action-summary)
  (:import-from #:cl-harness-next/src/projection
                #:+patch-tool-names+)
  (:export #:scripted-fix-policy
           #:policy-state
           #:policy-system
           #:policy-test-system
           #:+scripted-fix-system-prompt+))

(in-package #:cl-harness-next/src/scripted-policy)

(alexandria:define-constant +scripted-fix-system-prompt+
    (concatenate
     'string
     "You are a Common Lisp bug fixer inside a scripted harness. "
     "You will be shown a failure-analysis view of the current "
     "state. Respond with EXACTLY one JSON object and nothing else:"
     (string #\Newline)
     "{\"type\":\"tool_call\",\"tool\":\"lisp-edit-form\" or "
     "\"lisp-patch-form\",\"arguments\":{...},\"thought\":\"...\"}"
     (string #\Newline)
     "to patch source, or "
     "{\"type\":\"finish\",\"status\":\"give_up\",\"summary\":\"...\"} "
     "when you cannot make progress.")
  :test #'equal
  :documentation "System prompt for the diagnose call; pair with
MAKE-JUDGE-FN to build a :diagnose-fn from a provider.")

(defclass scripted-fix-policy (control-policy)
  ((diagnose-fn :initarg :diagnose-fn :reader policy-diagnose-fn
                :documentation "Function (failure-analysis view string)
→ raw LLM response string.")
   (system :initarg :system :reader policy-system)
   (test-system :initarg :test-system :reader policy-test-system)
   (state :initform :init :accessor policy-state)
   (incremental-oracle :accessor %incremental-oracle)
   (clean-oracle :accessor %clean-oracle))
  (:documentation "Scripted fix loop (PRD §11.2 distilled): the FSM
owns WHAT happens next; the LLM only proposes patch content."))

(defmethod initialize-instance :after ((policy scripted-fix-policy)
                                       &key)
  (setf (%incremental-oracle policy)
        (make-instance 'verification-oracle
                       :system (policy-system policy)
                       :test-system (policy-test-system policy)
                       :mode :incremental)
        (%clean-oracle policy)
        (make-instance 'verification-oracle
                       :system (policy-system policy)
                       :test-system (policy-test-system policy)
                       :mode :clean)))

(defun %give-up (control &rest arguments)
  (make-decision :kind :give-up
                 :reason (apply #'format nil control arguments)))

(defun %diagnose (policy kernel)
  "Ask the LLM for exactly one patch action against the
failure-analysis view. Anything else gives up (the scripted dial does
not negotiate)."
  (let* ((view (compile-context (kernel-world-model kernel)
                                :decision-point :failure-analysis))
         (response
           (handler-case (funcall (policy-diagnose-fn policy) view)
             (error (condition)
               (return-from %diagnose
                 (%give-up "diagnose call failed: ~A" condition)))))
         (action
           (handler-case (parse-action response)
             (action-parse-error (condition)
               (return-from %diagnose
                 (%give-up "unparseable diagnosis: ~A" condition))))))
    (cond
      ((and (eq :tool-call (agent-action-type action))
            (member (agent-action-tool action) +patch-tool-names+
                    :test #'string=))
       (setf (policy-state policy) :verify)
       (make-decision :kind :act
                      :tool (agent-action-tool action)
                      :arguments (agent-action-arguments action)
                      :reason (or (agent-action-thought action)
                                  "apply diagnosed patch")))
      ((eq :finish (agent-action-type action))
       (%give-up "model stopped: ~A"
                 (or (agent-action-summary action) "(no summary)")))
      (t
       (%give-up "scripted policy accepts only patch tools, got ~A"
                 (agent-action-tool action))))))

(defmethod decide ((policy scripted-fix-policy) kernel)
  (ecase (policy-state policy)
    (:init
     (setf (policy-state policy) :check)
     (make-decision :kind :consult
                    :oracle (%incremental-oracle policy)
                    :reason "establish the verification baseline"))
    (:check
     (let ((verdict (kernel-last-verdict kernel)))
       (if (and verdict (verdict-pass-p verdict))
           (progn
             (setf (policy-state policy) :clean-check)
             (make-decision :kind :consult
                            :oracle (%clean-oracle policy)
                            :reason "confirm on a clean image"))
           (%diagnose policy kernel))))
    (:verify
     (setf (policy-state policy) :check)
     (make-decision :kind :consult
                    :oracle (%incremental-oracle policy)
                    :reason "verify the patch"))
    (:clean-check
     (let ((verdict (kernel-last-verdict kernel)))
       (if (and verdict (verdict-pass-p verdict))
           (make-decision :kind :finish
                          :reason "clean verification green")
           (%diagnose policy kernel))))))
```

- [ ] **Step 3: Green** — expect 177 / 0.

- [ ] **Step 4: Lint and commit**

```bash
mallet next/src/scripted-policy.lisp next/tests/scripted-policy-test.lisp
git add next/src/scripted-policy.lisp next/tests/scripted-policy-test.lisp cl-harness-next.asd
git commit -m "feat(next): scripted fix policy — FSM owns sequence, LLM fills patches"
```

---

### Task 3: Facade, acceptance, docs

**Files:**
- Modify: `next/src/main.lisp`
- Modify: `next/tests/main-test.lisp`
- Modify: `README.md`

- [ ] **Step 1: Write the failing acceptance test**

Append to `next/tests/main-test.lisp` (facade symbols only — the
provider feeds the diagnose-fn through `make-judge-fn`, proving the
whole SP1–SP5 stack end-to-end):

```lisp
(defclass %sp5b-fix-transport (cl-harness-next:mcp-transport)
  ((fixed-p :initform nil :accessor %sp5b-fixed-p)))

(defmethod cl-harness-next:transport-send-request
    ((transport %sp5b-fix-transport) body)
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
                    (setf (%sp5b-fixed-p transport) t)
                    "{\"content\":[]}")
                   ((equal tool "run-tests")
                    (if (%sp5b-fixed-p transport)
                        "{\"passed\":3,\"failed\":0}"
                        "{\"passed\":2,\"failed\":1}"))
                   (t "{\"content\":[]}")))))
      (t (error "unexpected method ~S" method)))))

(deftest sp5b-scripted-loop-acceptance
  ;; SP5 capstone: a (stub) LLM provider drives the scripted policy
  ;; through the kernel over a real environment — red, one patch,
  ;; green, clean-verified — entirely through the facade.
  (uiop:with-temporary-file (:pathname log-path :type "jsonl")
    (uiop:delete-file-if-exists log-path)
    (let* ((patch-json
             (concatenate 'string
                          "{\"type\":\"tool_call\","
                          "\"tool\":\"lisp-edit-form\","
                          "\"arguments\":{\"file_path\":\"a.lisp\","
                          "\"content\":\"(defun f () 1)\"}}"))
           (provider
             (cl-harness-next:make-openai-provider
              :base-url "http://x/v1" :api-key "k" :model "m"
              :transport
              (lambda (url headers body)
                (declare (ignore url headers body))
                (values (with-output-to-string (out)
                          (yason:encode
                           (alexandria:plist-hash-table
                            (list "choices"
                                  (list (alexandria:plist-hash-table
                                         (list "message"
                                               (alexandria:plist-hash-table
                                                (list "role" "assistant"
                                                      "content" patch-json)
                                                :test #'equal)
                                               "finish_reason" "stop")
                                         :test #'equal)))
                            :test #'equal)
                           out))
                        200 (make-hash-table :test #'equal)))))
           (log (cl-harness-next:open-event-log log-path))
           (environment (cl-harness-next:make-cl-mcp-environment
                         :client (cl-harness-next:make-mcp-client
                                  (make-instance '%sp5b-fix-transport))
                         :condition :runtime-native
                         :event-log log))
           (kernel (cl-harness-next:make-kernel
                    :environment environment
                    :event-log log
                    :policy (make-instance
                             'cl-harness-next:scripted-fix-policy
                             :system "s" :test-system "s/tests"
                             :diagnose-fn
                             (cl-harness-next:make-judge-fn
                              provider
                              :system-prompt
                              cl-harness-next:+scripted-fix-system-prompt+)))))
      (multiple-value-bind (status reason)
          (cl-harness-next:run-kernel kernel)
        (ok (eq :done status))
        (ok (search "clean" reason)))
      (ok (cl-harness-next:clean-verified-p
           (cl-harness-next:world-model-projection
            (cl-harness-next:kernel-world-model kernel)
            :verification))))))
```

- [ ] **Step 2: Red** — facade exports missing.

- [ ] **Step 3: Extend the facade**

Add `:import-from` clauses (after the judge one), preserving all
existing clauses:

```lisp
  (:import-from #:cl-harness-next/src/kernel
                #:control-policy
                #:decide
                #:decision
                #:make-decision
                #:decision-kind
                #:decision-tool
                #:decision-arguments
                #:decision-oracle
                #:decision-subject
                #:decision-reason
                #:kernel
                #:make-kernel
                #:kernel-environment
                #:kernel-event-log
                #:kernel-world-model
                #:kernel-policy
                #:kernel-governor
                #:kernel-status
                #:kernel-reason
                #:kernel-step-count
                #:kernel-last-verdict
                #:kernel-last-result
                #:kernel-last-action-error
                #:kernel-step
                #:run-kernel)
  (:import-from #:cl-harness-next/src/scripted-policy
                #:scripted-fix-policy
                #:policy-state
                #:policy-system
                #:policy-test-system
                #:+scripted-fix-system-prompt+)
```

Add all of them to `:export` (grouped `;; kernel`, `;; scripted-policy`).

- [ ] **Step 4: Green** — expect 178 / 0.

- [ ] **Step 5: Force-compile + columns** — `(asdf:compile-system
:cl-harness-next :force t)` no warnings from next/ sources; awk column
check over `next/src/*.lisp next/tests/*.lisp` clean.

- [ ] **Step 6: Document** — extend the README next/ subsection: after
"...judge bridge)" insert "; SP5b adds the L3 kernel
(observe→decide→act→record with swappable control policies) and the
scripted fix policy — the first dial level" before ". It does not
affect".

- [ ] **Step 7: Lint and commit**

```bash
mallet next/src/*.lisp next/tests/*.lisp
git add next/src/main.lisp next/tests/main-test.lisp README.md
git commit -m "feat(next): facade exports + SP5b scripted-loop acceptance"
```

---

## Verification checklist (whole sub-project)

- Clean image: fresh worker → load-asd → `run-tests
  cl-harness-next/tests` 178/0.
- Legacy untouched: `git status --short src/ tests/` empty; `run-tests
  cl-harness/tests` 498/0.
- `mallet next/src/*.lisp next/tests/*.lisp` clean; no lines >100 cols.

## Deferred (SP6+ — do NOT build now)

- Guided and self-directed policies + the adaptive dial
  (demote/promote mid-run) — SP6.
- The develop-equivalent scripted pipeline (planner, test generation,
  staged reviews on this kernel) — after SP6, as policy + pack data.
- Mission-layer restart handlers richer than abort-run (SP7); the
  kernel's `%governor-halt-p` stance is deliberately the strictest.
- Diagnose retry/repair prompts on parse failure (today: give up; the
  governor bounds cycles) — revisit with bench data (L5).
- Token-usage accounting from chat-response into governor budgets.
- Oracle-conflict detection now that the kernel sees multiple verdicts
  (SP4 deferred; wire when guided policies consult review oracles).
