# bench-cycle: 104-cache-simple

**Date**: 2026-05-24
**Code**: cl-harness main (a2191eec75f667103cd8c7a0758821c3d39f131c)
**Settings**: review-policy=auto, max-impl-review-revisions=2, log-llm-requests=on, max-replans=3
**Driver**: /tmp/bench-cycle-1779560431.lisp
**Skill version**: bench-cycle (.claude/skills/bench-cycle/)

## 結果サマリ

| Task | Status | Steps | impl-reviews | impl-rejections | Elapsed |
|---|---|---:|---:|---:|---:|
| 104-cache-simple | :PASSED | 3 | 3 | 0 | 475.5s |

Replans=0、integration issues=0 で clean 完走。step 0 で
`:explore-downgrade` (lightweight→none, fresh-source-surface) が発火し、
agent 自体は安定動作。今日の最新 default (`max-context-tokens=4000`,
`max-tokens=8192`, `read-timeout=180s`) との組み合わせ。

## 104-cache-simple 詳細

### Plan 構造

```
step 0: test-make-cache (Define `simple-cache` defclass and `make-cache` constructor)
step 1: test-cache-put-and-retrieval (Implement `cache-put` and ensure retrieval works)
step 2: test-cache-get-default-and-nil (Implement `cache-get` default behavior)
```

### 真の根因(G1 failed_tests)

PASSED 完走のため最終 failure なし。中間 verify では:

- step 0 turn 0: `TEST-MAKE-CACHE`: `MAKE-CACHE is undefined`
- step 0 turn 5: 同上 — 1 patch 後も未解決（defclass のみ追加、constructor まだ）
- step 1 turn 0: `TEST-CACHE-PUT-AND-RETRIEVAL`: `CACHE-PUT is undefined`
- step 1 turn 3: 同 test: `CACHE-GET is undefined`（cache-put 追加後、新たに get 不足が露呈）
- step 2 turn 0: `TEST-CACHE-GET-DEFAULT-AND-NIL`: `invalid number of arguments: 3`（既存 cache-get が optional default arg を持たない）

### Patch trail

| step | turn | tool | summary |
|---|---:|---|---|
| 0 | 5 | lisp-edit-form | main.lisp +3/-0（defclass simple-cache のみ） |
| 0 | 6 | lisp-edit-form | main.lisp +3/-0（make-cache constructor → pass） |
| 1 | 3 | lisp-edit-form | main.lisp +4/-0（cache-put のみ） |
| 1 | 4 | lisp-edit-form | main.lisp +3/-0（cache-get → pass） |
| 2 | 3 | lisp-patch-form | main.lisp +2/-2（cache-get に optional default arg → pass） |

### Tool errors

| step | turn | tool | message |
|---|---:|---|---|
| 0 | 4 | fs-write-file | `Cannot overwrite existing .lisp/.asd with fs-write-file; use lisp-edit-form.` |

backlog #4 で既知の failure mode（agent が .lisp に対して fs-write-file
を試行）。今回も 1 step で発生。

### Run-end counters

```
step 0: status=passed, turns=6,  patches=2/atts=3, reads=3, repl=0, tool_calls=6, token=12566, elapsed=61.0s, max prompt 1643 tok
step 1: status=passed, turns=4,  patches=2/atts=2, reads=2, repl=0, tool_calls=4, token=7085,  elapsed=18.4s, max prompt 1592 tok
step 2: status=passed, turns=3,  patches=1/atts=1, reads=2, repl=0, tool_calls=3, token=5212,  elapsed=20.5s, max prompt 1404 tok
合計: token≈24.9k, per-step elapsed sum≈99.9s, wall-clock 475.5s
```

すべての step で max prompt < 1700 tokens、`max-context-tokens=4000`
threshold を下回るため compaction は発火せず。

### Wall-clock 内訳

per-step elapsed sum 99.9s に対し wall-clock 475.5s = ~376s が develop
pipeline review LLM 呼び出し (spec + plan-review + tests-review +
impl-review × 3 + planner) に消費。1 call あたり ~54s と昨日観察した
平均と同等。

### 改善候補

#### A. bench target 軸

- **104b-cache-concurrent sibling fixture** — 観察: 104 は単純な 1-thread cache で agent が安定動作。concurrent / threadsafe 要件を入れた variant があれば mutex / atomic 等の design choice を含むより複雑な fixture になる。
  - 仮説: 現状の 104 は agent の structure+constructor + per-function 分岐 pattern を踏ませる程度の難易度。より context-heavy な fixture を欲しい。
  - 変更案: `develop-benchmarks/104b-cache-concurrent/` 追加、goal に「`bordeaux-threads` で thread-safe な cache」と specify。test_source で並行 access を確認。
  - 期待効果: agent の thread-safety 系設計判断を観測できる新 fixture が増える。compaction や long-step の挙動も観測しやすい。
  - コスト: small + half-day。

#### B. log content 軸

- **`evolved-failures` event の追加** — 観察: 104 step 1 で initial verify が `CACHE-PUT undefined`、patch 後 verify が `CACHE-GET undefined` と reason が evolve。**「同じ test name で fail reason が前回と違う」**ことが暗黙の signal だが log では直接示されない（次の verify event を比較しないと分からない）。
  - 仮説: step 内で fail reason が evolve したケース（つまり「前 patch が effective だったが追加 work が必要」状態）を independent event として log すれば、bench-cycle 解析側で「分割が必要な step」を rule で自動検出可能。
  - 変更案: orchestrator の `%execute-step` 内で post-verify failed_tests を前回 verify failed_tests と比較し、test name が同じだが reason が異なるとき `:evolved-failure` event を emit。fields: `step_index`, `test_name`, `prior_reason`, `current_reason`, `turn`.
  - 期待効果: 「step が複数の implicit acceptance criteria を内包している」状態を自動検出。planner の step 設計 quality の metric として使える。
  - コスト: small + half-day（diff 比較 + event emit）。

#### C. cl-harness 実装軸

- **agent prompt に「structure + accessor / constructor 同 turn 内」ヒント追加** — 観察: 104 step 0 で defclass → verify-fail → make-cache、step 1 で cache-put → verify-fail → cache-get の 2 段階。各「step 内で 1 patch 追加 → verify → 不足発覚 → 2nd patch」flow が 2 step で繰り返された。turn 数だけ見ると合計 2-3 turn の浪費。
  - 仮説: backlog #24 (`defgeneric + method 同時定義`) と類似 pattern。class / function 系でも「使う側 (test) が要求する complete set を 1 turn でまとめて追加せよ」と prompt 化すれば 1 patch で済む。
  - 変更案: agent system prompt に 1 段落:
    > When the test exercises multiple symbols (`make-x` + `x-accessor`,
    > `cache-put` + `cache-get`, defclass + its constructor), add **all of
    > them in the same lisp-edit-form / lisp-patch-form turn** instead of
    > waiting for verify to reveal each missing one. Read the test
    > carefully to enumerate every symbol it references before patching.
  - 期待効果: 104 step 0, 1, 102 step 0 の往復削減（各 step で 1-2 turn 短縮）。複数 fixture で recurring pattern なので effect 範囲広い。
  - コスト: small + half-day（prompt 1 段落 + 1-2 fixture re-bench）。

- **impl-review-stage で「test に出る symbol を全カバーしたか」明示 check** — 観察: 104 step 0 で 1 patch 後 verify-fail の reason が「MAKE-CACHE undefined」だった。test source を読めば「make-cache を呼んでいる」と分かるはずだが、agent は defclass で満足してしまった。
  - 仮説: impl-review (#31 で keep) が「test source に出る symbol が全部 defined か」を明示的 check 項目として持てば、incomplete impl を early reject できる（リトライで agent が直す）。
  - 変更案: `review-development-artifact` の impl-review prompt に check 項目追加: "Does the implementation define every symbol the test references? Walk through the deftest body and enumerate." reject 時の feedback でも具体的に「missing: X, Y」を返す。
  - 期待効果: 「test に出る全 symbol」レベルでの incomplete-impl pattern を impl-review が catch。但し impl-review LLM call は cost なので、effect / cost の trade-off は要 measure。
  - コスト: medium + 1 day（prompt 修正 + bench で reject rate 観察）。

## Cross-cutting findings (104 + 既存 102, 103)

- **「structure + constructor 別 turn」recurring pattern**: 102 step 0
  (defclass counter → 1 patch → fail → make-counter → 2nd patch → pass)
  と 104 step 0 で同 pattern を観察。**3 fixture × 2 不要 turn = 累計
  6 turn 浪費**を観察可能データから検出。C 軸 #1 の prompt 変更でまとめて
  対処したい。
- **`:explore-downgrade` fixed-source-surface が 3 fixture (102, 103,
  104) で連続して発火**: planner が fresh project の step 0 でも
  `lightweight` を出す傾向はかなり一貫している。orchestrator-level downgrade (#21) が確実に効いているのは確認できた。
- **fs-write-file on existing .lisp**: 102, 104 で再観察 (#4 既出)。
  recurring rate がそこそこ高い → 優先度高め。

## 推奨次アクション

1. **C 軸提案: agent prompt に "test の全 symbol 1 turn でカバー"
   ヒント追加**: 3 fixture で recurring → effect 範囲広い。small / half-day。
2. **B 軸提案: `:evolved-failure` event 追加**: 解析基盤 multiplier。
   small / half-day。
3. それ以降は backlog 参照（#4 が priority 上昇）。

## 既存 backlog との関係

- 新規 backlog 候補: 4 件（A 軸 1, B 軸 1, C 軸 2）
- Existing backlog **#4** referenced: agent system prompt の tool 使用
  ガイダンス改善（fs-write-file on .lisp の再発）
- Existing backlog **#21** referenced: `:explore-downgrade` が今回も
  発火（実装済の効果再確認）
- Existing backlog **#24** referenced: defgeneric+method 同時定義 — 新
  C 軸 #1（structure+constructor 同 turn）は #24 の generalization。
  別 entry で記録するが #24 と並列扱い。
- 重複検出: 新規 4 件の title はいずれも既存 entry の先頭 20 char と
  衝突しない。
