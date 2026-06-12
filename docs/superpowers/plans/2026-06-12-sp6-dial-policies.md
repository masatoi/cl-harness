# SP6: Guided / Self-Directed Policies + Adaptive Dial Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Complete the autonomy dial (spec §6): the guided dial (harness-held agenda + invariants, agent picks each step), the self-directed dial (agent owns the loop; harness provides only resources/oracles/recording), and the adaptive dial (demote one level on progress stalls — same kernel, same world model — with the governor's stall counters reset).

**Architecture:** Task 1 extends the kernel minimally: a `:record` decision kind (policies can put findings/decisions on the event log through the kernel) and a `handle-intervention` generic so the POLICY chooses the governor restart (`control-policy` default stays `:abort-run`; `:demote-dial` makes the kernel continue and record a dial event; anything else halts). `llm-policies.lisp` holds the LLM-driven dial family: an `llm-step-policy` base (one constrained-JSON LLM call per step; finish-fixed claims pass through the mandatory clean gate — universal across dials per spec §7) with `guided-policy` (agenda = subgoal labels + world-model predicates rendered `[DONE]/[OPEN]` — progress derived from structured state, never from conversation; plus invariants) and `self-directed-policy` (no scaffolding sections). `adaptive-policy` wraps an ordered level list and demotes on `progress-stalled` (resets governor stall counters via the condition's governor slot); `budget-exhausted` still aborts — spent resources don't come back. Spec: §6/§6.1, §7 (clean gate), §11 (restarts).

**Tech Stack:** SBCL, rove, alexandria, yason. No new dependencies.

**Conventions** (same as SP1–SP5, incl. `elt`-not-`first` for yason arrays): 2-space indent, ≤100 cols, blank lines, docstrings, no `:local-nicknames`, `%`-internals unexported, conditions/structs house style. cl-mcp tools; `mallet` before commits; tests via `run-tests` `{"system": "cl-harness-next/tests"}`; worker-restart recovery `(asdf:load-asd "/home/wiz/.roswell/local-projects/cl-harness/cl-harness-next.asd")`. Unused test imports flagged by mallet get removed (note it). **WARNING (Task 1):** editing the `decision` defstruct in a live worker signals a struct-redefinition error on reload — after the kernel.lisp edits, `pool-kill-worker {"reset": true}` + re-register the `.asd` BEFORE running tests.

---

## File Structure

```text
next/src/kernel.lisp          MOD  decision gains payload + :record kind;
                                   handle-intervention generic; %governor-gate
next/src/governor.lisp        MOD  + reset-governor-progress
next/src/llm-policies.lisp    NEW  llm-step-policy base + guided + self-directed
next/src/adaptive-policy.lisp NEW  adaptive dial (demote on stall)
next/src/main.lisp            MOD  facade re-exports
next/tests/kernel-test.lisp        MOD (+3)
next/tests/governor-test.lisp      MOD (+1)
next/tests/llm-policies-test.lisp  NEW (+5 guided in T2, +3 self-directed in T3)
next/tests/adaptive-policy-test.lisp NEW (+4)
next/tests/main-test.lisp          MOD (+1 acceptance)
cl-harness-next.asd           MOD  + 2 test files
README.md                     MOD  one sentence
```

Test-count checkpoints: 178 → T1 182 → T2 187 → T3 190 → T4 194 → T5 195.

---

### Task 1: Kernel `:record` + policy-chosen interventions

**Files:**
- Modify: `next/src/kernel.lisp`, `next/src/governor.lisp`
- Modify: `next/tests/kernel-test.lisp`, `next/tests/governor-test.lisp`

- [ ] **Step 1: Write the failing tests**

`next/tests/kernel-test.lisp` — extend the kernel `:import-from` with
`#:decision-payload` and `#:handle-intervention`; add to the
projection imports block (NEW clause):

```lisp
  (:import-from #:cl-harness-next/src/projection
                #:apply-interaction
                #:interaction)
```

and extend the exploration-ledger access (NEW clause):

```lisp
  (:import-from #:cl-harness-next/src/exploration-ledger
                #:findings
                #:finding-hypothesis)
```

and the world-model accessor (NEW clause):

```lisp
  (:import-from #:cl-harness-next/src/world-model
                #:world-model-projection)
```

plus `#:kernel-world-model` in the kernel clause. Then append:

```lisp
(defun %stall-interaction ()
  (make-instance 'interaction
                 :tool "run-tests"
                 :result (%hash "failed" 1)
                 :action-seq 1 :observation-seq 2))

(deftest record-decision-feeds-the-ledger
  (with-log (log path)
    (declare (ignorable path))
    (let ((kernel (make-kernel
                   :environment (make-instance 'fake-environment :log log)
                   :event-log log
                   :policy (make-instance
                            'script-policy
                            :decisions
                            (list (make-decision
                                   :kind :record
                                   :payload (%hash "kind" "finding"
                                                   "hypothesis" "h"
                                                   "probe" "p"
                                                   "finding" "f"
                                                   "decision" "d")
                                   :reason "note insight")
                                  (make-decision :kind :finish
                                                 :reason "ok"))))))
      (ok (eq :done (run-kernel kernel)))
      (let ((ledger (world-model-projection (kernel-world-model kernel)
                                            :exploration)))
        (ok (= 1 (length (findings ledger))))
        (ok (equal "h" (finding-hypothesis (first (findings ledger)))))))))

(defclass demoting-policy (script-policy) ())

(defmethod cl-harness-next/src/kernel:handle-intervention
    ((policy demoting-policy) condition)
  (declare (ignore condition))
  :demote-dial)

(deftest demote-intervention-continues-and-is-recorded
  (with-log (log path)
    (let* ((governor (make-instance 'governor
                                    :max-stalled-verify-cycles 1))
           (kernel (make-kernel
                    :environment (make-instance 'fake-environment :log log)
                    :event-log log
                    :governor governor
                    :policy (make-instance
                             'demoting-policy
                             :decisions
                             (list (make-decision :kind :finish
                                                  :reason "after demote"))))))
      (apply-interaction governor (%stall-interaction))
      (multiple-value-bind (status reason) (run-kernel kernel)
        (ok (eq :done status))
        (ok (equal "after demote" reason)))
      (ok (find-if (lambda (event)
                     (and (eq :decision (event-type event))
                          (equal "dial" (gethash "kind"
                                                 (event-payload event)))))
                   (read-events path))))))

(defclass parking-policy (script-policy) ())

(defmethod cl-harness-next/src/kernel:handle-intervention
    ((policy parking-policy) condition)
  (declare (ignore condition))
  :park-mission)

(deftest unknown-restart-choice-halts
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
        (ok (eq :given-up status))
        (ok (search "PARK-MISSION" reason))))))
```

Also extend the test package imports with `#:event-payload` in the
event clause (it currently imports only `#:event-type`).

`next/tests/governor-test.lisp` — extend the governor `:import-from`
with `#:reset-governor-progress`; append:

```lisp
(deftest reset-clears-stalls-but-not-budgets
  (let ((governor (make-instance 'governor)))
    (apply-interaction governor (%interaction "lisp-edit-form" :seq 1
                                              :result (%hash "isError" t)))
    (apply-interaction governor (%interaction "run-tests" :seq 2
                                              :result (%hash "failed" 1)))
    (reset-governor-progress governor)
    (ok (zerop (governor-consecutive-failed-patches governor)))
    (ok (zerop (governor-stalled-verify-cycles governor)))
    (ok (= 2 (governor-action-count governor)))
    (ok (= 1 (governor-patch-count governor)))))
```

Run — red: `decision-payload` / `handle-intervention` /
`reset-governor-progress` unresolved (load failure on the import).

- [ ] **Step 2: Implement the kernel changes**

In `next/src/kernel.lisp`:

1. `defstruct decision` — add a `payload` slot after `subject`:

```lisp
(defstruct (decision (:conc-name decision-))
  kind        ; :act | :consult | :record | :finish | :give-up
  tool        ; for :act — cl-mcp tool name string
  arguments   ; for :act — hash-table or NIL
  oracle      ; for :consult — an oracle instance
  subject     ; for :consult — defaults to the kernel's environment
  payload     ; for :record — hash-table for the :decision event
  reason)     ; human-readable rationale (reason on finish/give-up)
```

2. Exports: add `#:decision-payload` and `#:handle-intervention`.

3. After the `decide` defgeneric, add:

```lisp
(defgeneric handle-intervention (policy condition)
  (:documentation "Choose the restart keyword for a governor
intervention (spec §11). The CONTROL-POLICY default is the strictest
stance — abort the run. The adaptive dial overrides this to demote on
progress stalls.")
  (:method ((policy control-policy) condition)
    (declare (ignore condition))
    :abort-run))
```

4. Replace `%governor-halt-p` with `%governor-gate` (and update the
call in `kernel-step`):

```lisp
(defun %governor-gate (kernel)
  "Run CHECK-GOVERNOR, letting the policy choose the restart via
HANDLE-INTERVENTION. :continue → proceed; :demote-dial → record a dial
event and proceed; anything else halts. True when halted."
  (let ((governor (kernel-governor kernel)))
    (when governor
      (let ((outcome
              (handler-bind ((governor-intervention
                               (lambda (condition)
                                 (invoke-restart
                                  (handle-intervention
                                   (kernel-policy kernel)
                                   condition)))))
                (check-governor governor))))
        (case outcome
          (:continue nil)
          (:demote-dial
           (emit-event (kernel-event-log kernel) :decision
                       (alexandria:plist-hash-table
                        (list "kind" "dial"
                              "text" "demoted one dial level")
                        :test #'equal))
           nil)
          (t
           (setf (kernel-status kernel) :given-up
                 (kernel-reason kernel)
                 (format nil "governor intervention: ~A" outcome))
           t))))))
```

5. Replace `kernel-step` so `:record` decisions emit their payload as
the `:decision` event (instead of the generic step note):

```lisp
(defun kernel-step (kernel)
  "One observe → decide → act → record iteration. Returns the status."
  (%refresh kernel)
  (when (%governor-gate kernel)
    (return-from kernel-step (kernel-status kernel)))
  (let ((decision (decide (kernel-policy kernel) kernel)))
    (if (eq :record (decision-kind decision))
        (emit-event (kernel-event-log kernel) :decision
                    (decision-payload decision))
        (progn
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
                   (kernel-reason kernel) (decision-reason decision)))))))
  (incf (kernel-step-count kernel))
  (%refresh kernel)
  (kernel-status kernel))
```

In `next/src/governor.lisp` — append (and export
`#:reset-governor-progress`):

```lisp
(defun reset-governor-progress (governor)
  "Zero the stall counters — NOT the spent budgets. A dial demotion
grants the new policy a fresh stall allowance; actions and patches
already spent stay spent (spec §6.1)."
  (setf (governor-consecutive-failed-patches governor) 0
        (governor-stalled-verify-cycles governor) 0
        (%patched-since-last-verify governor) nil)
  governor)
```

- [ ] **Step 3: Worker reset, then green**

`pool-kill-worker {"reset": true}` → `(asdf:load-asd ...)` (struct
redefinition) → run-tests. Expected: **182 / 0**.

- [ ] **Step 4: Lint and commit**

```bash
mallet next/src/kernel.lisp next/src/governor.lisp next/tests/kernel-test.lisp next/tests/governor-test.lisp
git add next/src/kernel.lisp next/src/governor.lisp next/tests/kernel-test.lisp next/tests/governor-test.lisp
git commit -m "feat(next): record decisions and policy-chosen governor interventions"
```

---

### Task 2: LLM step-policy base + guided dial

**Files:**
- Create: `next/tests/llm-policies-test.lisp`
- Create: `next/src/llm-policies.lisp`
- Modify: `cl-harness-next.asd` (add test file)

- [ ] **Step 1: Write the failing tests**

Create `next/tests/llm-policies-test.lisp`:

```lisp
;;;; next/tests/llm-policies-test.lisp
;;;;
;;;; Tests for next/src/llm-policies.lisp: the guided and (Task 3)
;;;; self-directed dials over a real environment with a configurable
;;;; canned transport. The agenda is rendered from world-model
;;;; predicates ([DONE]/[OPEN]) — progress from structured state.

(defpackage #:cl-harness-next/tests/llm-policies-test
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
  (:import-from #:cl-harness-next/src/exploration-ledger
                #:findings
                #:finding-hypothesis)
  (:import-from #:cl-harness-next/src/kernel
                #:make-kernel
                #:kernel-world-model
                #:run-kernel)
  (:import-from #:cl-harness-next/src/llm-policies
                #:guided-policy))

(in-package #:cl-harness-next/tests/llm-policies-test)

(defclass dial-transport (mcp-transport)
  ((fixable-p :initarg :fixable-p :initform t :reader dial-fixable-p)
   (kill-resets-p :initarg :kill-resets-p :initform nil
                  :reader dial-kill-resets-p)
   (edit-fails-p :initarg :edit-fails-p :initform nil
                 :reader dial-edit-fails-p)
   (fixed-p :initform nil :accessor dial-fixed-p)
   (kill-count :initform 0 :accessor dial-kill-count)))

(defmethod transport-send-request ((transport dial-transport) body)
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
                    (if (dial-edit-fails-p transport)
                        (concatenate 'string
                                     "{\"isError\":true,\"content\":"
                                     "[{\"type\":\"text\","
                                     "\"text\":\"form not found\"}]}")
                        (progn
                          (when (dial-fixable-p transport)
                            (setf (dial-fixed-p transport) t))
                          "{\"content\":[]}")))
                   ((equal tool "lisp-patch-form")
                    (when (dial-fixable-p transport)
                      (setf (dial-fixed-p transport) t))
                    "{\"content\":[]}")
                   ((equal tool "run-tests")
                    (if (dial-fixed-p transport)
                        "{\"passed\":3,\"failed\":0}"
                        (concatenate 'string
                                     "{\"passed\":2,\"failed\":1,"
                                     "\"failed_tests\":[{\"test_name\":"
                                     "\"t-x\",\"reason\":\"boom\"}]}")))
                   ((equal tool "pool-kill-worker")
                    (incf (dial-kill-count transport))
                    (when (dial-kill-resets-p transport)
                      (setf (dial-fixed-p transport) nil))
                    "{\"content\":[]}")
                   (t "{\"content\":[]}")))))
      (t (error "unexpected method ~S" method)))))

(defun %canned-step-fn (responses &optional prompts-box)
  "Pop RESPONSES per call (last repeats); capture prompts when a box
(a one-cell list) is supplied."
  (lambda (prompt)
    (when prompts-box (push prompt (car prompts-box)))
    (if (rest responses)
        (pop responses)
        (first responses))))

(defparameter *run-tests-json*
  "{\"type\":\"tool_call\",\"tool\":\"run-tests\",\"arguments\":{\"system\":\"s/tests\"}}")

(defparameter *edit-json*
  (concatenate 'string
               "{\"type\":\"tool_call\",\"tool\":\"lisp-edit-form\","
               "\"arguments\":{\"file_path\":\"a.lisp\","
               "\"content\":\"fix\"}}"))

(defparameter *finish-json*
  "{\"type\":\"finish\",\"status\":\"fixed\",\"summary\":\"done\"}")

(defparameter *give-up-json*
  "{\"type\":\"finish\",\"status\":\"give_up\",\"summary\":\"stuck\"}")

(defparameter *finding-json*
  (concatenate 'string
               "{\"type\":\"finding\",\"hypothesis\":\"h\","
               "\"probe\":\"p\",\"finding\":\"f\",\"decision\":\"d\"}"))

(defmacro with-dial-kernel ((kernel &key (policy-class ''guided-policy)
                                         responses prompts-box
                                         transport-var
                                         (transport-args 'nil)
                                         policy-extra-args)
                            &body body)
  (let ((transport (or transport-var (gensym "TRANSPORT"))))
    `(uiop:with-temporary-file (:pathname log-path :type "jsonl")
       (uiop:delete-file-if-exists log-path)
       (let* ((,transport (apply #'make-instance 'dial-transport
                                 ,transport-args))
              (log (open-event-log log-path))
              (environment (make-cl-mcp-environment
                            :client (make-mcp-client ,transport)
                            :condition :runtime-native
                            :event-log log))
              (,kernel (make-kernel
                        :environment environment
                        :event-log log
                        :policy (apply #'make-instance ,policy-class
                                       :system "s" :test-system "s/tests"
                                       :step-fn (%canned-step-fn
                                                 ,responses ,prompts-box)
                                       ,policy-extra-args))))
         (declare (ignorable ,transport))
         ,@body))))

(deftest guided-happy-path-passes-the-clean-gate
  (with-dial-kernel (kernel :responses (list *run-tests-json* *edit-json*
                                             *run-tests-json* *finish-json*)
                            :transport-var transport)
    (multiple-value-bind (status reason) (run-kernel kernel)
      (ok (eq :done status))
      (ok (search "clean" reason)))
    (ok (clean-verified-p
         (world-model-projection (kernel-world-model kernel)
                                 :verification)))
    (ok (= 1 (dial-kill-count transport)))))

(deftest guided-agenda-renders-progress-and-invariants
  (let ((prompts (list nil)))
    (with-dial-kernel (kernel :responses (list *run-tests-json* *edit-json*
                                               *run-tests-json*
                                               *finish-json*)
                              :prompts-box prompts
                              :policy-extra-args
                              (list :invariants
                                    (list "never edit test files")))
      (ok (eq :done (run-kernel kernel)))
      (let* ((chronological (reverse (car prompts)))
             (first-prompt (first chronological))
             (last-prompt (first (last chronological))))
        (ok (search "[OPEN] apply a source patch" first-prompt))
        (ok (search "- never edit test files" first-prompt))
        (ok (search "[DONE] apply a source patch" last-prompt))
        (ok (search "[DONE] make the tests green" last-prompt))))))

(deftest guided-failed-clean-gate-resumes-stepping
  (with-dial-kernel (kernel :responses (list *edit-json* *run-tests-json*
                                             *finish-json* *give-up-json*)
                            :transport-args (list :kill-resets-p t)
                            :transport-var transport)
    (multiple-value-bind (status reason) (run-kernel kernel)
      (ok (eq :given-up status))
      (ok (search "stuck" reason)))
    (ok (= 1 (dial-kill-count transport)))))

(deftest guided-findings-fold-into-the-ledger
  (with-dial-kernel (kernel :responses (list *finding-json* *give-up-json*))
    (ok (eq :given-up (run-kernel kernel)))
    (let ((ledger (world-model-projection (kernel-world-model kernel)
                                          :exploration)))
      (ok (= 1 (length (findings ledger))))
      (ok (equal "h" (finding-hypothesis (first (findings ledger))))))))

(deftest guided-unparseable-action-gives-up
  (with-dial-kernel (kernel :responses (list "certainly! here is my plan"))
    (multiple-value-bind (status reason) (run-kernel kernel)
      (ok (eq :given-up status))
      (ok (search "unparseable" reason)))))
```

Add `"cl-harness-next/tests/llm-policies-test"` to the tests system.
Run — red: load failure (missing package).

- [ ] **Step 2: Create `next/src/llm-policies.lisp`** (base + guided;
Task 3 appends self-directed)

```lisp
;;;; next/src/llm-policies.lisp
;;;;
;;;; The LLM-driven dial levels (spec §6). LLM-STEP-POLICY is the
;;;; shared loop: one constrained-JSON LLM call per step; a
;;;; finish-fixed claim ALWAYS passes through the clean-verification
;;;; gate (the universal final truth, spec §7). GUIDED-POLICY adds the
;;;; harness-held agenda — subgoal labels with world-model predicates
;;;; rendered [DONE]/[OPEN] (progress derived from structured state,
;;;; spec §6 guided dial) — plus invariants. SELF-DIRECTED-POLICY
;;;; (Task 3) strips all scaffolding: the agent owns its plan.

(defpackage #:cl-harness-next/src/llm-policies
  (:use #:cl)
  (:import-from #:cl-harness-next/src/kernel
                #:control-policy
                #:decide
                #:make-decision
                #:kernel-last-verdict
                #:kernel-last-action-error
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
                #:agent-action-status
                #:agent-action-summary
                #:agent-action-hypothesis
                #:agent-action-probe
                #:agent-action-finding
                #:agent-action-decision)
  (:import-from #:cl-harness-next/src/world-model
                #:world-model-projection)
  (:import-from #:cl-harness-next/src/verification-ledger
                #:last-test
                #:test-run-failed
                #:clean-verified-p)
  (:import-from #:cl-harness-next/src/change-ledger
                #:patches)
  (:export #:llm-step-policy
           #:guided-policy
           #:self-directed-policy
           #:policy-system
           #:policy-test-system
           #:policy-agenda
           #:policy-invariants
           #:make-subgoal
           #:subgoal-label
           #:subgoal-predicate
           #:default-fix-agenda
           #:+guided-system-prompt+
           #:+self-directed-system-prompt+))

(in-package #:cl-harness-next/src/llm-policies)

(alexandria:define-constant +action-schema-text+
    (concatenate
     'string
     "Respond with EXACTLY one JSON object and nothing else:"
     (string #\Newline)
     "{\"type\":\"tool_call\",\"tool\":\"...\",\"arguments\":{...},"
     "\"thought\":\"...\"} to act with a tool;"
     (string #\Newline)
     "{\"type\":\"finding\",\"hypothesis\":\"...\",\"probe\":\"...\","
     "\"finding\":\"...\",\"decision\":\"...\"} to record a REPL"
     " insight;"
     (string #\Newline)
     "{\"type\":\"finish\",\"status\":\"fixed\"} when done (the harness"
     " will clean-verify before accepting);"
     (string #\Newline)
     "{\"type\":\"finish\",\"status\":\"give_up\",\"summary\":\"...\"}"
     " when stuck.")
  :test #'equal
  :documentation "Shared action-schema instructions.")

(alexandria:define-constant +guided-system-prompt+
    (concatenate
     'string
     "You work inside a guided harness on a Common Lisp project. Each"
     " turn you see the harness-maintained agenda ([DONE]/[OPEN]"
     " subgoals), invariants you must never violate, and a compressed"
     " state view. Choose the single best next step yourself."
     (string #\Newline) (string #\Newline)
     +action-schema-text+)
  :test #'equal
  :documentation "System prompt for the guided dial; pair with
MAKE-JUDGE-FN to build a :step-fn from a provider.")

(alexandria:define-constant +self-directed-system-prompt+
    (concatenate
     'string
     "You own this Common Lisp run end to end: form your own plan,"
     " probe the runtime, patch source, and verify — the harness only"
     " provides tools, records everything, and clean-verifies your"
     " finish claim. Record important insights as findings."
     (string #\Newline) (string #\Newline)
     +action-schema-text+)
  :test #'equal
  :documentation "System prompt for the self-directed dial.")

(defclass llm-step-policy (control-policy)
  ((step-fn :initarg :step-fn :reader policy-step-fn
            :documentation "Function (prompt string) → raw LLM
response. Build from a provider with MAKE-JUDGE-FN + the dial's
system prompt; tests inject canned functions.")
   (system :initarg :system :reader policy-system)
   (test-system :initarg :test-system :reader policy-test-system)
   (state :initform :stepping :accessor %policy-state)
   (clean-oracle :accessor %clean-oracle))
  (:documentation "Shared LLM-per-step loop for the guided and
self-directed dials, with the mandatory clean gate on finish."))

(defmethod initialize-instance :after ((policy llm-step-policy) &key)
  (setf (%clean-oracle policy)
        (make-instance 'verification-oracle
                       :system (policy-system policy)
                       :test-system (policy-test-system policy)
                       :mode :clean)))

(defgeneric policy-prompt-sections (policy kernel)
  (:documentation "Dial-specific prompt sections rendered above the
context view, or NIL."))

(defun %step-prompt (policy kernel)
  (format nil "~@[~A~%~%~]~A~@[~%~%Last action error: ~A~]"
          (policy-prompt-sections policy kernel)
          (compile-context (kernel-world-model kernel))
          (kernel-last-action-error kernel)))

(defun %give-up (control &rest arguments)
  (make-decision :kind :give-up
                 :reason (apply #'format nil control arguments)))

(defun %llm-step (policy kernel)
  (let* ((response
           (handler-case (funcall (policy-step-fn policy)
                                  (%step-prompt policy kernel))
             (error (condition)
               (return-from %llm-step
                 (%give-up "step call failed: ~A" condition)))))
         (action
           (handler-case (parse-action response)
             (action-parse-error (condition)
               (return-from %llm-step
                 (%give-up "unparseable action: ~A" condition))))))
    (ecase (agent-action-type action)
      (:tool-call
       (make-decision :kind :act
                      :tool (agent-action-tool action)
                      :arguments (agent-action-arguments action)
                      :reason (or (agent-action-thought action)
                                  "agent-chosen step")))
      (:finding
       (make-decision :kind :record
                      :payload (alexandria:plist-hash-table
                                (list "kind" "finding"
                                      "hypothesis"
                                      (agent-action-hypothesis action)
                                      "probe" (agent-action-probe action)
                                      "finding"
                                      (agent-action-finding action)
                                      "decision"
                                      (agent-action-decision action))
                                :test #'equal)
                      :reason "record a finding"))
      (:finish
       (if (eq :fixed (agent-action-status action))
           (progn
             (setf (%policy-state policy) :clean-gate)
             (make-decision :kind :consult
                            :oracle (%clean-oracle policy)
                            :reason "mandatory clean gate on finish"))
           (%give-up "model gave up: ~A"
                     (or (agent-action-summary action)
                         "(no summary)")))))))

(defmethod decide ((policy llm-step-policy) kernel)
  (ecase (%policy-state policy)
    (:stepping (%llm-step policy kernel))
    (:clean-gate
     (let ((verdict (kernel-last-verdict kernel)))
       (if (and verdict (verdict-pass-p verdict))
           (make-decision :kind :finish
                          :reason "clean verification green")
           (progn
             (setf (%policy-state policy) :stepping)
             (%llm-step policy kernel)))))))

;; --- Guided dial ------------------------------------------------------------

(defstruct (subgoal (:conc-name subgoal-))
  label predicate)

(defun default-fix-agenda ()
  "The fix-mission agenda: each subgoal's completion is DERIVED from
the world model, never asserted by the agent."
  (list
   (make-subgoal
    :label "observe the failing baseline"
    :predicate (lambda (world-model)
                 (and (last-test (world-model-projection world-model
                                                         :verification))
                      t)))
   (make-subgoal
    :label "apply a source patch"
    :predicate (lambda (world-model)
                 (plusp (length (patches (world-model-projection
                                          world-model :changes))))))
   (make-subgoal
    :label "make the tests green"
    :predicate (lambda (world-model)
                 (let ((run (last-test (world-model-projection
                                        world-model :verification))))
                   (and run (eql 0 (test-run-failed run))))))
   (make-subgoal
    :label "pass clean verification"
    :predicate (lambda (world-model)
                 (clean-verified-p (world-model-projection
                                    world-model :verification))))))

(defclass guided-policy (llm-step-policy)
  ((agenda :initarg :agenda :initform nil :reader policy-agenda
           :documentation "List of SUBGOALs; defaults to
DEFAULT-FIX-AGENDA.")
   (invariants :initarg :invariants :initform nil
               :reader policy-invariants
               :documentation "Strings rendered as hard constraints."))
  (:documentation "The guided dial (spec §6): the harness holds the
agenda and invariants; the agent chooses each step."))

(defmethod initialize-instance :after ((policy guided-policy) &key)
  (unless (policy-agenda policy)
    (setf (slot-value policy 'agenda) (default-fix-agenda))))

(defmethod policy-prompt-sections ((policy guided-policy) kernel)
  (let ((world-model (kernel-world-model kernel)))
    (format nil "## Agenda~%~{~A~%~}~@[## Invariants~%~{- ~A~%~}~]"
            (mapcar (lambda (subgoal)
                      (format nil "- [~:[OPEN~;DONE~]] ~A"
                              (funcall (subgoal-predicate subgoal)
                                       world-model)
                              (subgoal-label subgoal)))
                    (policy-agenda policy))
            (policy-invariants policy))))
```

- [ ] **Step 3: Green** — expect **187 / 0**.

- [ ] **Step 4: Lint and commit**

```bash
mallet next/src/llm-policies.lisp next/tests/llm-policies-test.lisp
git add next/src/llm-policies.lisp next/tests/llm-policies-test.lisp cl-harness-next.asd
git commit -m "feat(next): guided dial — harness-held agenda, agent-chosen steps"
```

---

### Task 3: Self-directed dial

**Files:**
- Modify: `next/src/llm-policies.lisp`
- Modify: `next/tests/llm-policies-test.lisp`

- [ ] **Step 1: Write the failing tests**

Extend the test package's llm-policies `:import-from` with
`#:self-directed-policy`; append:

```lisp
(deftest self-directed-happy-path
  (with-dial-kernel (kernel :policy-class 'self-directed-policy
                            :responses (list *edit-json* *run-tests-json*
                                             *finish-json*))
    (multiple-value-bind (status reason) (run-kernel kernel)
      (ok (eq :done status))
      (ok (search "clean" reason)))
    (ok (clean-verified-p
         (world-model-projection (kernel-world-model kernel)
                                 :verification)))))

(deftest self-directed-prompt-has-no-scaffolding
  (let ((prompts (list nil)))
    (with-dial-kernel (kernel :policy-class 'self-directed-policy
                              :responses (list *give-up-json*)
                              :prompts-box prompts)
      (ok (eq :given-up (run-kernel kernel)))
      (let ((prompt (first (car prompts))))
        (ok (not (search "## Agenda" prompt)))
        (ok (not (search "## Invariants" prompt)))))))

(deftest self-directed-give-up-passthrough
  (with-dial-kernel (kernel :policy-class 'self-directed-policy
                            :responses (list *give-up-json*))
    (multiple-value-bind (status reason) (run-kernel kernel)
      (ok (eq :given-up status))
      (ok (search "stuck" reason)))))
```

Run — red: `self-directed-policy` unresolved.

- [ ] **Step 2: Implement**

Append to `next/src/llm-policies.lisp`:

```lisp
;; --- Self-directed dial -----------------------------------------------------

(defclass self-directed-policy (llm-step-policy)
  ()
  (:documentation "The self-directed dial (spec §6): the agent owns
plan and loop; the harness provides only resources, oracles, and
recording. The clean gate on finish still applies — it is universal."))

(defmethod policy-prompt-sections ((policy self-directed-policy)
                                   kernel)
  (declare (ignore kernel))
  nil)
```

- [ ] **Step 3: Green** — expect **190 / 0**.

- [ ] **Step 4: Lint and commit**

```bash
mallet next/src/llm-policies.lisp next/tests/llm-policies-test.lisp
git add next/src/llm-policies.lisp next/tests/llm-policies-test.lisp
git commit -m "feat(next): self-directed dial — agent owns the loop"
```

---

### Task 4: Adaptive dial

**Files:**
- Create: `next/tests/adaptive-policy-test.lisp`
- Create: `next/src/adaptive-policy.lisp`
- Modify: `cl-harness-next.asd` (add test file)

- [ ] **Step 1: Write the failing tests**

Create `next/tests/adaptive-policy-test.lisp`:

```lisp
;;;; next/tests/adaptive-policy-test.lisp
;;;;
;;;; Tests for next/src/adaptive-policy.lisp (spec §6.1): demote one
;;;; dial level on progress stalls — same kernel, same world model —
;;;; with the governor's stall counters reset; budgets stay spent.

(defpackage #:cl-harness-next/tests/adaptive-policy-test
  (:use #:cl #:rove)
  (:import-from #:cl-harness-next/src/mcp-client
                #:make-mcp-client)
  (:import-from #:cl-harness-next/src/environment
                #:make-cl-mcp-environment)
  (:import-from #:cl-harness-next/src/event-log
                #:open-event-log
                #:read-events)
  (:import-from #:cl-harness-next/src/event
                #:event-type
                #:event-payload)
  (:import-from #:cl-harness-next/src/world-model
                #:world-model-projection)
  (:import-from #:cl-harness-next/src/verification-ledger
                #:clean-verified-p)
  (:import-from #:cl-harness-next/src/governor
                #:governor
                #:governor-consecutive-failed-patches
                #:progress-stalled
                #:budget-exhausted)
  (:import-from #:cl-harness-next/src/kernel
                #:handle-intervention
                #:make-kernel
                #:kernel-world-model
                #:run-kernel)
  (:import-from #:cl-harness-next/src/llm-policies
                #:self-directed-policy)
  (:import-from #:cl-harness-next/src/scripted-policy
                #:scripted-fix-policy)
  (:import-from #:cl-harness-next/src/adaptive-policy
                #:adaptive-policy
                #:policy-levels
                #:policy-level-index))

(in-package #:cl-harness-next/tests/adaptive-policy-test)

;; The dial-transport and canned JSON live in llm-policies-test;
;; tests here import that package's package-qualified symbols would
;; couple test files, so the transport is duplicated minimally.
(defclass stall-transport (cl-harness-next/src/mcp-client:mcp-transport)
  ((fixed-p :initform nil :accessor stall-fixed-p)))

(defmethod cl-harness-next/src/mcp-client:transport-send-request
    ((transport stall-transport) body)
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
                   ;; lisp-edit-form is broken in this world; only
                   ;; lisp-patch-form fixes.
                   ((equal tool "lisp-edit-form")
                    (concatenate 'string
                                 "{\"isError\":true,\"content\":"
                                 "[{\"type\":\"text\","
                                 "\"text\":\"form not found\"}]}"))
                   ((equal tool "lisp-patch-form")
                    (setf (stall-fixed-p transport) t)
                    "{\"content\":[]}")
                   ((equal tool "run-tests")
                    (if (stall-fixed-p transport)
                        "{\"passed\":3,\"failed\":0}"
                        "{\"passed\":2,\"failed\":1}"))
                   (t "{\"content\":[]}")))))
      (t (error "unexpected method ~S" method)))))

(defparameter *edit-json*
  (concatenate 'string
               "{\"type\":\"tool_call\",\"tool\":\"lisp-edit-form\","
               "\"arguments\":{\"file_path\":\"a.lisp\","
               "\"form_type\":\"defun\",\"form_name\":\"f\","
               "\"operation\":\"replace\",\"content\":\"x\"}}"))

(defparameter *patch-form-json*
  (concatenate 'string
               "{\"type\":\"tool_call\",\"tool\":\"lisp-patch-form\","
               "\"arguments\":{\"file_path\":\"a.lisp\","
               "\"form_name\":\"f\",\"old_text\":\"a\","
               "\"new_text\":\"b\"}}"))

(defun %levels (&rest policies) policies)

(deftest stall-demotes-and-resets-the-governor
  (let* ((governor (make-instance 'governor))
         (adaptive (make-instance
                    'adaptive-policy
                    :levels (%levels :level-a :level-b))))
    (setf (governor-consecutive-failed-patches governor) 3)
    (ok (eq :demote-dial
            (handle-intervention adaptive
                                 (make-condition 'progress-stalled
                                                 :governor governor))))
    (ok (= 1 (policy-level-index adaptive)))
    (ok (zerop (governor-consecutive-failed-patches governor)))))

(deftest stall-at-the-last-level-aborts
  (let ((adaptive (make-instance 'adaptive-policy
                                 :levels (%levels :only))))
    (ok (eq :abort-run
            (handle-intervention adaptive
                                 (make-condition 'progress-stalled))))
    (ok (zerop (policy-level-index adaptive)))))

(deftest budget-exhaustion-always-aborts
  (let ((adaptive (make-instance 'adaptive-policy
                                 :levels (%levels :level-a :level-b))))
    (ok (eq :abort-run
            (handle-intervention adaptive
                                 (make-condition 'budget-exhausted))))
    (ok (zerop (policy-level-index adaptive)))))

(deftest stalled-self-directed-demotes-to-scripted-and-finishes
  (uiop:with-temporary-file (:pathname log-path :type "jsonl")
    (uiop:delete-file-if-exists log-path)
    (let* ((log (open-event-log log-path))
           (environment (make-cl-mcp-environment
                         :client (make-mcp-client
                                  (make-instance 'stall-transport))
                         :condition :runtime-native
                         :event-log log))
           (self-directed (make-instance
                           'self-directed-policy
                           :system "s" :test-system "s/tests"
                           :step-fn (lambda (prompt)
                                      (declare (ignore prompt))
                                      *edit-json*)))
           (scripted (make-instance
                      'scripted-fix-policy
                      :system "s" :test-system "s/tests"
                      :diagnose-fn (lambda (view)
                                     (declare (ignore view))
                                     *patch-form-json*)))
           (kernel (make-kernel
                    :environment environment
                    :event-log log
                    :governor (make-instance
                               'governor
                               :max-consecutive-failed-patches 2)
                    :policy (make-instance
                             'adaptive-policy
                             :levels (list self-directed scripted)))))
      (multiple-value-bind (status reason) (run-kernel kernel)
        (ok (eq :done status))
        (ok (search "clean" reason)))
      (ok (clean-verified-p
           (world-model-projection (kernel-world-model kernel)
                                   :verification)))
      (ok (find-if (lambda (event)
                     (and (eq :decision (event-type event))
                          (equal "dial" (gethash "kind"
                                                 (event-payload event)))))
                   (read-events log-path))))))
```

Add `"cl-harness-next/tests/adaptive-policy-test"` to the tests
system. Run — red: load failure (missing package).

- [ ] **Step 2: Create `next/src/adaptive-policy.lisp`**

```lisp
;;;; next/src/adaptive-policy.lisp
;;;;
;;;; The adaptive dial (spec §6.1): an ordered list of policies,
;;;; highest autonomy first. DECIDE delegates to the current level; a
;;;; PROGRESS-STALLED intervention demotes one level — same kernel,
;;;; same world model, fresh stall allowance (the governor's stall
;;;; counters reset; spent budgets stay spent, so BUDGET-EXHAUSTED
;;;; still aborts).

(defpackage #:cl-harness-next/src/adaptive-policy
  (:use #:cl)
  (:import-from #:cl-harness-next/src/kernel
                #:control-policy
                #:decide
                #:handle-intervention)
  (:import-from #:cl-harness-next/src/governor
                #:progress-stalled
                #:budget-exhausted
                #:intervention-governor
                #:reset-governor-progress)
  (:export #:adaptive-policy
           #:policy-levels
           #:policy-level-index))

(in-package #:cl-harness-next/src/adaptive-policy)

(defclass adaptive-policy (control-policy)
  ((levels :initarg :levels :reader policy-levels
           :documentation "Policies ordered highest autonomy first,
e.g. (self-directed guided scripted).")
   (level-index :initform 0 :accessor policy-level-index))
  (:documentation "Spec §6.1 adaptive dial: capability-adaptive
demotion driven by governor stall interventions."))

(defun %current-level (policy)
  (elt (policy-levels policy) (policy-level-index policy)))

(defmethod decide ((policy adaptive-policy) kernel)
  (decide (%current-level policy) kernel))

(defmethod handle-intervention ((policy adaptive-policy) condition)
  (typecase condition
    (budget-exhausted :abort-run)
    (progress-stalled
     (if (< (1+ (policy-level-index policy))
            (length (policy-levels policy)))
         (progn
           (incf (policy-level-index policy))
           (alexandria:when-let
               ((governor (intervention-governor condition)))
             (reset-governor-progress governor))
           :demote-dial)
         :abort-run))
    (t :abort-run)))
```

- [ ] **Step 3: Green** — expect **194 / 0**.

- [ ] **Step 4: Lint and commit**

```bash
mallet next/src/adaptive-policy.lisp next/tests/adaptive-policy-test.lisp
git add next/src/adaptive-policy.lisp next/tests/adaptive-policy-test.lisp cl-harness-next.asd
git commit -m "feat(next): adaptive dial — demote on stall, same world model"
```

---

### Task 5: Facade, acceptance, docs

**Files:**
- Modify: `next/src/main.lisp`
- Modify: `next/tests/main-test.lisp`
- Modify: `README.md`

- [ ] **Step 1: Write the failing acceptance test**

Append to `next/tests/main-test.lisp` (facade symbols only):

```lisp
(defclass %sp6-stall-transport (cl-harness-next:mcp-transport)
  ((fixed-p :initform nil :accessor %sp6-fixed-p)))

(defmethod cl-harness-next:transport-send-request
    ((transport %sp6-stall-transport) body)
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
                    "{\"isError\":true,\"content\":[]}")
                   ((equal tool "lisp-patch-form")
                    (setf (%sp6-fixed-p transport) t)
                    "{\"content\":[]}")
                   ((equal tool "run-tests")
                    (if (%sp6-fixed-p transport)
                        "{\"passed\":3,\"failed\":0}"
                        "{\"passed\":2,\"failed\":1}"))
                   (t "{\"content\":[]}")))))
      (t (error "unexpected method ~S" method)))))

(deftest sp6-adaptive-dial-acceptance
  ;; SP6 capstone: a self-directed level stalls on failing patches,
  ;; the adaptive dial demotes to scripted (same world model), which
  ;; fixes and clean-verifies — entirely through the facade.
  (uiop:with-temporary-file (:pathname log-path :type "jsonl")
    (uiop:delete-file-if-exists log-path)
    (let* ((edit-json
             (concatenate 'string
                          "{\"type\":\"tool_call\","
                          "\"tool\":\"lisp-edit-form\","
                          "\"arguments\":{\"file_path\":\"a.lisp\","
                          "\"content\":\"x\"}}"))
           (patch-json
             (concatenate 'string
                          "{\"type\":\"tool_call\","
                          "\"tool\":\"lisp-patch-form\","
                          "\"arguments\":{\"file_path\":\"a.lisp\","
                          "\"old_text\":\"a\",\"new_text\":\"b\"}}"))
           (log (cl-harness-next:open-event-log log-path))
           (environment (cl-harness-next:make-cl-mcp-environment
                         :client (cl-harness-next:make-mcp-client
                                  (make-instance '%sp6-stall-transport))
                         :condition :runtime-native
                         :event-log log))
           (kernel (cl-harness-next:make-kernel
                    :environment environment
                    :event-log log
                    :governor (make-instance
                               'cl-harness-next:governor
                               :max-consecutive-failed-patches 2)
                    :policy (make-instance
                             'cl-harness-next:adaptive-policy
                             :levels
                             (list (make-instance
                                    'cl-harness-next:self-directed-policy
                                    :system "s" :test-system "s/tests"
                                    :step-fn (lambda (prompt)
                                               (declare (ignore prompt))
                                               edit-json))
                                   (make-instance
                                    'cl-harness-next:scripted-fix-policy
                                    :system "s" :test-system "s/tests"
                                    :diagnose-fn
                                    (lambda (view)
                                      (declare (ignore view))
                                      patch-json)))))))
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

Add `:import-from` clauses (after the scripted-policy one), preserving
all existing clauses; extend the kernel clause with
`#:decision-payload #:handle-intervention` and the governor clause
with `#:reset-governor-progress`:

```lisp
  (:import-from #:cl-harness-next/src/llm-policies
                #:llm-step-policy
                #:guided-policy
                #:self-directed-policy
                #:policy-agenda
                #:policy-invariants
                #:make-subgoal
                #:subgoal-label
                #:subgoal-predicate
                #:default-fix-agenda
                #:+guided-system-prompt+
                #:+self-directed-system-prompt+)
  (:import-from #:cl-harness-next/src/adaptive-policy
                #:adaptive-policy
                #:policy-levels
                #:policy-level-index)
```

NOTE: `policy-system`/`policy-test-system` are ALREADY imported from
scripted-policy in the facade — llm-policies defines its own readers
with those names in a different package; do NOT import them again
from llm-policies (symbol clash). Leave the facade's existing
scripted-policy clause as-is and exclude those two from the
llm-policies clause (the list above already excludes them).

Add to `:export` (groups `;; llm-policies`, `;; adaptive`):

```lisp
           ;; llm-policies
           #:llm-step-policy
           #:guided-policy
           #:self-directed-policy
           #:policy-agenda
           #:policy-invariants
           #:make-subgoal
           #:subgoal-label
           #:subgoal-predicate
           #:default-fix-agenda
           #:+guided-system-prompt+
           #:+self-directed-system-prompt+
           ;; adaptive
           #:adaptive-policy
           #:policy-levels
           #:policy-level-index
           ;; kernel/governor SP6 additions
           #:decision-payload
           #:handle-intervention
           #:reset-governor-progress
```

- [ ] **Step 4: Green** — expect **195 / 0**.

- [ ] **Step 5: Force-compile + columns** — no warnings from next/
sources; awk column check clean.

- [ ] **Step 6: Document** — extend the README next/ subsection: after
"...the scripted fix policy — the first dial level" insert "; SP6
completes the dial (guided agenda + self-directed + adaptive demotion
on stalls)" before ". It does not affect".

- [ ] **Step 7: Lint and commit**

```bash
mallet next/src/*.lisp next/tests/*.lisp
git add next/src/main.lisp next/tests/main-test.lisp README.md
git commit -m "feat(next): facade exports + SP6 adaptive-dial acceptance"
```

---

## Verification checklist (whole sub-project)

- Clean image: fresh worker → load-asd → `run-tests
  cl-harness-next/tests` 195/0.
- Legacy untouched: `git status --short src/ tests/` empty; `run-tests
  cl-harness/tests` 498/0.
- `mallet next/src/*.lisp next/tests/*.lisp` clean; no lines >100 cols.

## Deferred (SP7+ — do NOT build now)

- Dial PROMOTION (re-escalation after sustained progress) — needs
  positive-progress metrics; revisit with bench data (L5).
- Pack-driven dial construction (`:dial-rules` already exists as pack
  data since SP1; an `adaptive-policy-from-pack` constructor belongs
  to the mission layer, SP7).
- Mission-layer restart handlers for :replan/:park-mission/:ask-human
  (kernel treats them as halt today) — SP7.
- LLM-asserted agenda progress / agenda editing — agenda predicates
  stay world-model-derived until there's evidence prompting needs it.
- Repair prompts on unparseable actions (still give-up; bench data
  first, L5).
- Oracle advisory-vs-blocking wiring per dial beyond the universal
  clean gate (review oracles consulted by guided policies) — wire when
  a consumer needs it.
