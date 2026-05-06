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

**v0.3.0** (`2f4c6eb`). Builds on v0.2.0's credibility / usability /
methodology hardening with a planner+orchestrator stack on top of
the executor, plus three Tier 4 design-hardening refactors:

- **`cl-harness:develop`** — new entry point. Takes a free-form goal
  and a project root, asks an LLM to decompose into focused sub-goals
  (planner authors a rove test per sub-goal), and drives each through
  the existing fix loop with replan-on-failure. Terminal statuses:
  `:passed` / `:limit-exhausted` (`limit-hit :max-replans`) /
  `:stuck` (`limit-hit :no-progress`, set when the replanner returns
  the same failing test twice in a row).
- **Develop-level JSONL transcript** at `--log-path` carries
  `develop-start / plan / step-start / step-end / develop-end`.
  Per-step run-agent transcripts are referenced via `transcript_path`
  so a single develop file is enough to drill into any sub-goal.
- **Greenfield benchmark fixtures** under `develop-benchmarks/`
  (100-greet, 101-double) — empty-source + spec-test starter
  material. No runner yet; `develop-bench` is a v0.4 wish-list item.
- **Tier 4 C-2:** `summarize-tool-result` is now a defgeneric with
  per-tool eql-keyword methods; third-party tools register custom
  summarizers via `defmethod` without modifying agent.lisp.
- **Tier 4 C-1:** policy.lisp drops the three hand-curated tool
  lists in favour of a single rule table with `prefix*` glob
  matching. Future cl-mcp tools shipped under an existing family
  (e.g. `lisp-format-form`) auto-flow into the right policy without
  a cl-harness release. `make-tool-policy :available-tools` lets
  callers feed the live `tools/list` output for an exact intersection.
- **Tier 4 C-3:** new `compact-history` helper for chat-history
  size management. Keeps head + tail verbatim, replaces the middle
  with a digest message that records the elided count and approximate
  token cost. Auto-trigger inside the agent loop is a v0.4 task; the
  data-structure transformation is in place now.

All v0.2.0 invariants (clean-room ASDF scoping, clean-verify on
`:passed`, error_text in JSONL on tool failures, the seven run-limits
slots, stdio MCP transport by default) carry over unchanged.

125 unit tests pass on a clean worker; 12 fix/bench fixtures + 2
greenfield develop fixtures.

Single-trial pass-rate over the 12-task suite under `:generic-mcp`:
**11/12 (91.7%)** on Qwen3.6-35B-A3B (SGLang); **10/12 (83.3%)** on
`llama-3.3-70b-versatile` (Groq). See
`docs/benchmarks/results-2026-05-06-qwen.md` for the post-anomaly-fix
v2 run; the four-cell ±20% variance still applies.

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
  --max-replans 3
```

```lisp
(cl-harness:develop
 :goal "Add a greet function under package demo that returns Hello, NAME!"
 :project-root "/path/to/your/asdf/project"
 :system "demo"
 :test-system "demo/tests"
 :test-file "/path/to/your/asdf/project/tests/main-test.lisp"
 :max-replans 3)
```

`--test-file` (or `:test-file`) is the rove file the planner-authored
deftest forms get appended to; it must already exist with a
defpackage that imports rove and the project's main package.
Greenfield-shaped starter fixtures live under `develop-benchmarks/`
(see that directory's README).

Terminal status:
- `:passed` — all sub-goals' tests green
- `:limit-exhausted` (`limit-hit :max-replans`) — replan budget spent
- `:stuck` (`limit-hit :no-progress`) — replanner returned the same
  failing test twice in a row

Develop-level JSONL transcript at `--log-path` records
`develop-start / plan / step-start / step-end / develop-end`; each
step's per-run-agent JSONL is referenced via `transcript_path` so a
single develop-level file is enough to drill down to any sub-goal's
detail. See `docs/notes/2026-05-06-planner-orchestrator.md` for the
design.

## Architecture

```
cl-harness/
├── src/
│   ├── action.lisp        LLM JSON action parser (tool_call / finish)
│   ├── agent.lisp         turn-based loop, system prompt, finalize
│   ├── bench.lisp         benchmark runner (task, suite, trials, report)
│   ├── cli.lisp           fix / bench / develop programmatic entry points
│   ├── cli-main.lisp      clingon shell command for the binary build
│   ├── config.lisp        run-config + run-limits
│   ├── log.lisp           JSONL transcript writer
│   ├── main.lisp          facade re-exports under nickname `cl-harness`
│   ├── mcp.lisp           JSON-RPC 2.0 client + transport abstraction
│   ├── mcp-stdio.lisp     stdio transport: spawns its own cl-mcp
│   ├── mcp-resolve.lisp   picks HTTP vs stdio from kwargs / env
│   ├── model.lisp         OpenAI-compatible chat client
│   ├── orchestrator.lisp  develop loop: plan-execute-replan-stuck-detect
│   ├── planner.lisp       LLM-driven plan-step decomposer
│   ├── policy.lisp        tool allow-list per condition
│   └── verify.lisp        incremental + clean verification
├── tests/                 rove unit tests, mostly stub-driven (no LLM)
├── benchmarks/            12 deliberately broken mini ASDF projects (fix/bench)
├── develop-benchmarks/    greenfield fixtures (empty source + spec) for develop
├── prompts/               system prompts (planner + REPL-driven dev)
└── docs/
    ├── cl-harness-prd.md
    ├── notes/             stdio-transport / qwen-smoke / planner notes
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
