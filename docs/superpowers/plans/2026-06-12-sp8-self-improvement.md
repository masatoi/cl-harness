# SP8: L5 Self-Improvement Loop Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the L5 self-improvement loop (spec §10) v1: paired champion/challenger trials with a sign-test judge, a deterministic transcript miner that replays event logs into the SP3 world model, an LLM variant proposer constrained to ONE artifact mutation per cycle, and a promoter that auto-promotes prompt/budget wins (with an audit event) while code-kind proposals become human-approval dossiers — the decided authority boundary, enforced in code.

**Architecture:** Four modules. `bench.lisp`: `trial` records, `run-paired-trials` (fixture execution is an injected `(pack index) → trial` function — real fixture wiring needs full LLM/env setups and arrives with usage), `judge-trials` (paired sign test: net challenger wins ≥ threshold promotes; cost reported, sequential early stopping deferred). `miner.lisp`: `mine-transcript` replays a log into the standard world model + a governor and reads the ledgers (failed patches, tool errors, stalls, dial demotions, clean success) — deterministic, no LLM; `rank-failure-modes` aggregates. `variant.lisp`: fail-closed JSON parsing of LLM proposals (targets stay STRINGS — matched against entry-id names, never interned), `pack-form` reconstruction with a patch-version bump, `apply-variant` changing EXACTLY one entry (the one-artifact safety rule structurally enforced), `write-pack-form`. `improver.lisp`: `improve-once` orchestrates mine → propose → materialize challenger → paired trials → judge → promote (`:decision` audit event with both fingerprints) / reject / dossier (code-kind: NO trials, human approval required per spec §10.3). Spec: §10.1–10.4, 原則3/原則4.

**Tech Stack:** SBCL, rove, alexandria, yason. No new dependencies.

**Conventions** (same as SP1–SP7, incl. `elt`-not-`first`, macro-arg quoting): 2-space indent, ≤100 cols, blank lines, docstrings, no `:local-nicknames`, `%`-internals unexported, no runtime interning of LLM-supplied names. cl-mcp tools; `mallet` before commits; tests via `run-tests` `{"system": "cl-harness-next/tests"}`; worker-restart recovery `(asdf:load-asd "/home/wiz/.roswell/local-projects/cl-harness/cl-harness-next.asd")`. Unused test imports flagged by mallet get removed (note it).

---

## File Structure

```text
next/src/bench.lisp     NEW  trial records, paired runner, sign-test judge
next/src/miner.lisp     NEW  transcript mining via world-model replay + ranking
next/src/variant.lisp   NEW  proposal parse (fail-closed), pack-form, apply, write
next/src/improver.lisp  NEW  improve-once driver, authority boundary, audit, dossier
next/src/main.lisp      MOD  facade re-exports
next/tests/bench-test.lisp    NEW (+4)
next/tests/miner-test.lisp    NEW (+3)
next/tests/variant-test.lisp  NEW (+6)
next/tests/improver-test.lisp NEW (+4)
next/tests/main-test.lisp     MOD (+1 acceptance)
cl-harness-next.asd     MOD  + 4 test files
README.md               MOD  one sentence
```

Test-count checkpoints: 210 → T1 214 → T2 217 → T3 223 → T4 227 → T5 228.

---

### Task 1: Bench (paired trials + sign-test judge)

**Files:**
- Create: `next/tests/bench-test.lisp`, `next/src/bench.lisp`
- Modify: `cl-harness-next.asd` (add test file)

- [ ] **Step 1: Write the failing tests**

Create `next/tests/bench-test.lisp`:

```lisp
;;;; next/tests/bench-test.lisp
;;;;
;;;; Tests for next/src/bench.lisp (spec §10.2 stages 1+4): paired
;;;; champion/challenger trials and the v1 sign-test judge.

(defpackage #:cl-harness-next/tests/bench-test
  (:use #:cl #:rove)
  (:import-from #:cl-harness-next/src/bench
                #:trial
                #:make-trial
                #:trial-index
                #:trial-pack-fingerprint
                #:trial-success-p
                #:trial-actions
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
```

Add `"cl-harness-next/tests/bench-test"` to the tests system. Run —
red: load failure (missing package).

- [ ] **Step 2: Create `next/src/bench.lisp`**

```lisp
;;;; next/src/bench.lisp
;;;;
;;;; Bench scheduling and statistical judgment for the L5 loop
;;;; (spec §10.2 stages 1 and 4) — v1: paired design (the same trial
;;;; index runs both packs), and a paired sign test (net challenger
;;;; wins). Fixture execution is an injected function — real fixtures
;;;; need a full LLM + environment setup, which callers own.
;;;; Sequential early stopping is deferred (see the plan's Deferred).

(defpackage #:cl-harness-next/src/bench
  (:use #:cl)
  (:export #:trial
           #:make-trial
           #:trial-index
           #:trial-pack-fingerprint
           #:trial-success-p
           #:trial-actions
           #:trial-reason
           #:run-paired-trials
           #:judge-trials))

(in-package #:cl-harness-next/src/bench)

(defstruct (trial (:conc-name trial-))
  index pack-fingerprint success-p actions reason)

(defun run-paired-trials (trial-fn champion challenger n)
  "Run N paired trials: index i runs CHAMPION then CHALLENGER under
the same fixture conditions. TRIAL-FN is (pack index) → TRIAL; the
pack arguments are passed through opaquely (fingerprint strings or
pack objects — TRIAL-FN decides). Returns
(values champion-trials challenger-trials), index order."
  (loop for index below n
        collect (funcall trial-fn champion index) into champion-trials
        collect (funcall trial-fn challenger index) into challenger-trials
        finally (return (values champion-trials challenger-trials))))

(defun %mean-actions (trials)
  (if trials
      (/ (reduce #'+ trials :key (lambda (trial)
                                   (or (trial-actions trial) 0)))
         (length trials))
      0))

(defun judge-trials (champion-trials challenger-trials
                     &key (min-net-wins 2))
  "Paired sign test (v1, spec §10.2 stage 4): a win is an index where
the challenger succeeded and the champion failed; a loss the reverse.
Net wins ≥ MIN-NET-WINS → :promote; net < 0 → :reject; otherwise
:inconclusive (run more trials). Returns (values verdict summary);
the summary also reports mean actions (cost is informative, not yet
decisive)."
  (let ((wins 0)
        (losses 0))
    (loop for champion-trial in champion-trials
          for challenger-trial in challenger-trials
          do (cond ((and (trial-success-p challenger-trial)
                         (not (trial-success-p champion-trial)))
                    (incf wins))
                   ((and (trial-success-p champion-trial)
                         (not (trial-success-p challenger-trial)))
                    (incf losses))))
    (let* ((net (- wins losses))
           (verdict (cond ((>= net min-net-wins) :promote)
                          ((< net 0) :reject)
                          (t :inconclusive)))
           (summary (format nil
                            "wins ~A losses ~A net ~A; mean actions ~,1F → ~,1F"
                            wins losses net
                            (%mean-actions champion-trials)
                            (%mean-actions challenger-trials))))
      (values verdict summary))))
```

- [ ] **Step 3: Green** — expect **214 / 0**.

- [ ] **Step 4: Lint and commit**

```bash
mallet next/src/bench.lisp next/tests/bench-test.lisp
git add next/src/bench.lisp next/tests/bench-test.lisp cl-harness-next.asd
git commit -m "feat(next): paired bench trials with a sign-test judge"
```

---

### Task 2: Transcript miner

**Files:**
- Create: `next/tests/miner-test.lisp`, `next/src/miner.lisp`
- Modify: `cl-harness-next.asd` (add test file)

- [ ] **Step 1: Write the failing tests**

Create `next/tests/miner-test.lisp`:

```lisp
;;;; next/tests/miner-test.lisp
;;;;
;;;; Tests for next/src/miner.lisp (spec §10.2 stage 2): deterministic
;;;; failure-mode mining by replaying event logs into the world model.

(defpackage #:cl-harness-next/tests/miner-test
  (:use #:cl #:rove)
  (:import-from #:cl-harness-next/src/event-log
                #:open-event-log
                #:emit-event)
  (:import-from #:cl-harness-next/src/miner
                #:mine-transcript
                #:failure-report-total-actions
                #:failure-report-failed-patches
                #:failure-report-tool-errors
                #:failure-report-dial-demotions
                #:failure-report-clean-verified-p
                #:rank-failure-modes))

(in-package #:cl-harness-next/tests/miner-test)

(defun %hash (&rest plist)
  (alexandria:plist-hash-table plist :test #'equal))

(defun %emit-interaction (log tool &key result error arguments)
  (emit-event log :action (%hash "tool" tool
                                 "arguments" (or arguments (%hash))))
  (if error
      (emit-event log :observation (%hash "tool" tool "error" error))
      (emit-event log :observation
                  (%hash "tool" tool "result" (or result (%hash))))))

(defmacro with-mined-log ((report) &body emissions)
  `(uiop:with-temporary-file (:pathname path :type "jsonl")
     (uiop:delete-file-if-exists path)
     (let ((log (open-event-log path)))
       ,@emissions
       (let ((,report (mine-transcript path)))
         ,report))))

(deftest mine-counts-failure-modes
  (let ((report
          (with-mined-log (report)
            ;; A failed patch (tool-level isError).
            (%emit-interaction log "lisp-edit-form"
                               :arguments (%hash "file_path" "a.lisp")
                               :result (%hash "isError" t))
            ;; A transport-level tool error.
            (%emit-interaction log "repl-eval" :error "boom")
            ;; A dial demotion.
            (emit-event log :decision (%hash "kind" "dial"
                                             "text" "demoted"))
            ;; A red run, never fixed.
            (%emit-interaction log "run-tests"
                               :result (%hash "passed" 1 "failed" 1)))))
    (ok (= 3 (failure-report-total-actions report)))
    (ok (= 1 (failure-report-failed-patches report)))
    ;; Tool errors count BOTH transport errors and isError results, so
    ;; the failed patch contributes here too (intentional overlap).
    (ok (= 2 (failure-report-tool-errors report)))
    (ok (= 1 (failure-report-dial-demotions report)))
    (ok (not (failure-report-clean-verified-p report)))))

(deftest mine-recognizes-clean-success
  (let ((report
          (with-mined-log (report)
            (%emit-interaction log "pool-kill-worker")
            (%emit-interaction log "load-system")
            (%emit-interaction log "run-tests"
                               :result (%hash "passed" 3 "failed" 0)))))
    (ok (failure-report-clean-verified-p report))
    (ok (zerop (failure-report-failed-patches report)))))

(deftest rank-aggregates-and-orders
  (let* ((red (with-mined-log (report)
                (%emit-interaction log "lisp-edit-form"
                                   :result (%hash "isError" t))
                (%emit-interaction log "lisp-patch-form"
                                   :result (%hash "isError" t))
                (%emit-interaction log "repl-eval" :error "boom")))
         (modes (rank-failure-modes (list red red))))
    ;; 4 failed patches > 2 tool errors... but failed patches ALSO
    ;; carry the isError observation, counting as tool errors too —
    ;; ranked totals: tool-errors 6, failed-patches 4.
    (ok (equal :tool-errors (car (first modes))))
    (ok (= 6 (cdr (first modes))))
    (ok (equal :failed-patches (car (second modes))))
    (ok (= 4 (cdr (second modes))))
    ;; Zero-count modes are omitted.
    (ok (null (assoc :dial-demotions modes)))))
```

Add `"cl-harness-next/tests/miner-test"` to the tests system. Run —
red: load failure (missing package). NOTE on the intentional overlap:
the miner's tool-error scan counts observations carrying an "error"
key OR an isError result (both are tool failures), so a failed patch
contributes to BOTH failed-patches (ledger) and tool-errors (scan).
Third test math: per log, 2 isError patches + 1 transport error = 3
tool-errors and 2 failed patches; doubled across two reports →
tool-errors 6, failed-patches 4.

- [ ] **Step 2: Create `next/src/miner.lisp`**

```lisp
;;;; next/src/miner.lisp
;;;;
;;;; Transcript miner (spec §10.2 stage 2): replay an event log into
;;;; the standard world model plus a governor and read the ledgers —
;;;; deterministic failure-mode extraction, no LLM. The ranked output
;;;; is the machine version of docs/improvement-backlog.md.

(defpackage #:cl-harness-next/src/miner
  (:use #:cl)
  (:import-from #:cl-harness-next/src/event
                #:event-type
                #:event-payload)
  (:import-from #:cl-harness-next/src/event-log
                #:read-events)
  (:import-from #:cl-harness-next/src/world-model
                #:make-standard-world-model
                #:build-world-model
                #:world-model-projection)
  (:import-from #:cl-harness-next/src/change-ledger
                #:patches
                #:patch-entry-ok-p)
  (:import-from #:cl-harness-next/src/verification-ledger
                #:clean-verified-p)
  (:import-from #:cl-harness-next/src/governor
                #:governor
                #:governor-action-count
                #:governor-stalled-verify-cycles)
  (:export #:failure-report
           #:mine-transcript
           #:failure-report-log-path
           #:failure-report-total-actions
           #:failure-report-failed-patches
           #:failure-report-tool-errors
           #:failure-report-stalled-cycles
           #:failure-report-dial-demotions
           #:failure-report-clean-verified-p
           #:rank-failure-modes))

(in-package #:cl-harness-next/src/miner)

(defstruct (failure-report (:conc-name failure-report-))
  log-path total-actions failed-patches tool-errors
  stalled-cycles dial-demotions clean-verified-p)

(defun %tool-error-event-p (event)
  "An :observation whose tool failed — transport error key OR an
isError result (both are tool failures)."
  (and (eq :observation (event-type event))
       (let ((payload (event-payload event)))
         (and (hash-table-p payload)
              (or (nth-value 1 (gethash "error" payload))
                  (let ((result (gethash "result" payload)))
                    (and (hash-table-p result)
                         (multiple-value-bind (value present-p)
                             (gethash "isError" result)
                           (and present-p value t)))))))))

(defun %dial-event-p (event)
  (and (eq :decision (event-type event))
       (let ((payload (event-payload event)))
         (and (hash-table-p payload)
              (equal "dial" (gethash "kind" payload))))))

(defun mine-transcript (log-path)
  "Replay LOG-PATH into the standard world model + a fresh governor
and distill a FAILURE-REPORT (deterministic; spec §10.2 stage 2)."
  (let* ((governor (make-instance 'governor))
         (world-model (build-world-model
                       log-path
                       :world-model (make-standard-world-model
                                     :extra-projections
                                     (list :governor governor))))
         (changes (world-model-projection world-model :changes))
         (verification (world-model-projection world-model
                                               :verification))
         (events (read-events log-path)))
    (make-failure-report
     :log-path log-path
     :total-actions (governor-action-count governor)
     :failed-patches (count-if-not #'patch-entry-ok-p
                                   (patches changes))
     :tool-errors (count-if #'%tool-error-event-p events)
     :stalled-cycles (governor-stalled-verify-cycles governor)
     :dial-demotions (count-if #'%dial-event-p events)
     :clean-verified-p (clean-verified-p verification))))

(defun rank-failure-modes (reports)
  "Aggregate failure counts across REPORTS, descending; zero modes
omitted. Returns an alist of (mode-keyword . total)."
  (flet ((total (key) (reduce #'+ reports :key key)))
    (let ((totals
            (list (cons :failed-patches
                        (total #'failure-report-failed-patches))
                  (cons :tool-errors
                        (total #'failure-report-tool-errors))
                  (cons :stalled-verify-cycles
                        (total #'failure-report-stalled-cycles))
                  (cons :dial-demotions
                        (total #'failure-report-dial-demotions)))))
      (sort (remove 0 totals :key #'cdr) #'> :key #'cdr))))
```

- [ ] **Step 3: Green** — expect **217 / 0**.

- [ ] **Step 4: Lint and commit**

```bash
mallet next/src/miner.lisp next/tests/miner-test.lisp
git add next/src/miner.lisp next/tests/miner-test.lisp cl-harness-next.asd
git commit -m "feat(next): deterministic transcript miner over world-model replays"
```

---

### Task 3: Variants (propose, parse fail-closed, apply one mutation)

**Files:**
- Create: `next/tests/variant-test.lisp`, `next/src/variant.lisp`
- Modify: `cl-harness-next.asd` (add test file)

- [ ] **Step 1: Write the failing tests**

Create `next/tests/variant-test.lisp`:

```lisp
;;;; next/tests/variant-test.lisp
;;;;
;;;; Tests for next/src/variant.lisp (spec §10.2 stage 3, §10.4
;;;; safety): fail-closed proposal parsing (LLM-supplied names are
;;;; never interned), exactly-one-mutation application, pack-form
;;;; reconstruction with a version bump.

(defpackage #:cl-harness-next/tests/variant-test
  (:use #:cl #:rove)
  (:import-from #:cl-harness-next/src/policy-pack
                #:load-policy-pack
                #:pack-name
                #:pack-version
                #:pack-prompt
                #:pack-budget
                #:pack-fingerprint)
  (:import-from #:cl-harness-next/src/variant
                #:variant
                #:variant-kind
                #:variant-target
                #:variant-value
                #:variant-hypothesis
                #:parse-variant
                #:pack-form
                #:apply-variant
                #:write-pack-form
                #:propose-variant))

(in-package #:cl-harness-next/tests/variant-test)

(defparameter *pack-text*
  "(:name \"p\"
    :version \"1.2.3\"
    :prompts ((:id :agent-system :text \"You are the agent.\"))
    :budgets ((:id :max-actions :value 20)
              (:id :max-patches :value 5)))")

(defmacro with-pack ((pack) &body body)
  `(uiop:with-temporary-file (:pathname pack-path :type "sexp")
     (with-open-file (out pack-path :direction :output
                                    :if-exists :supersede
                                    :external-format :utf-8)
       (write-string *pack-text* out))
     (let ((,pack (load-policy-pack pack-path)))
       ,@body)))

(deftest parse-variant-accepts-the-three-kinds
  (let ((budget (parse-variant
                 (concatenate 'string
                              "{\"kind\":\"budget\",\"target\":\"max-actions\","
                              "\"value\":40,\"hypothesis\":\"more room\"}"))))
    (ok (eq :budget (variant-kind budget)))
    (ok (equal "max-actions" (variant-target budget)))
    (ok (= 40 (variant-value budget)))
    (ok (equal "more room" (variant-hypothesis budget))))
  (ok (eq :prompt (variant-kind (parse-variant
                                 (concatenate 'string
                                              "{\"kind\":\"prompt\","
                                              "\"target\":\"agent-system\","
                                              "\"value\":\"Be terse.\","
                                              "\"hypothesis\":\"h\"}")))))
  (ok (eq :code (variant-kind (parse-variant
                               "{\"kind\":\"code\",\"hypothesis\":\"h\"}")))))

(deftest parse-variant-fails-closed
  (dolist (bad '("not json" "{\"kind\":\"magic\",\"hypothesis\":\"h\"}"
                 "{\"kind\":\"budget\",\"target\":\"x\"}"))
    (ok (null (parse-variant bad))
        (format nil "~S should not parse" bad))))

(deftest pack-form-roundtrips-with-a-version-bump
  (with-pack (pack)
    (uiop:with-temporary-file (:pathname new-path :type "sexp")
      (write-pack-form (pack-form pack) new-path)
      (let ((reloaded (load-policy-pack new-path)))
        (ok (equal "p" (pack-name reloaded)))
        (ok (equal "1.2.4" (pack-version reloaded)))
        (ok (equal "You are the agent." (pack-prompt reloaded
                                                     :agent-system)))
        (ok (= 20 (pack-budget reloaded :max-actions)))
        (ok (not (equal (pack-fingerprint pack)
                        (pack-fingerprint reloaded))))))))

(deftest apply-variant-changes-exactly-one-entry
  (with-pack (pack)
    (uiop:with-temporary-file (:pathname new-path :type "sexp")
      (write-pack-form
       (apply-variant pack (parse-variant
                            (concatenate 'string
                                         "{\"kind\":\"budget\","
                                         "\"target\":\"max-actions\","
                                         "\"value\":40,"
                                         "\"hypothesis\":\"h\"}")))
       new-path)
      (let ((challenger (load-policy-pack new-path)))
        (ok (= 40 (pack-budget challenger :max-actions)))
        (ok (= 5 (pack-budget challenger :max-patches)))
        (ok (equal "You are the agent."
                   (pack-prompt challenger :agent-system)))))))

(deftest apply-variant-rejects-unknown-targets
  (with-pack (pack)
    (ok (handler-case
            (progn (apply-variant pack
                                  (parse-variant
                                   (concatenate 'string
                                                "{\"kind\":\"budget\","
                                                "\"target\":\"nope\","
                                                "\"value\":1,"
                                                "\"hypothesis\":\"h\"}")))
                   nil)
          (error () t)))))

(deftest propose-variant-builds-the-prompt-and-parses
  (with-pack (pack)
    (let* ((captured (list nil))
           (variant (propose-variant
                     pack
                     '((:tool-errors . 6) (:failed-patches . 4))
                     (lambda (prompt)
                       (push prompt (car captured))
                       (concatenate 'string
                                    "{\"kind\":\"budget\","
                                    "\"target\":\"max-patches\","
                                    "\"value\":8,\"hypothesis\":\"h\"}")))))
      (ok (eq :budget (variant-kind variant)))
      (let ((prompt (first (car captured))))
        (ok (search "tool-errors" prompt))
        (ok (search "max-patches" prompt))
        (ok (search "exactly ONE" prompt))))))
```

Add `"cl-harness-next/tests/variant-test"` to the tests system. Run —
red: load failure (missing package).

- [ ] **Step 2: Create `next/src/variant.lisp`**

```lisp
;;;; next/src/variant.lisp
;;;;
;;;; Artifact variants for the L5 loop (spec §10.2 stage 3): an LLM
;;;; proposes ONE mutation of the policy pack (the §10.4 safety rule —
;;;; one artifact per cycle — is structural here: APPLY-VARIANT can
;;;; only change a single entry). Parsing fails closed; LLM-supplied
;;;; target names stay STRINGS matched against entry-id names — they
;;;; are never interned.

(defpackage #:cl-harness-next/src/variant
  (:use #:cl)
  (:import-from #:cl-harness-next/src/json
                #:parse-json)
  (:import-from #:cl-harness-next/src/policy-pack
                #:pack-name
                #:pack-version
                #:pack-prompts
                #:pack-budgets
                #:pack-oracle-profiles
                #:pack-dial-rules
                #:pack-tool-policies
                #:parse-semver)
  (:export #:variant
           #:variant-kind
           #:variant-target
           #:variant-value
           #:variant-hypothesis
           #:parse-variant
           #:pack-form
           #:apply-variant
           #:write-pack-form
           #:propose-variant))

(in-package #:cl-harness-next/src/variant)

(defstruct (variant (:conc-name variant-))
  kind        ; :prompt | :budget | :code
  target      ; entry-id NAME as a string (never interned)
  value       ; new :text (prompt) or :value (budget)
  hypothesis) ; predicted effect (recorded with the proposal)

(defun %kind-keyword (string)
  (cond ((equal string "prompt") :prompt)
        ((equal string "budget") :budget)
        ((equal string "code") :code)
        (t nil)))

(defun parse-variant (text)
  "Parse an LLM variant proposal. Returns a VARIANT or NIL — fail
closed: bad JSON, unknown kinds, or missing fields yield NIL.
:code variants need only a hypothesis (they become human dossiers);
:prompt/:budget need target, value, and hypothesis."
  (let ((parsed (handler-case (parse-json text)
                  (error () nil))))
    (when (hash-table-p parsed)
      (let ((kind (%kind-keyword (gethash "kind" parsed)))
            (target (gethash "target" parsed))
            (value (gethash "value" parsed))
            (hypothesis (gethash "hypothesis" parsed)))
        (cond
          ((null kind) nil)
          ((not (stringp hypothesis)) nil)
          ((eq kind :code)
           (make-variant :kind :code :hypothesis hypothesis
                         :target (and (stringp target) target)
                         :value value))
          ((and (stringp target) value)
           (make-variant :kind kind :target target :value value
                         :hypothesis hypothesis))
          (t nil))))))

(defun %bump-patch (version)
  (destructuring-bind (major minor patch) (parse-semver version)
    (format nil "~A.~A.~A" major minor (1+ patch))))

(defun pack-form (pack &key version)
  "Reconstruct PACK's sexp form from its slots, with VERSION
(default: the patch component bumped — every variant is a new
versioned, fingerprinted artifact, spec §10.1)."
  (append (list :name (pack-name pack)
                :version (or version (%bump-patch (pack-version pack))))
          (alexandria:when-let ((prompts (pack-prompts pack)))
            (list :prompts prompts))
          (alexandria:when-let ((budgets (pack-budgets pack)))
            (list :budgets budgets))
          (alexandria:when-let ((profiles (pack-oracle-profiles pack)))
            (list :oracle-profiles profiles))
          (alexandria:when-let ((rules (pack-dial-rules pack)))
            (list :dial-rules rules))
          (alexandria:when-let ((policies (pack-tool-policies pack)))
            (list :tool-policies policies))))

(defun %entry-named (entries target)
  "Find the entry whose :id NAME matches TARGET (string compare —
no interning of LLM-supplied names)."
  (find-if (lambda (entry)
             (let ((id (getf entry :id)))
               (and id (string-equal (symbol-name id) target))))
           entries))

(defun %replace-entry (entries target key value)
  (let ((entry (%entry-named entries target)))
    (unless entry
      (error "variant: no pack entry named ~S" target))
    (substitute (let ((copy (copy-list entry)))
                  (setf (getf copy key) value)
                  copy)
                entry entries :test #'eq)))

(defun apply-variant (pack variant)
  "New pack FORM with exactly ONE entry changed (§10.4: one artifact
mutation per cycle, enforced structurally). Only :prompt and :budget
variants are applicable; :code variants become human dossiers."
  (let ((form (pack-form pack)))
    (ecase (variant-kind variant)
      (:prompt
       (let ((updated (%replace-entry (getf form :prompts)
                                      (variant-target variant)
                                      :text (variant-value variant))))
         (setf (getf form :prompts) updated)
         form))
      (:budget
       (let ((updated (%replace-entry (getf form :budgets)
                                      (variant-target variant)
                                      :value (variant-value variant))))
         (setf (getf form :budgets) updated)
         form)))))

(defun write-pack-form (form path)
  "Write FORM as a pack file readable by LOAD-POLICY-PACK."
  (with-open-file (out path :direction :output :if-exists :supersede
                            :external-format :utf-8)
    (with-standard-io-syntax
      ;; Keywords must keep their ':' prefix on disk (the default
      ;; *package* under standard io syntax guarantees it); pack forms
      ;; contain only keywords, strings, and numbers. *PRINT-READABLY*
      ;; must be NIL: under standard io syntax it is T, and SBCL then
      ;; prints base-strings as #A((5) base-char . "...") which the
      ;; pack reader rejects.
      (let ((*print-pretty* t)
            (*print-case* :downcase)
            (*print-readably* nil))
        (prin1 form out))))
  path)

(defun %pack-summary (pack)
  (format nil "name ~A version ~A~%prompts:~{ ~A~}~%budgets:~{ ~A=~A~}"
          (pack-name pack) (pack-version pack)
          (mapcar (lambda (entry)
                    (string-downcase (symbol-name (getf entry :id))))
                  (pack-prompts pack))
          (loop for entry in (pack-budgets pack)
                append (list (string-downcase
                              (symbol-name (getf entry :id)))
                             (getf entry :value)))))

(defun propose-variant (pack failure-modes propose-fn)
  "Ask PROPOSE-FN (prompt → response; build one from a provider with
MAKE-JUDGE-FN) for ONE pack mutation targeting FAILURE-MODES (the
miner's ranked alist). Returns a VARIANT or NIL (fail closed)."
  (parse-variant
   (handler-case
       (funcall propose-fn
                (format nil
                        "You improve a coding-harness policy pack. ~
Current pack:~%~A~%~%Observed failure modes (count, descending):~%~
~{- ~A: ~A~%~}~%Respond with EXACTLY one JSON object proposing ~
exactly ONE change:~%~
{\"kind\":\"prompt\"|\"budget\",\"target\":\"<entry id>\",~
\"value\":...,\"hypothesis\":\"...\"}~%~
or {\"kind\":\"code\",\"hypothesis\":\"...\"} when only a harness ~
code change would help (it will be routed to a human)."
                        (%pack-summary pack)
                        (loop for (mode . count) in failure-modes
                              append (list (string-downcase
                                            (symbol-name mode))
                                           count))))
     (error () (return-from propose-variant nil)))))
```

- [ ] **Step 3: Green** — expect **223 / 0**.

- [ ] **Step 4: Lint and commit**

```bash
mallet next/src/variant.lisp next/tests/variant-test.lisp
git add next/src/variant.lisp next/tests/variant-test.lisp cl-harness-next.asd
git commit -m "feat(next): one-mutation pack variants with fail-closed proposals"
```

---

### Task 4: Improver (drive the cycle; authority boundary; audit)

**Files:**
- Create: `next/tests/improver-test.lisp`, `next/src/improver.lisp`
- Modify: `cl-harness-next.asd` (add test file)

- [ ] **Step 1: Write the failing tests**

Create `next/tests/improver-test.lisp`:

```lisp
;;;; next/tests/improver-test.lisp
;;;;
;;;; Tests for next/src/improver.lisp (spec §10.2 stage 5 + §10.3
;;;; authority boundary + §10.4 audit): the improve-once cycle.

(defpackage #:cl-harness-next/tests/improver-test
  (:use #:cl #:rove)
  (:import-from #:cl-harness-next/src/event
                #:event-type
                #:event-payload)
  (:import-from #:cl-harness-next/src/event-log
                #:open-event-log
                #:emit-event
                #:read-events)
  (:import-from #:cl-harness-next/src/policy-pack
                #:load-policy-pack
                #:pack-version
                #:pack-budget
                #:pack-fingerprint
                #:policy-pack)
  (:import-from #:cl-harness-next/src/bench
                #:make-trial)
  (:import-from #:cl-harness-next/src/improver
                #:improve-once))

(in-package #:cl-harness-next/tests/improver-test)

(defun %hash (&rest plist)
  (alexandria:plist-hash-table plist :test #'equal))

(defparameter *budget-variant-json*
  (concatenate 'string
               "{\"kind\":\"budget\",\"target\":\"max-actions\","
               "\"value\":40,\"hypothesis\":\"more room to verify\"}"))

(defmacro with-improver-fixtures ((champion transcript audit-log
                                   pack-directory)
                                  &body body)
  `(uiop:with-temporary-file (:pathname pack-path :type "sexp")
     (uiop:with-temporary-file (:pathname transcript-path :type "jsonl")
       (uiop:with-temporary-file (:pathname audit-path :type "jsonl")
         (uiop:delete-file-if-exists transcript-path)
         (uiop:delete-file-if-exists audit-path)
         (with-open-file (out pack-path :direction :output
                                        :if-exists :supersede
                                        :external-format :utf-8)
           (write-string
            "(:name \"p\" :version \"1.0.0\"
              :budgets ((:id :max-actions :value 20)))"
            out))
         (let ((,champion (load-policy-pack pack-path))
               (,transcript transcript-path)
               (,audit-log (open-event-log audit-path))
               (,pack-directory
                 (uiop:pathname-directory-pathname pack-path)))
           ;; One synthetic failure in the transcript.
           (let ((log (open-event-log transcript-path)))
             (emit-event log :action (%hash "tool" "lisp-edit-form"
                                            "arguments" (%hash)))
             (emit-event log :observation
                         (%hash "tool" "lisp-edit-form"
                                "result" (%hash "isError" t))))
           ,@body)))))

(defun %trial-fn (champion-successes challenger-successes
                  &optional calls-box)
  (lambda (pack index)
    (when calls-box (push pack (car calls-box)))
    (let ((successes (if (equal (pack-version pack) "1.0.0")
                         champion-successes
                         challenger-successes)))
      (make-trial :index index
                  :pack-fingerprint (pack-fingerprint pack)
                  :success-p (elt successes index)
                  :actions 10))))

(deftest improve-once-promotes-a-winning-budget-variant
  (with-improver-fixtures (champion transcript audit-log pack-directory)
    (multiple-value-bind (outcome detail)
        (improve-once :champion champion
                      :transcripts (list transcript)
                      :propose-fn (lambda (prompt)
                                    (declare (ignore prompt))
                                    *budget-variant-json*)
                      :trial-fn (%trial-fn '(nil nil nil) '(t t t))
                      :pack-directory pack-directory
                      :audit-log audit-log
                      :trials 3)
      (ok (eq :promoted outcome))
      (ok (typep detail 'policy-pack))
      (ok (= 40 (pack-budget detail :max-actions)))
      (ok (equal "1.0.1" (pack-version detail)))
      ;; audit-path is captured anaphorically by the fixture macro.
      (let ((promotion (find-if
                        (lambda (event)
                          (and (eq :decision (event-type event))
                               (equal "promotion"
                                      (gethash "kind"
                                               (event-payload event)))))
                        (read-events audit-path))))
        (ok promotion)
        (ok (equal (pack-fingerprint detail)
                   (gethash "to" (event-payload promotion))))))))

(deftest improve-once-rejects-a-losing-variant
  (with-improver-fixtures (champion transcript audit-log pack-directory)
    (multiple-value-bind (outcome detail)
        (improve-once :champion champion
                      :transcripts (list transcript)
                      :propose-fn (lambda (prompt)
                                    (declare (ignore prompt))
                                    *budget-variant-json*)
                      :trial-fn (%trial-fn '(t t t) '(nil nil nil))
                      :pack-directory pack-directory
                      :audit-log audit-log
                      :trials 3)
      (ok (eq :rejected outcome))
      (ok (stringp detail)))))

(deftest improve-once-handles-unparseable-proposals
  (with-improver-fixtures (champion transcript audit-log pack-directory)
    (multiple-value-bind (outcome detail)
        (improve-once :champion champion
                      :transcripts (list transcript)
                      :propose-fn (lambda (prompt)
                                    (declare (ignore prompt))
                                    "no idea")
                      :trial-fn (%trial-fn '(t) '(t))
                      :pack-directory pack-directory
                      :audit-log audit-log)
      (ok (eq :no-variant outcome))
      (ok (stringp detail)))))

(deftest code-variants-become-dossiers-without-trials
  (with-improver-fixtures (champion transcript audit-log pack-directory)
    (let ((calls (list nil)))
      (multiple-value-bind (outcome detail)
          (improve-once :champion champion
                        :transcripts (list transcript)
                        :propose-fn
                        (lambda (prompt)
                          (declare (ignore prompt))
                          (concatenate 'string
                                       "{\"kind\":\"code\","
                                       "\"hypothesis\":\"needs a new"
                                       " oracle\"}"))
                        :trial-fn (%trial-fn '(t) '(t) calls)
                        :pack-directory pack-directory
                        :audit-log audit-log)
        (ok (eq :proposal outcome))
        (ok (search "human approval" detail))
        (ok (search "needs a new oracle" detail))
        ;; The authority boundary: no trials were run for code changes.
        (ok (null (car calls)))))))
```

Add `"cl-harness-next/tests/improver-test"` to the tests system. Run —
red: load failure (missing package).

- [ ] **Step 2: Create `next/src/improver.lisp`**

```lisp
;;;; next/src/improver.lisp
;;;;
;;;; The improve-once cycle (spec §10.2 stage 5): mine → propose ONE
;;;; variant → materialize the challenger pack → paired trials →
;;;; judge → promote or reject. The §10.3 authority boundary is
;;;; enforced here: :prompt/:budget wins auto-promote with an audit
;;;; event carrying both fingerprints; :code proposals never run
;;;; trials — they become human-approval dossiers.

(defpackage #:cl-harness-next/src/improver
  (:use #:cl)
  (:import-from #:cl-harness-next/src/event-log
                #:emit-event)
  (:import-from #:cl-harness-next/src/policy-pack
                #:load-policy-pack
                #:pack-fingerprint)
  (:import-from #:cl-harness-next/src/miner
                #:mine-transcript
                #:rank-failure-modes)
  (:import-from #:cl-harness-next/src/variant
                #:variant-kind
                #:variant-target
                #:variant-value
                #:variant-hypothesis
                #:apply-variant
                #:write-pack-form
                #:propose-variant)
  (:import-from #:cl-harness-next/src/bench
                #:run-paired-trials
                #:judge-trials)
  (:export #:+promotable-kinds+
           #:promotable-p
           #:record-promotion
           #:format-proposal-dossier
           #:improve-once))

(in-package #:cl-harness-next/src/improver)

(alexandria:define-constant +promotable-kinds+ '(:prompt :budget)
  :test #'equal
  :documentation "The §10.3 authority boundary: prompt/config changes
auto-promote on statistical evidence; anything else needs a human.")

(defun promotable-p (variant)
  (member (variant-kind variant) +promotable-kinds+))

(defun record-promotion (audit-log &key champion challenger summary)
  "Append the §10.4 audit event: which pack replaced which, on what
evidence."
  (emit-event audit-log :decision
              (alexandria:plist-hash-table
               (list "kind" "promotion"
                     "from" (pack-fingerprint champion)
                     "to" (pack-fingerprint challenger)
                     "summary" (or summary ""))
               :test #'equal)))

(defun format-proposal-dossier (variant failure-modes)
  "Markdown dossier for a non-promotable variant — code changes
require human approval (spec §10.3)."
  (format nil
          "# Improvement proposal (human approval required)~%~%~
A ~A-kind change cannot auto-promote — code changes require human ~
approval (spec §10.3).~%~%## Hypothesis~%~A~%~%~
## Observed failure modes~%~{- ~A: ~A~%~}"
          (string-downcase (symbol-name (variant-kind variant)))
          (variant-hypothesis variant)
          (loop for (mode . count) in failure-modes
                append (list (string-downcase (symbol-name mode))
                             count))))

(defun %challenger-path (pack-directory form)
  (merge-pathnames (format nil "~A-~A.sexp"
                           (getf form :name) (getf form :version))
                   pack-directory))

(defun improve-once (&key champion transcripts propose-fn trial-fn
                          pack-directory audit-log
                          (trials 3) (min-net-wins 2))
  "One self-improvement cycle (spec §10.2). CHAMPION is the active
pack; TRANSCRIPTS are event-log paths to mine; PROPOSE-FN is
(prompt → response); TRIAL-FN is (pack index) → TRIAL (it receives
POLICY-PACK objects); the challenger pack file is written into
PACK-DIRECTORY. Returns (values outcome detail):
:promoted + the new champion pack — with a §10.4 audit event;
:rejected / :inconclusive + the judge summary;
:proposal + a human-approval dossier (code-kind — no trials run);
:no-variant + a note (unparseable or absent proposal)."
  (let* ((reports (mapcar #'mine-transcript transcripts))
         (failure-modes (rank-failure-modes reports))
         (variant (propose-variant champion failure-modes propose-fn)))
    (cond
      ((null variant)
       (values :no-variant "proposal was absent or unparseable"))
      ((not (promotable-p variant))
       (values :proposal
               (format-proposal-dossier variant failure-modes)))
      (t
       (let* ((form (apply-variant champion variant))
              (challenger (load-policy-pack
                           (write-pack-form
                            form (%challenger-path pack-directory
                                                   form)))))
         (multiple-value-bind (champion-trials challenger-trials)
             (run-paired-trials trial-fn champion challenger trials)
           (multiple-value-bind (verdict summary)
               (judge-trials champion-trials challenger-trials
                             :min-net-wins min-net-wins)
             (ecase verdict
               (:promote
                (record-promotion audit-log :champion champion
                                            :challenger challenger
                                            :summary summary)
                (values :promoted challenger))
               (:reject (values :rejected summary))
               (:inconclusive (values :inconclusive summary))))))))))
```

- [ ] **Step 3: Green** — expect **227 / 0**.

- [ ] **Step 4: Lint and commit**

```bash
mallet next/src/improver.lisp next/tests/improver-test.lisp
git add next/src/improver.lisp next/tests/improver-test.lisp cl-harness-next.asd
git commit -m "feat(next): improve-once cycle with audited promotions and human dossiers"
```

---

### Task 5: Facade, acceptance, docs

**Files:**
- Modify: `next/src/main.lisp`, `next/tests/main-test.lisp`, `README.md`

- [ ] **Step 1: Write the failing acceptance test**

Append to `next/tests/main-test.lisp` (facade symbols only):

```lisp
(deftest sp8-self-improvement-acceptance
  ;; SP8 capstone: one full improve-once cycle through the facade —
  ;; mine a real transcript, accept a (canned) LLM budget variant,
  ;; win the paired trials, promote with an audit event.
  (uiop:with-temporary-file (:pathname pack-path :type "sexp")
    (uiop:with-temporary-file (:pathname transcript-path :type "jsonl")
      (uiop:with-temporary-file (:pathname audit-path :type "jsonl")
        (uiop:delete-file-if-exists transcript-path)
        (uiop:delete-file-if-exists audit-path)
        (with-open-file (out pack-path :direction :output
                                       :if-exists :supersede
                                       :external-format :utf-8)
          (write-string
           "(:name \"active\" :version \"1.0.0\"
             :budgets ((:id :max-actions :value 10)))"
           out))
        (let ((log (cl-harness-next:open-event-log transcript-path))
              (champion (cl-harness-next:load-policy-pack pack-path)))
          (cl-harness-next:emit-event
           log :action (alexandria:plist-hash-table
                        (list "tool" "lisp-edit-form") :test #'equal))
          (cl-harness-next:emit-event
           log :observation
           (alexandria:plist-hash-table
            (list "tool" "lisp-edit-form"
                  "error" "form not found")
            :test #'equal))
          (multiple-value-bind (outcome challenger)
              (cl-harness-next:improve-once
               :champion champion
               :transcripts (list transcript-path)
               :propose-fn
               (lambda (prompt)
                 (declare (ignore prompt))
                 (concatenate 'string
                              "{\"kind\":\"budget\","
                              "\"target\":\"max-actions\","
                              "\"value\":30,"
                              "\"hypothesis\":\"verify costs 3\"}"))
               :trial-fn
               (lambda (pack index)
                 (cl-harness-next/src/bench:make-trial
                  :index index
                  :pack-fingerprint
                  (cl-harness-next:pack-fingerprint pack)
                  :success-p (= 30 (cl-harness-next:pack-budget
                                    pack :max-actions))
                  :actions 9))
               :pack-directory (uiop:pathname-directory-pathname
                                pack-path)
               :audit-log (cl-harness-next:open-event-log audit-path)
               :trials 3)
            (ok (eq :promoted outcome))
            (ok (= 30 (cl-harness-next:pack-budget challenger
                                                   :max-actions)))
            (ok (find-if
                 (lambda (event)
                   (and (eq :decision (cl-harness-next:event-type
                                       event))
                        (equal "promotion"
                               (gethash "kind"
                                        (cl-harness-next:event-payload
                                         event)))))
                 (cl-harness-next:read-events audit-path)))))))))
```

(One module-qualified exception: `cl-harness-next/src/bench:make-trial`
— the trial CONSTRUCTOR is bench-internal API for trial-fn authors;
the facade exports the readers. This is deliberate; do not add
make-trial to the facade.)

- [ ] **Step 2: Red** — facade exports missing.

- [ ] **Step 3: Extend the facade**

Add `:import-from` clauses (after the mission-runner one):

```lisp
  (:import-from #:cl-harness-next/src/bench
                #:trial
                #:trial-index
                #:trial-pack-fingerprint
                #:trial-success-p
                #:trial-actions
                #:trial-reason
                #:run-paired-trials
                #:judge-trials)
  (:import-from #:cl-harness-next/src/miner
                #:failure-report
                #:mine-transcript
                #:failure-report-total-actions
                #:failure-report-failed-patches
                #:failure-report-tool-errors
                #:failure-report-stalled-cycles
                #:failure-report-dial-demotions
                #:failure-report-clean-verified-p
                #:rank-failure-modes)
  (:import-from #:cl-harness-next/src/variant
                #:variant
                #:variant-kind
                #:variant-target
                #:variant-value
                #:variant-hypothesis
                #:parse-variant
                #:pack-form
                #:apply-variant
                #:write-pack-form
                #:propose-variant)
  (:import-from #:cl-harness-next/src/improver
                #:+promotable-kinds+
                #:promotable-p
                #:record-promotion
                #:format-proposal-dossier
                #:improve-once)
```

Add them all to `:export` (groups `;; bench`, `;; miner`,
`;; variant`, `;; improver`).

- [ ] **Step 4: Green** — expect **228 / 0**.

- [ ] **Step 5: Force-compile + columns** — no warnings from next/
sources; awk column check clean.

- [ ] **Step 6: Document** — extend the README next/ subsection: after
"...async human escalation)" insert "; SP8 closes the loop with L5
self-improvement (transcript mining, one-mutation pack variants,
paired sign-test promotion with an audit trail, human dossiers for
code changes)" before ". It does not affect". Also change the
subsection's opening "(experimental)" qualifier line's last sentence
if present — leave the rest of the README untouched.

- [ ] **Step 7: Lint and commit**

```bash
mallet next/src/*.lisp next/tests/*.lisp
git add next/src/main.lisp next/tests/main-test.lisp README.md
git commit -m "feat(next): facade exports + SP8 self-improvement acceptance"
```

---

## Verification checklist (whole sub-project)

- Clean image: fresh worker → load-asd → `run-tests
  cl-harness-next/tests` 228/0.
- Legacy untouched: `git status --short src/ tests/` empty; `run-tests
  cl-harness/tests` 498/0.
- `mallet next/src/*.lisp next/tests/*.lisp` clean; no lines >100 cols.

## Deferred (post-SP8 backlog — do NOT build now)

- Real fixture trial-fns (wire run-mission + a fixture project + a
  provider into a trial-fn; belongs with first live usage).
- Sequential early stopping and proper significance tests (v1 sign
  test with min-net-wins; upgrade with real bench data).
- Post-promotion champion/challenger monitoring + auto-rollback
  (spec §10.4 — needs live runs to monitor).
- Held-out fixtures against Goodhart (needs a fixture corpus).
- Dossier filing (write to docs/proposals/ + PR creation) — the
  dossier STRING is the deliverable for now.
- Multi-cycle improve loop driver (improve-once is the unit; looping
  belongs with real usage and cost controls).
- Oracle-profile / dial-rule / tool-policy variant kinds (the pack
  sections exist; extend +promotable-kinds+ and apply-variant when
  evidence calls for them).

## Final-review notes (recorded 2026-06-12, non-blocking)

- Fixed pre-merge: parse-json now also pins yason:*parse-object-key-fn*
  (the one interning-relevant decoder knob) + hostile-key-fn regression
  test.
- Challenger pack files are keyed name-version, not fingerprint —
  rejected challengers can overwrite; fingerprint-suffix the filename
  with the dossier-filing work.
- improve-once should assert audit-log up front for promotable variants
  (today a missing log errors after trials complete).
- Unknown-target proposals error loudly out of improve-once (correct);
  the deferred multi-cycle driver must wrap it.
- Defaults trials=3 / min-net-wins=2 admit noisy promotions on flaky
  fixtures — raise :trials for live use until sequential testing lands.
- mine-transcript double-reads the log; %dial-event-p assumes all dial
  events are demotions (true today).
