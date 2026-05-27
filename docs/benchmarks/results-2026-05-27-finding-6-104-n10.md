# Finding 6 verification: 104-cache-simple N=10 sweep (2026-05-27)

**Date**: 2026-05-27
**Fixture**: 104-cache-simple
**Setting**: review-policy=auto, max-impl-review-revisions=2, max-replans=3, max-review-replans=2
**N**: 10 trials each side

## Finding 6 の問題

`%plan-with-review` は planner-fn が emit した plan を LLM review に
通すだけで、 **deterministic な structural check** をしていなかった。
Qwen の token budget exhaustion で test_source が途中で切られた場合
(`(deftest foo (ok t` のような unbalanced parens)、 EXECUTE-PLAN 冒頭の
`validate-test-source` で planner-error が raise → develop loop の
HANDLER-CASE は MODEL-ERROR しか catch しないため、 例外が外に漏れて
develop run が ERROR で abort。

N=10 sweep で 4/10 trial がこの mode で死亡していた。

## Fix

`%plan-with-review` に **L1 deterministic structural gate**
(`%validate-plan-test-sources`) を追加。 planner-fn が return した plan の
全 step に対して `validate-test-source` を実行、 planner-error を 一覧
化して replan request の failure-context に変換する。 既存の LLM 経由
plan/tests review reject path と同じ shape で動作。

L1 が reject すると review-replan-count が増え、 max-review-replans (2)
で打ち止め → status :LIMIT-EXHAUSTED に着地 (silent ERROR より visible)。

## 比較データ

### Before (4f0a93e + regression fix, 1779821262 stem)

| Trial | Status | Replans | Elapsed |
|---:|---|---:|---:|
| 1 | :STUCK | 1 | 1067s |
| 2 | **ERROR (test_source parse eof)** | — | 208s |
| 3 | :STUCK | 2 | 1253s |
| 4 | **ERROR (test_source parse eof)** | — | 263s |
| 5 | **ERROR (test_source parse eof)** | — | 241s |
| 6 | **ERROR (test_source parse eof)** | — | 221s |
| 7 | :PASSED | 0 | 392s |
| 8 | :PASSED | 0 | 728s |
| 9 | :PASSED | 0 | 458s |
| 10 | :PASSED | 0 | 753s |

**Pass rate: 4/10 (40%)**, ERROR: 4/10 (40%), STUCK: 2/10 (20%)

### After (Finding 6 fix on top, 1779828445 stem)

| Trial | Status | Replans | Steps | Elapsed |
|---:|---|---:|---:|---:|
| 1 | :LIMIT-EXHAUSTED | 1 | 3 | 1055s |
| 2 | ERROR (JSON decode eof) | — | — | 361s |
| 3 | :LIMIT-EXHAUSTED | 0 | 0 | 437s |
| 4 | :PASSED | 1 | 6 | 1474s |
| 5 | :PASSED | 1 | 6 | 1173s |
| 6 | :PASSED | 0 | 3 | 588s |
| 7 | ERROR (JSON decode eof) | — | — | 724s |
| 8 | :LIMIT-EXHAUSTED | 0 | 0 | 453s |
| 9 | :PASSED | 0 | 3 | 431s |
| 10 | :PASSED | 0 | 3 | 443s |

**Pass rate: 5/10 (50%)**, ERROR: 2/10 (20%), LIMIT-EXHAUSTED: 3/10 (30%)

## Effect

### Direct (Finding 6 fix が catch するパターン)

| metric | Before | After | Δ |
|---|---:|---:|---:|
| `test_source parse error: end of file` | 4/10 | **0/10** | **-4** |
| Pass rate | 40% | 50% | +10pt |
| STUCK | 20% | 0% | -20pt |
| LIMIT-EXHAUSTED | 0% | 30% | +30pt |
| ERROR (任意理由) | 40% | 20% | -20pt |

`test_source parse error: end of file` を **完全に消去**。 4 件 ERROR の
うち 1 件が PASS に転じ、 3 件が LIMIT-EXHAUSTED (silent ERROR より
visible な terminal state) に着地。 STUCK 2 件が消えたのは replan path
で別経路に逃げたため。

### Trade-off

- **elapsed mean (PASSED-only): 583s → 822s** — replan を救済するので
  LLM call が増え、 時間 cost が pile up。 中身を見ると mean を押し上げ
  ているのは trial 4/5 の 1474s / 1173s (replans=1)。 median 自体は
  588s で変化なし
- **steps: 3 → 6 (replan ありの trial で)** — replan で step が増えて
  実行コストは上がるが「死ぬよりはマシ」 方向の trade-off

### 残存

- **`JSON decode failed: end of file`** (yason 経由) が 2 件で発生 →
  これは `chat-parse-response` 内で raised される別 layer の failure で、
  `%plan-with-review` の deterministic gate が呼ばれる前 (planner-fn の
  内部) に起きる。 Finding 7 候補:
  > planner-fn の chat-parse-response が malformed JSON を受け取った場合
  > に planner-error を replan path に変換する

## Test

新規 unit test:
- `plan-with-review-replans-on-structurally-invalid-test-source`:
  planner stub が最初に malformed source、 次に valid source を返す
  scenario。 develop が abort せず status :passed で完了することを assert

全 497 件 GREEN。

## 結論

Finding 6 fix は意図通り `test_source parse error: end of file` を
完全に消去し、 fatal abort を visible terminal state (LIMIT-EXHAUSTED) や
PASSED に振り分ける。 pass rate +10pt と ERROR -20pt の net positive
effect。 trade-off として PASSED elapsed が伸びる場合がある (replan 経由
recovery のコスト) が、 これは設計上の意図通り。
