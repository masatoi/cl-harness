# #56b verification: initial-verify seeding doesn't reach default threshold either

**Date**: 2026-05-26
**Code**: cl-harness main @ fa51fc4 (#56 with initial-verify seeding)
**Fixtures**: 100-greet / 101-double / 102-counter-class / 104-cache-simple × N=3
**Driver**: /tmp/bench-56b-verify-1779720518.lisp
**Wall-clock total**: ~120 min

## 結論: **#56 default threshold (3) 依然 fire 0 件 — 観察された failed step は典型 verify 数 2**

| Bench | Pass rate | #56 fires |
|---|---:|---:|
| 73ebeb9 (H baseline) | 11/12 (92%) | N/A |
| 485ac0a (#56 first impl, post-patch only) | 8/12 (67%) | 0 |
| **fa51fc4 (#56b initial-seeded)** | **9/12 (75%)** | **0** |

#56 initial-verify seeding は実装通り working だが **threshold 3 に届かない** —
失敗 step の典型 verify 数が 2 (initial + 1 post-patch) で、 streak max=2 <3。

## 結果テーブル

| Fixture | Trial 1 | Trial 2 | Trial 3 |
|---|---|---|---|
| 100-greet | PASSED 171s | PASSED 165s | PASSED 149s |
| 101-double | PASSED 159s | PASSED 175s | PASSED 151s |
| 102-counter-class | ERROR (planner JSON) 198s | PASSED 371s | PASSED 532s |
| 104-cache-simple | PASSED 416s | :STUCK 940s | :STUCK 1045s |

100/101 完璧、 102 大幅改善 (2/3、+1 ERROR は planner-side JSON empty)、 104 依然 1/3。

## 失敗 step の verify count 分布

```
4 failed-step transcripts in this bench:
  step1 (test-put-and-get):       verifies=2  → #45 fired
  step0 (test-make-cache):        verifies=2  → #45 fired
  step1 (test-cache-put):         verifies=2  → max-patches fired
  step0 (test-make-cache):        verifies=3  (but step PASSED, not failed)
```

failed step の **典型 verify 数 = 2** (initial + 1 post-patch)。 #45 (consecutive
failed patches) や max-patches が先に fire するため、 #56 が threshold 3 に届く前に
abort される。

## #56 の position evaluation

| Metric | Result |
|---|---|
| Implementation correctness | ✅ unit tests 482 pass |
| Wiring (post-patch + initial verify) | ✅ both update streak |
| Fire rate in observed workload | **0 / 24 cells across 2 verification benches** |
| Pass rate regression | ❌ no (#56 fire 0 → cannot cause regression; 11/12 → 9/12 は variance) |
| Cost | minimal (1 slot + 1 check) |
| Benefit so far | 0 (never fires) |

#56 は **silent preventative code** で現状の workload には届かない。 これは
H instrumentation (compact fires 0/157) と類似の "implemented but dormant" 状態。

## 3 つの選択肢

### Option A: threshold を 2 に lower (aggressive)

initial + 1 post-patch verify が同 key なら fire。 但し:
- patches 失敗が 1 turn 内で起きる typical pattern (read → patch → fail-key 同じ) で
  FP fire しまくる可能性
- agent の "natural progress" (defclass 追加 → 依然 method missing CFE) も
  捕まえてしまう

→ **N=10 paired bench で empirical 検証必須**、 現時点では risky

### Option B: 現状維持 (silent preventative)

cost ほぼゼロ (1 slot + 1 check + 1 log event)、 fire しないので harm もなし。
fixture 規模が大きくなり typical step の verify 数が 3+ になれば自動的に effective に。

→ **無害な future-proofing**

### Option C: Remove #56

未使用 code を keep する cost を避ける。 但し implementation 自体は健全で、
将来の bigger fixture で role を果たす可能性あり。

→ minor cleanup、 H instrument が示したと同様「動かない code 改善は無意味」原則

## 102-trial1 ERROR (planner JSON decode)

新 failure mode: planner LLM が empty content 返却 → yason が end-of-file エラー。
backlog #40 (complete-chat empty content retry) で吸収可能。 single occurrence なので
sporadic Qwen behavior。

## 推奨

**Option B (現状維持)** が最も合理的:
- #56 自体は cost ほぼゼロ
- 動かないことが新たに確認できた (H instrumentation similar story)
- 将来 fixture が大規模化 / model 変更時に意味を持つ可能性

優先順位:
1. **#56 関連は当面 freeze** (H と同じ "implemented dormant" 扱い)
2. 残 backlog の中で **#41 / #50 強化** (planner stub quality) が 104 chronic 困難への
   最大 lever — planner が同 fixture で plan を生成する quality が agent の成功率を決める
3. #40 (planner empty content retry) を簡易実装 (sporadic だが reactive)

## 学び

- **限界値 (threshold) の design は計測無しで合理判断できない** — #56 default 3 は
  104-trial2 single observation から推測したが、 実際の失敗 step は verify 2 件で
  終わる pattern が dominant
- **H instrumentation patterns が #56 評価でも適用** — 計測 → 動いていない確認 →
  freeze。 思考の framework が再利用できた
- **新 limit の addition は H instrumentation 後にやるべき** — 動いている前提で
  default tuning するより、 動かないことを先に確認する
