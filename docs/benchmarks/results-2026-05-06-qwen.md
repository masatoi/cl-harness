# Qwen3.6-35B-A3B sweep — 12 tasks × 2 conditions

**Date**: 2026-05-06
**Model**: `Qwen/Qwen3.6-35B-A3B` served by SGLang at
`http://192.168.0.17:8000/v1`, no API key, local network.
**Code**: cl-harness v0.2.0 (`62f62f5`). All cells use the new stdio
default for the cl-mcp transport, so the harness ran against its own
private cl-mcp subprocess and never touched the host-shared HTTP pool.
**Settings**: temperature 0, max_tokens 4096, `enable_thinking: false`
via `chat_template_kwargs` (otherwise Qwen3 spends the entire
max_tokens budget inside `reasoning_content` and emits nothing usable
on `content`).

### Per-task results

| Task | Generic-MCP | Runtime-Native |
|---|---|---|
| 000-smoke | `passed` / 7t / 8.8k tok | `passed` / 5t / 5.8k |
| 001-wrong-operator | `passed` / 8t / 11.3k | `passed` / 8t / 11.5k |
| 002-typo-defun | `passed` / 3t / 3.2k | **anomaly: 0 turns / 0 tokens; verify reported `passed` at turn 0 against an unfixed sandbox — see "Anomaly" below** |
| 003-missing-import | `passed` / 5t / 6.4k | `passed` / 5t / 6.7k |
| 004-defmethod-specializer | `limit-exhausted` (max-patches) / 6t / 8.1k | `limit-exhausted` (max-patches) / 10t / 17.1k |
| 005-defclass-slot | `passed` / 3t / 3.0k | `passed` / 9t / 12.7k |
| 006-format-arity | `passed` / 7t / 8.7k | `passed` / 8t / 11.0k |
| 007-error-signal | `passed` / 7t / 9.3k | `passed` / 6t / 7.2k |
| 008-macro-expansion | `passed` / 11t / 18.4k | `limit-exhausted` (max-patches) / 11t / 18.1k |
| 009-handler-case-typo | `passed` / 6t / 8.5k | `passed` / 5t / 6.1k |
| 010-unbound-symbol | `passed` / 3t / 3.2k | `passed` / 6t / 7.1k |
| 011-let-vs-let-star | `passed` / 4t / 5.2k | `passed` / 3t / 3.6k |

### Per-condition aggregate

| Condition | Total | Passed | Pass-rate | Mean turns | Mean tokens | Mean elapsed_s |
|---|---:|---:|---:|---:|---:|---:|
| `generic-mcp`  | 12 | 11 | **91.7%** | 5.8 | 7,851 | 9.8 |
| `runtime-native` | 12 | 10 | **83.3%** | 6.3 | 8,908 | 8.7 |

The runtime-native row counts the 002-typo-defun anomaly as `passed`
(the bench reported it that way); the more conservative reading,
counting it as a failure, lowers runtime-native to 9/12 = 75.0%.

### Comparison with the llama-3.3-70b baseline

Same 12-task suite, same cl-harness version, same host. llama numbers
from `docs/benchmarks/results-2026-05-06.md`.

| Condition | llama-3.3-70b | Qwen3.6-35B-A3B |
|---|---|---|
| `generic-mcp` | 10 / 12 (83.3%), 6.9t mean, 9.1k tok mean | 11 / 12 (91.7%), 5.8t, 7.9k tok |
| `runtime-native` | 8 / 12 (66.7%), 7.8t, 12.5k tok | 10 / 12 (83.3%), 6.3t, 8.9k tok |

Qwen3 leads on every metric in this single trial: pass-rate, mean
turns, mean tokens. With `enable_thinking: false` it averages a
clean fix in ~6 turns and ~8k tokens — better turn efficiency than
llama-3.3-70b on this fixture set.

That ranking should not be quoted as a stable comparison: see
"Variance" below.

### Where the conditions diverge for Qwen3

- **004-defmethod-specializer:** both conditions hit
  `limit-exhausted (max-patches)`. The model attempted patches three
  times under each policy and never converged. This is the only task
  where Qwen3 strictly fails.
- **008-macro-expansion:** generic-mcp passed in 11 turns;
  runtime-native exhausted patches at the same turn count. This is
  the only divergent task — the extra REPL probing freedom under
  runtime-native cost Qwen3 a successful patch attempt instead of
  helping it.

In both divergent cases, runtime-native lost to generic-mcp — the
same direction as the llama result. The probe tools genuinely
*subtract* on this fixture set, which means either the model under
test does not yet exploit them or the tasks themselves do not
reward probing.

### Headline finding

On this single-trial 12-task suite, **Qwen3.6-35B-A3B
(`generic-mcp` 91.7%) leads llama-3.3-70b-versatile (83.3%) by 1
cell**, with materially fewer turns and tokens per fix. The
runtime-native gap is similar (83.3% vs 66.7%, +2 cells).

Two caveats worth keeping in mind:

1. The Qwen runtime-native total includes the 002-typo-defun
   anomaly. If counted as a fail, runtime-native drops to 9/12 =
   75.0%, still ahead of llama's 8/12.
2. Qwen3 emits flat-arg tool calls roughly half the time (see
   `docs/notes/2026-05-06-qwen-smoke.md`). The `parse-action`
   tolerance landed in commit `19b06ad` keeps those calls dispatching
   correctly; without that change the same sweep would have produced
   significantly worse numbers.

### Anomaly: 002-typo-defun runtime-native at 0 turns

The runtime-native cell for 002-typo-defun reported `passed` at turn
0 with 0 tool calls and 0 tokens, immediately after the generic-mcp
cell for the same task had successfully fixed *its* sandbox. Manual
clean-room reproduction against the same runtime-native sandbox path
(post-bench) confirms the test in fact fails — `typo-defun:greet` is
undefined in that sandbox copy.

The harness's clean-room (`pool-kill-worker :reset t` +
`scope-asdf-to-project` at run-agent entry) should have prevented
state leakage from the previous cell, but something let the new
runtime-native verify see the previous (patched) typo-defun. Possible
causes (not yet confirmed):

- A race where pool-kill returns before the new worker is fully
  ready, leaving the old worker live.
- ASDF source-registry inheritance from parent process not being
  fully overridden inside cl-mcp.
- cl-mcp's load-system tool re-installing inherited config.

The bench transcript shows only a single `verify` event with
`passed: 1, failed: 0` and no patches — there is no LLM-side action
to debug. Either way, this is a harness-side issue, not a model-side
one. Tracked as a follow-up; until reproduced and fixed, isolated
single-trial cells should be re-checked when the bench shows a
0-turn pass against a task whose initial fixture is known broken.

### Methodology notes

- `enable_thinking: false` is mandatory for Qwen3 under the harness
  budget. With thinking on, even a one-word reply consumes the full
  max_tokens through `reasoning_content` and `content` is empty, so
  the parser sees a no-op response.
- `parse-action` (commit `19b06ad`) was load-bearing for this sweep.
  Several cells contained turns where the model emitted flat-arg
  shape JSON; the tolerance silently rescued them.
- Sandbox isolation per cell is `%sandbox-fixture` with random +
  internal-real-time suffix and `cp -r` (T3.7's fix is intact).

### Limitations

- **Single trial per cell.** Qwen3 is a MoE model whose expert
  routing introduces variance the temperature knob does not control;
  a second pass would shift cells. Treat ±10–20% as noise on every
  number above. The `003-missing-import` cell that previously
  produced 4× variance under llama (Phase 5.2) is the obvious
  candidate to re-trial first.
- **No `:file-only` column.** Same reason as the llama report:
  expected to be near-zero on this fixture set; not a productive use
  of the budget.
- **One model.** The architectural goal of the v0.2 stdio default
  was *not* to crown Qwen3 — it was to make any model's number
  defensible against shared-pool noise. The cross-model comparison
  here is incidental.
- **`:max-patches` default 3 is the dominant failure mode.** Bumping
  it to 5 or 7 might lift `004-defmethod-specializer` and
  `008-macro-expansion` — that is a tuning experiment for v0.3.

### Files

- Transcripts: `/tmp/qwen-2026-05-06/bench-*.jsonl` (24 files, one
  per cell).
- Anomalous cell: `/tmp/qwen-2026-05-06/bench-002-typo-defun-runtime-native-4198877656.jsonl`.
- Sandbox tmpdirs: `/tmp/cl-harness-bench-<task>-<rand>/`.
- llama baseline this is compared against:
  `docs/benchmarks/results-2026-05-06.md`.
