# bench-cycle: 102-counter-class, 104-cache-simple

**Date**: 2026-05-24
**Code**: cl-harness main (457b52a) + 2 in-tree fixes (spec-generator robustness + CLI max-tokens forwarding)
**Settings**: review-policy=auto, max-impl-review-revisions=2, log-llm-requests=on, max-replans=3, read-timeout=1200s
**Provider**: Qwen3.6-35B-A3B @ http://192.168.0.17:8000/v1 (local OpenAI-compatible endpoint)
**Drivers**: /tmp/bench-cycle-1779568317.lisp (Qwen-v3, the run analyzed here)
**Skill version**: bench-cycle (.claude/skills/bench-cycle/)
**Goal of this cycle**: empirical verification of #38 patching-guidance effect on the recurring
`patch -> fail -> add missing symbol -> patch -> fail -> add another symbol` pattern.

## 結果サマリ (Qwen3.6 v3)

| Task | Status | Steps completed | Replans | impl-reviews | Elapsed | LIMIT-HIT |
|---|---|---:|---:|---:|---:|---|
| 102-counter-class | :LIMIT-EXHAUSTED | 0/3 (3 replans all gave up at step 0) | 3 | 0 | 1668s (28 min) | :MAX-REVIEW-REPLANS |
| 104-cache-simple | **:PASSED** | 3/3 | 0 | 3 | 601s (10 min) | — |

104 が初の :PASSED 完走、102 は別ブロッカーで停滞。

## 進捗の流れ (4 model + 4 driver, N=1 each)

| Try | Model | Driver | Outcome |
|---|---|---|---|
| v1 | Groq gpt-oss-20b | 1779564413 | spec-generator が `[{criterion: "..."}, ...]` shape を拒否 (#38 と無関係 bug発覚) |
| v2 | Groq gpt-oss-20b | 1779565902 | spec parser robustness 修正後 → "spec generator returned empty content" (CLI max-tokens=nil → server default → reasoning モデルが content 全 token を reasoning に消費) |
| v3 | Groq gpt-oss-20b | 1779566133 | CLI max-tokens 転送 fix 後 → 102 review JSON empty / 104 agent turn-1 で http-client-error |
| v4 | Groq gpt-oss-20b | 1779566251 | driver で `:max-tokens 16384` 明示 → 102 同じ http-error / 104 plan review が MAX-REVIEW-REPLANS 到達 |
| Qwen-v1 | Qwen3.6-35B-A3B | 1779566922 | 102 で 360s 超 → I/O timeout (180s read-timeout 累積) |
| Qwen-v2 | Qwen3.6-35B-A3B | 1779567370 | 両 fixture 22s で transport-timeout (endpoint 一時 down) |
| **Qwen-v3** | **Qwen3.6-35B-A3B** | **1779568317** | **102 :LIMIT-EXHAUSTED / 104 :PASSED** ← 本 doc で分析 |

## 104-cache-simple 詳細 (PASSED)

### Plan structure (planner 出力)
```
step 0: test-make-cache
step 1: test-cache-put
step 2: test-cache-get
```

各 step が **1 symbol を 1 test で覆う granularity**。#38 が targets する「単一 test が複数 symbol を要求」pattern は本 plan には現れない。

### Per-step narrative

**Step 0: test-make-cache** (32.1s, 8 llm-turns, 2 patches, 1 tool-error)

| turn | event | summary |
|---|---|---|
| 0 | verify | failed: `MAKE-CACHE is undefined` |
| 1-6 | (reads/edits) | agent explores then issues 1st patch |
| 7 | verify | still failed: `MAKE-CACHE is undefined` (1st patch didn't add make-cache directly, possibly wrong package/export) |
| 8 | verify | **passed** (after 2nd patch) |

**Step 1: test-cache-put** (144.4s, 10 turns, 3 patches (5 attempts), 3 tool-errors)

| turn | event | summary |
|---|---|---|
| 0 | verify | failed: `CACHE-PUT is undefined` |
| 7 | verify | still failed: `CACHE-PUT is undefined` |
| 9 | verify | failed: `no applicable method` for CACHE-PUT (defclass / method-spec mismatch) |
| 10 | verify | **passed** |

**Step 2: test-cache-get** (143.6s, 10 turns, 2 patches (4 attempts), 2 tool-errors)

| turn | event | summary |
|---|---|---|
| 0 | verify | failed: `CACHE-GET is undefined` |
| 9 | verify | failed: `no applicable method` for CACHE-GET |
| 10 | verify | **passed** |

### Run-end counters (合計)

```
status=:PASSED, replans=0, steps=3/3, impl-reviews=3, impl-rejections=0
total elapsed=600.8s, total turns=28, total patches=7 (patch_attempts=11)
```

## 102-counter-class 詳細 (LIMIT-EXHAUSTED on MAX-REVIEW-REPLANS)

### 3 plan attempts (all aborted at step 0)

**Plan 1**: `test-counter-class-and-constructor` — defclass + make-counter の 2-symbol pattern
- 10 turns, 1 patch (failed to apply: `ok=False`), 2 tool-errors, status=give-up
- turn 0: `no class named COUNTER`
- turn 9: `CLASS-SLOTS is undefined` ← planner が生成した test stub に **MOP の `class-slots`** を呼ぶ assertion が含まれていた

**Plan 2**: `test-package-exports-and-class-structure`
- 12 turns, 3 patches (全部 `ok=False`), 3 tool-errors, status=limit-exhausted (:MAX-PATCHES)
- turn 0: `CLASS-SLOTS undefined` (同じ planner 問題)
- turn 7-12: 連続 `COMPILE-FILE-ERROR` — agent の patch がコンパイル不能な Lisp を出力

**Plan 3**: `test-make-counter-default-and-custom`
- 10 turns, 5 patches (全部 `ok=False`), max-patches 到達
- turn 3-4: `MISSING-DEPENDENCY: Component "clos" not found` — agent が `.asd` に存在しない "clos" component を追加しようとした
- 他 turn 全部 `COMPILE-FILE-ERROR`

### 102 failure root causes

1. **Planner test stub に MOP関数** (`class-slots`) を含めた — backlog #41 と同種
2. **Agent patch の品質低下** — 全 patch が `ok=False` で適用失敗。Qwen3.6 の出力する patch JSON が
   結構な頻度で構文不正 / `lisp-patch-form` の `old_text` が match しない / 等
3. **エラー復旧の難しさ** — COMPILE-FILE-ERROR が出ると agent はそれを修正するため別 patch を試みるが、
   その patch も `ok=False` で連鎖的に状況が悪化

これらはすべて **#38 (patching-guidance) が対処する範囲外**。

## #38 (patching-guidance) の effect 評価

### 構造的検証 (✅ verified)
v3 step 0 transcript の `llm-request` event で agent system message に `Patching guidance (backlog #38):`
段落が含まれることを確認。prompt-level の wiring は正常。

### 実 effect 測定 (⚠ partial)
今回の bench では **#38 が target する pattern が plan に殆ど現れず、empirical 効果を直接測定できなかった**:

- **104**: planner が 3 step を 1-symbol-per-step に分解。各 step の test は単一 symbol を呼ぶのみで、
  #38 の「多 symbol を 1 patch でまとめろ」guidance が適用できる場面が無い。
- **102**: 全 3 plan が step 0 で planner-stub の品質問題で阻まれ、agent の patch 戦略まで届かなかった。

唯一 #38-pattern 近似 (1 test の中で多 symbol を要求) は **104 step 1/2 の "verify 通った後 generic-function の applicable method がない"** で
出現したが、これは `defclass` と `defmethod` の同時定義が必要なケース。#38 wording は「`make-x` + accessor」「defclass +
constructor」を例示するので、**defclass + defmethod** が含まれているかは agent の判断次第。今回は agent が 2-3 patch かけて
収束しており、1 turn での解決には至らず。

### 比較 baseline がない

#38-OFF (patching-guidance section を一時的に外した) baseline run を取れば、本 v3 と paired comparison
できる。今回はそこまで取れず。今後の bench-cycle で paired evaluation を実施するのが妥当。

## Cross-cutting findings

- **planner test stub の標準 CL 逸脱**: 102 で `class-slots` (MOP) を使う test を planner が生成した。
  以前 (v3 Groq) も `exported-symbols` (未定義 helper) を生成した実績あり。 → backlog #41 に統合
- **patch quality**: 102 で agent が 9 patch 中 9 件 `ok=False`。`lisp-edit-form` / `lisp-patch-form` の
  入力検証が結構厳しい (parinfer auto-repair でも回復しないケース多数) で、Qwen3.6 が出力する patch JSON が
  exact-match できないことが頻繁にある。 → 新規 backlog 候補 (本 doc 末尾の追加 proposal 参照)
- **wall-clock コスト**: Qwen3.6 で 102 が 28 分、104 が 10 分。local reasoning model 利用時の bench
  サイクル時間が長い。`--max-replans 1` 等での bench-cycle 高速化が有用 → 既存 backlog #44 で対応

## 推奨次アクション

1. **paired #38-on/off bench** を別 cycle で実施 (in-tree branch で patching-guidance を一時無効化 → 同 plan で比較)
2. **planner prompt 強化** (backlog #41) で MOP / 未定義 helper を test stub から排除
3. **patch JSON 品質保証** (本 doc で新規提案 #45) — agent が `ok=False` patch を連発する場合の早期 give-up や retry-with-hint
4. **bench-cycle driver template** (backlog #44) に `:read-timeout 1200 :max-replans 1` を default 化

## 既存 backlog との関係

- 新規 backlog 候補: 1 件 (#45 patch-validity early-give-up)
- 既存 backlog 参照: #38, #40, #41, #42, #43, #44
- 補強される backlog: #41 (planner test stub) — 本 cycle で再観察 (`class-slots`)、#42 (plan-review event) — 102 の MAX-REVIEW-REPLANS で再痛感

## 実装済 (本 cycle 副産物, in-tree uncommitted)

1. **spec-generator JSON shape robustness** (`src/review.lisp`):
   `%coerce-spec-entry` ヘルパー追加。reasoning model が `{"criterion": "..."}` で
   各エントリを wrap した時も string として coerce する。test
   `parse-develop-spec-accepts-object-wrapped-entries` で pin。

2. **CLI max-tokens forwarding** (`src/cli.lisp` fix/bench/develop 3 か所):
   `:max-tokens nil` を model.lisp に forward すると `make-openai-provider` の
   `(max-tokens 8192)` default を override してしまうため、`apply` で nil 時に
   kwarg を省略するパターンに変更。これで #33 の 8192 default が CLI 経由でも効く。

## 新規 backlog 候補 #45

### 45. agent patch が `ok=False` で連続する場合の早期 give-up

**Source**: bench-cycle 2026-05-24, fixture 102-counter-class (Qwen3.6 v3)
**Axis**: cl-harness 実装

**観察**: 102 の plan 2/3 で agent が出力した patch が 3-5 連続で `ok=False` (parinfer auto-repair / token
match で reject)。失敗 patch ごとに verify が COMPILE-FILE-ERROR を返し、agent はそれを修正しようと
更に malformed patch を出す悪循環。最終的に :MAX-PATCHES exhaustion。

**仮説**: `lisp-edit-form` / `lisp-patch-form` が連続して `ok=False` を返したら「agent の patch 戦略が
そもそも崩壊している」signal なので、早期に :GIVE-UP に流したほうが他 step の budget を温存できる。

**変更案**:
- orchestrator で連続 `ok=False` patch 数を track
- N (例: 3) 連続したら次 turn で `give_up` finish を agent に強制 OR step を :limit-exhausted で終了
- tool-error feedback に「your last 3 patches failed structural validation; consider giving up」hint を追加

**期待効果**: pathological patch 連発時の wall-clock 節約。multi-step plan の場合 step 0 の浪費を抑え、
後続 step の budget を確保。

**コスト**: small + half-day (counter + early-termination + regression test)。
