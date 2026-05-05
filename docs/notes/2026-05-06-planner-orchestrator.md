# Planner + Orchestrator Design Note — 2026-05-06

Notes toward a v0.3 architectural extension that lifts cl-harness from
"focused bug-fixer / TDD Green helper" to "TDD Red+Green pair able to
take a structured feature request and drive it to passing tests."

This is a design draft, not a commitment. Open questions are flagged
explicitly. v0.2.0 stays the shipping baseline; the work outlined
here would be the bulk of v0.3.

## Why

The current `run-agent` (`src/agent.lisp`) is purely tactical. Its
single observation is "the latest result of running the configured
rove test", and its single output channel is "one MCP tool call or
finish action per turn." The loop terminates when the test passes.

That works because the user has implicitly already done the planning:
- chosen which test to point at,
- decided that the failure mode is fixable as a single contiguous
  effort,
- expressed the goal as a one-paragraph `:issue` string.

When the input is instead a high-level request — "add an
authentication middleware", "make this library Unicode-safe",
"refactor X to use the visitor pattern" — none of those preconditions
hold. There is no single failing test, no single goal,
no single contiguous effort. The agent loop has no surface to
attach to.

The natural fix is a **planner** that translates a high-level
request into a sequence of focused, run-agent-shaped sub-goals,
plus an **orchestrator** that runs them in order and replans on
failure.

## Goal / scope of this layer

In: a high-level natural-language request + a project root.

Out: either
- the project's tests for the requested feature pass (project is in
  the requested state), or
- a structured failure summary explaining which sub-goals were
  achieved, which were not, and why.

Out of scope (deliberately):

- **Requirements gathering / product design.** Translating a vague
  idea into a structured request is somebody else's problem
  (brainstorming agent, human PM, design doc author).
  cl-harness's input is "requirement statement", not "vague idea."
- **Choosing whether to build the feature at all.** This is a build
  tool, not a steering wheel.
- **Cross-repo or cross-language work.** Common Lisp + ASDF + rove,
  same as the rest of the harness.

## What's missing today

`run-agent` (the executor) does not maintain:

- a goal hierarchy
- any notion of "which sub-task am I on"
- any way to declare partial progress
- any signal other than "tests pass / don't pass"

It also has no way to be told "first add a defclass, then a method,
then update the tests" — its only knob is `:issue`, which is a
single paragraph the LLM reads once at start and may forget by
turn 5.

The planner+orchestrator pair fills exactly that gap and nothing
else. **The executor stays unchanged.** This is the most important
constraint of the design: don't bloat agent.lisp.

## Architecture sketch

```
[ user request: "<freeform feature description>" ]
              |
              v
       Planner (LLM call)
              |
              v
   [ plan: ordered list of (sub-goal, acceptance, condition, limits) ]
              |
              v
        Orchestrator
              |
              +---- for each step ----.
              |                       |
              |                       v
              |             RUN-CONFIG built from step
              |                       |
              |                       v
              |              run-agent (existing)
              |                       |
              |                       v
              |        success? → next step
              |        failure? → Replanner (LLM call) → revised plan
              |                       |
              |                       v
              |                 (loop back into orchestrator)
              v
        Final report
```

### Connection to existing pieces

- `RUN-CONFIG` (`src/config.lisp`) already encodes everything one
  sub-goal needs: project-root / system / test-system / issue /
  condition / limits. The planner's per-step output is just that
  struct + a few extra fields.
- `run-agent` accepts a RUN-CONFIG and drives one focused fix
  loop. Every existing guarantee (clean-room ASDF scoping,
  clean-verify on `:passed`, JSONL transcript per run, `error_text`
  on failures, `:max-*` limits) carries over for free.
- `bench.lisp` is essentially a hand-written orchestrator over a
  static plan (the `benchmarks/<task>/task.json` files). The
  v0.3 orchestrator is the same shape, but the plan is dynamic
  (LLM-emitted) and supports replanning between steps.

### New code, sized

| File | Approximate role | Lines (est.) |
|---|---|---|
| `src/planner.lisp` | LLM call + JSON parse → list of plan steps | ~120 |
| `src/orchestrator.lisp` | Execute plan, capture results, call replanner on failure | ~180 |
| `prompts/planner.md` | Planner system prompt + few-shot examples | ~200 (prose) |
| `src/cli.lisp` (extension) | New `cl-harness:develop` entry point | ~40 |
| `src/cli-main.lisp` (extension) | `cl-harness develop` shell command | ~50 |
| Tests | Stub-driven planner + orchestrator coverage | ~250 |

`run-agent` itself: zero changes.

## Three design hard points

### 1. Acceptance criterion per sub-goal

The current verifier is hard-wired to "the run-tests result on the
configured test-system reports zero failures." For planner-emitted
sub-goals there is, by definition, no pre-existing test. Three
options:

**(a) Planner authors the test for each sub-goal.** Cleanest from
the harness's perspective: each step is still a RUN-CONFIG with a
real test-system, just one whose source the planner just generated.
The existing verify path works untouched. Clean-verify still
catches FASL-cache cheats. Failure mode: the planner writes a test
that doesn't actually capture the requirement (low-fidelity test —
"passes the wrong thing"). Mitigation: a *test-quality* check —
e.g. mutation-test the new test against a deliberately broken
implementation, or have a second LLM review the test for
correspondence to the sub-goal. This is the "verify the verifier"
problem and it's real.

**(b) Allow alternative verifiers.** Widen the verify interface so
acceptance can be "compile cleanly, no warnings", "macroexpand-1 on
form X matches pattern P", "run-tests passes AND a custom
post-check returns true". This is a non-trivial refactor of
`src/verify.lisp` and `agent.lisp`'s wiring around verify-task /
clean-verify-task. Useful long-term but big.

**(c) LLM-as-judge per sub-goal.** Drop test-based verification,
ask an LLM whether the sub-goal is "done." Trivial to implement,
disastrously soft as evidence. The whole point of the v0.2
methodology hardening (clean-verify, run-end metrics, JSONL with
error_text) was to keep the harness's accept-signal mechanical.
LLM-judge would un-do that. Reject this for now.

**Recommendation**: ship (a) as default, leave the verify interface
extension for later if (a) proves insufficient.

### 2. Planner vs executor responsibility split

There's a real spectrum:

- **Heavy planner / light executor.** Planner specifies "in file
  src/auth.lisp, between lines L1 and L2, insert this defun." The
  executor's job is essentially `lisp-edit-form`. Risk: planner
  has to know the codebase in detail, prompts blow up, and any
  surprise (e.g. function name conflict) needs a replan. The
  executor's situated tools (`code-find`, `repl-eval`,
  `clgrep-search`) become useless.

- **Light planner / heavy executor.** Planner says "add an
  authentication middleware that validates session tokens". The
  executor reads the codebase, decides where the middleware goes,
  patches it. Risk: the executor is the current one, with a 3-patch
  budget — it can only get one or two files right per sub-goal.

- **Balanced (recommended).** Planner specifies *what* changes
  (one or two file-level edits), *where* in coarse terms (which
  file or which package), and *what test should now pass*. The
  executor handles the within-file decisions, finds the exact
  insertion point, runs probes if needed.

The balance point isn't fixed; it'll need iteration once we have
real tasks. Concretely, the planner output schema should support
*either* "give me a file-level summary" or "give me an exact
insertion point" so we can experiment.

### 3. Replanning cost and termination

Re-prompting the planner after every sub-goal failure is expensive
in tokens and can loop forever ("planner emits plan with the same
broken step again"). Termination conditions to enforce in the
orchestrator:

- **Hard step budget**: total RUN-AGENTS allowed across all sub-goals
  + replans (e.g. ≤ 3× the original plan length).
- **Replan budget**: maximum number of replans, separate from
  step budget (e.g. ≤ 5 replans per `develop` run).
- **No-progress detection**: if two consecutive plans share the
  same first failing step (by signature), stop and report stuck.
- **Wall-clock budget**: same shape as `:max-wall-clock-seconds`
  on `run-agent`, but for the whole orchestrator.
- **Total token budget**: across planner + executor + replanner
  combined.

All of these need to land in a single struct (`develop-limits`
analogous to `run-limits`) so JSONL events can record which one
tripped, mirroring how v0.2 records `:limit-exhausted` +
`:limit-hit`.

## What the JSONL transcript should look like

The current per-RUN-AGENT JSONL stays untouched (one file per
sub-goal). The orchestrator should emit its **own** higher-level
JSONL alongside, with at minimum:

```
develop-start    { goal, project, planner-model, timestamp }
plan             { plan-id, steps: [ ... ] }
step-start       { step-index, sub-goal, transcript-path }
step-end         { step-index, status, ms, link-to-run-end }
replan-trigger   { step-index, reason, prior-plan-id, new-plan-id }
plan             { ... revised plan ... }
develop-end      { status: passed | give-up | limit-exhausted, ... }
```

Each `step-start`/`step-end` references the run-agent JSONL by
path so post-mortems can drill down. This preserves the v0.2
property that "a single transcript file is enough to reconstruct
what happened" — just one level higher.

## Open questions (deliberately not decided here)

- **Should the planner itself be model-agnostic, or should we ship
  one specifically tuned for Qwen3 / Claude / GPT-4o-mini?** The
  v0.2 LLM provider abstraction in `model.lisp` works for any
  OpenAI-compatible endpoint, so technically we can stay generic.
  But planner prompt engineering may be model-specific in practice.

- **How does the planner discover the codebase before producing a
  plan?** Option A: read whole files into the prompt (cheap, scales
  badly). Option B: do a `clgrep-search` / `code-find` pass first
  via cl-mcp (more turns, less context bloat). Option C: pre-build
  a project summary cached on disk. This decision shapes prompt
  size dramatically.

- **Should sub-goals ever be parallel?** The current architecture
  is strictly sequential. In Common Lisp + a single ASDF system,
  serializing is probably fine. In multi-system projects, parallel
  feature work might be feasible but then we need locking on the
  cl-mcp transport's project-root state. Defer.

- **Replanner identity: same model as planner, or smaller / faster?**
  Replanning may be cheap if the diagnosis is straightforward
  ("the import was wrong"). Splitting roles could halve cost.
  Empirical question.

- **Does this need its own benchmarks?** Today's `benchmarks/`
  fixtures are all "broken source + breaking test" (bug-fix
  shape). To measure planner+orchestrator quality we'd need
  greenfield-shaped fixtures: empty source + spec test, multi-file
  spec tests, missing-feature-with-natural-language-request, etc.
  Probably 5–8 new fixtures is enough to start.

## Sizing / phasing

Three commits, each independently testable:

**Phase P1** — Planner alone, no orchestrator yet.

- `src/planner.lisp` exposes `(plan-development goal project-info
  provider) → list of RUN-CONFIG`.
- Tests use a stub LLM provider returning canned JSON plans.
- Output: a tool that tells you "this is what I would do," driven
  manually run by run by the human via existing `cl-harness:fix`.

**Phase P2** — Orchestrator over a static plan.

- `src/orchestrator.lisp` runs a sequence of pre-built RUN-CONFIGs,
  no replanning.
- Develop-level JSONL emitted.
- Effectively a "scripted multi-fix" mode; useful in its own right
  for dev workflows like "fix all 12 benchmarks back-to-back."

**Phase P3** — Replanning + new entry point.

- Wire planner + orchestrator. Replan on step failure.
- `cl-harness:develop` programmatic API + `cl-harness develop` CLI.
- Add 5–8 greenfield benchmark fixtures.
- Document.

Each phase is one PR. Total estimate: 3–5 days, dominated by the
greenfield fixtures and prompt-engineering work in phase P3.

## Risks

- **Planner-written tests of low fidelity.** The planner says
  "passed" but the requirement isn't actually met. Mitigation:
  test-quality check (mutation or LLM review). If unmitigated,
  every benchmark number is suspect.
- **Replan loops.** Without strict budgets, the orchestrator can
  thrash. Mitigation: the limits enumerated above, plus
  no-progress detection.
- **Prompt size blowup.** Planner needs codebase context. Without
  a discovery strategy, prompts hit the context window quickly.
  Mitigation: explicit P1 design choice (option B: structured
  discovery via cl-mcp tools, charged against a token budget).
- **Scope creep into requirements analysis.** The temptation to
  let the planner ask clarifying questions about the goal will be
  strong. Resist. Out of scope (see top of doc).

## Relationship to v0.2 and existing notes

- v0.2 (`docs/v0.2-roadmap.md`) shipped the credibility / usability
  / methodology layers needed to make this layer's results
  trustworthy. Planner+orchestrator on top of HTTP-shared cl-mcp
  pool would have been measuring noise; on top of stdio default +
  package-cleanup verify, the numbers will mean something.
- `docs/notes/2026-05-06-stdio-transport.md` and the anomaly #64
  fix are prerequisites we already have.
- This note is positioned for v0.3. Tier 4 hardening (dynamic tool
  schema, generic summarize-tool-result, context compaction) is
  parallel — it would make the executor stronger, but is not on
  this layer's critical path.
