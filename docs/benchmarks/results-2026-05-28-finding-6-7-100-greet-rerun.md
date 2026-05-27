# 100-greet N=10 re-measurement (post Finding 6+7, 2026-05-28)

**Date**: 2026-05-28 03:08 - 03:35 JST
**Fixture**: 100-greet
**Code**: cl-harness main @ e5b7650 (post Finding 6 + Finding 7)
**Setting**: review-policy=auto, max-impl-review-revisions=2, max-replans=3
**N**: 10 trials
**Purpose**: Finding 6+7 fix series が trivial fixture の baseline を
壊していないか + observable な variance 改善があるか確認

## 結果

| metric | Prior (pre F6+F7, stem 1779819462) | **Current (post F6+F7, stem 1779905424)** | Δ |
|---|---:|---:|---:|
| Pass rate | 10/10 (100%) | **10/10 (100%)** | 0 |
| elapsed mean | 148.3s ± 19.2 | **150.1s ± 10.9** | +1.8s mean, **-44% sd** |
| elapsed median | 145.5s | 152.1s | +6.6s |
| elapsed min / max | 128.0 / 196.2 | 131.5 / 167.7 | max **-28.5s** |
| LLM call mean | 4.3 ± 1.5 | **3.4 ± 1.0** | **-21%** |
| LLM call median | 4 | 4 | 0 |
| LLM call range | 2-8 | 2-4 | max **-50%** |
| token mean | 7274 ± 3070 | **5353 ± 1567** | **-26%** |
| token median | 6338 | 6277 | -61 |
| test_change_request | 0 | 0 | 0 |
| impl-rejection | 0 | 0 | 0 |
| replan | 0 | 0 | 0 |

## 評価

### Baseline 維持

100-greet は trivial fixture で planner output が安定しているため、
Finding 6 (deterministic L1 gate) と Finding 7 (planner-fn handler-case
wrap) はどちらも **発火しない**:

- test_change_request 0 件
- impl-rejection 0 件
- replan 0 件
- L1/L2 reject 0 件

それでも pass rate 100% を維持しており、 fix が trivial fixture の
happy-path を壊していない (no regression) ことは確認。

### Variance 縮小の signal

direct fix effect ではないが、 observable な variance 改善:

- **elapsed SD -44%** (19.2 → 10.9) — outlier 削減
- **max elapsed -28.5s** (196.2 → 167.7) — long-tail 削減
- **LLM call max -50%** (8 → 4) — Prior の trial 2 で 8 calls / 14980
  tokens だった outlier が今回消失

これは fix が catch する planner output failure とは別経路だが、
**baseline trial が tighter distribution に収束** している signal。
N=10 vs N=10 で sample variance に含まれる範囲なので strong claim
できないが、 net positive な方向性。

### Net Effect

| metric | Δ |
|---|---|
| Pass rate | 100% → 100% (no regression) |
| elapsed sd | -44% (variance shrink) |
| LLM call max | -50% (outlier eliminated) |
| token mean | -26% (lower bandwidth cost) |

trivial fixture でも accidental な **stability gain** が見える。 これは
おそらく N=10 同士の noise 範囲だが、 少なくとも fix が baseline を傷つ
けていないことは確実。

## 全 3 fixture 累積結果 (post Finding 6+7)

| Fixture | N | Pass rate | ERROR (post-F7) | ERROR (pre-fix) | Notes |
|---|---:|---:|---:|---:|---|
| 100-greet | 10 | **100%** | 0/10 | 0/10 (元々) | baseline maintained, variance shrunk |
| 104-cache-simple | 10 | **70%** | 0/10 | 4/10 (40%) | ERROR -40pt, Pass +30pt |
| 102-counter-class | 10 | **60%** | 0/10 | ~33% (history) | ERROR 消失, visible terminal へ |

**3/3 fixture で `planner-error` 系 silent ERROR を 0/10 達成**。 trivial
fixture (100) も non-trivial fixture (102, 104) も baseline 壊さず +
silent abort 消去。

## 結論

Finding 6+7 fix series は:
1. **silent ERROR を完全消去** (3 fixture すべてで)
2. **non-trivial fixture で pass rate 改善** (104: +30pt, 102: +27pt vs 5/26)
3. **trivial fixture の baseline 維持** (100: 100% 100% 不変)

→ fix series は **regression なし** & **non-trivial で大幅改善** という
理想形の effect を示している。

次の improvement target は LIMIT-EXHAUSTED / STUCK / GIVE-UP の解消で、
これは planner output 品質 / agent retry / Qwen sampling 質の話で
fix series の対象外。
