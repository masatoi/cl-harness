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
- A running cl-mcp HTTP server (default URL
  `http://127.0.0.1:3001/mcp`)
- An OpenAI-compatible LLM endpoint (Groq, OpenAI, local llama.cpp,
  Ollama, LM Studio — anything that speaks `/v1/chat/completions`)

### Configure

Three environment variables (override per-call with kwargs if you
prefer):

```bash
export CL_HARNESS_LLM_BASE_URL=https://api.groq.com/openai/v1
export CL_HARNESS_LLM_API_KEY=sk-...
export CL_HARNESS_LLM_MODEL=llama-3.3-70b-versatile
# optional:
export CL_HARNESS_MCP_URL=http://127.0.0.1:3001/mcp
```

### Fix one project

From a SBCL REPL:

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
│   ├── action.lisp     LLM JSON action parser (tool_call / finish)
│   ├── agent.lisp      turn-based loop, system prompt, finalize
│   ├── bench.lisp      benchmark runner (task, suite, trials, report)
│   ├── cli.lisp        fix / bench entry points
│   ├── config.lisp     run-config + run-limits
│   ├── log.lisp        JSONL transcript writer
│   ├── main.lisp       facade re-exports under nickname `cl-harness`
│   ├── mcp.lisp        JSON-RPC 2.0 over HTTP client for cl-mcp
│   ├── model.lisp      OpenAI-compatible chat client
│   ├── policy.lisp     tool allow-list per condition
│   └── verify.lisp     incremental + clean verification
├── tests/              rove unit tests, mostly stub-driven (no LLM)
├── benchmarks/         10 deliberately broken mini ASDF projects
└── docs/
    ├── cl-harness-prd.md
    └── benchmarks/results-2026-05-05*.md
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
