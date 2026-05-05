# Qwen3.6-35B-A3B (SGLang) Smoke Run — 2026-05-06

Connectivity / capability smoke against a local SGLang endpoint serving
`Qwen/Qwen3.6-35B-A3B` at `http://192.168.0.17:8000/v1`.

## Endpoint Recipe

```lisp
(let* ((thinking (alexandria:alist-hash-table
                  `(("enable_thinking" . ,yason:false)) :test 'equal))
       (extra-body (alexandria:alist-hash-table
                    `(("chat_template_kwargs" . ,thinking)) :test 'equal)))
  (cl-harness:fix
   :base-url "http://192.168.0.17:8000/v1"
   :api-key "none"
   :model "Qwen/Qwen3.6-35B-A3B"
   :max-tokens 4096
   :extra-body extra-body
   ...))
```

Confirmed:

- `GET /v1/models` returns the model id without auth.
- API key is unused; any string passes.
- `chat_template_kwargs.enable_thinking: false` **does** disable Qwen3
  thinking on this SGLang build, but **only** when the value is encoded as a
  JSON boolean. Passing CL `nil` encodes as JSON `null` and is silently
  ignored by the chat template (thinking stays on). Use `yason:false` for
  the false literal; `t` is fine for true. Nested objects must be
  hash-tables — alists encode as JSON arrays and trip a 400 from the
  validator.
- With thinking enabled and `max_tokens=32`, the entire response is
  consumed by `reasoning_content` (`finish=length`, `content=NIL`). With
  thinking disabled, a one-word reply costs ~2 completion tokens.
- SGLang also accepts `separate_reasoning: false`, which folds the
  `<think>...</think>` block into `content`. Not useful for cl-harness
  (the parser then has to strip the tag); prefer `enable_thinking: false`.

## Smoke Run (000-smoke / generic-mcp)

Two consecutive runs with `cl-harness:fix` against fresh tmp sandboxes.
Both terminated with `:LIMIT-EXHAUSTED (:MAX-TURNS)` even though the
patch applied in each run was correct (`(- x y)` → `(+ x y)`) and a
manual `run-tests :smoke/tests` post-run reported PASS.

| metric            | run 1 | run 2 |
|-------------------|-------|-------|
| status            | limit-exhausted | limit-exhausted |
| turns             | 20    | 20    |
| patches applied   | 1 / 2 attempted | 1 / 2 attempted |
| tokens (chat)     | 45 486 | 35 844 |
| wall clock        | 26.6s | 19.8s |
| final-verify      | (none) | (none) |
| post-run manual run-tests | PASS | PASS |

The model produced a clean, correct `lisp-patch-form` action by turn 9
in run 2. The remaining 11 turns were the LLM repeatedly calling
`run-tests` because the in-loop verify reported error.

## Two Issues Surfaced

### 1. `cl-harness:fix` does not enforce sandbox isolation

`fix` calls `fs-set-project-root` then `verify-task`, but never
re-scopes the cl-mcp worker's ASDF source-registry to the project root.
If the worker has previously loaded a same-named system from a
different directory (extremely common during benchmark-driven
development — every `bench` invocation populates `/tmp/cl-harness-bench-*`
copies), `(asdf:find-system "smoke")` resolves to whichever copy is
first found in the current source-registry, **not** to the
`:project-root` argument.

`bench.lisp` already has `%scope-asdf-to-sandbox` (cf. v0.2 Tier 3) for
exactly this reason. The same logic needs to fire on `cl-harness:fix`
entry, before the initial verify.

Repro: the run 1 transcript shows the post-patch verify (turn 7)
reporting `test-failed` despite the source on disk being correct,
because the worker had loaded a different sandbox's `smoke` earlier in
the session and `force=t` reload alone does not re-resolve the
`.asd` file path.

### 2. Worker `run-tests` returns `is_error: true` mid-loop, but PASSes after

In run 2 the in-loop verify at turn 9 reported `load-failed`, and
every subsequent run-tests call from the LLM also returned
`is_error: true` (the model spammed run-tests for 11 more turns).
Immediately after the run terminated, calling `run-tests :smoke/tests`
through the same worker session returned PASS with 21 ms duration.

Root cause is unclear. Candidates:

- ASDF FASL cache contamination across the rapid load-system /
  run-tests calls.
- A previously-loaded `smoke` system whose ASD path no longer matches
  the current source-registry, which `force=t` does not heal.
- A cl-mcp `load-system` tool path that re-installs an inherited
  source-registry on each call, undoing our re-scope.

Independent of the cause, this is an availability defect: the fix loop
is unable to observe its own success and burns its turn budget.

## Bottom Line on Qwen3.6-35B-A3B

The model itself worked. Within 9 turns of generic-mcp it located the
file, read the test, read the source, and emitted a correct unified
patch. Tool-call JSON was well-formed (one parse-error streak in run 1,
none in run 2). With thinking disabled, token cost per turn averaged
~1.8k.

The harness, not the model, is the bottleneck on these runs.

## Next Actions

In rough priority order:

1. **`cl-harness:fix` clean-room on entry.** Lift the
   `%scope-asdf-to-sandbox` logic out of `bench.lisp` into a shared
   helper and call it from `run-agent` before the initial verify-task,
   conditional on a new `:isolate-asdf-p` kwarg (default `t`). For
   `bench` callers the helper is idempotent. Also add
   `pool-kill-worker :reset t` at the very start so the run begins on a
   guaranteed-clean worker. — closes issue #1.

2. **Reproduce issue #2 in isolation.** Strip the LLM out of the loop:
   write a test that does
   `verify-task → lisp-patch-form → verify-task` repeatedly against
   the smoke fixture inside a single worker session and assert that the
   second verify reports test-passed. If this reproduces, bisect: is it
   the patch (force-recompile of FASL while old FASL is still loaded?)
   or the load-system tool itself? — owner: harness side.

3. **Surface verify error text in the JSONL `tool-result` event.**
   Right now `is_error: true` is recorded but the `text` payload is
   dropped. Without the message, post-mortem on issues like #2 requires
   a re-run with extra logging. Add an `error_text` field whenever
   `is_error` is true. — small change in `src/log.lisp` /
   `src/agent.lisp`.

4. **Propagate the Qwen recipe.** Add a section to README under
   "Reasoning models" documenting the SGLang/Qwen3 case: nested dicts
   must be hash-tables, booleans must use `yason:false`, the
   `enable_thinking` kwarg lives under `chat_template_kwargs`.

5. **Defer broader Qwen benchmarking** until issues #1 and #2 are
   fixed. Single-trial pass-rate for a model that is repeatedly denied
   the chance to declare success would mis-represent its capability.
   After the fixes, run the standard 12-task × 2-condition sweep and
   compare to the llama-3.3-70b-versatile baseline in
   `docs/benchmarks/results-2026-05-06.md`.

Optional / lower priority:

6. **Default `max-tokens` for reasoning models.** Provide a
   `:reasoning-budget` knob on `make-openai-provider` that bumps
   `max_tokens` to e.g. 8192 when `:reasoning-effort` is set, so a
   user who forgets `enable_thinking: false` does not silently get
   `finish=length` with empty content.

## Resolution Status (2026-05-06)

- **Issue #1 (sandbox isolation):** closed by commit `367587a` — `run-agent`
  now does `pool-kill-worker :reset t` and ASDF source-registry scoping at
  entry under the new `:isolate-asdf-p` kwarg (default `t`).
- **Issue #2 (mid-loop verify `is_error`):** closed implicitly by the
  Phase A–D stdio-transport migration
  (`docs/notes/2026-05-06-stdio-transport.md`, commits `e945d90`, `fc3809d`,
  `b74c862`, `ed15f10`, and the Phase D default flip). The original
  diagnosis ("ASDF FASL contamination" or "load-system tool re-installing
  inherited source-registry") was wrong: the actual cause was cl-mcp's
  shared HTTP worker pool getting exhausted when each `cl-harness:fix`
  call leaked a bound worker, after which `load-system` returned
  `Component "smoke" not found in pool` and verify reported `load-failed`
  for the rest of the run. By default `cl-harness:fix` now spawns its own
  cl-mcp subprocess via stdio and tears it down on exit, so the pool is
  no longer shared. Re-running the same smoke fixture under this default
  produced `:PASSED` in 7 turns / 8.8 s / 8 380 tokens — the first time
  this fixture has gone clean end-to-end on a Qwen3.6-35B-A3B run.
- **Next Action #3 (error_text in tool-result events):** still open —
  worth doing for general post-mortem readability even though #2 was
  resolved by transport, not by reading the missing payload.
- **Next Action #4 (README Qwen recipe):** open.
- **Next Action #5 (full Qwen sweep):** unblocked. After running, append
  the report under `docs/benchmarks/`.

## New Observation (2026-05-06): Qwen3 emits flat-arg tool calls at random

A re-run of 000-smoke under the new stdio default produced
`:LIMIT-EXHAUSTED` with 0 patches because every tool call landed as

```json
{"type":"tool_call","tool":"lisp-read-file","path":"...","collapsed":true}
```

instead of the schema-required

```json
{"type":"tool_call","tool":"lisp-read-file","arguments":{"path":"...","collapsed":true}}
```

`src/action.lisp:parse-action` only looks at the nested `arguments`
object, so the flat layout decays to an empty argument hash and
cl-mcp rejects every call with `path is required`. Same model, same
temperature 0, same fixture as the Phase C smoke that landed `:PASSED`
in 7 turns — the model is non-deterministic across runs even at
temp 0 (Qwen3.6-35B-A3B is a MoE; expert routing introduces variance
that ignores the temperature knob).

Possible follow-ups, in priority order:

- **Tolerate flat-args in `parse-action`.** If the parsed object has
  no `arguments` and the `tool` key is set, take every key other
  than `type`, `tool`, `thought` as the implicit arguments map. Cheap,
  unambiguous, helps every model that occasionally drifts off schema.
- **Reinforce schema in the system prompt.** Spell out the exact
  envelope shape with one example, both nested and (as a negative
  example) flat. Cheap but won't fully fix MoE variance.
- **Separate Qwen-specific eval track.** Run multiple trials per cell
  (already supported via `run-benchmark-task-trials`) and report
  pass-rate ± stddev rather than single-trial outcomes for this model.

