# #55 verification bench: 100/101/102/104 × N=3 on 2a176cd

**Date**: 2026-05-25
**Code**: cl-harness main @ 2a176cd (post-#55 stage-aware review prompt)
**Baselines**:
- Pre-#54 (5a32b89): `docs/benchmarks/results-2026-05-24-48-50-verification.md`
- Post-#54 (5ee88fb): `docs/benchmarks/results-2026-05-25-54-verification.md`
**Settings**: review-policy=auto, max-impl-review-revisions=2, max-replans=3,
read-timeout=1200s, natural planner (no predefined-plan)
**Provider**: Qwen3.6-35B-A3B @ http://192.168.0.17:8000/v1
**Driver**: /tmp/bench-55-verify-1779636665.lisp
**Wall-clock total**: ~72 min (cells: 12)
**Cells**: 12 (4 fixtures × 3 trials)

## 結論: **Pass rate 67% → 83% (+17pt)**, **102 が 0/3 → 3/3 完全回復**

| Metric | Pre-#54 (5a32b89) | Post-#54 (5ee88fb) | **Post-#55 (2a176cd)** | Δ vs prior |
|---|---:|---:|---:|---:|
| **Pass rate** | 5/12 (42%) | 8/12 (67%) | **10/12 (83%)** | **+17pt** |
| 100-greet | 1/3 | 3/3 | 3/3 | maintain |
| 101-double | 1/3 | 3/3 | 2/3 | -1 |
| **102-counter-class** | **2/3** | **0/3** | **3/3** | **+3 ✨** |
| 104-cache-simple | 1/3 | 2/3 | 2/3 | maintain |
| Mean wall-clock / cell | ~860s | ~540s | **~362s** | -33% |
| Total wall-clock | 10138s | 6481s | **4349s** | -33% |

**#55 (stage-aware review prompt) が target だった 102 regression を完全に解消**。
102 が 0/3 → 3/3 + 100/104 維持 → aggregate pass rate が 67% → 83% に。

Pre-#54 から累積で **42% → 83% (+41pt)** の改善。

## 結果テーブル

| Fixture | Pre-#54 (5a32b89) | Post-#54 (5ee88fb) | Post-#55 (2a176cd) |
|---|---|---|---|
| 100-greet | LIMIT/PASSED/STUCK | PASSED 151s/162s/161s | **PASSED 133s/217s/198s** |
| 101-double | PASSED/ERROR/LIMIT | PASSED 123s/110s/137s | PASSED 139s/126s / **STUCK 443s** |
| 102-counter-class | PASSED/GIVE-UP/PASSED | LIMIT/STUCK/LIMIT | **PASSED 400s/685s/451s** |
| 104-cache-simple | LIMIT/PASSED/LIMIT | PASSED 410s/578s / STUCK | PASSED 486s/382s / **STUCK 691s** |

## #55 (stage-aware review prompt) の effect 分析

### 102-counter-class: 0/3 → 3/3 (+3) — direct evidence of #55 effect

| Trial | Pre-#54 | Post-#55 | Δ |
|---|---|---|---|
| 1 | :LIMIT-EXHAUSTED (1586s, 3 replans) | **:PASSED (400s, 0 replans, 2 steps)** | -1186s, +pass |
| 2 | :STUCK (1198s, 3 replans) | **:PASSED (685s, 0 replans, 3 steps)** | -513s, +pass |
| 3 | :LIMIT-EXHAUSTED (1878s, 3 replans) | **:PASSED (451s, 0 replans, 4 steps)** | -1427s, +pass |

全 trial が 0 replan で完走、wall-clock 平均 **-66%**。

仮説検証 ✅: Post-#54 では approve-by-default が weak test stub を通して agent が
満たせず replan 3 回 → 失敗。Post-#55 で **tests review が strict** に戻ったことで
weak stub を弾き、planner が改善版を出して agent が一発で解ける plan に。impl-reviews
2-4 件 / impl-rejections 0 件 — review がちゃんと機能しているが reject していない
(= 改善された plan + impl quality 共に approval 基準を満たしている)。

### 101-double: 3/3 → 2/3 (-1) — minor regression

trial3 のみ :STUCK (443s, 1 replan)。Pre-#54 では 1/3 (1 PASSED) 程度だったので
variance 範囲。strict tests review が trivial fixture でも稀に reject する可能性あるが、
N=3 では断定不能。

### 104-cache-simple: 2/3 → 2/3 — maintain

異なる trial が STUCK (pre は trial3、post も trial3 だが reason 違い)。stable。

### 100-greet: 3/3 → 3/3 — maintain (wall-clock やや増)

mean elapsed 158s → 182s (+15%)。stricter tests review が初動で +1 turn 使う可能性
だが、いずれも PASSED。

## 累積 improvement の trajectory

| Commit | Pass | wall-clock | 主要変更 |
|---|---:|---:|---|
| 0368f1e (pre-#38 removal) | 4/12 (33%) | ~10138s | baseline |
| 1f29778 (#38 removal) | (not measured on this subset) | — | net-negative removal |
| 5a32b89 (#48 + #50) | 5/12 (42%) | 6481s | fs-write-file + planner stub fix |
| 5ee88fb (#53 + #54) | 8/12 (67%) | 6481s? | NIL guard + approve-by-default |
| **2a176cd (#55)** | **10/12 (83%)** | **4349s** | stage-aware tests-strict |

**約 1 日で pass rate 33% → 83% (+50pt)、wall-clock -57%**。

## 失敗 case detail

### 101-double trial3 (:STUCK, 443s, 1 replan, 1 step)

可能性:
- stricter :tests review が trivial 'double' 関数の最初の test stub を reject → replan
  → agent が改善版で進めても結局 stuck (詳細不明、step transcript 必要)
- variance (N=3 では捕捉困難)

### 104-cache-simple trial3 (:STUCK, 691s, 1 replan, 3 steps)

3 steps 実行 (impl-reviews 2 件) して途中で stuck。multi-symbol test の inner method
dispatch issue 等の可能性。

## 既存 backlog との関係

- ✅ **#55 implementation の direct effect 実証**: 102 完全回復 (0/3 → 3/3)
- ✅ **#54 の core gain 維持**: 100/101 で trivial fixture pass rate ほぼ満点
- ⚠ **101-double 1 STUCK / 104 1 STUCK**: variance か新 issue か N=10 で再評価必要
- **#45 (#55 と直交)** は本 sweep で fire 観測されず
- **#41 / #50 強化路線** は引き続き有効 (planner stub 品質改善)

## 推奨次アクション

1. **N=10 sweep on 100/101/102/104** で 83% pass rate の statistical confirmation
   (現 N=3 では CI 広い)
2. **101 trial3 / 104 trial3 STUCK の詳細調査** (step transcripts から root cause 抽出)
3. **103/105/106 にも sweep を拡張** して full 7-fixture baseline 更新
4. 残 candidates: #41/#50 強化、planner prompt 品質改善、bench-cycle skill の
   dispose-friendly 化

## 学び

- **target された stage-aware split は regression を完全に治癒できる** (102: 0/3 → 3/3)
- **#54 の trivial-fixture gain (+200% pass) を保ちながら 102 を救う** ことが可能だった
- **prompt-level 改善の cumulative ROI が大きい**: 4 commits (#48/#50/#54/#55) で
  pass rate +50pt、wall-clock -57%
- per-step transcript を保存できなかった (disk space) のは引き続き痛い → bench-cycle skill
  の dispose-friendly な disk 管理 が次の cycle で必要
