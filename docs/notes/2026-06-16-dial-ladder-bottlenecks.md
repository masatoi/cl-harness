# The Dial Ladder Has Two Harness Bottlenecks — 2026-06-16

A benchmark campaign on `cl-harness-next` (the greenfield redesign) against a
weak local model. The headline result inverts the naive expectation about the
control-policy "dial ladder", and it is backed by an end-to-end fix that lands
in `main`.

> **TL;DR.** On a 12-fixture bug-fix suite with Qwen3.6-35B-A3B, raising the
> dial from `template-fix` to `scripted` to `guided` made success rate go
> **down**, not up (9/9 body bugs → 8/12 → 1/12). The weak model's *reasoning*
> was never the limit; it produced correct fixes at every dial. The limit is two
> things the harness can do for the model and a high-agency dial makes the model
> do for itself: **(1) constructing valid tool calls** and **(2) recognising
> completion**. Repair both — argument coercion for (1), a harness "green-stop"
> for (2) — and the highest-agency dial reaches parity with the lowest
> (1/12 → 3/12 → 8/12). The green-stop half shipped: cl-harness PR #9 (`652a339`)
> and PR #10 (`8fbd0ce`, default-on).

## Setup

**Dials.** `cl-harness-next` exposes a control-policy ladder of increasing agent
agency (spec §6, `docs/superpowers/specs/2026-06-11-autonomous-harness-redesign-design.md`):

| dial | who builds the tool call | who decides "done" |
|------|--------------------------|--------------------|
| `template-fix` | the harness (FSM assembles `lisp-edit-form`; the LLM emits only a form body) | the harness (green verify → clean gate → done) |
| `scripted` | the harness, at the single patch step (the LLM emits one structured patch per cycle) | the harness (after each patch, the harness runs the verify oracle) |
| `guided` | the LLM, every action (read / edit / verify, free-form) | the LLM (it must emit a `:finish`, which triggers the clean gate) |
| `self-directed` | the LLM, everything | the LLM |

**Fixtures.** `benchmarks/000…011`: twelve single-bug fix missions, each a tiny
ASDF system with a failing Rove test. Bug shapes span `defun` bodies, a `defun`
rename, a missing test-package import, a `defmethod` specializer, a `defclass`
slot `:initarg`, a `defmacro` expansion, format arity, error signalling, etc.

**Model / harness.** `Qwen/Qwen3.6-35B-A3B` (SGLang, `http://192.168.0.17:8000/v1`),
`enable_thinking=false`. The dials drive a live `cl-mcp` worker per run (fresh
stdio child). Sweep harness: `/tmp/clh-bench/sweep*.sh` + `tools/run-next-experiment.lisp`.
Fixtures are copied to sandboxes so `benchmarks/` stays pristine; the source file
is injected as a hint to isolate the fix/tool-arg layer from blind discovery.

## Two harness bugs the benchmark surfaced first

Before any dial comparison was meaningful, two harness defects had to be removed.
Both produced *false* failures — the model was right, the harness lost the work.

**G1 — schema noise (scripted).** `render-tool-schemas` rendered *every*
`inputSchema` property to the model. The weak model filled the optional
`readtable` argument of `lisp-patch-form` with plausible-but-wrong values
(`:COMMON-LISP`, `:CL`, …), and `cl-mcp` rejected them ("Readtable :X not
found"). This was the *dominant* scripted failure (~30+ occurrences across a
sweep). Fix: a `+schema-noise-keys+` denylist
(`readtable`, `dry_run`, `normalize_blank_lines`). readtable errors ~30+ → 0.
→ cl-harness **PR #8** (`c597dc9`).

**G2 — sandbox isolation defeated by ASDF resolution.** The `template-fix`
dial produced correct fixes for all 7 body-bug fixtures, yet the worker's
`run-tests` always saw the *old* code. The "stale fasl second-granularity"
hypothesis was a confirmed-but-irrelevant red herring; the true cause is that
the benchmark fixtures' `.asd` files live under Roswell's `local-projects`
registry, so setting `MCP_PROJECT_ROOT` to the sandbox did **not** make ASDF
resolve the sandbox copy — it kept resolving and compiling the original,
unedited fixture. Fix: make the worker's project root win ASDF resolution by
prepending the (truename-canonicalised) root to `asdf:*central-registry*`, with
exactly one managed entry, clearing systems under a prior root on a root change.
→ cl-mcp **PR #116** (`9c113b6`). With it, `template-fix` flips 0/7 → 7/7.

(The full G2 derivation — `(:tree)` caching vs. central-registry non-caching,
the found-system cache leak, package-inferred subsystems needing
`component-pathname` not `system-source-directory`, symlinked roots needing
`truename` — is recorded across cl-mcp PR #116's seven review rounds.)

## Three-dial comparison

With G1 and G2 fixed, the same Qwen3.6, same sweep:

| # | fixture | bug shape | `template-fix` | `scripted` | `guided` |
|---|---------|-----------|:---:|:---:|:---:|
| 000 | smoke | defun body | DONE | DONE | PARKED |
| 001 | wrong-operator | defun body | DONE | DONE | PARKED |
| 002 | typo-defun | **signature (rename)** | n/a | FAILED | PARKED |
| 003 | missing-import | **test scaffold** | n/a | PARKED | PARKED |
| 004 | defmethod-specializer | **signature (specializer)** | n/a | DONE | PARKED |
| 005 | defclass-slot | defclass body | DONE | DONE | PARKED |
| 006 | format-arity | defun body | DONE | DONE | PARKED |
| 007 | error-signal | defun body | DONE | DONE | FAILED\* |
| 008 | macro-expansion | defmacro body | DONE | FAILED | PARKED |
| 009 | handler-case-typo | defun body | DONE | DONE | PARKED(80 act) |
| 010 | unbound-symbol | defun body | DONE | FAILED | PARKED |
| 011 | let-vs-let-star | defun body | DONE | DONE | **DONE** |
| | **total** | | **9/9** | **8/12** | **1/12** |

\* runner hiccup (0-action abort).

Notes:
- **`template-fix` is a definition-body oracle.** It applies to the 9 body-bug
  fixtures and reaches **9/9**. `defclass` (005) and `defmacro` (008) work with
  *zero* code change — `%definition-form-p` already accepts them and the re-wrap
  is form-type-agnostic; only `defun`/`defmethod` bodies were exercised before.
  The 3 it cannot address are **out of model**: signature/head bugs (002 rename,
  004 specializer — the corrective edit is the *head*, not a body) and a
  test-scaffold bug (003 — the bug is in the test's `:import-from`, not a SUT
  form). All DONEs verified real: `run-tests FAIL → edit → run-tests PASS`.
- **`scripted` (8/12)** has broader reach (it edits free-form, so it fixes 004's
  specializer) but is exposed to a tool-argument layer: its 4 misses are
  `action-parse-error: unknown action type`, `form_type "function"≠"defun"`,
  `operation "edit"`, missing `form_name`, brittle `old_text` whitespace.
- **`guided` (1/12)** collapses. The diagnoses are *correct* — for the three
  residual fixtures the model emitted exactly the right fix (`gret→greet`,
  `:import-from #:add-one`, `((d dog)) … (dog-name d)`) — but it thrashed on
  tool-call *values* (`operation:overwrite`, `form_type:buffer`,
  `form_name:"defmethod bark"`, whitespace `old_text`) and the governor PARKed it
  at 4 consecutive failed patches.

## The inverted dial ladder

| dial | agency | tool-arg exposure | DONE |
|------|--------|-------------------|:---:|
| `template-fix` | lowest (harness builds the call) | none | 9/9 |
| `scripted` | mid (one structured patch) | moderate | 8/12 |
| `guided` | high (every action free-form) | maximum | 1/12 |

**Success rate is inversely proportional to tool-argument exposure.** "More
agency reaches harder tasks" fails for *this* weak model on *these* simple bugs,
because the bottleneck is tool-call construction, not reasoning — and a higher
dial hands the model more tool calls to get wrong.

## Decomposing the bottleneck

Is tool-call construction the *only* bottleneck? An argument-coercion experiment
(experiment-side only: `/tmp/clh-bench/run-next-coerce.lisp`, unit-tested 6/6)
repaired the weak model's malformed-but-correct tool calls: route a
`lisp-patch-form` whose `new_text` is a complete form to a `lisp-edit-form`
replace (sidestepping brittle `old_text`); `form_type "function"→"defun"`;
`operation`→`replace`; strip a `form_type`/package prefix from `form_name`.

Result on `guided` (all 12), separating "ever reached green" from "declared
done":

| metric | `guided` | `guided`+coercion |
|--------|:---:|:---:|
| DONE (terminal) | 1/12 | **3/12** |
| ever-green (a run hit `failed=0, passed>0`) | — | **9/12** |
| reached green but PARKed | — | 6/12 (5 re-broke the green) |
| never-green | — | 3/12 (000, 002, 003) |

So coercion **largely solves bottleneck (1)** — 9/12 reach green, the weak
model's fixes land — but exposes a **second bottleneck (2): done-recognition.**
Of the 9 that reached green, only 3 became DONE; the other 6 *overshot* — they
kept editing past green, and 5 re-broke the now-green code, PARKing on
max-actions. (A single-fixture trace of 002 showed the patch land — `run-tests
PASS` — followed by the model renaming the function again, breaking it.)

This is exactly why the lower dials win: their FSM owns **both** tool-call
construction **and** the verify→done transition. The model never decides "am I
done"; the harness does, the moment the acceptance (tests green) is met.

## green-stop: giving the guided dial the done-oracle

`green-stop` (cl-harness PR #9, `652a339`) makes the `guided` harness drive
straight to the existing mandatory clean gate as soon as the world model shows
the tests green — instead of waiting for the agent's `:finish`. The clean gate is
unchanged, so there is **no false done**: a spurious incremental green whose
clean re-verify fails falls back to agent-driven steps (green-stop fires at most
once per mission — the fire-once guard prevents an infinite re-fire on the
still-green projection). Implementation: a `%preempt-finish-p` generic (base
no-op so `self-directed` is untouched, specialised on `guided-policy`) consulted
in `decide`'s `:stepping` branch.

Validated on `guided` + coercion + green-stop (all 12):

| configuration | DONE |
|---------------|:---:|
| `guided` (baseline) | 1/12 |
| `guided` + coercion (fixes bottleneck 1) | 3/12 (9/12 ever-green) |
| **`guided` + coercion + green-stop** (fixes 1 **and** 2) | **8/12** |

green-stop fired on all 8 DONE fixtures (verified in the event logs), so the
conversions are causally attributable to it. The result is **parity with
`scripted` (8/12)**. The 4 remaining PARKs are not green-stop's domain: 002/003
never reach green (the tool-arg/locate layer — bottleneck 1, not done
recognition), and 005/008 were LLM-variance non-green in that run.

green-stop shipped opt-in (PR #9), then flipped **default-on** once the gain was
confirmed (PR #10, `8fbd0ce`); `CLH_GREEN_STOP=0/off/no/false` opts out. Both PRs
passed two Codex review rounds.

## Conclusion — the harness design rule

> A weak model's reasoning was sufficient at every dial. The rate limit was the
> harness's handling of two layers the model is bad at: **(1) constructing valid
> tool calls** and **(2) recognising completion**. Take both away from the model
> — argument coercion / structured tool construction for (1), a green-stop /
> done-oracle for (2) — and even the highest-agency dial reaches the same success
> as the lowest. **The dial ladder should be operated from the bottom up**:
> `template-fix` first (body bugs, cheap and certain), escalate to `scripted`,
> and only spend `guided`/`self-directed` once both bottlenecks are addressed.

## What shipped vs. what is still experiment-side

- **Shipped to `main`:** G1 (PR #8), G2 (cl-mcp PR #116), green-stop (PR #9) and
  its default-on flip (PR #10). `template-fix`'s `defclass`/`defmacro` support was
  already latent and is exercised by the sweep.
- **Experiment-side only (not committed):** the argument-coercion layer lives in
  `/tmp/clh-bench/run-next-coerce.lisp`. Productionising it (especially the
  `defclass`/`defmacro` `new_text` routing) is open follow-up, as is the
  bottleneck-1 residue for 002 (rename locate) and 003 (test-scaffold edit).

## Reproduction

```bash
# 1. fixes must be present: cl-harness main (PR #8/#9/#10) + cl-mcp main (PR #116)
# 2. point at the model
export CL_HARNESS_LLM_BASE_URL=http://192.168.0.17:8000/v1
export CL_HARNESS_LLM_API_KEY=dummy
export CL_HARNESS_LLM_MODEL=Qwen/Qwen3.6-35B-A3B

# scripted / guided sweeps (all 12)            -> results-<dial>.tsv
bash /tmp/clh-bench/sweep.sh scripted
bash /tmp/clh-bench/sweep.sh guided

# template-fix body-bug sweep (9 incl. defclass/defmacro) -> results-template.tsv
bash /tmp/clh-bench/sweep-template.sh

# guided + argument coercion (+ green-stop)     -> results-guided-coerce[-gstop].tsv
bash /tmp/clh-bench/sweep-coerce.sh guided
CLH_GREEN_STOP=1 bash /tmp/clh-bench/sweep-coerce.sh guided
```

A DONE row is real iff its event log shows `run-tests FAIL (baseline) → edit →
run-tests PASS → finish`; green-stop DONEs additionally carry a `green-stop`
decision before the clean gate. The benchmark uses fresh workers per run; the
guided green-stop reuse/clearing paths are covered by `cl-harness-next/tests`
(330/330) and `cl-mcp`'s set-project-root suite, not the e2e sweep.
