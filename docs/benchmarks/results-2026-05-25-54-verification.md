# #54 verification bench: 100/101/102/104 × N=3 on 5ee88fb

**Date**: 2026-05-25
**Code**: cl-harness main @ 5ee88fb (post-#53 NIL guard + #54 review prompt rebalance)
**Baseline**: `docs/benchmarks/results-2026-05-24-48-50-verification.md` (5a32b89, post-#48+#50)
**Settings**: review-policy=auto, max-impl-review-revisions=2, max-replans=3,
read-timeout=1200s, natural planner (no predefined-plan)
**Provider**: Qwen3.6-35B-A3B @ http://192.168.0.17:8000/v1
**Driver**: /tmp/bench-54-verify-1779628433.lisp
**Wall-clock total**: ~2 hours 5 min (cells: 12)
**Cells**: 12 (4 fixtures × 3 trials)
**Note**: /tmp disk full during 104 trial3 summary write (other processes holding ~1.9GB
in Chrome-Cache / mcomix tempfiles). Per-step transcripts cleaned up to recover space;
develop-level data preserved at `.bench-data/2026-05-25-54-verify/`.

## 結論: **Pass rate 42% → 67% (+25pt)**, 但し 102 で予期しない regression

| Metric | Pre (5a32b89) | Post (5ee88fb) | Δ |
|---|---:|---:|---|
| **Pass rate** | **5/12 (42%)** | **8/12 (67%)** | **+25pt** |
| Trivial fixtures (100, 101) | 2/6 | **6/6** | +67pt |
| Complex fixtures (102, 104) | 3/6 | 2/6 | -17pt |
| 102 alone | 2/3 | 0/3 | **-67pt regression** |

#54 (review approve-by-default) effect は trivial fixture で完璧、102 で逆効果。
**alarm signal**: 全体改善でも regression を見落としてはいけない。

## 結果テーブル

| Fixture | Pre (5a32b89) | Post (5ee88fb) | Δ |
|---|---|---|---|
| 100-greet | LIMIT 946s / PASSED 356s / STUCK 803s = **1/3** | PASSED **151s** / PASSED **162s** / PASSED **161s** = **3/3** ⬆ |
| 101-double | PASSED 156s / ERROR 365s / LIMIT 1287s = **1/3** | PASSED **123s** / PASSED **110s** / PASSED **137s** = **3/3** ⬆ |
| 102-counter-class | PASSED 605s / GIVE-UP 365s / PASSED 489s = **2/3** | LIMIT 1586s / STUCK 1198s / LIMIT 1878s = **0/3** ⬇ |
| 104-cache-simple | LIMIT 494s / PASSED 530s / LIMIT 448s = **1/3** | PASSED 410s / PASSED 577s / STUCK ~ = **2/3** ⬆ |

### Wall-clock 比較 (PASSED runs only)

- 100-greet: pre PASSED 356s → post mean 158s (**-56%**)
- 101-double: pre PASSED 156s → post mean 123s (**-21%**)
- 104-cache-simple: pre PASSED 530s → post mean 494s (-7%)
- 102 PASSED 無し (regression)

trivial fixture で wall-clock 半減 ← review が早く approve、agent が早く finish。

## #54 (approve-by-default) effect 観察

### Positive: 100 / 101 が 100% PASSED + 大幅短縮

prior bench で 1/3 だった 100-greet と 101-double が **両方 3/3 PASSED**。
wall-clock も 100 で -56%。review が agent の最初の合理的な submit を即時 approve するように
なり、無駄な replan が消えた直接的効果。

### Negative: 102 の **0/3 regression** (review が weak plan を通してしまう)

| Trial | Status | Replans | Steps |
|---|---|---:|---:|
| 1 | :LIMIT-EXHAUSTED (max-replans) | 3 | 5 |
| 2 | :STUCK (no-progress) | 3 | 4 |
| 3 | :LIMIT-EXHAUSTED (max-replans) | 3 | 5 |

全 trial が **3 replans (= max-replans 上限)** に到達。これは:
- Pre: review が strict → weak plan を reject → 改善要求 → eventually pass
- Post: review が approve-by-default → weak plan も approve → agent が実行 → verify fail
  → replan → 別 weak plan → 同 cycle → replan budget 切れ

**仮説**: 102 (counter class + 3 generic functions) の planner output は test stub の
品質に幅があり、Pre は review が weak stub を弾いて改善版を出させていた。Post の approve
-by-default はこの safety net を外してしまった。

特に 102 で steps=5 / replans=3 が多い ← 各 replan で planner が新 plan を提示するが、
それも weak で agent が完走できない loop。

## 集計 (デバイス制約による partial data)

per-step transcript は disk 枯渇で削除済 (tool-error / patch-quality 集計は今回 N/A)。
develop-level summary のみ:

```
Pass rate: 8/12 = 67% (+25pt vs pre 5/12)
Failure mode breakdown (post):
  :LIMIT-EXHAUSTED (:MAX-REPLANS): 2 (102 trial1, trial3)
  :STUCK (:NO-PROGRESS): 2 (102 trial2, 104 trial3)
  :PASSED: 8
```

`:MAX-REVIEW-REPLANS` は **post で 0 件** (pre は 4 件) — #54 直接効果 ✅。
代わりに `:MAX-REPLANS` と `:NO-PROGRESS` が 102 で 4 件に concentrated。

## 推奨次アクション

### 102 regression への対応 (新規 backlog 候補 #55)

#54 の approve-by-default は trivial fixture では正しいが、複雑 fixture
(多 generic function + class) で review-by-LLM の safety net を完全に外すと
weak plan が通過する。提案:

1. **stage-aware review**: plan review は softer、tests review は stricter
2. **scope-based threshold**: plan-step が >= N (e.g. 3) generic-function を要求する
   なら test stub の coverage check を強化
3. **failure-aware retry**: agent が同 step で 2+ replan しても progress なしの場合、
   review prompt を一時的に strict に切り替え
4. もしくは planner prompt 側で 102 patterns (CLOS class + multi-method) の test stub
   品質を改善 (backlog #41 / #50 の延長)

### #53 effect は今 bench で direct test されず

101-double 1/3 ERROR (verify-result-status NIL) は本 bench で発生せず → #53 が pre-emptive
に防いだ可能性、もしくは元々 sporadic。

## 既存 backlog との関係

- ✅ **#54 implementation の direct effect 実証**: `:MAX-REVIEW-REPLANS` 4→0、trivial
  fixture pass-rate 67pt 改善
- ⚠ **#54 の side effect 観察**: 102 で over-approval regression、新 backlog #55 候補
- **#41 / #50 の重要度上昇**: 102 の planner stub 品質が #54 regression の根因
- #53 (NIL guard) は preventive、今 sample で発火せず

## 副次成果

- **trivial fixture が初の 100% 完走**: 100-greet 3/3、101-double 3/3
- **Wall-clock 大幅短縮**: 100 -56%、101 -21% (PASSED runs)
- **Review 関連 failure mode (:MAX-REVIEW-REPLANS) を 100% 解消**: 4→0

## 学び

- **大胆な prompt 変更は target 改善と意外な side effect の両方を持つ**: 100/101 で完全勝利、102 で
  完全敗北
- **trivial / complex fixture の最適 review threshold が異なる**: 1 つの prompt で両方
  satisfy するのは難しい → 動的 threshold (#55 候補) が必要
- bench-cycle skill の **dispose-friendly な disk usage 設計** が必要 (今回 disk 枯渇で
  log/step transcripts を失った)
