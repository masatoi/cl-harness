# bench-cycle: 103-fizz-buzz

**Date**: 2026-05-23
**Code**: cl-harness main (110da86a57fd7b7e46880d64dd10117eabf63bb7)
**Settings**: review-policy=auto, max-impl-review-revisions=2, log-llm-requests=on, max-replans=3
**Driver**: /tmp/bench-cycle-1779537796.lisp
**Skill version**: bench-cycle (.claude/skills/bench-cycle/)

## 結果サマリ

| Task | Status | Steps | impl-reviews | impl-rejections | Elapsed |
|---|---|---:|---:|---:|---:|
| 103-fizz-buzz | :PASSED | 3 | 3 | 0 | 450.7s |

Replans=0、integration issues=0 でクリーンパス。但し以下の通り
**plan 過剰分割 + review pipeline 重コスト**が観察される。

## 103-fizz-buzz 詳細

### 真の根因(G1 failed_tests)

PASSED 完走のため最終失敗なし。中間 verify では:

- step 0 turn 0: `TEST-FIZZ-BUZZ-N15`: `FIZZ-BUZZ is undefined`（initial verify）
- step 1, 2 の initial verify: **既に passed**（step 0 の patch で step 1/2 の test も同時に pass）

### Patch trail

| step | turn | tool | summary |
|---|---:|---|---|
| 0 | 6 | lisp-edit-form | src/main.lisp +8/-0（fizz-buzz function 全体実装） |
| 1 | – | – | patch 不要（initial verify pass） |
| 2 | – | – | patch 不要（initial verify pass） |

### Tool errors

なし（全 step 通じて 0 件）。

### Run-end counters

```
step 0: status=passed, turns=6, patches=1/atts=1, reads=5, repl=0, tool_calls=6, token=14148, elapsed=45.2s
step 1: status=passed, turns=0, patches=0/atts=0, reads=0, repl=0, tool_calls=0, token=0, elapsed=2.0s
step 2: status=passed, turns=0, patches=0/atts=0, reads=0, repl=0, tool_calls=0, token=0, elapsed=2.0s
develop合計: token≈14.1k, per-step elapsed sum≈49.2s, wall-clock 450.7s
```

### Wall-clock 内訳分析

per-step 実行時間の合計が 49.2s なのに対し wall-clock は 450.7s。差分の
~400s は **develop pipeline の review/planner LLM 呼び出し**:

| LLM call | 件数 (推定) |
|---|---:|
| spec 生成 (review-policy=:auto) | 1 |
| plan 生成 | 1 |
| plan review | 1 |
| tests review | 1 |
| agent loop (step 0 / step 1, 2 は no-op) | 6 |
| impl review (per step) | 3 |
| **計** | **~13 round-trips** |

local LLM の latency ~30s/round で 390s ≈ 観察 wall-clock。「trivial な
fixture でも review pipeline の固定コストが支配的」状況が明確に。

### 改善候補

#### A. bench target 軸

- **103b-fizz-buzz-large-n sibling fixture** — N>=100 の variant を追加して planner の step 設計を強めにストレステスト
  - 仮説: 現状 103 は実装が単純すぎて step 過剰分割の弊害が見えにくい。N=100 で stream output / 大きい list の design choice が絡む variant を入れれば、planner の step 設計品質を測りやすくなる。
  - 変更案: `develop-benchmarks/103b-fizz-buzz-large-n/` を追加、goal text を「N=100 までを 1 行ずつ stdout に出力する `fizz-buzz` 関数」のように specify。test_source も大量出力を確認する形に。
  - 期待効果: planner の step 設計 quality が直接観測可能に。"3 step に分けるべきか 1 step で済むか" の判断 fixture が増える。
  - コスト: small + half-day（fixture 1 個追加）。

#### B. log content 軸

- **`step-end` event に `initial_verify_passed` boolean を追加** — 観察: step 1, 2 で initial verify が即 pass、agent loop は 0 turn で抜けた。今回は `turns=0` から推定したが、独立 field がなく自動検出しにくい。
  - 仮説: 「前 step の patch によって後続 step も既に成立した」状態を専用フィールドで宣言できれば、planner の over-fragmentation を解析側で度数集計可能。
  - 変更案: `step-end` event に `initial_verify_passed: true|false` を追加。turn=0 で verify status=passed なら true。
  - 期待効果: bench-cycle 解析側で「実質 no-op だった step の比率」を直接集計可能になり、planner 設計の品質 metric として使える。
  - コスト: small + half-day。

- **`verify` event を `pre-verify` / `post-verify` で区別** — 観察: 現状はすべて `verify` type、turn 値で区別。
  - 仮説: turn=0 の verify と patch 後の verify を type で分けたほうが filter / 解析がきれい。「step の最初に必ず走る verify」と「patch ごとの確認 verify」は意味が違う。
  - 変更案: event type を `pre-verify` (turn=0 の initial verify) / `verify` (patch 後) に分割。後方互換のため `verify` をそのまま残しつつ別 type を併用する案も可。
  - 期待効果: G1 解析が type-based filter で書きやすくなる。
  - コスト: small + half-day。

#### C. cl-harness 実装軸

- **planner prompt に「step 間 acceptance criteria 非重複」guidance** — 観察: 103 で plan の step 0 が test-fizz-buzz-n15（"all four output categories"）を含むため、step 1 (divisibility-only) と step 2 (non-divisible) は step 0 の test だけで既に subsume されており、redundant な分割。
  - 仮説: planner system prompt に「各 step の deftest は前 step の test が既に保証する事象を再確認しないこと」を明示すれば、独立した acceptance criterion 単位の分割になる。
  - 変更案: `+default-planner-system-prompt+` (および prompts/planner.md) の Rules セクションに 1 行追加: "Each step's test_source must check a behavior NOT already implied by earlier steps' tests. If you can't think of one, the previous step is the only step you need."
  - 期待効果: 103 のような trivial fixture で no-op step が無くなり、wall-clock 短縮（impl-review LLM call が無駄に発火しなくなる）。他 fixture でも planner の冗長分割を抑制。
  - コスト: small + half-day（prompt 1 段落 + 1 fixture re-bench）。

- **trivial-task path: review pipeline の short-circuit** — 観察: 103 で wall-clock 450.7s のうち ~400s が review pipeline (spec / plan-review / tests-review / impl-review × 3) の LLM 呼び出し。実際の agent work は 49s のみ。
  - 仮説: goal text と plan が十分単純な場合（例: 1 file / 1 function / <= 50 LoC 想定）、review pipeline の一部 / 全部を省略して agent loop に直行できれば 30-50% wall-clock 削減。
  - 変更案: `cl-harness:develop` に `:review-policy :light` mode を追加。`:light` は spec 生成・plan review・tests review をスキップ、impl-review のみ残す。または heuristic で goal-text の文字数 / plan の step 数 < N の場合に自動で light mode に降格。
  - 期待効果: 103-fizz-buzz / 100-greet / 101-double 等の trivial fixture で wall-clock 30-50% 短縮の見込み。複雑 fixture（102+）には影響なし。
  - コスト: medium + 1-2 days（mode 追加 + heuristic 設計 + 既存テスト維持）。

## Cross-cutting findings

単 fixture なので cross-fixture finding はないが、今日の 102 + 103 観察を
横断すると:

- **planner の step 過剰分割パターン**: 102 では 4 step が適切（実 work
  が分散）、103 では 3 step のうち 1 step だけが実 work（過剰）。同じ
  「step 数 3-7」ガイダンスでも fixture の本質的複雑度によって最適 step
  数は大きく違う。backlog #15（expected-step-count）の精度向上が引き続き
  鍵。
- **review pipeline の固定コスト**: 102 では全体の ~25%、103 では ~85%
  を占める。fixture が単純なほど比率が悪化。C2 の light-mode が刺さる
  範囲が広い。

## 推奨次アクション

1. **C2（trivial-task light review pipeline）**: wall-clock の最大ボトル
   ネック。既存 fixture 半数以上に効く可能性。medium / 1-2 day。
2. **C1（planner prompt: non-overlapping acceptance criteria）**: 103 の
   step 1/2 no-op を直接潰す。small / half-day。即効性あり。
3. **B1（initial_verify_passed field）**: 解析基盤として multiplier。
   small / half-day。

## 既存 backlog との関係

- 新規 backlog 候補: 5 件（A 軸 1, B 軸 2, C 軸 2）
- Existing backlog #15 referenced: "develop-task.json に expected-step-count / expected-replans 期待値 field" — 「planner の step 数判断」を支援する別の角度。本 results doc の cross-cutting で関連性を再確認。
- 重複検出ルール: lowercase + trim 後の先頭 20 char 一致 — 新規 5 件はいずれも既存タイトル接頭辞と衝突しない。
