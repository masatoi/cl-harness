# #46 fixed-plan paired bench: 104b-cache-simple-paired (ON vs OFF, N=3)

**Date**: 2026-05-24
**Code**:
- ON arm: cl-harness main @ 27f70f7 (with #38 patching-guidance + #46 predefined-plan)
- OFF arm: bench-38-off branch (c3a5e0d, #38 段落削除)
**Fixture**: `develop-benchmarks/104b-cache-simple-paired/` (新規 fixture, predefined plan で
multi-symbol step を強制)
**Settings**: review-policy=auto, max-impl-review-revisions=2, max-replans=0 (fixed-plan),
read-timeout=1200s, log-llm-requests=off
**Provider**: Qwen3.6-35B-A3B @ http://192.168.0.17:8000/v1
**Driver**: /tmp/bench-46-paired-104b.lisp (BENCH_ARM env で arm 切替)
**Wall-clock total**: ~28 min (OFF: 13 min, ON: 14 min)

## 結論: **#38 は本 fixed-plan paired bench で agent を悪化させた**

| Arm | Pass | Mean elapsed | Total elapsed |
|---|---:|---:|---:|
| OFF (#38 removed) | **3/3** | 255s | 764s |
| ON (main, #38 present) | **1/3** | 278s | 833s |

Wilson 95% CI overlap (3/3=[44%,100%], 1/3=[6%,79%]) なので統計的有意ではないが、
**per-step の patch quality 指標で一貫した差** が観察された (下記)。

## 結果テーブル

| Arm | Trial 1 | Trial 2 | Trial 3 |
|---|---|---|---|
| OFF | :PASSED 256s | :PASSED 224s | :PASSED 285s |
| ON | :LIMIT-EXHAUSTED (max-patches) 229s | :PASSED 279s | :GIVE-UP 325s |

## Step 1 (multi-symbol: cache-put + cache-get) 詳細

predefined plan は step 1 を **1 test 内で cache-put + cache-get を要求** する形に
設計 (#38 が targets するまさにそのパターン)。

| Arm | Trial | Verify pattern | OK patches / Failed | Tool errors | Status |
|---|---|---|---:|---:|---|
| OFF | 1 | put→put→get→**pass** | 3 / 1 | 1 | :PASSED |
| OFF | 2 | put→put→get→**pass** | 3 / 1 | 2 | :PASSED |
| OFF | 3 | put→put→get→**pass** | 3 / 1 | 2 | :PASSED |
| ON | 1 | put→put→get (timeout) | 2 / **3** | **5** | :LIMIT-EXHAUSTED (max-patches) |
| ON | 2 | put→put→get→pass | 3 / 2 | 3 | :PASSED |
| ON | 3 | put→put (gave up) | 1 / 2 | **5** | :GIVE-UP |

### 重要な observation

1. **#38 directive 不遵守は ON/OFF 共通**:
   両方の arm で agent は最初 cache-put を patch → verify が CACHE-GET undefined を吐く →
   cache-get を patch → pass の **evolved-failure pattern** を辿った。#38 が抑制を意図
   した「全 symbol を 1 patch でまとめる」行動は **どの ON trial でも観察されず**。

2. **ON は patch 品質が劣化**:
   - ON: failed patches 2-3 per trial / tool-errors 3-5 per trial
   - OFF: failed patches 1 per trial / tool-errors 1-2 per trial
   - 同じ multi-symbol pattern を辿っているのに、ON agent は出力する patch JSON が
     構造的に reject される頻度が高い

3. **ON は max-patches budget を使い果たす**:
   - ON trial1: 5 attempts 使い果たし :LIMIT-EXHAUSTED (max-patches)
   - ON trial3: 1 success + 2 failures 後に agent 自己 give-up

## 仮説: なぜ #38 が逆効果になるか

Qwen3.6 が "Patching guidance" 段落を読んだ時の解釈:
- > "implement ALL of them in the SAME patch"
- → agent は **1 patch で複数 symbol を入れようとする** が、より大きく複雑な patch を
  生成しがちで JSON / Lisp 構文の正確性が低下
- → `lisp-edit-form` / `lisp-patch-form` の parinfer auto-repair / token-match で reject
- → 失敗 patch ごとに verify が tool-error を返し、agent はそれを修正しようと更に
  malformed な patch を生成 → 悪循環

OFF agent は incremental approach (1 symbol ずつ追加) で各 patch が小さく
構造的に valid なため、結果として早く完走する。

## 既存 paired bench (104) との関係

2026-05-24 の paired bench (`docs/benchmarks/results-2026-05-24-bench-cycle-38-paired-104.md`)
では planner output variance が confounder で結論不明だった:
- OFF: :PASSED 556s (3 steps)
- ON: :PASSED 571s (1 step, different plan)

本 fixed-plan paired bench は planner を除外して同 plan で比較したため、**agent
prompt 単独の effect を isolated に観察できた**。結果は **#38 は net-negative**。

## #38 の今後

データから言える:
- N=3 paired で **OFF が ON より consistent に良い**: pass-rate (3/3 vs 1/3), per-step
  patch quality (failed 1 vs 2-3), tool-errors (1-2 vs 3-5)
- 統計的有意性は N=3 では確保できない (CI overlap)
- 但し per-step quality 指標の一貫性は signal として強い

**推奨**: 
1. N=10 paired で再確認 (本 doc は N=3 暫定結果)
2. もし N=10 でも結果が再現するなら、**#38 prompt 段落を削除 / 大幅修正** を検討
3. 仕様変更案: "implement ALL in SAME patch" を弱め、"plan to add all related symbols
   before submitting first patch; if a single patch becomes too large, split safely"
   等の reword

**当面の処置**: #38 を即削除はしない (N=3 では rolling back の根拠不十分)。
backlog に注意書きを追加し、N=10 paired を follow-up として残す。

## 副次成果

- **#46 core infrastructure が works as designed**: predefined-plan で planner LLM call
  を完全 skip、6 trial 全てが同じ plan で実行され、paired evaluation が初めて可能に
- **104b-cache-simple-paired fixture が paired bench の reference として使える**

## 既存 backlog との関係

- #38 entry に「N=3 fixed-plan paired で OFF > ON の signal あり、N=10 follow-up 待ち」を追記
- #46 を再度 ✅ 確認 (本 doc が #46 infra の実 use case)
- 新規 backlog 候補: なし (本 finding は既存 #38 の reassessment)
