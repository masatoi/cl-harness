# #48 + #50 verification bench: 100/101/102/104 × N=3 on 5a32b89

**Date**: 2026-05-24
**Code**: cl-harness main @ 5a32b89 (post-#48 + #50 prompt fixes)
**Baseline**: N=3 sweep at 0368f1e (`docs/benchmarks/results-2026-05-24-bench-sweep-n3.md`)
**Settings**: review-policy=auto, max-impl-review-revisions=2, max-replans=3,
read-timeout=1200s, log-llm-requests=off, natural planner (no predefined-plan)
**Provider**: Qwen3.6-35B-A3B @ http://192.168.0.17:8000/v1
**Driver**: /tmp/bench-48-50-verify-1779620881.lisp
**Wall-clock total**: ~110 min (cells: 12, mean ~9 min)
**Cells**: 12 (4 fixtures × 3 trials)

## 結論: **両 fix が target issue を完全除去**

| Metric | Pre (0368f1e) | Post (5a32b89) | Δ |
|---|---:|---:|---|
| **fs-write-file refusals** | **13** | **0** | **-100%** ← #48 ✅ |
| **MOP helper undef (arglist/FLL)** | **10** | **0** | **-100%** ← #50 ✅ |
| Tool errors total | 42 | 11 | **-74%** |
| **Patch fail rate** | **42.9%** (24/56) | **9.1%** (3/33) | **-79%** |
| Pass rate | 4/12 (33%) | 5/12 (42%) | +9pt |
| Total wall-clock | ~10138s | ~6481s | -36% |

両 prompt 改善は **意図した failure mode を完全に排除**。patch quality も劇的改善
(fail rate 4.7x 低下)。但し pass rate 上昇は控えめ — 別の bottleneck (MAX-REVIEW-REPLANS) が
新 dominant に。

## 結果テーブル

| Fixture | Pre 1 / 2 / 3 | Post 1 / 2 / 3 |
|---|---|---|
| 100-greet | GIVE-UP 339s / LIMIT 1008s / PASSED 436s | LIMIT 946s / PASSED 356s / STUCK 803s |
| 101-double | LIMIT 835s / PASSED 276s / STUCK 580s | PASSED 156s / **ERROR 364s** / LIMIT 1287s |
| 102-counter-class | PASSED 821s / LIMIT 1968s / GIVE-UP 350s | **PASSED 605s / GIVE-UP 365s / PASSED 489s** |
| 104-cache-simple | LIMIT 2669s / PASSED 689s / ERROR 168s | LIMIT 494s / PASSED 530s / LIMIT 448s |

### Pre vs Post per-fixture pass count

- 100-greet: 1/3 → 1/3 (同等; 但し PASSED run の elapsed は同等で variance)
- 101-double: 1/3 → 1/3 (内 1 が internal bug = 別 issue)
- **102-counter-class: 1/3 → 2/3** (改善 +1)
- 104-cache-simple: 1/3 → 1/3 (同等; 但し PASSED run の elapsed が 689s → 530s)

102 で +1 pass (#50 が刺さった可能性: pre は MOP helper 含む test stub が頻発、
post で planner が正しい test stub を生成するように)。

## 直接的な fix effect (target errors 完全消失)

### #48: fs-write-file 制限の prompt 追加

- Pre: 13 occurrences of "Cannot overwrite existing .lisp/.asd with fs-write-file"
- **Post: 0 occurrences** ← 完全消失

agent は post 環境で初手から lisp-edit-form insert_after を使うようになり、
1 turn / step を節約。

### #50: planner stub MOP helper 排除

- Pre: 7× `arglist`, 3× `function-lambda-list` (test source / verify failure)
- **Post: 0 occurrences** ← 完全消失

planner が test_source に MOP helper を含めなくなり、解決不能 stuck pattern が消えた。
102-counter-class の +1 pass はこの直接 effect の可能性が高い。

### Patch fail rate 改善

Pre: 24 failed / 56 attempted = **42.9%**
Post: 3 failed / 33 attempted = **9.1%**

patch fail の絶対数も attempted の総数も両方減少 (= 1 step 内の試行錯誤 turn が
減って agent が早く正解を出すように)。

## 新 dominant failure mode: :MAX-REVIEW-REPLANS

| Failure | Pre count | Post count |
|---|---:|---:|
| :MAX-REVIEW-REPLANS | 1 | **4** |
| :NO-PROGRESS (:STUCK) | 2 | 1 |
| :MAX-PATCHES | 2 | 0 |
| agent GIVE-UP | 2 | 2 |
| internal :ERROR | 1 | 1 (new: verify-result-status bug) |

**Post 環境で MAX-REVIEW-REPLANS が +3 と急増**。これは patch quality 改善で
review に到達する artifact が増えた結果、review が反復 reject する pattern が見えた。
原因仮説:
- review prompt が #38 削除 / patch quality 向上に追随していない
- review が以前は patch fail で短絡 reject していたが、今は実 artifact を見る機会が増えた

→ **新 backlog 候補**: review-policy threshold tuning / review feedback の質改善

## 新規発見 bug: `verify-result-status` no-applicable-method

101-double trial2 で:
```
ERROR: There is no applicable method for the generic function
       #<STANDARD-GENERIC-FUNCTION CL-HARNESS/SRC/VERIFY:VERIFY-RESULT-STATUS (1)>
       when called with arguments
```

agent から返った verify result object が `verify-result` 型でない (NIL? hash-table?
別 condition?) ことで verify-result-status の generic function dispatch が失敗。
これは cl-harness 内部の defensive coding 不足。**#48 / #50 と無関係**。
→ 新規 backlog 候補 #53。

## 既存 backlog との関係

- ✅ **#48 実装の effect 実証**: fs-write-file refusals 13 → 0
- ✅ **#50 実装の effect 実証**: MOP helpers 10 → 0
- ✅ **#41 が #50 で部分カバー**: 残りは exported-symbols 等 (本 sweep では出ず)
- 新規候補: **#53 verify-result-status guard** (internal bug)
- 新規候補: **review-policy tuning** (MAX-REVIEW-REPLANS +3 急増)

## 推奨次アクション

1. **#53 (verify-result-status guard)** を即時実装 — 内部 bug は 1 件でも稼働阻害
2. **review-policy threshold review** — N=3 で 4/7 failures が MAX-REVIEW-REPLANS、
   review-fn が "complete enough" を判定できていない可能性
3. **N=10 sweep on full 7 fixtures** で post-#48+#50 baseline 確立 — 但し wall-clock
   12+ hours なので別 cycle

## 学び

- **target された prompt 改善は対応 failure mode を 100% 排除できる** (#48, #50 共)
- **patch quality 改善は隠れていた次 bottleneck を露出させる** (今回 = review-replans)
- **小さな prompt fix の cumulative effect は大きい** (-74% tool errors, -79% patch fail)
- JSONL aggregate analysis → targeted small fix → empirical verify → 次 cycle の
  diagnostic data 蓄積、というループが workable と実証
