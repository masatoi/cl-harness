# #56 verification bench + initial-verify wiring follow-up (2026-05-25)

**Date**: 2026-05-25
**Code @ bench**: cl-harness main @ 485ac0a (#56 max-stalled-verify-cycles 初実装)
**Code @ follow-up**: 次 commit (initial verify を streak に seeding)
**Fixtures**: 100-greet / 101-double / 102-counter-class / 104-cache-simple × N=3 = 12 cells
**Settings**: review-policy=auto, max-replans=3, max-context-tokens=4000,
read-timeout=1200s, log-llm-requests=nil
**Provider**: Qwen3.6-35B-A3B @ http://192.168.0.17:8000/v1
**Driver**: /tmp/bench-56-verify-1779708241.lisp
**Wall-clock total**: ~120 min

## 結論: **#56 は本 bench で 1 度も発火せず, threshold 設計の見直しが必要**

### Pass rate (cumulative trajectory)

| Commit | Pass | Notes |
|---|---:|---|
| 0368f1e (baseline) | 4/12 (33%) | — |
| 2a176cd (#55 stage-aware review) | 10/12 (83%) | — |
| 73ebeb9 (H instrumentation, 機能変更なし) | 11/12 (92%) | — |
| **485ac0a (#56 first impl)** | **8/12 (67%)** | **regression** |

8/12 は #55 直後 (10/12) を下回る。 **variance か #56 由来か** を切り分け必要。

### #56 limit fires: **0 / 12 cells**

```
Limit fires by type (across all cells / steps):
  max-consecutive-failed-patches (#45): 5
  max-stalled-verify-cycles (#56):       0   ← NEVER fired
  :compact event:                         0   (over-engineered confirmed, H baseline 維持)
```

#56 が 1 度も fire していないので、**pass rate 低下は #56 由来ではない** (= variance)。
但し意図した effect (104-trial2 like の早期 abort) も達成されていない。

### Why #56 didn't fire — analysis

104-trial2 H bench original analysis:
- Round 1 step 1: 初期 verify CFE + 2 post-patch verify (turns 6, 8) 同じ CFE

`%verify-failure-key` は post-patch verify でのみ streak update する設計のため:
- post-patch verify 1 (turn 6): streak = 1, key = CFE
- post-patch verify 2 (turn 8): streak = 2, same key — **fires only at streak ≥ 3**

→ max-patches=5 burn (turn 6/7/8/9/10) が先に到達。

## Fix (follow-up commit): 初期 verify を streak に seeding

`run-agent` の initial verify ブロックで `%verify-failure-key` を呼び、 失敗時に
`stalled-verify-streak = 1, last-verify-failure-key = key` を seed。 これで:

- initial CFE: streak 1, key CFE
- post-patch CFE (turn 6): streak 2, same key
- post-patch CFE (turn 8): streak 3, same key → **FIRES**

threshold 3 を維持しつつ 104-trial2 case を catch 可能に。

cl-harness/tests 482 passed (regression なし)。

## 結果テーブル

| Fixture | Trial 1 / 2 / 3 |
|---|---|
| 100-greet | PASSED 143s / PASSED 178s / PASSED 161s = 3/3 |
| 101-double | PASSED 169s / PASSED 183s / PASSED 156s = 3/3 |
| 102-counter-class | PASSED 438s / **:STUCK 1331s** / PASSED 684s = 2/3 |
| 104-cache-simple | **:STUCK 934s / :LIMIT 1709s / :STUCK 990s** = 0/3 |

104 が 0/3 で完全敗北。 全 trial が長時間 (~1000-1700s) 試行錯誤後に :STUCK / :MAX-REPLANS で abort。

これは **#56 implementation 不在/firing 不足** が原因ではなく、 Qwen3.6 が
104 の multi-symbol cache fixture で苦戦している variance / sampling 由来。 H bench
(73ebeb9) では 104 が 2/3 だったが、 本 bench (485ac0a, 機能差は #56 のみで
fire しない) では 0/3 — code 変更で説明できない。

## H bench 比較 (`:compact` / token estimate)

| Metric | H bench (73ebeb9) | #56 bench (485ac0a) |
|---|---:|---:|
| `:compact` fires | 0 | 0 |
| median prompt tokens | 1541 | (未集計だが近似 1500) |
| max prompt tokens | 2928 | (未集計) |

compaction の状況は不変 (再確認、 over-engineered 維持)。

## 推奨次アクション

1. **commit the initial-verify wiring fix** (今この commit で同時に)
2. **再 bench (#56 follow-up)** で:
   - `:max-stalled-verify-cycles` fire 回数 ≥ 1 を確認
   - 104-trial2 like cases が早期 abort (~700s → ~400s) を確認
3. 104 fixture の chronic 困難について別 angle (planner stub 改善 / paired bench で
   104 用 predefined plan 検討)

## 学び

- 「N=3 で pass rate drop」は noise が大きく即時 regression と決めつけられない —
  fire count と limit-attribution の確認が必要
- 新 limit を 初期 verify から seeding するかどうかは **default behavior の重要な
  question**、 unit test だけでは現れず empirical bench で判明
- threshold 3 + post-patch-only counting は 104 case (max-patches 5 burn しがち) で
  too late → 初期 verify counting で +1 streak head-start
- 計測 (H instrumentation) があるおかげで fire 0 を即時確認できた — 計測 first の
  ROI が再度実証

## 既存 backlog との関係

- ⚠ **#56 default tuning 必要** — initial verify seeding を含めて initial-aware に
- ✅ **H instrumentation works** — fire count / limit type の即時把握が可能
- 104 fixture の chronic 困難は #41 / #50 強化 (planner stub) 路線で別途
