# template-fix-policy — Design Spec (2026-06-13, as-built)

Status: **implemented** (this session). Target system: `cl-harness-next`.
Source `next/src/template-policy.lisp`; tests `next/tests/template-policy-test.lisp`;
adaptive wiring `next/src/adaptive-policy.lisp`; runner `tools/run-template.lisp`.
Commits: `f8029c6` (design) → `f75519a` (A) → `037b49c` (B) → `2dd85a6` (C, Qwen
5/5) → `7795659` (B2 DISCOVER) → `f7a86d9` (refinements) → `f2139b5` (review fixes).

> This document was **reconciled with the implementation** after build. The
> original pre-build synthesis (workflow run `wf_50a7b10b-a55`) proposed a
> clgrep-driven DISCOVER, a hand-written char scanner, a free-var gate, and a
> `lisp-check-parens` validation step; the implementation deviated from all of
> those. The sections below describe **what was actually built**; where the
> as-built differs from the synthesis it is called out inline.

## 1. Motivation & principle

This session's dogfooding showed that a weak local model (Qwen3.6-35B-A3B)
fails the multi-method "implement 5 stub defmethods to pass a rove test" task
not because of **code generation** — Qwen writes correct one-liner bodies, and
solved the 1-form clh-demo task — but because of the **agentic layer** we asked
the LLM to own: planning, tool-call construction, observation→action, when to
verify, and the completion decision. Every measured failure (wandering,
read-but-no-patch, sloppy tool calls, premature give-up, malformed output) lives
in that layer. A capable agent (Opus) drove the *same* harness to `:done`.

**Principle**: move the entire agentic layer into the harness FSM; reduce the
LLM to a *stateless code-generation oracle* — "given a fully-specified hole
(signature + contract + class), emit the body". This is the purest application
of the spec's central thesis *autonomy ∝ capability*: it is the lowest dial rung,
where the LLM has zero agency.

**Corollary (the honest residue)**: removing agency does not make hard *code*
easy. The design's value is that any residual failure surfaces as a *clean,
isolated, measurable code-gen failure* (not muddied by agency), addressable by
pushing **code structure** into the harness too (skeleton scaffolding — §10,
deferred), not by reaching for a stronger model. **Measured outcome (§11): the
residue did not materialize — Qwen reached 5/5 `:done`, including `total`/
`top-key`.**

## 2. Selection model (how the dial is chosen)

Not "always start high and fall back". Two axes:

- **Primary = capability-based starting rung.** Capability (per model × task
  shape) sets *where in the ladder a run starts*. For a known-weak model on an
  implement-stubs task, start directly at `template-fix`. Mechanism: config /
  per-model registry now; auto-calibration (the L5 model×autonomy matrix) later
  (§10).
- **Safety net = demotion on `:give-up`.** ✅ implemented in `adaptive-policy`
  (§7.4): a sub-level `:give-up` demotes to the next rung and re-decides *this
  step*. So `template-fix` placed as the bottom `:levels` rung is reachable when
  a higher rung gives up — a `:give-up` otherwise terminates the kernel before
  any governor pass, so the existing `progress-stalled` trigger never fired.

This work built `template-fix-policy` so it runs **standalone** (capability-based
start = "Qwen → template-fix", `tools/run-template.lisp`) **and** as the bottom
rung of `adaptive`.

## 3. Revisions over the baseline synthesis (as-built)

1. **Body extraction uses the Lisp reader, not a hand-written char scanner**
   (§6). The policy runs in the worker; `read` (with `*read-eval* nil`) handles
   strings/comments/char-literals/nesting correctly.
2. **DISCOVER reads the whole source via `fs-read-file` and parses it with the
   reader** (`discover-targets`, §5) — *not* clgrep-per-symbol nor parsing
   `failed_tests[].form` in the SUT package. Stub detection from source is
   primary; a baseline `run-tests` cross-check narrows to tested symbols.
3. **Per-form done requires *positive* evidence** — the suite is green, or
   `failed_tests` is present and the target symbol is absent from it (§7.2). A
   tool error or a detail-less failure is **not** treated as resolved (a second
   Codex review caught that an empty `failed_tests` made `notany` vacuously true,
   so a never-compiling body looked fixed). This is *not* "failed count strictly
   decreased" (which can misjudge — first review finding 2).
4. **Whole-definition unwrap accepts only `defmethod`/`defun`** — `defgeneric`/
   `defclass`/`defmacro` are rejected as nested definitions (review finding 3).
5. **No `lisp-check-parens`, no free-var gate, no post-edit revert.** Body
   validity is checked by *re-reading the assembled form* in-process; wrong-var
   and wrong-body cases are caught by the load/run-tests retry loop. The free-var
   gate is deferred (review finding 4 — it needs lexical-scope tracking).
6. **Capability-based start primary; adaptive `:give-up` demotion as the safety
   net** — both implemented (§2, §7.4).
7. **Skeleton scaffolding** remains the deferred answer to any hard-method
   code-gen residue (§10), unused so far (Qwen reached 5/5).

## 4. Package / file / build (as-built)

- File `next/src/template-policy.lisp`; package
  `cl-harness-next/src/template-policy` (package-inferred-system; **no
  `:local-nicknames`**).
- Imports: kernel (`control-policy` `decide` `make-decision` `kernel-last-result`
  `kernel-last-action-error` `kernel-last-verdict`), oracle (`verdict-pass-p`),
  verification-oracle (`verification-oracle`), action (`strip-code-fence` —
  **newly exported** from `next/src/action.lisp`). `alexandria:plist-hash-table`
  is used package-qualified. (No projection / kernel-environment / world-model
  imports — the policy reads only `kernel-last-{result,action-error,verdict}`.)
- Exports: `template-fix-policy`, `fix-target` + `make-fix-target` + the
  `target-*` accessors, `discover-targets`, `extract-method-body`,
  `+template-snippet-system-prompt+`, `policy-state`/`policy-system`/
  `policy-test-system`/`policy-parked`.
- `.asd`: `cl-harness-next/tests/template-policy-test` added to the
  `cl-harness-next/tests` `:depends-on`; that test package `:import-from`s the
  source, pulling it into the build. No `main.lisp` facade edit (the standalone
  runner loads `"cl-harness-next/src/template-policy"` explicitly; adaptive
  wiring is the production path).

## 5. DISCOVER (harness-only, no LLM)

`discover-targets (source file &key package)` is a **pure** function (unit
tested) returning `(values targets class-text sut-package)`. The FSM feeds it the
`fs-read-file` result text. It reads `source` with the Lisp reader
(`*read-eval* nil`, `*package*` = `CL-USER` — **the SUT package is never required
to exist**; the package name is derived from the `(in-package …)` form via
`symbol-name`, resolving review finding 1).

For each top-level form it derives:
- **stubs** = `defmethod`/`defun` whose body (after dropping leading declarations
  **and a leading docstring** — review finding 6) is empty or a single literal
  constant (`%degenerate-body-p`). Each stub becomes a `fix-target`:
  `symbol` (upcased operator name), `file`, `form-type` (`"defmethod"`/`"defun"`),
  `form-name` (for `defmethod`, name + specializer lambda list
  `"observe ((h histogram) key)"`; for `defun`, the bare name), `head` (the same
  name+lambda-list text, re-printed downcase with `*package*` bound so no package
  prefixes leak), `contract` (the matching `defgeneric` docstring).
- **class-text** = the verbatim `defclass` source (substring via span tracking),
  concatenated across files — non-negotiable in the prompt (without it Qwen
  fabricates accessors).
- **sut-package** = the `(in-package …)` name string.

**Overloads** (first review finding 3 / edge case): because parsing is
*form-by-form*, an overloaded generic's two stub `defmethod`s become **two
distinct targets** (distinct specializer `form-name`s) — there is no symbol→form
ambiguity at discovery. Locked by `discover-handles-overloaded-methods`.
*Done-detection*, however, keys off the operator symbol, which the two overloads
**share** (a second review caught this): a remaining failure for one overload
still mentions the symbol, so `%form-resolved-p` alone would falsely re-try/park
the already-patched sibling. For a shared symbol (`%symbol-shared-p`) `%check`
therefore judges resolution by **progress**, not symbol-presence
(`%overload-resolved-p`): the build must be clean (real test data) AND either the
symbol is now wholly gone, or this patch **strictly reduced** the count of
`failed_tests` entries mentioning the symbol versus the target's **pre-count**
(the count when the target began). A *third* review caught that "build clean"
alone advanced a compiling-but-*wrong* body without retry (the shared symbol
still failed, but the run wasn't a tool error) → premature give-up at the final
gate; the count-decrease test repairs that — a wrong body makes no progress and
is retried within K. The pre-count is snapshotted at each target's start
(`%snapshot-pre-count`) from the latest test result; to give the *first* target a
pre-count, the **injected-targets path now also runs a baseline `load-system` +
`run-tests`** (the cross-check filter is skipped for explicit targets). A *fourth*
review caught that the count comparison needs **positive evidence**: a
detail-less red run (`{passed:0,failed:1}` with no `failed_tests`) made
`%symbol-fail-count` return 0, so `now=0` read as "symbol gone" and advanced a
still-red overload. `%overload-resolved-p` now requires either `%form-resolved-p`
(green / symbol-absent-with-detail) or (per-test **detail present** AND a strict
count decrease) — a tool error or detail-less red is not resolved. Locked by
`template-overloaded-generic-resolves-each-method` (correct body, one edit each),
`template-overloaded-wrong-body-is-retried-not-advanced` (wrong body retried),
and `template-overload-detail-less-red-is-not-resolved` (no detail → retried).

> **Known limitation** (re-review, *not* fixed): branch 2 accepts *any* count
> decrease, so an overload with several failing assertions that the body only
> **partially** fixes still advances; it then fails at the final clean oracle
> ("suite still red") — a safe give-up, never a false `:done`. A precise
> per-overload check is impossible from the shared symbol's aggregate, and any
> *retry re-patches the form*, which would risk overwriting a **correct**
> sibling's body under a weak model (exactly the audience template-fix serves).
> Overwrite-safe advance-on-progress is the deliberate trade-off; the sound fix
> is group-level retry with body snapshot/revert (tracked in
> `docs/improvement-backlog.md`).

**Failing-test cross-check** (`:disc-baseline-test` → `:disc-filter`): after
discovering all source stubs, the FSM runs a baseline `load-system` + `run-tests`
and keeps only targets whose `symbol` appears in the raw `failed_tests` (string
match on the `form`/`description`/`test_name` fields — untested stubs do not block
green, so they are skipped). **Conservative**: if the baseline yields no/absent
failure data (e.g. the all-stub image failed to load), all stubs are kept. The
baseline test result is also retained (`last-tests-result`) as the first target's
pre-count source. Injected targets run the same baseline but **skip the filter**
(`injected-p`) — explicit targets are never narrowed away.

`fix-target` also has an `original-body` slot reserved for a future revert
payload; it is not populated yet (no post-edit revert — §3.5).

## 6. Body extraction (reader-based)

`extract-method-body (raw &key head form-type package)` →
full-form-string | `(values nil reason feedback)`. Reuses `strip-code-fence`.
**No char scanner, no `lisp-check-parens`** — the Lisp reader does all lexical
parsing and a re-read validates the assembled form.

Steps:
1. **Pre-clean**: `(string-trim ws (strip-code-fence raw))`. Empty → `:empty`.
2. **Read from the start** with the real reader (`*read-eval* nil`), collecting
   all top-level forms. The reader preserves leading reader prefixes
   (`'(…)`, `` `(…) ``, `#'(…)`) — review finding 5. Only on a *read error*
   (genuine leading prose), **or** when the first form read is a bare atom while a
   `(` waits later, fall back to scanning to the first `(` and re-read. A reader
   error with no recoverable form → `:malformed`.
3. **Reject prose**: ≥2 forms, none of them a cons → `:malformed` (catches
   "I cannot help with that" reading as bare symbols).
4. **Classify**:
   - Exactly one form whose head ∈ `{defmethod defun}` (`%method-form-p`) →
     **whole-definition**: keep the body sub-forms (after qualifiers + lambda
     list), discard the model's header (never trust its specializers).
   - Otherwise → the read forms **are** the body (multiple body forms allowed).
5. **Reject nested definitions**: any body form whose head ∈ `{defmethod defun
   defgeneric defclass defmacro}` (`%definition-form-p`) → `:nested-definition`.
   This is how a whole `defgeneric`/`defclass`/`defmacro` reply is rejected
   (review finding 3) — it is not a `%method-form-p`, so it falls here.
6. **Degenerate rejection**: stub-equivalent body (constant after dropping
   declarations + a leading docstring) → `:degenerate`.
7. **Assemble** under the FSM-owned head: `(format nil "(~A ~A~%  ~A)" form-type
   head body-text)`, where `body-text` is the original substring (bare-body case,
   preserves formatting) or the re-printed body forms (whole-definition case).
   This keeps the on-disk `form-name` ↔ header invariant across all K retries.
8. **Re-read guard**: read the assembled candidate back; it must be exactly one
   definition form. Fail → `:malformed`. (Closes the "bare body silently replaces
   the whole defmethod" corruption — a naked `(incf …)` would re-read as a
   top-level `incf`, not a `defmethod`.)

Deferred (review finding 4): a free-variable gate (body uses `self` where the
param is `h`). It needs lexical-binder scope tracking to avoid false positives on
`let`/`lambda`/`maphash` locals; until then the load/run-tests retry catches
wrong-variable bodies.

## 7. FSM

`template-fix-policy` subclasses `control-policy`; builds the **clean**
`verification-oracle` in `initialize-instance :after` (`:mode :clean`,
`:clear-fasls` default **t**). Per-form verification is done with **explicit
`load-system` + `run-tests` `:act`s** (so the policy sees the raw `failed_tests`
for per-symbol done-detection); only the *final* gate uses the clean oracle.

Slots: `snippet-fn` (prompt→raw-string), `system`, `test-system`, `sut-package`
(accessor — set by discovery), `clear-fasls-p`, `k` (per-form cap, default 3),
`targets` (accessor — injected or discovered), `class-text` (accessor),
`source-files` (default `("src/main.lisp")`), `disc-files`, `pending-file`,
`state` (`:init`), `queue`, `current`, `attempts`, `feedback`, `parked`,
`injected-p` (skip the cross-check filter), `last-tests-result` +
`pre-count` (overload progress baseline), `clean-oracle`.

`decide` is an `ecase` over `state`; **every branch returns exactly one
`decision`** (kernel is one-decision-per-step). The **LLM round-trip happens
inside `decide`** in `%gen` (called from `:init`/advance/retry) — it is *not* a
kernel `:consult` (that kind needs an oracle returning a verdict).

### 7.1 Discovery sub-FSM
`:init` (no targets) → set `disc-files`, emit `fs-read-file` (`:act`), state
`:disc` → `:disc` (parse the result with `discover-targets`, accumulate
targets/class-text/package; more files → read next, else `%baseline-load`) →
`:disc-baseline-test` (emit `run-tests` `:act`) → `:disc-filter` (cross-check
filter §5, then start the per-form loop). **Injected targets** (`:init` with
`:targets`) take the *same* baseline path — `%init` sets `injected-p` and calls
`%baseline-load` → `:disc-baseline-test` → `:disc-filter` — but `%disc-filter`
skips the filter for `injected-p`. The baseline exists so the first target has a
`pre-count` for overload done-detection (§5).

### 7.2 Per-form loop
`%gen`: build the prompt (§8), call `snippet-fn`, `extract-method-body`; on a
valid candidate emit a harness-built `lisp-edit-form` `:act`, state `:await-edit`;
on ≤K malformed re-samples (feeding the reason back) failing, park and advance.
`:await-edit` (edit tool error → retry/park; else emit `load-system` `:act`,
state `:verify`) → `:verify` (**load `isError` → feed the load error back and
retry/park, NOT run-tests** — a third review caught that unconditionally running
tests clears `kernel-last-action-error` before `%check` sees it, and run-tests on
the stale image could mark a never-loaded form resolved; else emit `run-tests`
`:act`, state `:check`) → `:check` (done? → advance; else `incf attempts`, retry
`%gen` while `< K`, else park) → advance (next target → `%gen`; queue empty →
`:final`). The done test is
`%form-resolved-p` (positive evidence §3) for a unique symbol; for an
**overloaded** symbol (`%symbol-shared-p`) it is `%overload-resolved-p` —
*progress* against the `pre-count` (symbol gone, or its `failed_tests` count
strictly dropped), since the shared symbol can't single out the specializer and
"build clean" alone would advance a compiling-but-wrong body (§5). `%advance` and
`%finish-discovery` snapshot the next target's `pre-count`; `%check` records each
test result. The final clean oracle remains the backstop.

### 7.3 Termination & governor
`:final` consults the clean oracle: `verdict-pass-p` → `:finish`
"clean verification green"; else `:give-up` naming the parked forms. Two retry
budgets: the in-`decide` malformed re-sample (≤K, never reaches the file) and the
per-form `attempts` counter (red verify → park at K). The policy's own K+park is
the bound — a compile-broken edit *succeeds* as a tool call, so the governor's
`consecutive-failed-patches` never fires. **The run factory must set**
`:max-steps ≥ 120/200`, `:max-actions` high, and disable/raise
`max-consecutive-identical-actions` (K edits to one `form-name` collapse to one
identical-action signature). `tools/run-template.lisp` uses `:max-actions 300`
and `nil` for the stall guards.

### 7.4 Adaptive `:give-up` demotion (`adaptive-policy`)
`decide` intercepts a sub-level `:give-up`: while a lower rung remains, it
demotes (`level-index`++, governor stall reset, a logged `"dial"` event for
replay coherence) and **re-enters its *own* `decide` this same step** — not the
lower rung's `decide` directly. Re-entering the wrapper is what lets a *chain* of
give-ups keep demoting: in a `guided → scripted → template-fix` stack a guided
give-up followed by a scripted give-up demotes twice and reaches `template-fix`,
rather than terminating at the middle rung (a second review caught the direct-call
version stopping one rung early). Only the bottom rung's `:give-up` escapes. The
existing `progress-stalled` path is unchanged. Locked by
`chained-give-ups-demote-through-to-a-finishing-rung`.

## 8. Model contract

`snippet-fn` is a `make-judge-fn` closure over the OpenAI-compatible provider with
a **dedicated** system prompt (`+template-snippet-system-prompt+`, NOT
`+scripted-fix-system-prompt+` which demands JSON):

> You are a Common Lisp method-body oracle. You are given one method's signature,
> its contract, and the class it operates on. Reply with ONLY the body of the
> method as Common Lisp s-expressions — no defmethod wrapper, no markdown, no
> prose, no explanation. Use ONLY the accessors and slots shown.

The per-form **user** prompt (`%build-prompt`) is assembled deterministically
(ZERO LLM decomposition) from harness-held data: the verbatim `class-text`
(slots/accessors), the method head with `<YOUR BODY HERE>`, the `contract`
docstring, and any `feedback` from a failed attempt. (The failing-assertion text
is used by discovery's cross-check, not injected into the prompt; the contract +
class proved sufficient on Qwen.) Work-queue order is discovery order
(easy→hard naturally, since stubs are processed as found).

## 9. Tests (RED-first; actual names)

Body extraction (pure unit): `body-extraction-bare-body-wraps`,
`-strips-fence-and-prose`, `-rewraps-whole-defmethod`,
`-accepts-multiple-body-forms`, `-rejects-nested-definition`,
`-rejects-degenerate-and-malformed`, `-rejects-non-method-definitions`
(finding 3), `-preserves-leading-reader-prefix` (finding 5),
`-rejects-declare-docstring-constant` (finding 6).

Discovery (pure unit): `discover-finds-stub-defmethods`,
`discover-handles-overloaded-methods`.

FSM over a canned `template-transport` + `with-template-kernel`:
`template-happy-path-canned-oracle-drives-to-done` (5 forms → `:done`, one
`pool-kill-worker`), `template-malformed-snippet-recovers-within-k`,
`template-unfixable-form-parks-then-gives-up` (4/5 patched, names the parked
form), `template-discovery-drives-to-done` (NO injected targets — reads source,
discovers, `:done`), `discovery-cross-check-skips-untested-stubs`,
`template-tool-error-is-not-treated-as-resolved` (second review: a NOCOMPILE body
errors the build → retried, not falsely advanced),
`template-overloaded-generic-resolves-each-method` (second review: each overload
patched once, no spurious park on the shared symbol),
`template-overloaded-wrong-body-is-retried-not-advanced` (third review: a
compiling-but-wrong overload makes no progress vs the pre-count → retried within
K, not advanced to a premature give-up),
`template-load-failure-is-not-treated-as-resolved` (fourth review: a body that
edits cleanly but fails `load-system` is fed back and retried, not silently
followed by run-tests on the stale image),
`template-overload-detail-less-red-is-not-resolved` (fourth review B: a
detail-less red run does not resolve an overloaded target).

Adaptive: `give-up-demotes-to-the-next-rung-this-step`,
`give-up-at-the-bottom-rung-escapes`,
`chained-give-ups-demote-through-to-a-finishing-rung` (second review: two
successive give-ups reach the bottom rung) (plus the unchanged progress-stalled
tests).

280 tests green; `mallet` clean; `compile-system :force t` clean.

Real Qwen: `tools/run-template.lisp` (`CLH_DISCOVER=1` for source discovery,
else injected targets).

## 10. Deferred (follow-ups)

- **Capability auto-calibration**: a cheap per-model probe / the L5 model×autonomy
  matrix to pick the starting rung (largest remaining item).
- **Multi-file auto-listing**: `fs-list-directory` to populate `source-files`
  (today an explicit list, default `src/main.lisp`).
- **Free-variable gate** (§6, review finding 4): lexical-scope-aware, with a
  class-derived accessor allow-list.
- **Post-edit integrity / revert**: `lisp-check-parens` on the whole file after an
  edit + revert from `original-body` on parinfer mis-repair.
- **Skeleton scaffolding**: for any accumulation-pattern method that fails as
  code-gen, supply a body skeleton with a smaller hole (e.g. a `maphash` template)
  — unused so far (Qwen reached 5/5).
- **vLLM `guided_grammar`** (single balanced s-expr) via `:extra-body` — add only
  if §6 sanitization proves insufficient.

## 11. Risk & measured outcome

Predicted: easy-3 (`count-of`/`observe`/`distinct`) reach green; `total`/
`top-key` (`maphash` accumulators) were the honest code-gen residue, expected to
be coin-flips → a realistic 3–4/5 partial.

**Measured**: Qwen3.6-35B-A3B reached **5/5 `:done`** on clh-histogram via
`template-fix`, **reproduced** (injected and discovery modes), including `total`
and `top-key` (`observe` needed 1 retry; the rest one-shot) — versus **0/5** on
every agency dial (scripted/guided/adaptive). The "coin-flip" prediction was
pessimistic: with the class in context and a precisely specified hole, the weak
model's code-gen sufficed even for the hard methods. The hypothesis (collapse the
LLM to a body oracle, move all agency into the harness) is confirmed for this
task class.
