# bench-cycle: 103-fizz-buzz, 102-counter-class, 104-cache-simple

**Date**: 2026-05-27
**Code**: cl-harness main (4f0a93e + tolerant-package read regression fix on top)
**Settings**: review-policy=auto, max-impl-review-revisions=2, log-llm-requests=t, max-replans=3
**Driver**: /tmp/bench-cycle-1779812831.lisp
**Purpose**: DR-2026-05-27 implementation review fix (H1/M1/M2/L1) の
effect 確認

## 結果サマリ

| Task | Status | Replans | Steps | impl-reviews | impl-rejections | Elapsed |
|---|---|---:|---:|---:|---:|---:|
| 103-fizz-buzz | :PASSED | 0 | 3 | 3 | 0 | 243.6s |
| 102-counter-class | :PASSED | 0 | 3 | 3 | 0 | 450.2s |
| 104-cache-simple | :PASSED | 0 | 3 | 3 | 0 | 814.5s |

**3/3 clean pass** (0 replan、 0 impl-rejection、 0 test_change_request 観測)。

## 主結果

### 1. Implementation review fix の direct effect は **N=1 で観測できない**

3 fixture が一発で通ったため、 H1 (name collision) / M2 (L1 reject feedback)
の経路は **発火しなかった**。 つまり今回の bench で確認できたのは:

- **regression が無い** こと (baseline 維持)
- 既存 N=10 paired bench で 67-92% variance だった条件下、 N=1 で 3/3 PASSED
  は LLM output 質の許容範囲

H1/M2 の直接 effect 観測には **意図的に collision / malformed source を仕込んだ
synthetic test** または **N=10 paired bench で test_change_request 発生 fixture
(100-greet 等) を回す** 必要がある。

### 2. **Critical regression を発見・修正**

初回 bench-cycle で **3 fixture すべて planner-error で死亡**:

```
103-fizz-buzz ERROR: planner-error: test_source parse error: Package FIZZ-BUZZ does not exist.
102-counter-class ERROR: planner-error: test_source parse error: Package COUNTER does not exist.
104-cache-simple ERROR: planner-error: test_source parse error: Package CACHE does not exist.
```

**Root cause**: `validate-test-source` (d6fa5a9 で導入された structural read
gate) が、 planner-emit する `(deftest fizz-buzz::sample ...)` のような
package-qualified symbol を read しようとすると、 開発対象 system のパッケージは
まだ image に存在しないため **`READ` 段階で `package-error`**。 これは
DR-2026-05-27 fix 直接の bug ではなく、 d6fa5a9 から潜在していた hazard で、
N=10 paired bench では `test_change_request` 経路から呼ばれるパターンが多く
**隠れていた** だけ。

**Fix**: `%pre-create-referenced-packages` を新設し、 `%read-single-form-from-
string` の冒頭で source を pre-scan して `NAME:` / `NAME::` パターンに遭遇した
ら missing package を空 (`:use nil`) で `make-package` + 必要なら symbol を
`intern` & `export`。 副作用は ephemeral sandbox worker に限定されるので image
を汚染しない。 unit test `validate-test-source-accepts-qualified-symbols-from-
unknown-packages` で RED→GREEN 確認、 全 496 件 GREEN。

### 3. 既存 N=10 paired bench との比較

| 観点 | N=10 paired (過去) | 今回 N=1 |
|---|---|---|
| pass rate | 67-92% variance | 100% (3/3) |
| replan | 平均 0.5-1.5 | 0 |
| test_change_request | 観測あり (104-cache-simple) | 観測なし |
| elapsed | fixture 依存 | 4-14min/fixture |

N=1 では variance を抑制できないため、 今回 100% は LLM 出力が "good day" だった
だけの可能性が高い。 fix の **defensive layer としての effect** は引き続き N=10
paired bench でないと measure できない。

## 既存 backlog との関係

- 新規 backlog 候補: 0 件 (failure narrative が無いため)
- 既存 backlog #DR-2026-05-27 implementation review followup を更新
  (regression fix を追記予定)

## 推奨次アクション

1. **regression fix を commit** (`%pre-create-referenced-packages` + 新 test +
   docstring 更新)。
2. N=10 paired bench で fix の defensive effect を後日 measure
   (test_change_request 発生 fixture: 100-greet, 104-cache-simple 中心)。
3. test_change_request が rare event である事実を踏まえ、 H1/M2 を bench で
   観測したいなら **synthetic agent stub** (intentional name collision /
   malformed source emission) の方が cost-effective。
