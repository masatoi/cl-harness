# bench-sweep N=3: 7 fixtures × 3 trials on main @ 0368f1e

**Date**: 2026-05-24
**Code**: cl-harness main @ 0368f1e (post-#38 / post-spec-generator / post-CLI-max-tokens fixes)
**Settings**: review-policy=auto, max-impl-review-revisions=2, max-replans=3, read-timeout=1200s, log-llm-requests=off
**Provider**: Qwen3.6-35B-A3B @ http://192.168.0.17:8000/v1
**Driver**: /tmp/bench-sweep-n3-1779574396.lisp
**Wall-clock total**: ~5 hours (07:13 → 12:10)
**Cells**: 21 (7 fixtures × 3 trials)

## Aggregate pass rate: 8/21 = 38%

| Status | Count | % |
|---|---:|---:|
| :PASSED | 8 | 38% |
| :LIMIT-EXHAUSTED | 6 | 29% |
| :STUCK | 4 | 19% |
| :GIVE-UP | 2 | 10% |
| ERROR (yason JSON decode) | 1 | 5% |

## 結果テーブル

| Fixture | Trial 1 | Trial 2 | Trial 3 | Pass | Mean elapsed |
|---|---|---|---|---:|---:|
| 100-greet | :GIVE-UP 339s | :LIMIT-EXHAUSTED 1008s | **:PASSED 436s** | 1/3 | 594s |
| 101-double | :LIMIT-EXHAUSTED 835s | **:PASSED 276s** | :STUCK 580s | 1/3 | 564s |
| 102-counter-class | **:PASSED 821s** | :LIMIT-EXHAUSTED 1968s | :GIVE-UP 350s | 1/3 | 1046s |
| 103-fizz-buzz | :STUCK 2326s | **:PASSED 313s** | **:PASSED 462s** | 2/3 | 1034s |
| 104-cache-simple | :LIMIT-EXHAUSTED 2669s | **:PASSED 689s** | ERROR 168s | 1/3 | 1175s |
| 105-validate-email | :LIMIT-EXHAUSTED 366s | :STUCK 961s | **:PASSED 453s** | 1/3 | 593s |
| 106-format-currency | :LIMIT-EXHAUSTED 1451s | **:PASSED 283s** | :STUCK 1049s | 1/3 | 928s |

## Per-fixture pass rate (95% Wilson CI, n=3)

| Fixture | Pass | CI 95% |
|---|---:|---|
| 103-fizz-buzz | 2/3 | [21%, 94%] |
| 100, 101, 102, 104, 105, 106 | 1/3 | [4%, 78%] |

**N=3 では CI が広すぎて fixture 間の有意差は検出できない**。

## 観察

### 1. trivial fixtures も意外に不安定 (100, 101)

`greet(name)` `double(n)` の単純 fixture でも 1/3 pass。pass run は短時間 (276s, 436s) で
完了するが、fail run は 580-1008s かけて諦める。これは典型的に planner が test stub に
未定義 helper を含めるか、agent の patch が初期段階で `ok=False` 連鎖する pattern。

### 2. 高 wall-clock 浪費の failure

`:LIMIT-EXHAUSTED` / `:STUCK` の中に **2000s 超** の run が複数:
- 103-fizz-buzz trial1: 2326s (39 min) → :STUCK
- 104-cache-simple trial1: 2669s (44 min) → :LIMIT-EXHAUSTED (max-patches に 7 step 試行)

これら 2 run だけで sweep 全体の wall-clock の 28% を占有。backlog #45
(連続 ok=False patch 時の早期 give-up) が刺さる場面。

### 3. 105-validate-email 初の PASSED 観測

これまで何度も bench したが :PASSED が観測されていなかった 105 が **trial3 で初の :PASSED**
(453s, 2 steps, 2 impl-reviews, 0 rejections)。fixture 自体は agent が解ける範囲にあるが、
1/3 の確率で planner / agent が嵌るパターンに入る。

### 4. 104-cache-simple trial3 で新 bug: yason JSON decode 失敗

trial3 が 168s で abort、reason:
```
review-error: review JSON decode failed: #\a fell through ECASE expression.
Wanted one of (#\" #\\ #\/ #\b #\f #\n #\r #\t #\u).
```

これは LLM が review-development-artifact phase で `"\a"` (backslash + a) を含む文字列を返却、
yason がこれを invalid JSON escape sequence として reject したケース。私の以前の fix
(array-of-objects spec shape) は spec generation のみで、review phase は未対応。

新規 backlog #47 として記録。

### 5. agent が :GIVE-UP を返す cases (2/21)

100 trial1 / 102 trial3 で agent が `{"type":"finish","status":"give_up"}` を emit。
これは agent が「これ以上進めない」と自己判断したケース。LIMIT-EXHAUSTED とは異なり、
budget はまだ残っているが agent が諦めている。

### 6. impl-rejections の偏り

105 trial2 で `:IMPL-REJECTIONS 6` (8 reviews 中 6 件 reject) — review が agent の patch を
反復的に拒否し、結局 :STUCK。これは review-policy が **overly strict** な可能性 (backlog
要検討: review threshold tuning)。

### 7. 106-format-currency: cl-mcp で repeated COMPILE-FILE-ERROR (money system)

3 trial 全てで cl-mcp worker から `load-system-error` (money/src/main コンパイル失敗) が
ログ。fixture の `money` system に latent な問題? — 別途調査。

## Failure mode breakdown

| Mode | Count | 典型的状況 |
|---|---:|---|
| :LIMIT-EXHAUSTED (:MAX-REVIEW-REPLANS) | ~3 | plan review が反復 reject (105 type) |
| :LIMIT-EXHAUSTED (:MAX-PATCHES) | ~3 | agent が patch を試行錯誤して budget 切れ |
| :STUCK (:NO-PROGRESS) | 4 | agent が無限ループ的に同 fail を再現 |
| :GIVE-UP (agent emit) | 2 | agent 自己判断で諦め |
| ERROR (yason) | 1 | LLM JSON output が invalid escape |

## #38 と本 sweep の関係

本 sweep は #38-ON main で実施。直前の paired bench (104 のみ) で #38 effect が観察されなかった
ことを踏まえ、N=3 sweep の数値が #38 の system-wide impact を測る reference point になる。

- **post-#38 main の aggregate pass rate**: 8/21 = 38%
- backlog #38 の implementation (commit 457b52a, 2026-05-24 04:17) 直後の bench-cycle
  で同じ 102 / 104 は混在 (:PASSED と :LIMIT-EXHAUSTED が両方観測)。今 sweep でも 102 1/3,
  104 1/3 とほぼ同じ → **#38 implementation は 102/104 の pass-rate を測定可能に改善した
  形跡なし**。
- #38 を OFF にした paired bench でも 104 は :PASSED → 同じく effect 不明。

→ #38 の prompt-level 改善は、Qwen3.6 + 現状の bench infrastructure では **isolated effect が
測定できない**。fixed-plan paired bench (backlog #46) を実装するか、別 model で再評価が必要。

## 推奨次アクション

優先度順:

1. **backlog #45 (連続 ok=False patch 早期 give-up)** を実装 — 2326s / 2669s の浪費 case を切れる
2. **backlog #47 (新規: review-phase の lenient JSON parsing)** を追加 — 104 trial3 の ERROR を防ぐ
3. **review-policy threshold tuning** — 105 trial2 の 6 連続 reject は overly strict 可能性
4. **fixture-side 改善**: 100, 101 でも planner stub 品質が不安定 → backlog #41 (planner test stub
   に未定義 helper 含めない) の重要度を上げる
5. **#38 を含む prompt-level 改善は #46 (fixed-plan infra) 実装まで再評価保留**

## 新規 backlog 候補 #47

### 47. review JSON parse: invalid escape を tolerate / retry

**Source**: bench-sweep 2026-05-24, fixture 104-cache-simple trial3
**Axis**: cl-harness 実装

**観察**: 104-cache-simple trial3 で review-development-artifact 内の `complete-chat` が
返した JSON 文字列に `"\a"` のような invalid JSON escape sequence が含まれ、yason が
`ECASE fell through` で reject。bench が 168s で ERROR abort。

**仮説**: LLM (Qwen3.6) が時々 control character や `\a` 等の non-standard escape を出力
する。yason は strict JSON parser なので無効 escape を receive すると hard error。

**変更案**:
- `src/review.lisp` の review JSON parse path で 2 段階処理:
  1. 元 string を直接 yason に渡す (現状)
  2. yason error 時、invalid escape sequence をサニタイズ (例: `\a` → `a`, `\<bad>` → `<bad>`)
     してから retry
- もしくは LLM call を 1 回 retry してから fail させる (backlog #40 と統合)
- regression test: invalid escape を含む文字列が review-error なく parse される

**期待効果**: sporadic な model output anomaly で bench が abort しなくなる。
N=3 sweep で 1/21 観測 (5%) → 削減できれば pass rate に直接寄与。

**コスト**: small + half-day (sanitize util + review error path + test)。

## 既存 backlog との関係

- 新規 backlog 候補: 1 件 (#47)
- 補強される backlog: #38, #40 (retry), #41 (planner stub), #45 (ok=False 連鎖), #46 (fixed-plan)
- 105 trial2 の 6 連続 impl-rejection: 新規検討項目 "review-policy strictness tuning"
- 106 の money/src compile-file-error: 別途調査必要
