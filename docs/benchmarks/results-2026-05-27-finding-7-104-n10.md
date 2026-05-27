# Finding 7 verification: 104-cache-simple N=10 sweep (2026-05-27)

**Date**: 2026-05-27 (bench finished 2026-05-28 ~00:22)
**Fixture**: 104-cache-simple
**Setting**: review-policy=auto, max-impl-review-revisions=2, max-replans=3, max-review-replans=2
**N**: 10 trials

## Finding 7 の問題

Finding 6 fix で `validate-test-source` の planner-error は replan に
乗ったが、 **planner-fn 自体が raise する planner-error は素通り**
だった。 観測されたパターン:

```
trial 2: ERROR: planner-error: JSON decode failed: end of file on
         #<SB-IMPL::STRING-INPUT-STREAM ...>
trial 7: ERROR: planner-error: JSON decode failed: end of file on
         #<SB-IMPL::STRING-INPUT-STREAM ...>
```

これは `src/planner.lisp:589` の `%parse-plan` 内で raise される。
Qwen の token-budget exhaustion で LLM 応答が `{"steps": [` のように
途中で切られて、 yason が JSON decode 中に EOF に到達するケース。

`%plan-with-review` の deterministic gate は **planner-fn が plan を
return した後** の structural check なので、 planner-fn 自体が
signal する planner-error には届かなかった。 結果 develop の outer
HANDLER-CASE (MODEL-ERROR のみ catch) を素通りして develop run が
ERROR で abort。

## Fix

`%plan-with-review` の `(funcall planner-fn ...)` を `handler-case` で
wrap し、 `planner-error` を catch。 catch した場合は L1 structural
reject / L2 LLM review reject と同じ shape で:

1. review-replan-count を増やす
2. budget exhaustion なら :limit-exhausted で着地
3. 余地があれば `prior-plan := NIL, failure-context := planner-error の
   message` で planner を再 invoke

これで P0 (planner-fn 自体の failure) / L1 (deterministic structural
gate) / L2 (LLM review) の **3 段階の同一 shape** な防御層になった。

## N=10 結果 (post Finding 7)

| Trial | Status | Replans | Steps | Elapsed |
|---:|---|---:|---:|---:|
| 1 | :PASSED | 0 | 3 | 470s |
| 2 | :PASSED | 1 | 5 | 1166s |
| 3 | :PASSED | 0 | 3 | 348s |
| 4 | :PASSED | 2 | 7 | 1374s |
| 5 | :PASSED | 0 | 4 | 892s |
| 6 | :PASSED | 0 | 3 | 603s |
| 7 | :STUCK | 2 | 4 | 830s |
| 8 | :PASSED | 0 | 3 | 661s |
| 9 | :LIMIT-EXHAUSTED | 1 | 3 | 934s |
| 10 | :LIMIT-EXHAUSTED | 0 | 0 | 409s |

**Pass rate: 7/10 (70%)**, ERROR: **0/10**, STUCK: 1/10, LIMIT-EXHAUSTED: 2/10

## 3 段階累積比較

| metric | Pre-fix (1779821262) | Post-F6 (1779828445) | **Post-F7 (1779887622)** | Δ (Pre→Post-F7) |
|---|---:|---:|---:|---:|
| Pass rate | 40% | 50% | **70%** | **+30pt** |
| ERROR (silent abort) | 40% | 20% | **0%** | **-40pt** |
| STUCK | 20% | 0% | 10% | -10pt |
| LIMIT-EXHAUSTED | 0% | 30% | 20% | +20pt |
| PASSED elapsed mean | 583s | 822s | 788s | +205s |
| PASSED elapsed median | 593s | 588s | 661s | +68s |

### Direct effect

- `JSON decode failed: end of file` 2 件 → **0 件**
- `test_source parse error: end of file` 0 件 (Finding 6 で消失済) 維持
- **silent fatal ERROR を完全消去** (40% → 0%)
- pass rate 40% → 70% (**+30pt**)

### Trade-off

- replan による recovery のコストで PASSED elapsed median が 593 → 661s
  (+68s) 増。 ただし「abort して 0% の pass rate」 を「+68s 払って 70%
  pass rate」 に変えるトレードオフは強い net positive

### 残存

- STUCK 1 件 (trial 7) と LIMIT-EXHAUSTED 2 件 — agent retry が plan
  修正に届かないケース。 これは別 layer の問題 (e.g. agent prompt 強化、
  Qwen の output 質依存)

## Test

新規 unit test:
- `plan-with-review-replans-on-planner-fn-error`:
  planner stub が最初 `planner-error` を signal、 次に valid plan を
  返す scenario。 develop が abort せず status :passed で完了することを
  assert

全 498 件 GREEN。

## まとめ

Finding 6 + Finding 7 fix series は cl-harness の develop loop の
**resilience 層を 3 段階に**整え、 104-cache-simple の N=10 sweep で
**silent ERROR を 40% → 0%**、 **pass rate を 40% → 70%** にした。
PASSED の elapsed mean は伸びるが、 これは fatal failure を replan で
救済する設計上のコストであり、 net positive。

次の improvement target は STUCK / LIMIT-EXHAUSTED の解消 — これは
**agent 側 prompt / planner output 質** の話で、 別 fix series。
