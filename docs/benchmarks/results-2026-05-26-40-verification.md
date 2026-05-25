# #40 verification: empty-content retry partially effective (2026-05-26)

**Date**: 2026-05-26
**Code**: cl-harness main @ 6a85561 (post-#40 empty-content retry)
**Driver**: /tmp/bench-40-verify-1779739158.lisp
**Wall-clock total**: ~85 min

## 結論: **#40 は 1 cell で works (104-trial3 早期 give-up)**、 **他で別 path に逃げる**

### Pass rate trajectory

| Commit | Pass rate |
|---|---:|
| 73ebeb9 (H peak) | 11/12 (92%) |
| 485ac0a (#56) | 8/12 (67%) |
| fa51fc4 (#56b) | 9/12 (75%) |
| d269d1f (#50b) | 8/12 (67%) |
| **6a85561 (#40)** | **7/12 (58%)** ← post-H 新低 |

post-H で連続 5 commit 8-9 範囲 を維持していたが #40 で 7/12。 N=3 variance か
真の regression か N=3 では断定不能。

### 結果テーブル

| Fixture | Trial 1 | Trial 2 | Trial 3 |
|---|---|---|---|
| 100-greet | PASSED 154s | PASSED 173s | PASSED 131s |
| 101-double | PASSED 137s | PASSED 289s | PASSED 124s |
| 102-counter-class | **:LIMIT (max-review-replans) 622s** | PASSED 528s | **ERROR (planner JSON) 372s** |
| 104-cache-simple | **:STUCK 998s** | **:STUCK 1428s** | **:GIVE-UP (empty-content) 329s** |

## #40 の effect 分析

### Positive: 104-trial3 で works as designed

```
[5:22] 104-trial3 START
[5:27] 104-trial3 DONE: status=GIVE-UP limit-hit=NIL elapsed=329s
       Status: :GIVE-UP (reason: :empty-content)
```

**329s で早期 abort** — Qwen が empty content を 1 retry 後も返した場合、 max-patches
や stuck loop に burnin する代わりに **fast fail** に着地。

これは #40 の意図通り: "burn wall-clock on degenerate LLM output instead of stuck
trial". 1 retry のあと諦めるが、 cumulative budget は他 fixture に温存される。

### Negative: 102-trial3 で別 path に逃げた (planner-error JSON decode)

```
[5:35] 102-trial3 START
[5:41] 102-trial3 ERROR: planner-error: JSON decode failed: end of file
```

これは `chat-parse-response` を通ったあと **`%parse-plan` 内の yason call で発生**:
1. complete-chat 返却 → content は **whitespace-only or partial JSON** (空ではない)
2. chat-parse-response の `(plusp (length content))` チェック通過
3. plan-development が chat-response-content を %parse-plan に渡す
4. yason:parse fails with "end of file" inside %parse-plan
5. planner-error 例外 → orchestrator handler → ERROR

**#40 は "empty string" のみ catch、 "whitespace-only" / "partial JSON" は通過**。
yason failures は別 layer で対応必要。

### Other failures (#40 と無関係)

- 102-trial1 :MAX-REVIEW-REPLANS: review がplan rejecting (#54 path)
- 104-trial1/trial2 :STUCK: agent stuck loop, #45/#56 等の既存 limits 関連

## #40 の評価

| 検証項目 | 結果 |
|---|---|
| 「empty content → 1 retry → recover」 working | 直接 evidence なし (リトライ event count を取らず) |
| 「empty content → 1 retry → 2nd も empty → give-up」 working | ✅ 104-trial3 で 329s 早期 give-up |
| yason "end of file" (whitespace / partial JSON) を catch | ❌ 102-trial3 で通過 → planner-error |
| 全体 pass rate 改善 | ❌ 7/12 (#50b 8/12 から低下、 但し N=3 variance 内) |

**Mixed result**: #40 は **一部の Qwen sampling pattern を catch する** が、 yason 経由の
"end of file" failures は別 path で起きるため不完全。

## 仮説 (なぜ regress に見えるか)

可能性 (検証不能 with N=3):

### A. 変動 (variance)

直近 5 commits の pass rate: 8 / 9 / 8 / 7 → mean ≈ 8 / 12 (67%) ± 1。 #40 は 7 だが
single trial 単位の variance はこの規模 (±1) は典型的。

### B. #40 が新 give-up path を作った

104-trial3 :GIVE-UP empty-content (329s) は **#40 によって作られた新 failure path**。
pre-#40 では同 sampling pattern が:
- max-action-parse-errors (Qwen が空コンテンツ → parse error 連発 → existing limit)
- max-patches (agent が patches を試行錯誤 → existing limit)
等の path で eventually terminated していたが、 wall-clock は long。 

→ #40 で **早期 give-up に集約**された結果、 give-up rate は上がるが wall-clock は減る。
trade-off: pass rate vs wall-clock。

### C. Qwen 自体の variance

最近 benches で Qwen の sampling quality が下がっている可能性 (model state /
load / hour-of-day effect)。 観測不能。

## 改善方向

### Option A: #40 を yason errors にも extend

complete-chat (or plan-development) で chat-response content を **eager yason validate**
する layer 追加。 失敗時 :empty-content と同等 retriable error。

cost: small (planner-error path で yason 失敗時 retry)。
risk: 過剰 retry で wall-clock 累積。

### Option B: whitespace-only content も :empty-content として扱う

chat-parse-response の check を `(string-trim ...)` 後の length で。
"empty" の semantic が広がるが、 102-trial3 の planner-error が空回避できる可能性。

cost: tiny (1 行修正)
risk: 通常 content が頭部空白だと false-positive

### Option C: #40 freeze, observe more

N=3 では結論できない。 N=10 paired bench で #40 effect (give-up rate / wall-clock)
を proper に測定してから次の改善判断。

## 推奨

**Option B (1 行修正)** で whitespace-only も catch + 別 bench 検証が最 ROI。
完全 retry coverage (#40 yason extension) は wall-clock リスクあり、 慎重に。

但し pass rate trajectory が連続して 8-9 範囲に張り付いている事実は、
**recent fixes が cumulative net positive / negative ではなく zero-sum** に近い
可能性を示唆。 H baseline 11/12 が peak で、 真の equilibrium は ~8-9/12 程度。

### 学び

- 「empty-content」 のような defensive measure は **特定 path で works** but
  **adjacent path に失敗が逃げる** ("squeeze the balloon" pattern)
- yason call が複数 layer に存在 (chat-parse-response, %parse-plan, %parse-develop-spec
  等)、 一箇所 fix しても全体 robustness は均一にならない
- 真の bottleneck は **Qwen 自体の output quality variance**、 client side defensive
  layers では限界がある
