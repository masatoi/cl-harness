# #32+#33 effect: 103-fizz-buzz wall-clock 41% 短縮 (N=1)

**Date**: 2026-05-24
**Code**: cl-harness main (post bcdac1d、本 commit と同じ tree)
**Settings**: review-policy=:auto, max-impl-review-revisions=2, log-llm-requests=on, max-replans=3
**Compared against**: docs/benchmarks/results-2026-05-23-bench-cycle-103-fizz-buzz.md
（同 fixture, 同 settings の baseline）

## 結果

| 指標 | baseline (2026-05-23) | after #32+#33 | 変化 |
|---|---|---|---|
| Status | :PASSED | **:PASSED** | 同等 |
| Plan size | 3 | 3 | 同等 |
| Replans | 0 | 0 | 同等 |
| Impl rejections | 0 | 0 | 同等 |
| Integration issues | 0 | 0 | 同等 |
| step 0 token | 14,148 | **6,759** | **-52%** |
| step 0 elapsed | 45.2s | **22.7s** | **-50%** |
| step 0 turns | 6 | **4** | -2 |
| step 1, 2 (no-op) | 0 token / ~2s each | 0 token / ~2s each | 同等 |
| sum per-step elapsed | 49.2s | **27.0s** | **-45%** |
| **wall-clock total** | 450.7s | **267.2s** | **-183.5s (-41%)** |

review pipeline overhead (wall-clock - per-step elapsed):
- baseline: 450.7 - 49.2 = ~401s for ~7 LLM calls = **~57s/call**
- after: 267.2 - 27.0 = ~240s for ~7 LLM calls = **~34s/call**
- 1 call あたり ~40% latency 短縮

## 効果の内訳（推測）

`:max-tokens 8192` default が直接効いた可能性が高い。理由:

- baseline では step 0 で 14,148 token を消費（response が冗長な傾向）
- after では step 0 で 6,759 token（response が短くなる）
- review pipeline 1 コールあたり latency も ~57s → ~34s と並行して短縮

これは「`max_tokens` を明示することで model server 側の生成停止が早まり、
1 response あたりの長さが短くなる → 1 call の latency が短い」効果と
解釈できる。`response token 数 ∝ latency` の関係を実証しているとも
言える。

`:read-timeout 180s` 短縮は今回 hang が起こらなかったので直接 effect は
観察できず。但し pathological hang が起きたときの fail-fast 効果が
保証される点で「保険」として価値あり。

## variance への注意

N=1 なので「変化分の何 % が実装由来 / variance 由来」は分離不能。
但し step 0 が -52% token / -50% elapsed という二指標で同方向に
動いたことは variance だけでは説明しにくく、`:max-tokens` 効果と
推定する妥当性はある。

variance bound を求めるには `:max-tokens nil` (server default) で同
fixture を N>=3 回しての差を取る必要あり。今後の検証 task。

## Bench artifacts

- driver: `/tmp/bench-cycle-1779555228.lisp`
- log: `/tmp/bench-cycle-1779555228.log`
- JSONL: `/tmp/bench-cycle-1779555228-103-fizz-buzz.jsonl`
- summary: `/tmp/bench-cycle-1779555228-103-fizz-buzz-summary.lisp`

## 関連

- backlog #32 (read-timeout), #33 (max-tokens): 実装済 (bcdac1d)
- backlog #31 (light review-policy): 実装済 (997d412)。本 bench は
  `:review-policy :auto` での測定で、#31 effect とは independent。
- backlog #34 (conversation reset), #35 (response prefix check):
  未実装、保留中。
