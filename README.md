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

Public CLI surface (`fix` / `bench` / `develop` / `scaffold`) is
stable. Versioned changes live in `docs/release-notes/`; per-run
benchmark effect measurements live in `docs/benchmarks/`.

### next/ — autonomous-harness redesign (experimental)

For a zero-to-running, end-to-end walkthrough of driving an autonomous
fix mission against your own project with `cl-harness-next`, see
[`next/README.md`](next/README.md).

`cl-harness-next` (sources under `next/`) is the greenfield redesign
substrate from
`docs/superpowers/specs/2026-06-11-autonomous-harness-redesign-design.md`.
SP1 ships the L0 event log (JSONL event sourcing) and policy pack
(versioned, fingerprinted prompt/config bundles); SP2 adds the L1
environment — cl-mcp wrapped as a policy-restricted observation/action
space (stdio subprocess per run) whose actions and observations are
recorded into the event log; SP3 adds the L2 world model (projections
with staleness and derived clean-verify state) and the token-budgeted
context compiler; SP4 adds the L2 oracles
(verification through the environment, AST invariants, pack-profiled
LLM review with injected judge) and the governor with
condition/restart interventions; SP5a adds LLM connectivity
(OpenAI-compatible provider, action parser, judge bridge); SP5b adds
the L3 kernel (observe→decide→act→record with swappable control
policies) and the scripted fix policy — the first dial level; SP6
completes the dial (guided agenda + self-directed + adaptive demotion
on stalls); SP7 adds the L4 mission layer (queue, suspend/resume from
the log, async human escalation); SP8 closes the loop with L5
self-improvement (transcript mining, one-mutation pack variants,
paired sign-test promotion with an audit trail, human dossiers for
code changes). It does not affect the `cl-harness` CLI.

Post-SP8, the stack was hardened by a day of live-fire runs against a
real cl-mcp subprocess and a real LLM (see
`docs/notes/2026-06-13-live-fire-experiments.md`): the L5 loop
promoted one pack and rejected a plausible-but-regressive one on
real trials; miner v2 grew the diagnose-layer failure vocabulary
(error samples, give-up/park reasons) that improve-once now feeds the
proposer automatically; the verification oracle gained `:clear-fasls`
(with a companion cl-mcp fix — ASDF `:force t` never rebuilt
package-inferred dependency subsystems); parked/aborted runs now log
terminal events; the context view learned to carry observation
content (read excerpts, failure values, tool errors) with staleness
supersession; and the governor detects identical-action repetition —
which the adaptive dial converts into a demotion, turning a guided
agent that can fix but never declares completion into a finished,
clean-verified mission (the first live data point for the
capability-adaptive dial hypothesis).

A follow-on benchmark campaign (see
`docs/notes/2026-06-16-dial-ladder-bottlenecks.md`) measured the dial
ladder against a weak model (Qwen3.6) on a 12-fixture fix suite and
found that success rate *inverts* with agency —
`template-fix` 9/9 (body bugs) > `scripted` 8/12 > `guided` 1/12 —
because the limit is the harness's two layers, not the model's
reasoning: constructing valid tool calls, then recognising completion.
The model emitted correct fixes at every dial; a higher dial just hands
it more tool calls to get wrong, and more chances to overshoot a green
it can't declare done. Repairing both (argument coercion for the first;
a harness "green-stop" for the second) brings `guided` to 8/12 —
parity with `scripted`. The green-stop half shipped: the guided dial
now finishes at the first green via the mandatory clean gate by default
(`:green-stop`, opt-out via `CLH_GREEN_STOP=0`). Two false-failure
harness bugs had to be removed first — schema noise feeding optional-arg
hallucination, and benchmark sandboxes shadowed on ASDF's registry (the
latter fixed in cl-mcp).

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

Three environment variables (override per-call with kwargs):

```bash
export CL_HARNESS_LLM_BASE_URL=https://api.groq.com/openai/v1
export CL_HARNESS_LLM_API_KEY=sk-...
export CL_HARNESS_LLM_MODEL=llama-3.3-70b-versatile
# optional MCP overrides — see "MCP transport selection" below:
# export CL_HARNESS_MCP_URL=http://127.0.0.1:3001/mcp
# export CL_HARNESS_MCP_COMMAND="ros run -s cl-mcp -e (cl-mcp:run :transport :stdio)"
```

### MCP transport selection

By default, every `fix` / `bench` / `develop` invocation spawns its
own `cl-mcp` subprocess and talks to it over stdio
(`ros run -s cl-mcp -e "(cl-mcp:run :transport :stdio)"`). The
subprocess is torn down when the run finishes, isolating the harness
from any other `cl-mcp` instance on the host.

Resolution order, highest priority first:

1. `--mcp-url <url>` — talk to that HTTP endpoint
2. `$CL_HARNESS_MCP_URL` — same, from the environment
3. `--mcp-command "<argv>"` — shell-style launch command for stdio
4. `--mcp-stdio` flag — explicitly use the built-in stdio command
5. `$CL_HARNESS_MCP_COMMAND` — same as `--mcp-command`, from env
6. Built-in stdio default

### Build the shell binary (optional)

```bash
sbcl --non-interactive \
  --eval '(asdf:load-asd "/abs/path/to/cl-harness/cl-harness.asd")' \
  --eval '(ql:quickload :cl-harness)' \
  --eval '(asdf:make :cl-harness/binary)'
# produces ./cl-harness in the system source directory (~57 MB)
```

### Scaffold a new project

```bash
cl-harness scaffold --project-root /tmp/demo --system demo
# → demo.asd, src/main.lisp, tests/main-test.lisp, .gitignore
```

Deterministic 4-file skeleton (package-inferred-system + rove test
discovery) ready for `cl-harness develop`. LLM-free. Refuses to write
if some skeleton files already exist; pass `--force` to overwrite
unconditionally.

### Fix one project

```bash
cl-harness fix \
  --project-root /path/to/your/asdf/project \
  --system your-system \
  --test-system your-system/tests \
  --issue "Brief description of the failing test or symptom." \
  --condition generic-mcp
```

Exit code: 0 on `:passed`, 1 on `:give-up` / `:limit-exhausted` /
`:dirty-only`, 2 on uncaught error. `--dry-run` exercises the LLM
without invoking any MCP tool — useful for prompt iteration.

REPL equivalent:

```lisp
(cl-harness:fix
 :project-root "/path/to/your/asdf/project"
 :system "your-system"
 :test-system "your-system/tests"
 :issue "Brief description of the failing test or symptom."
 :condition :generic-mcp)  ; :file-only / :generic-mcp / :runtime-native
```

The agent reads the test, patches the source via cl-mcp's
structure-aware editing tools, auto-reverifies after every patch, and
on `:finish :fixed` does a clean-image reverify (pool-kill-worker +
fresh load) before declaring success.

### Run the benchmark suite

```lisp
(cl-harness:bench
 :suite "/path/to/cl-harness/benchmarks/"
 :conditions '(:file-only :generic-mcp :runtime-native))
```

Each (task × condition) gets its own sandbox tmpdir copy of the
fixture, its own JSONL transcript, and an entry in the aggregated
markdown report.

### Develop a feature from a goal

`fix` and `bench` need a failing test pointed at them; `develop` goes
one level higher. It takes a free-form goal, asks an LLM (the
*planner*) to decompose it into a sequence of focused sub-goals
(each with its own author-generated rove test), then drives each
sub-goal through the fix loop with a replan-on-failure policy.

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

`develop` assumes the project skeleton is already in place. If you
are starting from an empty directory, run `cl-harness scaffold` first.
`--test-file` is the rove file the planner-authored deftest forms get
appended to; it must already exist with a defpackage that imports
rove and the project's main package.

`--mode` selects the development style:

- `mixed` (default) — let the planner decide per step.
- `top-down` — implement-first; every step's `needs-exploration` is
  forced to `:none`, no explore sub-agent runs.
- `bottom-up` — explore-first; promotes `:none` / nil to
  `:lightweight` so each step gets a quick read-only REPL look
  before implementing.

Terminal status:

- `:passed` — all sub-goals' tests green
- `:limit-exhausted` (`limit-hit :max-replans`) — replan budget spent
- `:stuck` (`limit-hit :no-progress`) — replanner returned the same
  failing test twice in a row

When LLM review is enabled (default for the CLI), `develop` runs an
implementation-review gate after each step's verification passes. On
rejection, the same step is rerun with the review feedback prepended
to the issue string, up to `--max-impl-review-revisions` rounds
(default 2).

Greenfield-shaped starter fixtures live under `develop-benchmarks/`.

### Reasoning models

For OpenAI o1-style or `gpt-oss-*`-family models, two extra knobs
are exposed on both `make-openai-provider` and the CLIs:

- `:reasoning-effort` — `"low"` / `"medium"` / `"high"`, passed as
  the `reasoning_effort` request field.
- `:extra-body` — hash-table / alist of extra top-level fields
  merged into every `/v1/chat/completions` body. Useful for
  endpoint-specific quirks (e.g. Groq's `gpt-oss-20b` needing
  explicit `tool_choice: "none"`).

### Transcript logging

Each run writes a JSONL transcript (default under
`(uiop:temporary-directory)`; override with `--log-path`). Events
include `:verify` (per-test failures), `:tool-result` (summarized
~1500 chars), and **opt-in** `:llm-request` (full chat history;
warning emitted on activation because payload may contain source).

`develop` adds a develop-level JSONL with
`develop-start / plan / step-start / step-end / abstraction-decision /
integration-check / develop-end`; per-step `run-agent` JSONLs are
referenced via `transcript_path`.

Markdown report formatters:

- `cl-harness:format-develop-report-markdown` (v0.4) — adopted /
  rejected / deferred abstractions, exploration notes, per-step
  status, integration-check.
- `cl-harness:format-develop-report-structured` (v0.5, opt-in) —
  ledger-aware report from develop-state's full slot set.

Per-ledger introspection via the develop-result's `develop-state`
(v0.5):

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

## Conditions

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
;; or via the cl-mcp run-tests tool: system="cl-harness/tests"
```

```bash
mallet src/*.lisp tests/*.lisp        # lint, must be clean before commit
```

`prompts/repl-driven-development.md` and
`prompts/common-lisp-expert.md` are the system prompts this project
is itself developed under (REPL-driven, TDD-first).

## Documentation

- `docs/cl-harness-prd.md` — full product requirements (Japanese).
- `docs/context-management.md` — v0.5 requirements doc.
- `docs/release-notes/` — per-version release notes (v0.4 / v0.5.x).
- `docs/notes/` — design notes (planner-orchestrator, v0.4-harness,
  context-management refactor, DR-2026-05-27 test-change architecture).
- `docs/plans/` — per-phase implementation plans.
- `docs/benchmarks/` — per-run results, including Finding 6+7 N=10
  sweeps on 100-greet / 102-counter-class / 104-cache-simple.

## License

MIT. See `LICENSE` if/when added; ASDF system declares `:license "MIT"`.
