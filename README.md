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

**v0.4.0**. Lifts cl-harness from "TDD-Green helper" to a
runtime-native development harness: enriched plan-step schema,
project inventory injection, a read-only explore phase, an
abstraction-decision ledger, a static integration check, a
top-down/bottom-up/mixed mode selector, and a 7-task greenfield
benchmark suite. Builds on the v0.3.0 planner+orchestrator stack
without breaking any existing `fix` / `bench` invariants.

What's new since v0.3.0:

- **Enriched plan-step schema** (Phase 1) — plan-step now carries
  `purpose`, `acceptance-criteria`, `investigation-targets`
  (`{kind, name, intent}`), `risks`, and `needs-exploration`
  (`:none` / `:lightweight` / `:deep`). All slots are optional so
  v0.3 planner responses keep parsing.
- **Project inventory injection** (Phase 2) — before each
  `plan-development` call, the harness gathers a 5KB read-only
  snapshot of `.asd` / `src/*.lisp` / `tests/*.lisp` heads and
  prepends it to the planner's user prompt so the LLM builds on
  existing vocabulary instead of inventing parallel structures.
- **Explore phase** (Phase 3) — when a plan-step's
  `needs-exploration` is `:lightweight` or `:deep`, an explore
  sub-agent runs first under a new `:explore` tool policy
  (read-only: `repl-eval`, `code-find`, `code-describe`,
  `inspect-object`, `lisp-read-file`; all write tools denied). Its
  one-paragraph memo is prepended to the implement step's issue.
- **Abstraction ledger** (Phase 4) — explore memos are parsed for
  `ADOPTED:` / `REJECTED:` / `DEFERRED:` markers (em-dash, en-dash,
  colon, hyphen separators all accepted) and aggregated on
  `develop-result-abstraction-ledger`. The new
  `format-develop-report-markdown` renders adopted / rejected /
  deferred sections, exploration notes, and per-step status.
- **Integration check** (Phase 5) — after every step reaches
  `:passed`, a static cross-package consistency check parses every
  `.lisp` under `project-root`, builds a defpackage graph, and
  flags `:unknown-package` and `:unexported-symbol` issues that
  per-step verify alone cannot detect. Out-of-project deps
  (`alexandria`, `rove`, ...) are skipped via a same-prefix
  heuristic.
- **Mode selector** (Phase 6) — `:mode` kwarg on
  `cl-harness:develop` (and `--mode` on the shell CLI):
  `:top-down` forces every step's needs-exploration to `:none`,
  `:bottom-up` promotes `:none` / `nil` to `:lightweight`,
  `:mixed` (default) leaves the planner's choice alone. The
  planner also sees a `Mode: ...` line in its user prompt so the
  LLM aligns its plan up-front; the orchestrator enforces the mode
  mechanically as the second line of defence.
- **Greenfield benchmark suite** (Phase 7) — `develop-benchmarks/`
  grows from 2 to 7 fixtures (`102-counter-class`, `103-fizz-buzz`,
  `104-cache-simple`, `105-validate-email`, `106-format-currency`).
  New `develop-bench` loader (`load-develop-task`,
  `discover-develop-tasks`, `prepare-develop-task-sandbox`) lets
  multi-model bench scripts copy fixtures to clean tmpdirs without
  polluting the in-repo seed.
- **Greenfield executor prompt补强** (Phase 0, shipped in v0.3.1) —
  `lisp-edit-form` `form_name` examples for `defpackage` /
  `in-package` / `defun` / `defmethod`, and an explicit fallback
  to `fs-write-file` after two consecutive `form_name` failures.
  Required for greenfield work to converge on Qwen3-class models.

All v0.3.0 entry points (`cl-harness:fix`, `cl-harness:bench`,
`cl-harness:develop`, the shell binary) keep their kwarg / flag
shapes; v0.4.0 additions are opt-in.

184 unit tests pass on a clean worker; 12 fix/bench fixtures + 7
greenfield develop fixtures. mallet clean.

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

```bash
cl-harness develop \
  --goal "Add a greet function under package demo that returns Hello, NAME!" \
  --project-root /path/to/your/asdf/project \
  --system demo \
  --test-system demo/tests \
  --test-file /path/to/your/asdf/project/tests/main-test.lisp \
  --mode mixed \
  --max-replans 3
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

Develop-level JSONL transcript at `--log-path` records
`develop-start / plan / step-start / step-end / abstraction-decision /
integration-check / develop-end`; each step's per-run-agent JSONL is
referenced via `transcript_path` so a single develop-level file is
enough to drill down to any sub-goal's detail. The structured
markdown report is available via `cl-harness:format-develop-report-markdown`
and includes adopted / rejected / deferred abstractions
(`:abstraction-decision` events), exploration notes, per-step
status, and the integration-check section. See
`docs/notes/2026-05-06-planner-orchestrator.md` and
`docs/notes/2026-05-06-v0.4-development-harness.md` for the design.

## Architecture

```
cl-harness/
├── src/
│   ├── abstraction.lisp   v0.4 P4: ADOPTED:/REJECTED:/DEFERRED: ledger
│   ├── action.lisp        LLM JSON action parser (tool_call / finish)
│   ├── agent.lisp         turn-based loop, system prompt, finalize
│   ├── bench.lisp         fix benchmark runner (task, suite, trials, report)
│   ├── cli.lisp           fix / bench / develop programmatic entry points
│   ├── cli-main.lisp      clingon shell command for the binary build
│   ├── compact.lisp       chat-history compaction helper (v0.3 Tier 4 C-3)
│   ├── config.lisp        run-config + run-limits
│   ├── develop-bench.lisp v0.4 P7: greenfield benchmark loader / sandbox
│   ├── explore.lisp       v0.4 P3: read-only sub-agent + memo synthesis
│   ├── integration.lisp   v0.4 P5: static cross-package consistency check
│   ├── inventory.lisp     v0.4 P2: project vocabulary snapshot for planner
│   ├── log.lisp           JSONL transcript writer
│   ├── main.lisp          facade re-exports under nickname `cl-harness`
│   ├── mcp.lisp           JSON-RPC 2.0 client + transport abstraction
│   ├── mcp-stdio.lisp     stdio transport: spawns its own cl-mcp
│   ├── mcp-resolve.lisp   picks HTTP vs stdio from kwargs / env
│   ├── model.lisp         OpenAI-compatible chat client
│   ├── orchestrator.lisp  develop loop: plan / explore / execute /
│   │                        replan / mode-selector / integration check
│   ├── planner.lisp       LLM-driven plan-step decomposer + mode nudge
│   ├── policy.lisp        tool allow-list per condition (incl. :explore)
│   └── verify.lisp        incremental + clean verification
├── tests/                 rove unit tests, mostly stub-driven (no LLM)
├── benchmarks/            12 deliberately broken mini ASDF projects (fix/bench)
├── develop-benchmarks/    7 greenfield fixtures for cl-harness:develop
├── prompts/               system prompts (planner + REPL-driven dev)
└── docs/
    ├── cl-harness-prd.md
    ├── notes/             stdio / qwen / planner / v0.4-harness notes
    └── benchmarks/        per-run results
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
- `docs/benchmarks/results-2026-05-05*.md` — Phase 5.0 / 5.1 / 5.2
  benchmark reports, including the variance demo and the explicit
  list of v0.2 follow-ups.

## License

MIT. See `LICENSE` if/when added; ASDF system declares `:license "MIT"`.
