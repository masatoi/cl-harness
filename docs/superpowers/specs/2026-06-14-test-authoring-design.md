# Test authoring for cl-harness-next — `authoring-policy` (`:mode :tdd` MVP)

**Date**: 2026-06-14
**Status**: design (approved in brainstorming; not yet implemented)
**Spec kind**: forward design (MVP = `:tdd`; `:spec-change` / `:coverage` are
designed-for extension points, not built in the first slice).

## 1. Problem & scope

`cl-harness-next` is currently **fix-type only**: a mission turns an *existing*
failing test suite green by patching source. Tests are the **immutable oracle**
(`verification-oracle`: `run-tests` green = the only truth). We want `next` to
also **author tests** — three goal-driven workflows:

1. **TDD bootstrap** — from a goal (no tests yet), write failing tests, then
   implement to green. **← MVP.**
2. **Spec-change follow** — goal/acceptance-criteria changed: rewrite tests to
   the new spec, then make code follow.
3. **Coverage add** — for existing (correct) code, add new tests for untested
   behavior.

Explicitly **out of scope**: *test repair* (the agent unilaterally deciding,
mid-fix, that a test is wrong and weakening it). That reopens the worst
oracle-gaming surface and was rejected in brainstorming. Here tests are authored
as a **deliberate, gated, goal-driven phase**, never opportunistically.

## 2. Decisions (from brainstorming)

- **Integrity of authored tests = RED-first (mechanical) + LLM tests-review
  (judge).** No human approval gate; no user-supplied example seeds — fully
  autonomous.
- **Architecture = approach A**: a new in-kernel **2-phase FSM dial**
  (`authoring-policy`) that reuses the existing kernel / L0 event log / oracles /
  fix dials. (Rejected: B = a `develop`-lite orchestration layer above the
  kernel — duplicates stable `develop`; C = tests as a general editable surface —
  reopens gaming.)
- **Inner fix dial default = `template-fix`.** TDD bootstrap naturally starts
  from a *stub* implementation, which is exactly template-fix's niche.
- Dial name **`authoring-policy`** with a **`:mode`** slot (`verification-oracle`
  precedent). MVP implements `:tdd`.

## 3. Architecture

### 3.1 Pipeline
A single mission runs three phases inside one FSM policy:

```
:author  →  :author-verify (RED-first)  →  :author-review (judge :consult)
         →  :fix (delegate to inner fix dial)  →  inner clean-verify
```

`authoring-policy` subclasses `control-policy` and is one-decision-per-step like
every other dial. Phases 1–3 are owned by `authoring-policy`; the fix phase
**delegates** to a pre-constructed inner fix policy exactly as `adaptive-policy`
delegates to `(decide (%current-level …) …)` — in `:fix`, `decide` just returns
`(decide (policy-fix-policy policy) kernel)`. The mission terminates on the inner
dial's `:finish` / `:give-up`.

### 3.2 Oracle integrity by **phase separation** (the key property)
Tests become an agent-authored artifact, so "self-authored tests + self-authored
code both pass" is the risk. We defeat it structurally:

- Tests are authored and **frozen** in phases 1–2 (gated by RED-first + judge).
- The fix phase uses the **existing fix dials**, which target `src/` only
  (template-fix fills source stubs; scripted/guided patch source forms). They
  **never edit test files**. So during the fix the agent **cannot weaken the
  authored tests to fake green** — there is no code path that touches them.

This makes the integrity gate a single, auditable choke point, and the final
`clean-verify` runs the *frozen, gated* tests in a fresh image.

## 4. `authoring-policy` FSM

### 4.1 Slots
| slot | meaning |
|------|---------|
| `mode` | `:tdd` (MVP). Reserved: `:spec-change`, `:coverage`. |
| `system` / `test-system` | ASDF systems (as in the fix dials). |
| `test-file` | path the authored `deftest` forms are written to (created with a defpackage skeleton if absent). |
| `author-fn` | `(prompt-string → raw-LLM-string)` producing `deftest` form(s); a `make-judge-fn` over `+test-author-system-prompt+`. |
| `reviewer` | a `tests-review-oracle` (consulted in `:author-review`). |
| `fix-policy` | the inner fix dial (injected, e.g. a `template-fix-policy`), delegated to in `:fix`. |
| `k` | per-phase regeneration cap (malformed / RED-first-green / judge-reject). |
| `state` / `attempts` / `feedback` / `sut-package` / `authored-names` | FSM bookkeeping. |

### 4.2 Transitions
The kernel is one-act-per-step, so the act *sequences* below span a few internal
states each (elided here at design granularity, as template-fix's `:disc` /
`:await-edit` / `:verify` / `:check` chain does).

- **`:init` → `:author`**: reuse template-fix's **source-discovery sub-FSM**
  (`fs-read-file` + reader parse) to derive the **SUT package + exported symbols
  + class-text** from `src/`. If `test-file` is absent, write a defpackage
  skeleton (`:use #:cl #:rove` + `:import-from` the SUT package's exports) via
  `fs-write-file`. → `:author`.
- **`:author`**: build the author prompt (goal + acceptance-criteria + SUT
  surface), call `author-fn`, **reader-validate** the reply into one-or-more
  `deftest` forms (analogous to template-fix `extract-method-body`: `read` with
  `*read-eval* nil`, reject non-`deftest`, reject empty). Record their test
  names. Then, as consecutive acts: **write** the forms to `test-file`
  (`lisp-edit-form` `insert_after` the last form; on edit error → regenerate ≤K)
  → **`load-system`** → `:author-verify`.
- **`:author-verify` (RED-first)**: emit `run-tests`; on the result require
  **(a)** the test system *loaded* (no `isError` / load failure — a non-compiling
  test is a false-red and is regenerated) **and (b)** every authored test name
  appears in `failed_tests` (asserts the test is non-vacuous against the current
  stub code). If all authored tests are *green* already → vacuous/already-met →
  regenerate (≤K) with feedback. On success → state `:author-review`.
- **`:author-review` (judge)**: `:consult` the `tests-review-oracle` with the
  authored test text + goal. Verdict pass → state `:fix`. Verdict fail →
  regenerate (≤K) with the judge's feedback; exceeding K → `:give-up`
  ("authored tests rejected by review").
- **`:fix`**: `(decide (policy-fix-policy policy) kernel)` until the inner dial
  finishes. The inner `template-fix` discovers the source stub(s) (the authored
  failing tests scope its targets via its own baseline cross-check) and fills
  them to green, then runs its own clean-verify.

## 5. Components

1. **`+test-author-system-prompt+`** — instructs the model to reply with ONLY
   `rove` `deftest` form(s) exercising the goal, using the listed SUT symbols, no
   prose/markdown. Mirrors `+template-snippet-system-prompt+` in spirit.
2. **`extract-deftest-forms` (reader-based)** — like `extract-method-body`:
   `*read-eval* nil` read of the reply; keep only `deftest` forms; reject
   empty/prose/`progn`-wrapped non-tests; return the validated form text +
   the test names. Re-read guard before writing.
3. **`tests-review-oracle`** — subclass of `oracle`. `consult` calls an injected
   judge `make-judge-fn` over a `+tests-review-system-prompt+` (ported/adapted
   from stable `src/review.lisp`), returns a verdict (`pass-p` + `reason`). Fits
   the `:consult` contract used by the verification oracles today.
4. **RED-first interpreter** — reuses `verification-ledger` semantics; "loaded
   AND each authored name in `failed_tests`" (reusing the load-vs-assertion
   distinction added for template-fix's `%verify`).
5. **Test-file writer** — `lisp-edit-form` `insert_after` for an existing file;
   `fs-write-file` for the defpackage skeleton of a new file. SUT package +
   exports derived from source parsing (shared with template-fix discovery).

## 6. Integrity model (why it holds)

- **Non-vacuity**: RED-first proves the authored test *distinguishes* the unmet
  state — it fails on the current stub. A `(ok t)` / empty test would pass on the
  stub and be rejected. (False-red from a non-compiling test is excluded by the
  load check.)
- **Faithfulness-to-goal**: the judge checks the authored tests actually encode
  the goal/criteria (not a weaker proxy).
- **Tamper-proof during fix**: §3.2 phase separation — the fix dial can't touch
  the gated tests.
- The final truth remains `clean-verify` on the frozen tests in a fresh image.

## 7. Events (L0)

New event payloads written to the single JSONL log (no new event *types*
required; reuse `decision` / `action` / `observation` / `oracle_result`):
- `:author` decision + the `lisp-edit-form` action writing the test file.
- `:author-verify` run-tests observation + a RED-first `oracle_result`-style note
  (or a `decision` annotation) recording "authored tests are red as required".
- `:author-review` → an `oracle_result` from `tests-review-oracle`.
- The `:fix` phase logs exactly as the inner dial does today.
Replay/suspend-resume keep working (the log stays the sole source of truth).

## 8. Error handling & bounds

- Malformed author reply → `extract-deftest-forms` feedback → regenerate (≤K).
- RED-first green (vacuous/already-met) → regenerate (≤K) with "your test passed
  on the unfixed code; make it assert the required behavior".
- Test fails to **load** (bad `deftest`) → treat as malformed, regenerate (≤K) —
  not as a satisfied RED-first.
- Judge reject → regenerate (≤K) with feedback; exceed K → `:give-up`.
- Inner fix dial `:give-up` → mission `:give-up` (the authored tests stand; the
  failure is the implementation's).

## 9. Extension points (designed, not built in MVP)

- **`:spec-change`** — `:author` *replaces* the named existing `deftest`s
  (`lisp-edit-form` `replace`) instead of appending; RED-first still holds (old
  code fails the new tests); then fix. Needs: target-existing-deftest selection.
- **`:coverage`** — author tests against *correct* existing code, so RED-first is
  **inverted** (the new tests must be **green**, and must *load*); the fix phase
  is skipped. Non-vacuity then rests on the judge (and, future, a mutation check:
  the test must fail on a mutated SUT). Flagged as the weakest integrity case.

## 10. Testing strategy

- **Unit (canned transport)**, mirroring `template-policy-test`'s harness:
  - author → RED-first green ⇒ regenerate, not advance (vacuous test rejected).
  - author → non-compiling test ⇒ regenerate (false-red excluded).
  - author → red + judge reject ⇒ regenerate with feedback; exceed K ⇒ `:give-up`.
  - author → red + judge pass ⇒ delegate to a canned inner fix policy ⇒ `:done`.
  - **phase separation**: assert the fix phase issues no edit to `test-file`.
- **End-to-end (real LLM)**: a `clh-demo`-shaped project with a **stub**
  `(defun add (a b) 0)` and **no tests**; `authoring-policy :mode :tdd`
  authors `add` tests, gates them, and the inner `template-fix` fills the stub to
  clean-green. (The README's buggy-`add` fixture is a *fix* demo; the TDD demo
  uses a *stub* `add` so template-fix applies.)

## 11. Risks / open questions

- **Test defpackage import wiring**: deriving `:import-from` from SUT exports
  assumes the SUT exports the symbols under test. If the goal targets unexported
  internals, the skeleton must `:use` the SUT package or qualify symbols — handle
  in the skeleton builder; revisit if it bites.
- **Author/judge collusion**: same base model authors and reviews. RED-first is
  the model-independent backstop; the judge is advisory faithfulness. Acceptable
  for MVP (autonomous by choice); a different reviewer model is a config knob.
- **`:coverage` non-vacuity** without RED-first is genuinely weaker — deferred
  with mutation testing noted as the sound follow-up.

## 12. File / package layout

- `next/src/authoring-policy.lisp` — package `cl-harness-next/src/authoring-policy`
  (`authoring-policy`, `+test-author-system-prompt+`, `extract-deftest-forms`,
  accessors). Re-export the user-facing names from the `cl-harness-next` facade
  (unlike template-fix, which is currently facade-private).
- `tests-review-oracle` — its own file/package or folded next to the other
  oracles; consulted via `:consult`.
- `next/tests/authoring-policy-test.lisp` — Rove suite (canned transport).
- `cl-harness-next.asd` — extend the `:depends-on` chain + the tests system.
- README §8 — add `authoring-policy` once the MVP lands (a *mode* above the fix
  dials, not a fix dial).
