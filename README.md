# cl-harness

A runtime-native coding agent harness for Common Lisp. Pairs an LLM
(any OpenAI-compatible Chat Completions endpoint) with
[cl-mcp](https://github.com/g000001/cl-mcp) so the agent can treat the
live SBCL image — REPL, ASDF, packages, CLOS, conditions/restarts — as
a first-class observation surface, not just a file-and-log surface.

`cl-harness` is the upper layer (agent loop, tool policy, workflow,
verification, benchmark runner, transcript logging). `cl-mcp` is the
lower layer that exposes the Lisp runtime as MCP tools.

## Status

**v0.5.2**. Production resilience for the LLM transport layer:
typed `model-error :kind` classification end-to-end (8 reasons:
`:auth-failed`, `:http-server-error`, `:http-client-error`,
`:rate-limited`, `:transport-timeout`, `:transport-unavailable`,
`:malformed-response`, `:empty-content`), `:reason` slot on
`agent-state` / `develop-state` / `develop-result`, and a minimal
automatic retry (1 retry, no backoff, opt-out via `:retry-p nil`)
on the 3 most-clearly-transient kinds. `tools/chaos-probe.lisp`
manual real-LLM failure-mode runner. **397 unit tests** (+36 over
v0.5.1). See
[docs/release-notes/v0.5.2.md](docs/release-notes/v0.5.2.md).

v0.5.1 was a patch release on top of v0.5.0: dexador read-timeout
10s → 600s, Phase G/H/I prompt-side wiring, live-verified against
Qwen/Qwen3.6-35B-A3B. See
[docs/release-notes/v0.5.1.md](docs/release-notes/v0.5.1.md).

v0.5.0 added the **context-management refactor**: every observation
the agent loop gathers is now a typed record on a central
`develop-state`, and every LLM-facing prompt is built from a
phase-appropriate, compressed view of that state rather than from
raw transcript history. 10 phases (A → J) + 4 follow-ups. Public
CLI surface (`fix` / `bench` / `develop`) is unchanged; v0.5
additions are opt-in.

What's new since v0.4.0:

- **Central `develop-state`** (Phase A) — single mutable
  container threaded through one `develop` invocation. Phases B–J
  extend it with seven new ledger slots without changing the
  public construction shape.
- **Three new ledgers** (Phase B) — `source-fact` (every
  successful read tool with `mtime-at-read`), `patch-record`
  (every successful source-mutating tool with diff summary), and
  `failure-ledger` (active vs resolved partition over
  `failure-record`s, with auto-resolve-on-disappear). All
  populated automatically by the agent loop / orchestrator.
- **Phase-specific context views** (Phase C) — `make-context-view`
  builds a snapshot for `:planning` / `:exploration` /
  `:implementation` and a `context-view->string` formatter renders
  it for prompt insertion. The planner / explore / agent
  prompt-builders all consume the view when a `develop-state` is
  threaded; legacy ad-hoc string assembly remains for standalone
  callers.
- **Tool result compression + history compaction** (Phase D) —
  seven cl-mcp tools' outputs (read / search / introspect)
  truncate at 1500 chars with footer; `summarize-run-tests`
  caps at 5 failures + footer; `compact-history` runs in the
  agent loop's `step-turn` gated by `run-limits.max-context-tokens`
  (default 50000).
- **Structured markdown reporting** (Phase E) —
  `format-develop-state-report` emits a markdown report from
  develop-state's full ledger set; opt-in via the new
  `format-develop-report-structured` wrapper.
- **`[STALE]` annotation** (Phase F + G) — `:exploration`
  formatter renders source-facts and runtime-vocab-facts whose
  on-disk mtime exceeds the recorded baseline with a `[STALE]`
  prefix at render time. Annotate-not-filter — stale facts still
  render so the LLM stays aware.
- **Runtime vocabulary ledger** (Phase G) —
  `runtime-vocab-fact` records `code-find` / `code-describe` /
  `code-find-references` results so the LLM sees a structured
  view of what's been probed. `:planning` view shows a warm-start
  summary; `:exploration` view shows current-step probes.
- **REPL finding ledger** (Phase H) — structured `(hypothesis
  probe finding decision)` 4-tuple records from
  `{"type":"finding"}` action shape (new in the action parser).
  `promoted-to-source-p` flag flipped automatically by the
  orchestrator when a patch's diff matches the hypothesis. The
  `:implementation` view shows ONLY unpromoted findings under
  "Findings to implement (REPL-confirmed, not yet shipped)" —
  enforces the §3.6 rule "REPL success ≠ implemented" at the
  view layer.
- **Project summary** (Phase I) — `gather-project-summary` wraps
  the existing inventory builder into a structured record; the
  agent loop's post-patch hook flips `dirty-p` when patches touch
  `.asd` or `defpackage`. `:planning` view annotates the section
  header `## [STALE] Project summary` when dirty.
- **Subtask summaries + regression watch** (Phase J) —
  `summarise-step-result` derives a `subtask-summary` from
  develop-state's existing slots (no new state); the
  `:implementation` view renders prior `:passed` steps as
  compressed bullets and lists the most-recent N (default 3)
  resolved failures as regression watch.
- **4 follow-ups** — step-index threading across all 3 recorders
  (cross-phase fix from Phase H final review); Phase C wiring
  activated in production (orchestrator → planner-fn now passes
  `:develop-state state`); `%vocab-facts-from-tool-result` shape
  fix (code-describe path now records facts in production);
  `develop-step-result` extracted into `src/step-result.lisp` to
  break a load-time cycle structurally.

All v0.4.0 entry points keep their kwarg / flag shapes; v0.5.0
additions are opt-in via the existing `:develop-state` kwarg.

**357 unit tests** pass on a clean cl-mcp worker (v0.4.0: 184;
delta = +173 across 10 phases + 4 follow-ups); 12 fix/bench
fixtures + 7 greenfield develop fixtures. mallet clean. See
`docs/release-notes/v0.5.0.md` for the per-phase rationale and
`docs/context-management.md` for the requirements doc that
drove the refactor.

Single-trial pass-rate over the 12-task `fix` suite under
`:generic-mcp` (carried from v0.3): **11/12 (91.7%)** on
Qwen3.6-35B-A3B (SGLang); **10/12 (83.3%)** on
`llama-3.3-70b-versatile` (Groq). See
`docs/benchmarks/results-2026-05-06-qwen.md` for the post-anomaly-fix
v2 run; the four-cell ±20% variance still applies. Multi-model
numbers for the new 7-task `develop` suite get filled into
`docs/benchmarks/results-2026-05-06-develop.md` as runs land.

## Quick start

### Prerequisites

- SBCL with Quicklisp + Roswell (the project is at
  `~/.roswell/local-projects/cl-harness/`)
- `cl-mcp` installed where Roswell can find it (no separate server
  process required — `cl-harness` spawns its own `cl-mcp` subprocess
  via stdio by default; see "MCP transport selection" below)
- An OpenAI-compatible LLM endpoint (Groq, OpenAI, local llama.cpp,
  Ollama, LM Studio — anything that speaks `/v1/chat/completions`)

### Configure

Three environment variables (override per-call with kwargs if you
prefer):

```bash
export CL_HARNESS_LLM_BASE_URL=https://api.groq.com/openai/v1
export CL_HARNESS_LLM_API_KEY=sk-...
export CL_HARNESS_LLM_MODEL=llama-3.3-70b-versatile
# optional MCP overrides — see "MCP transport selection" below:
# export CL_HARNESS_MCP_URL=http://127.0.0.1:3001/mcp
# export CL_HARNESS_MCP_COMMAND="ros run -s cl-mcp -e (cl-mcp:run :transport :stdio)"
```

### MCP transport selection

By default, every `fix` / `bench` invocation spawns its own `cl-mcp`
subprocess and talks to it over stdio. The launch command is
`ros run -s cl-mcp -e "(cl-mcp:run :transport :stdio)"`, matching the
form Codex / Claude Code stdio configs use, and the subprocess is
torn down when the run finishes. This isolates the harness from any
other `cl-mcp` instance that might already be running on the host —
sharing a server with Claude Code would pin one of its workers per
`fix` call and exhaust the pool.

Resolution order, highest priority first:

1. `--mcp-url <url>` — talk to that HTTP endpoint
2. `$CL_HARNESS_MCP_URL` — same, from the environment
3. `--mcp-command "<argv>"` — shell-style launch command for stdio
4. `--mcp-stdio` flag — explicitly use the built-in stdio command
5. `$CL_HARNESS_MCP_COMMAND` — same as `--mcp-command`, from env
6. Built-in stdio default

Set `--mcp-url` or `$CL_HARNESS_MCP_URL` to opt back into talking to
a shared HTTP server.

### Build the shell binary (optional)

```bash
sbcl --non-interactive \
  --eval '(asdf:load-asd "/abs/path/to/cl-harness/cl-harness.asd")' \
  --eval '(ql:quickload :cl-harness)' \
  --eval '(asdf:make :cl-harness/binary)'
# produces ./cl-harness in the system source directory
```

The resulting binary is a self-contained SBCL image (~57 MB).

### Scaffold a new project

```bash
cl-harness scaffold --project-root /tmp/demo --system demo
# → demo.asd, src/main.lisp, tests/main-test.lisp, .gitignore
```

Emits a deterministic 4-file skeleton (package-inferred-system + rove
test discovery) ready for `cl-harness develop`. LLM-free. Refuses to
write if some skeleton files already exist; pass `--force` to overwrite
unconditionally (no backup).

### Fix one project — shell

```bash
cl-harness fix \
  --project-root /path/to/your/asdf/project \
  --system your-system \
  --test-system your-system/tests \
  --issue "Brief description of the failing test or symptom." \
  --condition generic-mcp
```

Exit code: 0 on `:passed`, 1 on `:give-up` / `:limit-exhausted` / `:dirty-only`, 2 on uncaught error.

`--dry-run` exercises the LLM end-to-end without invoking any MCP tool — useful for prompt iteration.

`cl-harness fix --help` and `cl-harness bench --help` list every flag.

### Fix one project — REPL

```lisp
(ql:quickload :cl-harness)
(cl-harness:fix
 :project-root "/path/to/your/asdf/project"
 :system "your-system"
 :test-system "your-system/tests"
 :issue "Brief description of the failing test or symptom."
 :condition :generic-mcp)         ; :file-only / :generic-mcp / :runtime-native
```

The agent reads the test, patches the source via cl-mcp's
structure-aware editing tools, auto-reverifies after every patch, and
on `:finish :fixed` does a clean-image reverify (pool-kill-worker +
fresh load) before declaring success. A one-paragraph report is
printed to stdout; the JSONL transcript path is included.

### Reasoning models

For OpenAI o1-style or `gpt-oss-*`-family models, two extra knobs are
exposed both on `make-openai-provider` and on the `fix` / `bench`
CLIs:

- `:reasoning-effort` — passed through as the `reasoning_effort` field
  (`"low"` / `"medium"` / `"high"`). Reasoning models route a chunk of
  their `max_tokens` budget through this knob; lower values leave more
  for visible content.
- `:extra-body` — a hash-table or alist of extra top-level fields
  merged into every `/v1/chat/completions` request body. Useful for
  endpoint-specific quirks; e.g. Groq's `openai/gpt-oss-20b` returns
  `400 "Tool choice is none, but model called a tool"` against our
  default request shape, and an explicit `tool_choice: "none"` plus
  empty `tools: []` plus `reasoning_effort: "low"` is one workaround
  to try:

  ```lisp
  (cl-harness:fix
   :project-root "..." :system "..." :test-system "..." :issue "..."
   :model "openai/gpt-oss-20b"
   :reasoning-effort "low"
   :extra-body '(("tool_choice" . "none")
                 ("tools" . #())))
  ```

  The values land at the request body's top level (not nested under
  any other key), and `:extra-body` keys override anything set above
  (model / messages / temperature / max_tokens / reasoning_effort) so
  it can intentionally replace, not just augment.

### Run the benchmark suite

```lisp
(cl-harness:bench
 :suite "/path/to/cl-harness/benchmarks/"
 :conditions '(:file-only :generic-mcp :runtime-native))
```

Each (task × condition) gets its own sandbox tmpdir copy of the
fixture, its own JSONL transcript, and an entry in the aggregated
markdown report.

### Develop a feature from a goal — `cl-harness develop`

`fix` and `bench` need a failing test pointed at them; `develop`
goes one level higher. It takes a free-form goal, asks an LLM
(the *planner*) to decompose it into a sequence of focused
sub-goals (each with its own author-generated rove test), then
drives each sub-goal through the existing fix loop with a
replan-on-failure policy.

`develop` assumes the project skeleton is already in place. If you are
starting from an empty directory, run `cl-harness scaffold` first (see
above).

```bash
cl-harness develop \
  --goal "Add a greet function under package demo that returns Hello, NAME!" \
  --project-root /path/to/your/asdf/project \
  --system demo \
  --test-system demo/tests \
  --test-file /path/to/your/asdf/project/tests/main-test.lisp \
  --mode mixed \
  --max-replans 3 \
  --max-impl-review-revisions 2
```

```lisp
(cl-harness:develop
 :goal "Add a greet function under package demo that returns Hello, NAME!"
 :project-root "/path/to/your/asdf/project"
 :system "demo"
 :test-system "demo/tests"
 :test-file "/path/to/your/asdf/project/tests/main-test.lisp"
 :mode :mixed
 :max-replans 3)
```

`--test-file` (or `:test-file`) is the rove file the planner-authored
deftest forms get appended to; it must already exist with a
defpackage that imports rove and the project's main package.
Greenfield-shaped starter fixtures live under `develop-benchmarks/`
(see that directory's README).

`--mode` (or `:mode`) selects the development style (v0.4):

- `mixed` (default) — let the planner decide per step.
- `top-down` — implement-first; every step's needs-exploration is
  forced to `:none`, no explore sub-agent runs.
- `bottom-up` — explore-first; `:none` / nil needs-exploration is
  promoted to `:lightweight` so each step gets a quick read-only
  REPL look at the existing surface before implementing.

Terminal status:
- `:passed` — all sub-goals' tests green
- `:limit-exhausted` (`limit-hit :max-replans`) — replan budget spent
- `:stuck` (`limit-hit :no-progress`) — replanner returned the same
  failing test twice in a row

When an LLM review is enabled (default), `develop` runs an
implementation-review gate after each step's verification passes. If
the review rejects, `develop` re-runs the same step with the review
feedback prepended to the issue string, up to
`--max-impl-review-revisions` rounds (default 2). On budget
exhaustion the step is marked `:review-rejected` and the outer
replan loop fires as usual.

Develop-level JSONL transcript at `--log-path` records
`develop-start / plan / step-start / step-end / abstraction-decision /
integration-check / develop-end`; each step's per-run-agent JSONL is
referenced via `transcript_path` so a single develop-level file is
enough to drill down to any sub-goal's detail. Two markdown report
formatters are available:

- `cl-harness:format-develop-report-markdown` (v0.4) — adopted /
  rejected / deferred abstractions, exploration notes, per-step
  status, integration-check section.
- `cl-harness:format-develop-report-structured` (v0.5, opt-in) —
  ledger-aware report from develop-state's full slot set: Goal /
  Plan / Completed steps / Patches applied / Active failures /
  Resolved failures / Integration issues / Source facts. Empty
  sections elide.

Per-ledger introspection is also possible via the develop-result's
`develop-state` (v0.5):

```lisp
(let* ((result (cl-harness:develop ...))
       (state  (cl-harness:develop-result-develop-state result)))
  (cl-harness/src/state:develop-state-source-facts state)
  (cl-harness/src/state:develop-state-patch-records state)
  (cl-harness/src/state:develop-state-failure-ledger state)
  (cl-harness/src/state:develop-state-runtime-vocabulary state)
  (cl-harness/src/state:develop-state-repl-findings state)
  (cl-harness/src/state:develop-state-project-summary state))
```

See `docs/notes/2026-05-06-planner-orchestrator.md` and
`docs/notes/2026-05-06-v0.4-development-harness.md` for the v0.4
design, and `docs/context-management.md` for the v0.5 refactor.

## Architecture

```
cl-harness/
├── src/
│   ├── abstraction.lisp        v0.4 P4: ADOPTED:/REJECTED:/DEFERRED: ledger
│   ├── action.lisp             LLM JSON action parser (tool_call / finish / finding)
│   ├── agent.lisp              turn-based loop, system prompt, finalize, recorders
│   ├── bench.lisp              fix benchmark runner (task, suite, trials, report)
│   ├── cli.lisp                fix / bench / develop programmatic entry points
│   ├── cli-main.lisp           clingon shell command for the binary build
│   ├── compact.lisp            chat-history compaction helper (v0.3 Tier 4 C-3)
│   ├── config.lisp             run-config + run-limits
│   ├── context-view.lisp       v0.5 C: per-phase context-view formatter
│   ├── develop-bench.lisp      v0.4 P7: greenfield benchmark loader / sandbox
│   ├── explore.lisp            v0.4 P3: read-only sub-agent; v0.5 H: persists findings
│   ├── failure-ledger.lisp     v0.5 B: active/resolved failure partition
│   ├── integration.lisp        v0.4 P5: static cross-package consistency check
│   ├── inventory.lisp          v0.4 P2: project vocabulary snapshot for planner
│   ├── log.lisp                JSONL transcript writer
│   ├── main.lisp               facade re-exports under nickname `cl-harness`
│   ├── mcp.lisp                JSON-RPC 2.0 client + transport abstraction
│   ├── mcp-stdio.lisp          stdio transport: spawns its own cl-mcp
│   ├── mcp-resolve.lisp        picks HTTP vs stdio from kwargs / env
│   ├── model.lisp              OpenAI-compatible chat client
│   ├── orchestrator.lisp       develop loop: plan / explore / execute / replan /
│   │                             mode-selector / integration / promotion-linkage
│   ├── patch-record.lisp       v0.5 B: source-mutating-tool record + verify-status
│   ├── planner.lisp            LLM-driven plan-step decomposer + mode nudge
│   ├── policy.lisp             tool allow-list per condition (incl. :explore)
│   ├── project-summary.lisp    v0.5 I: structured project-context record + dirty flag
│   ├── repl-finding.lisp       v0.5 H: (hypothesis probe finding decision) ledger
│   ├── report.lisp             v0.5 E: format-develop-state-report (markdown)
│   ├── runtime-vocabulary.lisp v0.5 G: runtime-vocab-fact ledger
│   ├── source-fact.lisp        v0.5 B: read-tool record + mtime-at-read
│   ├── state.lisp              v0.5 A: central develop-state class (7 ledger slots)
│   ├── step-result.lisp        v0.5 follow-up: develop-step-result class (extracted)
│   ├── subtask-summary.lisp    v0.5 J: derived subtask-summary + summarise-step-result
│   └── verify.lisp             incremental + clean verification
├── tests/                      rove unit tests, mostly stub-driven (no LLM)
├── benchmarks/                 12 deliberately broken mini ASDF projects (fix/bench)
├── develop-benchmarks/         7 greenfield fixtures for cl-harness:develop
├── prompts/                    system prompts (planner + REPL-driven dev)
└── docs/
    ├── cl-harness-prd.md
    ├── context-management.md   v0.5 requirements doc + §14 phase status table
    ├── notes/                  stdio / qwen / planner / v0.4-harness notes
    ├── plans/                  per-phase implementation plans (Phases A–J + follow-ups)
    ├── release-notes/          per-version release notes
    └── benchmarks/             per-run results
```

Conditions (PRD §8.5) gate which cl-mcp tools the LLM can invoke:

- `:file-only` — `fs-{read,write,list-directory}` + `load-system` /
  `run-tests`. Baseline: full-file rewrites only.
- `:generic-mcp` — adds `lisp-{read-file,patch-form,edit-form}` and
  `clgrep-search`. Structure-aware patching.
- `:runtime-native` — adds `repl-eval`, `inspect-object`,
  `code-{find,describe,find-references}`, `pool-kill-worker`. REPL
  probing as part of the diagnose-then-patch flow.

## Development

```lisp
;; from this repo
(ql:quickload :cl-harness/tests)
(asdf:test-system :cl-harness/tests)
;; or via the cl-mcp run-tests tool
;;   system="cl-harness/tests"
```

```bash
mallet src/*.lisp tests/*.lisp        # lint, must be clean before commit
```

`prompts/repl-driven-development.md` and
`prompts/common-lisp-expert.md` are the system prompts the project
itself is developed under (REPL-driven, TDD-first).

## Documentation

- `docs/cl-harness-prd.md` — full product requirements (Japanese).
- `docs/context-management.md` — v0.5 requirements doc; §14
  implementation-status table maps every section to the phase
  that delivered it.
- `docs/release-notes/v0.5.2.md` — v0.5.2 release (typed
  `model-error :kind` classification + minimal retry policy on
  the 3 most-clearly-transient kinds; `tools/chaos-probe.lisp`
  manual real-LLM failure-mode runner).
- `docs/release-notes/v0.5.1.md` — v0.5.1 patch release (dexador
  timeout fix + Phase G/H/I prompt enrichment, with live
  verification numbers from Qwen/Qwen3.6-35B-A3B).
- `docs/release-notes/v0.5.0.md` — v0.5 release notes (10 phases
  + 4 follow-ups, per-phase rationale, migration notes).
- `docs/release-notes/v0.4.0.md` — v0.4 release notes (development
  harness foundation: explore phase, abstraction ledger,
  integration check, mode selector, greenfield benchmark suite).
- `docs/plans/` — per-phase implementation plans (Phases A–J plus
  the four follow-ups).
- `docs/benchmarks/results-2026-05-05*.md` — Phase 5.0 / 5.1 / 5.2
  benchmark reports, including the variance demo and the explicit
  list of v0.2 follow-ups.

## License

MIT. See `LICENSE` if/when added; ASDF system declares `:license "MIT"`.
