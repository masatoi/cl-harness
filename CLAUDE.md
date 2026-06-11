# CLAUDE.md

## Agent Guidelines

@prompts/repl-driven-development.md
@prompts/common-lisp-expert.md

## Project Overview

`cl-harness` is a runtime-native coding agent harness for Common Lisp projects.
It pairs an LLM provider with `cl-mcp` (the Common Lisp MCP server) so that an
agent loop can treat the live SBCL image — REPL, ASDF, packages, CLOS, macros,
conditions/restarts — as a first-class observation surface, instead of a
file-and-log surface.

`cl-harness` itself is the upper layer (agent loop, tool policy, workflow,
verification, benchmark runner, transcript logging). `cl-mcp` is the lower
layer that exposes Common Lisp runtime operations as MCP tools.

See `docs/cl-harness-prd.md` for the full PRD: scope, MVP cut, system layout,
benchmark plan, and roadmap. The project is currently at Phase 0 (skeleton):
no ASDF system, no `src/` yet — only docs and prompts.

## Development Workflow

`cl-harness` is developed *with* `cl-mcp`, not as part of it. The `.mcp.json`
in this repo connects to a running `cl-mcp` HTTP transport, and Claude Code
should drive Lisp work through cl-mcp tools rather than shell utilities.

- **Lisp code operations** (search, read, edit, eval): use cl-mcp tools
  (`clgrep-search`, `lisp-read-file`, `lisp-edit-form`, `lisp-patch-form`,
  `repl-eval`, `code-find`, etc.) per `prompts/repl-driven-development.md`.
- **Shell commands**: only for `git`, `mallet` (lint), test runners
  (`rove` fallback), and commands the user explicitly asks for. Never use
  `grep`/`sed`/`cat` against Lisp source.
- **First action of a session**: call `fs-set-project-root` on this directory
  before any file operation.
- **Persistence rule**: REPL-defined state is transient and lives only in the
  cl-mcp worker. Anything that should survive must be written to a source file
  via `lisp-edit-form` / `lisp-patch-form`.

## Testing & Linting

Once the ASDF system lands, run tests via the `run-tests` tool against the
project's test system (e.g. `cl-harness/tests`). Use `repl-eval` with
`(rove:run-test '...)` only as a single-test fallback.

Stale-image fallback (when worker state gets confused): run `rove cl-harness.asd`
from a clean shell, or call `pool-kill-worker` and reload.

**Pre-PR**: `(asdf:compile-system :cl-harness :force t)` to surface warnings
across all files, then run the full test suite.

**Lint** (required before commit, once Lisp sources exist):
```bash
mallet src/*.lisp
```

## Code Style

- Follow the Google Common Lisp Style Guide.
- 2-space indent, <=100 columns, no tabs.
- Blank line between top-level forms.
- Lower-case lisp-case: `my-function`, `*special*`, `+constant+`, `something-p`.
- Docstrings required for public functions/classes.
- Each file starts with `(in-package ...)`.
- **No `:local-nicknames` in `defpackage`.** Package-inferred-system rewrites
  `defpackage` as `uiop:define-package`, and the UIOP shipped with this
  project's ASDF (3.3.1) does not list `:local-nicknames` in its option
  ECASE, so loading fails with `":LOCAL-NICKNAMES fell through ECASE"`.
  Use `:import-from` + `:export` (which share symbol identity) or
  fully-qualified package names (`local-time:now`, `yason:encode`) instead.

## Repository Structure

```
cl-harness.asd    ASDF system (package-inferred-system) + tests system
src/              Implementation (Phase 0: main, config, log, cli)
next/             Greenfield redesign (system cl-harness-next; spec 2026-06-11)
tests/            Rove test suites (mirrored naming: *-test.lisp)
docs/             PRD and design notes (cl-harness-prd.md, ...)
prompts/          System prompts for AI agents
.claude/          Project-local Claude Code skills, commands, settings
.mcp.json         MCP server connection (cl-mcp over HTTP)
```

Each `src/<name>.lisp` defines package `cl-harness/src/<name>`; the public
facade `cl-harness/src/main` (nickname `cl-harness`) re-exports user-facing
symbols via `:import-from` + `:export`. Add a new file by extending
`cl-harness.asd`'s `:depends-on` chain.

Planned additions per PRD §10 / §16: `src/agent`, `src/mcp`, `src/model`,
`src/workflow/*`, `src/patch`, `src/verify`, `src/bench`, plus `benchmarks/`
and `scripts/`. Add them as the corresponding phase ships, not before.
