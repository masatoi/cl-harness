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

**v0.1.0-mvp** (`a410edc`). The PRD §17 capability checklist is closed:

- `fix` and `bench` CLIs work
- cl-mcp HTTP + OpenAI-compatible Chat Completions wired up
- 56 unit tests pass on a clean worker
- 10 benchmark fixtures
- 3-condition runner (`:file-only` / `:generic-mcp` / `:runtime-native`)
- per-(task × condition) JSONL transcripts and an aggregated report

Single-trial pass-rate over the 10-task suite under `:generic-mcp` on
`llama-3.3-70b-versatile` (Groq): **10 / 10**. Variance is large enough
across runs that you should not quote that as a stable performance
metric — see `docs/benchmarks/results-2026-05-05-2.md`.

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

## Architecture

```
cl-harness/
├── src/
│   ├── action.lisp       LLM JSON action parser (tool_call / finish)
│   ├── agent.lisp        turn-based loop, system prompt, finalize
│   ├── bench.lisp        benchmark runner (task, suite, trials, report)
│   ├── cli.lisp          fix / bench entry points
│   ├── cli-main.lisp     clingon shell command for the binary build
│   ├── config.lisp       run-config + run-limits
│   ├── log.lisp          JSONL transcript writer
│   ├── main.lisp         facade re-exports under nickname `cl-harness`
│   ├── mcp.lisp          JSON-RPC 2.0 client + transport abstraction
│   ├── mcp-stdio.lisp    stdio transport: spawns its own cl-mcp
│   ├── mcp-resolve.lisp  picks HTTP vs stdio from kwargs / env
│   ├── model.lisp        OpenAI-compatible chat client
│   ├── policy.lisp       tool allow-list per condition
│   └── verify.lisp       incremental + clean verification
├── tests/                rove unit tests, mostly stub-driven (no LLM)
├── benchmarks/           deliberately broken mini ASDF projects
└── docs/
    ├── cl-harness-prd.md
    ├── notes/            stdio-transport / qwen-smoke / v0.2 notes
    └── benchmarks/       per-run results
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
