# H instrumentation bench: first instrumented view of compaction (2026-05-25)

**Date**: 2026-05-25
**Code**: cl-harness main @ 73ebeb9 (post-H instrumentation)
**Fixtures**: 100-greet / 101-double / 102-counter-class / 104-cache-simple × N=3 = 12 cells
**Settings**: review-policy=auto, max-replans=3, max-context-tokens=4000 (default),
read-timeout=1200s, log-llm-requests=nil
**Provider**: Qwen3.6-35B-A3B @ http://192.168.0.17:8000/v1
**Driver**: /tmp/bench-H-instr-1779651561.lisp
**Wall-clock total**: ~120 min

## 結論

### 1. Pass rate **過去最高 11/12 (92%)**

| Commit | Pass | Mean elapsed |
|---|---:|---:|
| 0368f1e (baseline) | 4/12 (33%) | — |
| 2a176cd (#55 stage-aware review) | 10/12 (83%) | — |
| **73ebeb9 (H instrumentation)** | **11/12 (92%)** | — |

H 自体は機能変更なし (純粋に instrumentation) — pass rate 上昇は variance + 環境状態
(server load, sandbox state, planner luck) の改善か。 N=3 では断定不能。

### 2. **Compaction は 1 度も発火していない (0/157 LLM calls)**

これが本 bench の本命データ。 `:compact` event count:
- **0 across all 12 cells**
- 157 LLM calls (`:llm-response` event) すべてで threshold 4000 tokens 未到達

| Cell | Max prompt tokens estimate | Margin to 4000 |
|---|---:|---:|
| 100-greet trial1 | 1551 | +2449 |
| 100-greet trial2 | 1686 | +2314 |
| 100-greet trial3 | 1933 | +2067 |
| 101-double trial1 | 1475 | +2525 |
| 101-double trial2 | 1368 | +2632 |
| 101-double trial3 | 1676 | +2324 |
| 102-counter-class trial1 | 2527 | +1473 |
| 102-counter-class trial2 | 2122 | +1878 |
| 102-counter-class trial3 | 2723 | +1277 |
| 104-cache-simple trial1 | 2392 | +1608 |
| 104-cache-simple trial2 | 2928 | +1072 |
| 104-cache-simple trial3 | 2876 | +1124 |

**全 cell max が 4000 の 75% 以下**。 worst case (104 trial2, 2928 tokens) でも threshold
まで 27% の余裕。

### 3. LLM call token distribution (n=157)

```
min      = 1223
median   = 1541
p90      = 2214
p99      = 2876
max      = 2928

>3000: 0/157 (0.0%)
>4000: 0/157 (0.0%)
```

平均 1541 tokens で `max-context-tokens 4000` の threshold の **38.5%**。

## 仮説の検証

code review で 3 仮説を立てていた:

| 仮説 | 検証結果 |
|---|---|
| **A**: context mgmt が背景で work している | ❌ **却下** — compact 0 fire = work 0 |
| **B**: 現 workload で over-engineered | ✅ **確定** — 全 LLM call が threshold 38.5% 中央 |
| C: subtle に hurt している | ❌ work していないので harm もできない |

**現状の context management layer は今の fixture set / Qwen3.6 では機能していない**
(発火しないため neither harm nor help)。

## 含意

### a. 直近の pass rate 改善 (#48-#55, +50pt) は context mgmt と無関係

compaction は 1 度も発火していないので、 +50pt は **agent prompt** (#48 fs-write-file,
#50 MOP), **review prompt** (#54/#55) の改善のみ由来。 context mgmt は dormant。

### b. `max-context-tokens=4000` は保守的すぎる可能性

p99=2876 で 4000 まで 1100 token 余裕。 8000 に上げても **現 fixture set では何も
変わらない** (発火しないので)。 hang risk (backlog #34 motivated 4000 化) との
trade-off だが、 現 instrumentation データから言えば **8000 でも safe**。

但し本 bench は 4 fixture × N=3 = 12 cells。 全 fixture × N=10 等の大規模 sweep
ではより extreme な outlier (e.g. 多 step replan + long agent history) が出る
可能性、慎重判断必要。

### c. 仮説 A (digest content 強化, backlog 後続) は **現時点で不要**

compact が発火していない workload では digest 内容を改善しても効果ゼロ。 別の
lever (#41/#50 強化, planner 品質) が優先。

ただし将来 fixture set が大規模化 / context-heavy fixture 追加 / model 切替時に
発火するなら、 その時点で digest 改善が effective に。

### d. 当面の context-management work は **凍結 (frozen)** が合理的

H instrumentation で「現状 work していない」を確認したので、 さらなる context
management 投資 (digest 強化, gradient compaction, threshold tuning) は **fixture
規模が大きくなって compact 発火するまで保留** が ROI 最適。

## 副次成果 (pass rate / 失敗)

| Fixture | Pre 5ee88fb | Pre 2a176cd (#55) | **Post 73ebeb9 (H)** |
|---|---|---|---|
| 100-greet | 3/3 | 3/3 | **3/3** |
| 101-double | 3/3 | 2/3 | **3/3** (回復) |
| 102-counter-class | 0/3 | 3/3 | **3/3** (維持) |
| 104-cache-simple | 2/3 | 2/3 | **2/3** (維持) |

唯一の失敗 **104-cache-simple trial2 :STUCK 1483s** は別 issue (long-running stuck —
backlog #45 limit が機能していない or 別 limit pattern)。 後で root cause 抽出可能。

## 推奨次アクション

1. **context-management 系を当面 freeze** (digest 強化 / threshold tuning は保留)
2. **`max-context-tokens` を 8000 に bump** する選択肢を pending (現データでは safe、
   ただし extreme outlier の備えとして 4000 維持も合理的)
3. **104-trial2 :STUCK 1483s の root cause 調査** (新しい failure mode の可能性)
4. **次の improvement レバー は依然 prompt 系 / planner 品質**:
   - #41 / #50 強化 (planner test stub 多様化)
   - context-view :implementation の completed-subtask-summaries cap (smell D)
   - bench-cycle skill の disk usage 設計

## 学び

- **H instrumentation は code review の仮説 (B over-engineered) を direct に validate**
- **計測無しに tune するのは盲打ち** という reviewer warning が実証された (今回 4 行追加で
  全体像が一目)
- 「動いていない code を改善する」は無意味な作業 — instrumentation が saved that effort
- 次の bench からも `:compact` / `messages_tokens_estimate` で context 圧迫を即時 detect
  できる base infra が整った
