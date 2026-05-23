# bench-cycle: paired #38 on/off comparison (104-cache-simple)

**Date**: 2026-05-24
**Code**: cl-harness main (1c75c44) for ON; bench-38-off branch (6383df9, deleted post-bench) for OFF
**Settings**: review-policy=auto, max-impl-review-revisions=2, log-llm-requests=on, max-replans=3, read-timeout=1200s
**Provider**: Qwen3.6-35B-A3B @ http://192.168.0.17:8000/v1 (local OpenAI-compatible endpoint)
**Drivers**:
- ON v3 (earlier): /tmp/bench-cycle-1779568317.lisp
- OFF: /tmp/bench-cycle-38off-1779571422.lisp
- ON re-run: /tmp/bench-cycle-38on-1779572061.lisp

**Goal**: directly compare agent behavior with #38 patching-guidance section ON vs OFF on the
same fixture, to determine whether the prompt edit reduces the
`patch -> verify-fail with new missing symbol -> patch -> verify` cycle.

## 結果サマリ (N=1 each, 3 runs total)

| Run | Branch | Plan size | Total turns | Total patches (attempts) | Multi-symbol test? | Evolved-failure? | Elapsed |
|---|---|---:|---:|---:|---|---|---:|
| ON v3 (earlier) | main (#38 present) | 3 | 28 | 7 (11) | No (planner generated 1-symbol-per-step) | N/A | 600.8s |
| **OFF** | bench-38-off | 3 | **11** | 8 (8) | Yes (step 1: cache-put+cache-get) | **Yes** (turn 4: CACHE-PUT → CACHE-GET) | 556.3s |
| **ON re-run** | main (#38 present) | 1 | **13** | 3 (5) | Yes (step 0: implicit multi-symbol) | **Yes** (turn 12: MAKE-CACHE → CACHE-GET) | 571.6s |

すべて **:PASSED**。wall-clock は OFF 556s / ON 571s で **3% 差 (noise 範囲内)**。

## Plan structure 比較 (planner の確率分布)

planner は run ごとに異なる plan を生成 (non-deterministic):

**ON v3 plan** (3 steps, all 1-symbol):
- step 0: `test-make-cache`
- step 1: `test-cache-put`
- step 2: `test-cache-get`

**OFF plan** (3 steps, step 1 multi-symbol):
- step 0: `test-make-cache-instantiation`
- step 1: `test-cache-put-get-with-strings` ← put + get を 1 test に
- step 2: `test-cache-overwrite-and-default` ← 既に通る (skip)

**ON re-run plan** (1 step, implicit multi-symbol):
- step 0: `test-cache-get-default-nil` ← 単一 test 名だが make-cache / cache-put / cache-get 全部要求

planner output が highly variable で、paired comparison が難しい。

## Multi-symbol step の per-step 詳細

| Run | Test | Turns | Patches (ok/attempts) | Tool errors | Verify evolution |
|---|---|---:|---:|---:|---|
| OFF | test-cache-put-get-with-strings | **5** | 3 / 3 | 0 | turn 0: CACHE-PUT undef → turn 3: CACHE-PUT undef → **turn 4: CACHE-GET undef** → turn 5: pass |
| ON re-run | test-cache-get-default-nil | **13** | 3 / 5 | **4** | turn 0: MAKE-CACHE undef → turn 11: MAKE-CACHE undef → **turn 12: CACHE-GET undef** → turn 13: pass |

**両 run とも "evolved-failure" pattern が発生** (#38 がまさに抑制を意図したパターン)。
- OFF: CACHE-PUT → CACHE-GET (turn 3 → 4)
- ON: MAKE-CACHE → CACHE-GET (turn 11 → 12)

ON は OFF より turn 数が 2.6 倍多い (13 vs 5) が、これは tool-errors の差 (4 vs 0) が支配的で
#38 効果ではない。patch 数は同じ (3)。

## 結論: #38 の empirical effect は **本 N=1 paired bench では観察されず**

1. **#38 prompt の structural inclusion**: ✅ 確認済 (system prompt に `Patching guidance (backlog #38)` 段落含む)
2. **#38 の directive 遵守**: ❌ **観察されず** — agent は ON でも OFF でも multi-symbol test に
   対し「全 symbol を 1 patch でまとめる」行動を取らず、いずれも段階的に patch → evolved failure
   → patch のサイクルに陥った
3. **Wall-clock / turn / patch 数**: 統計的に区別不能 (OFF 556s vs ON 571s, ±3%; N=1)

### 推測される失敗理由 (#38 が agent 行動を変えなかった理由)

仮説 A: **Qwen3.6 が patching-guidance section を無視 / 弱く重み付け**
- 同じ Qwen3.6 で他の prompt section (例: "Respond with exactly one JSON object per turn") は遵守
- patching-guidance は最後の方に置かれていて salience が低い可能性

仮説 B: **agent の workflow が "enumerate-first" に向いていない**
- agent は典型的に「verify → read test → patch → verify」の loop で動く
- "test 全体を read して symbol を全部列挙してから patch" は計画的だが、Qwen は短期計画的に動く

仮説 C: **N=1 では variance が支配的**
- planner output が run 毎に違う (3 paths × 3 plan structures)
- 同じ multi-symbol test を ON / OFF で食わせる controlled experiment ではない

### Variance の数値

- ON v3 (single-symbol plan): 28 turns
- ON re-run (multi-symbol plan, 1 step): 13 turns
- OFF (multi-symbol plan, 3 steps): 11 turns

同 branch (ON) でも 13 → 28 と turn 数が 2 倍違う。N=1 では effect size を S/N 比的に検出できない。

## 推奨次アクション

1. **N=3 paired bench**: ON × 3 + OFF × 3 で variance を bound。同 fixture で 6 runs × 10 min ≈ 1 hour
2. **#38 prompt の prominence 強化**: section を system prompt の最上位 / 早い段階に移動 → re-test
3. **fixed-plan paired test**: planner output を fixture-side で固定 (predefined plan) し、ON/OFF
   を完全 controlled に比較する infrastructure を追加
4. **agent behavior trace**: llm-response の `thought` field を grep して agent が "enumerate" 行動を
   実際に取ったかを直接観察

## #38 自体の処遇

本 bench は **#38 を否定する強い証拠ではない** (N=1, 高 variance, confounders 多数) が、
**現状では positive effect の観測も無い**。当面は:

- #38 prompt section は維持 (negative effect も観測されないので削除コストの方が大きい)
- backlog の #38 entry に「empirical 効果は paired N=1 で観察されず、N=3 + prominence
  強化が follow-up 課題」と追記

## 既存 backlog との関係

- 新規 backlog 候補: 1 件 (#46 fixed-plan paired bench infrastructure)
- 既存 backlog 参照:
  - #38 を refine: empirical effect 未観察を追記
  - #44 driver template: N=3 への対応も入れる

## 新規 backlog 候補 #46

### 46. fixed-plan paired bench infrastructure (planner 確定化)

**Source**: bench-cycle 2026-05-24 paired #38 on/off run
**Axis**: bench target

**観察**: paired #38 on/off bench で同 fixture (104-cache-simple) でも planner が 3 種類の異なる
plan を生成 (3 steps×1-sym, 3 steps×multi-sym step1, 1 step×implicit multi-sym)。
agent 行動の controlled comparison が不可能。

**仮説**: planner の出力を fixture 側で predefined plan として与えれば (planner を skip)、
agent 段階の prompt 変更 (#38 のような) を pure に paired evaluation できる。

**変更案**:
- `develop-task.json` に optional `predefined_plan` field を追加
- `cl-harness:develop` に `:predefined-plan` kwarg 追加 (provided なら planner を bypass)
- bench-cycle skill の test cases に「multi-symbol step」「single-symbol step」両方を含む
  predefined plan を用意
- ON / OFF で N=3 ずつ走らせて wall-clock / turn / patch を比較する script を skill に追加

**期待効果**: prompt 変更の empirical effect を高 S/N で測定可能になる。#38 / #41 / #45 等の
prompt-level 改善 backlog で再現性のある evaluation が可能。

**コスト**: medium + 1-2 days (develop-task schema 拡張 + develop kwarg 追加 + skill template 拡張)。
