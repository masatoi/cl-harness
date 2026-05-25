# #50b verification: one-new-symbol rule, planner adherence OK but pass rate flat

**Date**: 2026-05-26
**Code**: cl-harness main @ d269d1f (post-#50b planner one-new-symbol rule)
**Driver**: /tmp/bench-50b-verify-1779726992.lisp
**Wall-clock total**: ~85 min

## 結論: **Planner adherence ✅ (rule に従い 4-step plans 多発)**、 **pass rate 改善せず**

### Pass rate trajectory (累積)

| Commit | Pass rate | 主要変更 |
|---|---:|---|
| 73ebeb9 (H baseline) | 11/12 (92%) | — (instrumentation) |
| 485ac0a (#56 first impl) | 8/12 (67%) | new limit (dormant) |
| fa51fc4 (#56b initial-seeded) | 9/12 (75%) | (same dormant) |
| **d269d1f (#50b one-new-symbol)** | **8/12 (67%)** | planner rule |

H baseline 11/12 は recent peak、 以降 3 commits は 8-9/12 範囲。

### 結果テーブル

| Fixture | Trial 1 | Trial 2 | Trial 3 |
|---|---|---|---|
| 100-greet | PASSED 156s | PASSED 151s | PASSED 144s |
| 101-double | PASSED 141s | PASSED 167s | PASSED 103s |
| 102-counter-class | **:STUCK / GIVE-UP 603s** | **:STUCK / LIMIT-EXHAUSTED 597s** | PASSED 620s |
| 104-cache-simple | **ERROR (planner JSON)** | **:STUCK / LIMIT 644s** | PASSED 428s |

## Planner rule adherence 検証

planner output structure を見ると **rule に従っている** (4-step plans 多発):

| Fixture | Plan structure | Status |
|---|---|---|
| 102-trial1 | 4 steps `[test-counter-class-and-reader, test-make-counter, test-increment, test-reset-counter]` | give-up at step3 |
| 102-trial2 | 4 steps `[test-make-counter, test-counter-value, test-increment, test-reset-counter]` | limit at step0 |
| 102-trial3 | 4 steps `[test-make-counter-creates-instance, test-counter-value-default, test-increment-bumps-count, test-reset-counter-returns-zero]` | PASSED |
| 104-trial2 | 4 steps `[test-simple-cache-class, test-make-cache, test-cache-put, test-cache-get]` | limit at step2 |
| 104-trial3 | 3 steps `[test-make-cache, test-cache-put, test-cache-get]` | PASSED |

→ planner は **separate 1-symbol step を生成するように**。 1 例外 (102-trial1 step0
`test-counter-class-and-reader` で 2 symbol combined) のみ。

## 失敗の分類

| Failure | Root cause | #50b 関連? |
|---|---|---|
| 102-trial1 give-up at step3 | 3 step PASSED 後 last step (test-reset-counter) 諦め | maybe (4 step plan で extra failure point 増えた) |
| 102-trial2 limit at step0 | **max-action-parse-errors** (Qwen が 3 consecutive JSON parse error) | **NO** (Qwen sampling bug) |
| 104-trial1 ERROR | **planner-error JSON decode** (Qwen empty content) | **NO** (Qwen sampling bug) |
| 104-trial2 limit at step2 | 2 step PASSED 後 test-cache-put で stuck | maybe (split で extra failure point) |

**4 failures のうち 2 は Qwen sampling bug** (backlog #40 で吸収可能)。
真の #50b 関連は 2 件: いずれも multi-step plan の **後半 step で stuck**。

### 仮説: split で failure points が増えた?

`one-new-symbol per step` rule で planner が plan を **3-step → 4-step** に
fragment 化。 各 step が個別 budget (max-patches=5) を持つので:

- 4-step plan: 4 chances to fail
- 3-step plan: 3 chances to fail

Pre-rule (combined step1): step1 で 2 symbols 一度に → 1 step で fail
Post-rule (separated): step1 で 1 symbol、 step2 で別 1 symbol → 2 steps で fail risk

理論上の trade-off: combined step は **1 step 内の patch 必要数増加** で fail risk 高
separated step は **plan 全体の step 数増加** で fail risk 累積

empirical signal が示唆: **どちらが net positive かは fixture / model 依存**。
104 chronic 困難の root cause が "agent が put/get の 1 patch 試行" だったので
combined step 化が逆に問題に。 一方 102 では separate step でも 4-step 化で
late-step failure を作っている可能性。

## 累積観察

pass rate trajectory:
- 0368f1e (baseline): 4/12 (33%)
- 5ee88fb (#54): 8/12 (67%)
- 2a176cd (#55): 10/12 (83%)
- 73ebeb9 (H): 11/12 (92%) ← peak (variance-driven likely)
- 485ac0a/fa51fc4/d269d1f: 8-9/12 (67-75%) ← post-H 範囲

**11/12 H peak は変動の上限、 真の pass rate は ~70-80% 程度** (Wilson 95% CI:
[42%, 90%] と広い、 N=3 では断定不能)。

100/101 は 直近 4 benches 連続で 12/12 PASSED ← trivial fixtures は完全に解消。
全 variance は 102/104 由来。

## 推奨

### Option A: rule を refine — 「prefer 1 new symbol」を soft hint に弱める

現状の rule は強制的すぎる可能性。 「prefer」を「balance: minimize multi-symbol
risk vs minimize step count」と表現。 但し実装複雑。

### Option B: rule をそのまま keep + N=10 paired で再評価

empirical 信号弱い (8 vs 9 vs 11) 中で結論せず、 N=10 paired bench で:
- pre-#50b (revert) と post-#50b で同 fixture × N=10
- 統計的に有意かを確認

Cost: ~3-4 hours wall-clock。

### Option C: rule revert

8/12 vs 9/12 vs 11/12 で改善なし → 効果 evidence 弱。 revert して別 lever を探る。
但し H pattern と同じ「implemented but minimal effect」状態で freeze するのも合理的。

### 推奨: **Option B → 結果次第で Option C**

#50b は code review 段階で empirical signal が一見強かった (28.6% vs 62.5%) が、
N=15 trials 程度の sample で interpretable 信号は実は小さかった可能性。 N=10 paired
で確認すれば conclusive。

## 学び

- empirical signal の strength is sample-size-dependent — N=15 では 28.6% vs 62.5%
  に見えたが、 別の view では variance に隠れた
- planner rule の application is verifiable from JSONL (確実に rule 通り plan が
  出ている)。 implementation は正しい。
- 「planner rule changes」も H instrumentation similar に dormant / minimal-effect
  状態が起きうる
- 真の bottleneck は **agent の patch 戦略 / model の output quality** で、
  planner level の改善はそれを fundamentally 変えない可能性

## 既存 backlog との関係

- #50b implementation 正しい (planner adherence empirical 確認)
- 効果 weak — pass rate に大きく影響せず
- #40 (planner / complete-chat empty content retry) 重要度上昇 (Qwen JSON bug が
  2 件 fail を caused)
- 次 lever 候補: **Qwen sampling robustness** (#40), **agent prompt 多様化**
