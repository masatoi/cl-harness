# template-fix-policy — Design Spec (2026-06-13)

Status: approved (this session). Target system: `cl-harness-next`.

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
(signature + contract + class + failing assertions), emit the body". This is the
purest application of the spec's central thesis *autonomy ∝ capability*: it is
the lowest dial rung, where the LLM has zero agency.

**Corollary (the honest residue)**: removing agency does not make hard *code*
easy. Qwen's code-gen has a difficulty gradient — `gethash`/`incf`/
`hash-table-count` one-liners are reliable; `maphash` accumulators with tie-breaks
(`total`, `top-key`) are coin-flips. The design's value is that such failures now
surface as *clean, isolated, measurable code-gen failures* (not muddied by
agency). The residue is addressed by pushing **code structure** into the harness
too (skeleton scaffolding — §10, deferred), not by reaching for a stronger model.

## 2. Selection model (how the dial is chosen) — decided

Not "always start high and fall back". Two axes, decided this session:

- **Primary = capability-based starting rung.** Capability (per model × task
  shape) sets *where in the ladder a run starts*. For a known-weak model on an
  implement-stubs task, start directly at `template-fix`. Mechanism: config /
  per-model registry now; auto-calibration (the spec's model×autonomy matrix /
  L5) later.
- **Safety net = fast demotion** (deferred, §10). When the start is too high,
  demote — but on *leading* indicators (malformed-rate, exploration-without-edit,
  identical-action, **give-up**), not only the lagging `progress-stalled`, and
  **reset state on demotion** so the lower rung starts clean.

**Scope for THIS work**: build `template-fix-policy` **standalone** and run it
directly (capability-based start = "Qwen → template-fix"). Adaptive `:levels`
integration + the widened demotion trigger are a **follow-up** (§10).

## 3. Revisions over the baseline synthesis

The detailed grounding/critique/synthesis is in the design workflow output
(run `wf_50a7b10b-a55`). This spec adopts it with these revisions:

1. **Body extraction uses the Lisp reader, NOT a hand-written char scanner.**
   The policy is Lisp running in the worker; `read` (with `*read-eval* nil`,
   `*package*` = SUT package) correctly handles the string/comment/char-literal/
   nesting boundaries a hand-rolled scanner would botch. See §6.
2. **DISCOVER leads with stub-detection from source**, using test failures only
   to prioritize and to decide done. See §5.
3. **Standalone first**; adaptive/demote integration deferred (§2, §10).
4. **Capability-based start is primary**; fallback-demotion is the safety net
   (§2).
5. **Skeleton scaffolding** is the deferred answer to hard methods (§10), applied
   only if `total`/`top-key` fail as code-gen on real Qwen.

## 4. Package / file / build

- File: `next/src/template-policy.lisp`; package
  `cl-harness-next/src/template-policy` (package-inferred-system; **no
  `:local-nicknames`** per project CLAUDE.md).
- Imports from kernel (`control-policy` `decide` `make-decision`
  `kernel-last-verdict` `kernel-last-result` `kernel-last-action-error`
  `kernel-world-model` `kernel-environment`), oracle (`verdict-pass-p`
  `verdict-reason`), verification-oracle (`verification-oracle`), action
  (`strip-code-fence` — **must be newly exported** from
  `next/src/action.lisp`), projection (`+patch-tool-names+`).
- Exports: `template-fix-policy` `policy-state` `policy-system`
  `policy-test-system` `make-template-snippet-system-prompt` `+template-snippet-system-prompt+`
  and the body-extraction entrypoint `extract-method-body` (for unit tests).
- `.asd`: add `cl-harness-next/tests/template-policy-test` to the
  `cl-harness-next/tests` `:depends-on`. No `main.lisp` facade edit needed
  (package-inferred-system pulls the source via the test dep / future adaptive
  wiring).

## 5. DISCOVER (harness-only, no LLM)

Produces a work queue of form-descriptors:
`{symbol, file, form-type, form-name, head-text, bound-vars, contract, original-body}`
plus a shared `class-text`.

- **Primary: stub detection from source.** Read the SUT source
  (`lisp-read-file`, untruncated targeted reads — never the 480-char source-fact
  view). Enumerate top-level `defmethod`/`defun` forms whose body is a *stub*
  (a single constant `0`/`nil`/`t` or `(declare …)`-only). Each becomes a target.
  - `form-name`: for `defmethod`, the name + specializer lambda list
    (`"observe ((h histogram) key)"`, the exact `lisp-edit-form` requirement);
    for `defun`, the bare name.
  - `head-text`: the text between `(defmethod`/`(defun` and the body — used to
    re-assemble (`"observe ((h histogram) key)"` / `"observe (histogram key)"`).
  - `bound-vars`: variable names parsed from the lambda list (for the free-var
    check, §6).
  - `contract`: the `defgeneric` docstring if present (read via name_pattern).
  - `original-body`: the current stub body verbatim (revert payload on file
    poisoning).
  - `class-text`: the verbatim `defclass` form(s) of the SUT (shared across all
    prompts; non-negotiable — without it Qwen fabricates accessors).
- **Secondary: failing-test cross-check.** Parse `kernel-last-result`'s
  `failed_tests` (raw run-tests result, NOT the lossy world-model view): read
  each `failed_tests[].form` with a guarded reader (`*read-eval* nil`, SUT
  package), walk the whole s-expression collecting every operator symbol, filter
  to SUT external symbols. Use this set to (a) **prioritize** the queue and (b)
  define **per-form done** (`symbol no longer in failed_tests AND failed
  count strictly decreased`). It does NOT define queue membership (a stub may
  pass an assertion by accident, e.g. `(= 0 (count-of h :z))`).
- **Edge cases**: defgeneric+single defmethod → patch the defmethod. plain defun
  → bare name. **>1 defmethod on one generic → park-and-surface (never guess)**.
  target with no resolvable on-disk stub → classify unresolvable; if any
  unresolvable target is required for green → `:give-up` (never loop).
- DISCOVER reads need **no load** (parent-process tools). The baseline incremental
  `:consult` is best-effort; if the all-stub image fails to compile, proceed
  disk-only.

## 6. Body extraction (reader-based — revision ①)

`(raw-llm-text, head-text, form-type, bound-vars, sut-package) → full-form-string | (values nil reason feedback)`.
Reuse `strip-code-fence`; validate with `lisp-check-parens`. **No hand-written
char scanner** — use the Lisp reader for all lexical parsing.

Steps:
1. **Pre-clean**: `(string-trim ws (strip-code-fence raw))`. Empty → `:empty`.
2. **Locate first form**: scan to the first `(`/`#(` (skips leading prose the
   model added despite instructions). No form-open at all → treat the trimmed
   text as a single atom candidate (caught by degenerate check).
3. **Read all top-level forms** with the real reader: `with-input-from-string`,
   `*read-eval* nil`, `*package* (find-package sut-package)`, loop `read` with an
   eof sentinel, recording each form. A reader error → `:malformed` (capture the
   condition message as feedback). The reader correctly handles `"…"` strings,
   `;`/`#|…|#` comments, `#\(` char literals, nested parens.
4. **Classify**:
   - Exactly one form whose head ∈ `{defmethod defun defgeneric defclass}` →
     **whole-definition** (case b, Qwen's common behavior): take the body
     sub-forms (after name + lambda-list + optional qualifiers/docstring);
     **discard the model's header** (never trust model-supplied specializers).
   - Otherwise → **body forms** (case a): all read forms are the body.
5. **Reject nested definitions**: any body form whose head ∈ definitions →
   `:nested-definition`.
6. **Degenerate rejection**: body equals the stub (`0`/`nil`/`t` /
   `(declare …)`-only) → `:degenerate` (else it re-creates the stub and loops).
7. **Free-variable check**: collect symbols in the body; subtract CL-package
   symbols + SUT-exported symbols + `bound-vars`. A remaining lowercase
   param-shaped symbol (`self`, `obj`) → `:free-var` with feedback ("body uses
   `self` but the parameter is `h`").
8. **Assemble under the FSM-owned head**: `(format nil "(~A ~A~%  ~A)" form-type
   head-text body-text)` where `body-text` is the original substring (case a,
   preserves formatting) or the re-printed body forms (case b). This keeps the
   on-disk header ↔ `form-name` invariant across all K retries.
9. **Head-match assertion**: guarded-read the assembled candidate; assert head is
   the expected definition operator and matches `form-name`. Fail → never write.
   (Closes the "bare body silently replaces the whole defmethod" corruption.)
10. **`lisp-check-parens {code: assembled}`** (the assembled form, not the bare
    body). Not-success → fail, capture message.
11. Return the validated full-form string for the FSM to splice via its own
    `lisp-edit-form` `:act`.

## 7. FSM

`template-fix-policy` subclasses `control-policy`; builds incremental + clean
`verification-oracle`s in `initialize-instance :after` (mirroring
`scripted-fix-policy`, `:clear-fasls` default **t**). Slots: `snippet-fn`
(prompt→raw-string), `system`, `test-system`, `sut-package`, `k` (per-form
attempt cap, default 3), `snippet-timeout`, `state` (`:init`), `queue`,
`current`, `attempts`, `parked`, the two oracles, and the cached DISCOVER data.

`decide` is an `ecase` over `state`; **every branch returns exactly one
`decision` and advances state** (kernel is one-decision-per-step). The LLM
round-trip happens **inside `decide`** at `:consult-snippet` (it is NOT a kernel
`:consult` — that kind needs an oracle returning a verdict).

States (per the synthesis FSM table): `:init` (consult incremental baseline) →
`:discover-tests` (run-tests to enumerate) → `:parse-targets` (DISCOVER, pure) →
`:read-form`/`:await-read` (read current body) → `:consult-snippet` (call
snippet-fn under timeout; extract+validate §6; emit `lisp-edit-form` :act) →
`:await-edit` (check tool error) → `:check-integrity` (post-edit
`lisp-check-parens` whole-file; revert with cached original on poison) →
`:check-form` (consult incremental; per-form done = symbol gone from failed_tests
& failed decreased; else incf attempts, retry < K else park) → `:next-form` (pop
queue) → `:final-decide` (consult clean oracle; `verdict-pass-p` → `:finish`,
else `:give-up` naming parked forms).

- **Two retry budgets**: in-`decide` sample loop for malformed/empty snippets
  (≤ K, never reach the file); per-form `attempts` counter for clean-but-wrong
  bodies (incremented on red verify; park at K). **Do not delegate per-form
  bounding to the governor** — a compile-broken edit *succeeds* as a tool call so
  `consecutive-failed-patches` never fires.
- **Termination**: variant `Σ(K − attempts_f)` strictly decreases each verify
  cycle; queue strictly shrinks. Terminal set `{:done, :given-up}`.
- **Governor calibration (the run factory must set)**: `:max-steps ≥ 120`,
  `:max-actions ≥ 80`, and `max-consecutive-identical-actions` raised (≥ K+3) or
  `nil` — K successive edits to one `form-name` collapse to one identical-action
  signature (`%argument-token` renders hash args as a constant) and would trip
  `progress-stalled` mid-form. The policy's own K+park is the real bound.

## 8. Model contract

`snippet-fn` is a `make-judge-fn`-style closure with a **dedicated** system
prompt (NOT `+scripted-fix-system-prompt+`, which demands JSON):

> You are a Common Lisp method-body oracle. You are given one generic function's
> contract, the class it operates on, and the failing test assertions. Reply with
> ONLY the body of the method as Common Lisp s-expressions — no defmethod
> wrapper, no markdown, no prose. Use ONLY the accessors and slots shown.

Per-form user prompt assembled deterministically (ZERO LLM decomposition): the
verbatim `class-text` (slots/accessors), the method head with `<YOUR BODY HERE>`,
the `contract` docstring, and the `failed_tests` entries for this symbol (use
`description` to preserve `:keywords`). The per-symbol spec is NOT extracted from
the free-text goal (no decomposition call); it is assembled from CONTRACT +
FAILING ASSERTIONS + CLASS (all harness-held). Work-queue order easy→hard to bank
green assertions.

## 9. TDD plan (RED-first, smallest increment first)

Increment A — **body extraction** (pure unit, no kernel), in
`next/tests/template-policy-test.lisp`:
1. `body-extraction-bare-body-wraps`
2. `body-extraction-strips-fence-and-prose`
3. `body-extraction-rewraps-whole-defmethod-under-canonical-head` (divergent sig)
4. `body-extraction-accepts-multiple-body-forms` *(reader-based: a body may be
   several forms — this REPLACES the synthesis's "reject multiple forms", which
   was a char-scanner artifact)*
5. `body-extraction-rejects-nested-definition`
6. `body-extraction-rejects-free-variable` (feedback message)
7. `body-extraction-rejects-degenerate-and-malformed` (empty / `nil`-only /
   unbalanced)

Increment B — **FSM + DISCOVER end-to-end with a canned oracle** (mirrors
`scripted-policy-test.lisp`: a stateful `fix-transport`, a `with-template-kernel`
macro, `run-kernel`):
8. `discover-finds-stubs-and-targets` (stub detection + failing-test cross-check;
   the `(EQ A (TOP-KEY H))` nesting trap)
9. `happy-path-canned-oracle-drives-to-done` (snippet-fn returns correct bodies;
   stateful transport flips failed_tests empty when all patched; assert `:done`,
   `clean-verified-p`, one `pool-kill-worker`, 5 patches)
10. `malformed-snippet-recovers-within-k`
11. `empty-reply-gets-extra-retries-not-immediate-park`
12. `unfixable-form-parks-then-gives-up` (4/5 patched, reason names the parked
    symbol)
13. `post-edit-broken-file-reverts` (cached-original revert on poison)
14. `governor-identical-action-threshold-respected`

Increment C — **real Qwen**: wire a `snippet-fn` over the OpenAI-compatible
provider (`make-judge-fn` + the §8 system prompt), run via
`tools/run-next-experiment.lisp` (a new `CLH_DIAL=template`), **easy-3 first**
(work-queue order makes this natural), then full-5. Measure & record.

## 10. Deferred (separate follow-ups, not this work)

- **Adaptive integration**: append `template-fix` as the bottom `:levels` rung;
  widen demotion to `:give-up` (+ leading-indicator triggers); reset state on
  demotion.
- **Capability auto-calibration**: a cheap per-model probe / the L5 model×autonomy
  matrix to pick the starting rung.
- **Skeleton scaffolding**: for accumulation-pattern methods that fail as code-gen
  on real Qwen, the harness supplies a body skeleton with a smaller hole
  (e.g. a `maphash` template with `<HOLE>` = the accumulation step) — the same
  agency-removal principle applied one level deeper into the code.
- **vLLM `guided_grammar`** (single balanced s-expr) via `:extra-body` — add only
  if §6 sanitization proves insufficient on real Qwen.

## 11. Risk

Easy-3 (`count-of`/`observe`/`distinct`) plausibly reach green on Qwen — the
design eliminates failure modes 1/2/3/5 structurally and bounds 4. `total`/
`top-key` are the honest residue (code-gen difficulty, no live data); realistic
first outcome is 3–4/5 green → `:given-up` (partial), strictly better than
today's 0/5. Smallest validation: Increment A + the canned-oracle full-loop
(test 9) proves the machinery with zero LLM variance; only then real Qwen on
easy-3.
