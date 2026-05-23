---
description: Run cl-harness develop-bench on one or more fixtures with full G1/G2/G3 logging, then analyze the JSONL transcripts and produce 3-axis improvement proposals (bench target, log content, cl-harness implementation). Append findings to docs/improvement-backlog.md and write a new docs/benchmarks/results-<DATE>-*.md. Use when iterating on cl-harness reliability via the bench → log → propose cycle.
allowed-tools: Bash, Read, Write, Edit, AskUserQuestion, mcp__cl-mcp__fs-set-project-root, mcp__cl-mcp__repl-eval, mcp__cl-mcp__fs-read-file, mcp__cl-mcp__fs-list-directory
---

# bench-cycle (cl-harness)

Run develop-bench on chosen fixtures, analyze JSONL transcripts with G1+G2+G3
logging, propose improvements across 3 axes, append findings to the
project backlog.

## Arguments

`$ARGUMENTS` is a single whitespace-separated string. Parse left to right:

- Tokens NOT starting with `--` are **fixture IDs** (e.g. `102-counter-class`).
  At least one required.
- `--max-replans N` consumes the next token as integer. Default 3.
- `--no-log-llm-requests` is a flag (no argument). Default G3 is ON.

Examples:
- `/bench-cycle 102-counter-class`
- `/bench-cycle 102-counter-class 104-cache-simple --max-replans 1`
- `/bench-cycle 103-fizz-buzz --no-log-llm-requests`

## Instructions

Execute the 5 phases below in order. Do not skip review checkpoints. Do not
spawn subagents; this skill runs entirely in the orchestrating agent.

### Phase 1: bench plan

1. **Set project root**: `mcp__cl-mcp__fs-set-project-root` with
   `/home/wiz/.roswell/local-projects/cl-harness`.

2. **Parse arguments**: split `$ARGUMENTS` by whitespace, separate fixture
   IDs from flags as described above. If fewer than 1 fixture ID, print
   usage and exit:
   ```
   Usage: /bench-cycle <fixture-id> [fixture-id...] [--max-replans N] [--no-log-llm-requests]
   Available fixture IDs:
     $(ls develop-benchmarks/ — only entries with develop-task.json)
   ```

3. **Validate fixture IDs**: For each ID, check
   `develop-benchmarks/<ID>/develop-task.json` exists via
   `mcp__cl-mcp__fs-list-directory` on `develop-benchmarks/<ID>/`. Report
   unknown IDs and exit if any.

4. **Validate env**: Use `mcp__cl-mcp__repl-eval` to confirm:
   - `(uiop:getenv "CL_HARNESS_LLM_BASE_URL")` non-empty
   - `(uiop:getenv "CL_HARNESS_LLM_API_KEY")` non-empty
   - `(uiop:getenv "CL_HARNESS_LLM_MODEL")` non-empty

   If any missing, print:
   ```
   Missing required env vars:
     - CL_HARNESS_LLM_BASE_URL
     - CL_HARNESS_LLM_API_KEY
     - CL_HARNESS_LLM_MODEL
   Export them before running this skill.
   ```
   and exit.

5. **Generate driver script**: Read
   `.claude/skills/bench-cycle/templates/driver.lisp.template`. Substitute:
   - `<TIMESTAMP>`: current time in `YYYY-MM-DDTHH:MM:SS` form (use any
     available means — `date -u +%FT%TZ` via Bash works)
   - `<FIXTURES>`: comma-separated fixture IDs
   - `<LOG_PATH_STEM>`: `/tmp/bench-cycle-<EPOCH>` where `<EPOCH>` is
     `date +%s` from Bash
   - `<DEVELOP_BENCHMARKS_DIR>`: `/home/wiz/.roswell/local-projects/cl-harness/develop-benchmarks`
   - `<LOG_LLM_REQUESTS>`: `t` or `nil` per `--no-log-llm-requests` flag
   - `<MAX_REPLANS>`: integer from `--max-replans` or 3
   - `<FIXTURE_CALLS>`: space-separated `(run-fixture "<id>")` forms

   Write the substituted text to `/tmp/bench-cycle-<EPOCH>.lisp` via `Write`.

6. **Report opening summary** to the user:
   ```
   bench-cycle starting:
     fixtures: <list>
     driver:   /tmp/bench-cycle-<EPOCH>.lisp
     log stem: /tmp/bench-cycle-<EPOCH>
     settings: max-replans=<N>, log-llm-requests=<t/nil>
   ```

### Phase 2: bench run

1. **Launch** the driver in background via `Bash` with
   `run_in_background=true`:
   ```bash
   CL_HARNESS_LLM_BASE_URL=$(repl-eval-from-env-or-pre-confirmed-value) \
   CL_HARNESS_LLM_API_KEY=$(repl-eval-from-env-or-pre-confirmed-value) \
   CL_HARNESS_LLM_MODEL=$(repl-eval-from-env-or-pre-confirmed-value) \
   ros run -- --non-interactive --load /tmp/bench-cycle-<EPOCH>.lisp \
     > /tmp/bench-cycle-<EPOCH>.log 2>&1
   ```

   Practically: the skill should `repl-eval` to read each env var in the
   cl-mcp worker, then export them in the shell command via inline
   assignment (the shell session does NOT inherit the cl-mcp env directly).

2. **Wait for the background-task completion notification** — do NOT
   poll, do NOT sleep in a loop. The harness fires a notification when
   the job ends.

3. **After completion**, read the tail of `/tmp/bench-cycle-<EPOCH>.log`
   for the final `FINAL <fixture>: ...` block and per-fixture
   `*-summary.lisp` files for structured data.

4. **Collect summary**: for each fixture, read `*-<fixture-id>-summary.lisp`
   and extract status / replans / steps / impl-reviews / impl-rejections /
   elapsed-sec / sandbox / log-path.

### Phase 3: JSONL extract

For each fixture:

1. **Read develop-level JSONL** (`/tmp/bench-cycle-<EPOCH>-<fixture-id>.jsonl`):
   - `develop-start` / `develop-end` events
   - `plan` event(s) for step structure
   - `step-start` / `step-end` events for per-step status
   - Collect `transcript_path` from `step-start` events to find per-step
     JSONL paths

2. **Read each per-step JSONL** referenced above:
   - **`verify` events**: extract `failed_tests` array; for each entry record
     `test_name`, `reason`, `source.file`, `source.line`, `form` (if present)
   - **`patch` events**: turn, file, diff (full text; will be truncated in
     results doc)
   - **`tool-error` events**: turn, tool, message (truncate to 300 char)
   - **`limit-exhausted` event**: which limit hit
   - **`run-end` event**: all 7 counters + token_total + elapsed_seconds

3. **Build a narrative** per step in turn order:
   ```
   step N "<test_name>":
     turn 0: initial verify failed — <reason>
     turn 3: tool-call lisp-edit-form → error: <message>
     turn 5: patch applied — <file>, +<X>/-<Y> lines, diff snippet
     turn 7: verify after patch — passed=A failed=B, new reason: <...>
     ...
     run-end: <limit_hit>, patches=<X>/attempts=<Y>, elapsed=<Z>s
   ```

4. **Do not retain JSONL in working memory** beyond field extraction. Read
   each JSONL file, extract what you need into a structured summary,
   discard the rest. This keeps the orchestrating agent's context lean.

### Phase 4: 3-axis improvement proposal

For each fixture, based on the narrative from Phase 3, produce proposals
across 3 axes. Each proposal follows the
`templates/backlog-item.md.template` shape (read the template before
authoring to know the expected fields).

#### The 3 axes

- **A. bench target 軸**: Could a fixture-level or bench-config change
  unblock this? (`develop-task.json` goal text, test stub, `--max-replans`,
  `--max-impl-review-revisions`, adding a new fixture that exposes the same
  failure more sharply, etc.)

- **B. log content 軸**: What's missing from G1/G2/G3 that would have made
  diagnosis faster? (New event type, additional field on existing event,
  opt-in flag for verbose data, structured payload improvement, etc.)

- **C. cl-harness 実装軸**: What code change in cl-harness itself would
  prevent this failure mode? (Planner prompt, orchestrator behavior,
  agent system prompt, run-limits default, new auto-recovery hook, etc.)

For each axis, generate 1-3 proposals (more if the failure mode is rich;
fewer if the axis truly has no actionable item). Each proposal must include:

- Title (short, descriptive)
- 観察 (1-2 lines from the narrative; quote JSONL fields where helpful)
- 仮説 (root cause guess)
- 変更案 (concrete change, with file paths / function names where
  identifiable)
- 期待効果 (which fixture unblocks, what changes)
- コスト (small / medium / large + rough effort, e.g. "half-day",
  "1 day", "2-3 days")

#### Cross-cutting

After per-fixture proposals, scan for **patterns shared across multiple
fixtures** (e.g., the same `NAME-CONFLICT` failure mode appearing in
multiple bench runs). Promote those to a `## Cross-cutting findings`
section.

### Phase 5: Write artifacts

1. **Read** `.claude/skills/bench-cycle/templates/results.md.template`.

2. **Substitute** placeholders:
   - `<FIXTURES_LIST>`: comma-separated fixture IDs
   - `<DATE>`: today (`YYYY-MM-DD`)
   - `<BRANCH>` and `<SHA>`: from `git branch --show-current` and
     `git rev-parse HEAD` via Bash
   - `<G3>`: `on` or `off`
   - `<MAX_REPLANS>`: integer
   - `<DRIVER_PATH>`: `/tmp/bench-cycle-<EPOCH>.lisp`
   - Per-fixture sections: filled with Phase 3 narrative + Phase 4 proposals

3. **Write results doc** to
   `docs/benchmarks/results-<DATE>-bench-cycle-<TOPIC>.md` where `<TOPIC>`
   is fixture IDs joined by `-`. If the join is longer than 60 chars, use
   `<first-fixture-id>-and-N-others` (e.g. `102-counter-class-and-2-others`).

4. **Backlog dedup + append**:
   - Read `docs/improvement-backlog.md`.
   - Extract existing entry titles by matching the regex
     `^### \d+\. (.+)$` (skill should parse the lines).
   - For each new Phase 4 proposal:
     - Normalize its title: lowercase + trim leading/trailing whitespace
     - Normalize each existing title the same way
     - If new normalized title is `equal` to any existing OR the first
       20 chars are equal, mark as duplicate of existing #N
   - For non-duplicate proposals: append to `docs/improvement-backlog.md`
     a new section `## <DATE> bench-cycle 由来` (if not already present
     for today) with each proposal in `backlog-item.md.template` shape
   - For duplicates: do NOT append to backlog; instead, in the results
     doc's `## 既存 backlog との関係` section, list "Existing backlog
     #<N> referenced: <title>"

5. **Do NOT git commit** automatically. The skill is write-only.

6. **Report to user**:
   ```
   bench-cycle complete:
     - results doc: docs/benchmarks/results-<DATE>-bench-cycle-<TOPIC>.md (X lines)
     - backlog: +N new proposals, M existing references
     - fixtures: <id>: <status>, <id>: <status>, ...
   Suggested commit:
     git add docs/benchmarks/results-<DATE>-* docs/improvement-backlog.md
     git commit -m "docs: bench-cycle <DATE> — <short topic>"
   ```

## Argument-parsing reference

`$ARGUMENTS` is a single string. Pseudocode for parsing:

```
tokens = $ARGUMENTS.split(/\s+/)
fixtures = []
max_replans = 3
log_llm_requests = true
i = 0
while i < tokens.length:
    t = tokens[i]
    if t == "--max-replans":
        max_replans = int(tokens[i+1])
        i += 2
    elif t == "--no-log-llm-requests":
        log_llm_requests = false
        i += 1
    elif t.startswith("--"):
        error: unknown flag t
    else:
        fixtures.append(t)
        i += 1
if fixtures is empty: print usage; exit
```

## Error handling

| Situation | Action |
|---|---|
| No fixture IDs | Print usage + available IDs from `develop-benchmarks/`, exit |
| Invalid fixture ID | List unknown IDs + available, exit |
| Missing env vars | List which env vars missing, exit |
| > 3 fixtures specified | Use `AskUserQuestion` to confirm (context budget concern); if user declines, exit |
| Bench timeout (>1 hour total) | Proceed to Phase 3 with partial data; mark missing fixtures as `:timeout` in summary |
| Individual fixture errored in driver | Capture error in summary, continue with other fixtures |
| JSONL line malformed | Skip line; in Phase 4, note "data incomplete; axis X partially inferred" |
| `docs/improvement-backlog.md` missing | Print warning, generate results doc anyway, skip backlog append |

## Output format conventions

- All timestamps in `YYYY-MM-DDTHH:MM:SS` form (no timezone — local time)
- All "elapsed" values in seconds with 1 decimal place
- Diff snippets in results doc: show first 5 lines of `-` and first 5 of `+`,
  with `[... N more lines ...]` if longer
- Tool error messages: truncated to 300 chars with `[...]` suffix if truncated
- Backlog item costs: must be one of {small, medium, large} for filterability

## When NOT to use this skill

- For fix-bench (this skill is develop-bench focused)
- For multi-trial / variance bounding (always N=1 here)
- For cross-model A/B comparison (single model per invocation)
- When `CL_HARNESS_LLM_*` env is not configured
- When fewer than 1 fixture id is provided
