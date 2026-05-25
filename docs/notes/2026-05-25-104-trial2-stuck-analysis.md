# 104-cache-simple trial2 :STUCK 1483s root cause (2026-05-25)

H instrumentation bench で唯一の failure を analyze。 元 trial:
`bench-H-instr-1779651561-104-cache-simple-trial2`、 develop-result =
`:STUCK :NO-PROGRESS 1483s`。

## イベント時系列

trial 全体は 2 round の develop + abort:

### Round 1 (initial plan)

```
plan: [test-make-cache, test-cache-put-get, test-equal-keys-and-exports]
step 0 (test-make-cache): PASSED
step 1 (test-cache-put-get): LIMIT-EXHAUSTED :max-patches
develop-end :LIMIT-EXHAUSTED 2/3
```

#### Round 1 step 1 詳細 (重要)

- 12 turns / 9 tool calls / **patch_count = 2 / patch_attempts = 5 (= 3 failed)** / max-patches fired
- 3 verify failures **all COMPILE-FILE-ERROR** (test file references undefined cache-put / cache-get)

Patch timeline:
- turn 6: ok — `(defclass simple-cache () ((store :initform (make-hash-table) :accessor store)))`
- turn 7: **FAIL** — "patch produced malformed form text (trailing content after form)"
- turn 8: ok — `(defgeneric cache-put (cache key value) (:documentation "..."))`
- turn 9: **FAIL** — "Reader error: expected ) when input ended" (unbalanced parens)
- turn 10: **FAIL** — same reader error

**Key pattern**: 各 patch が成功しても次の verify が **同じ CFE で fail し続ける** —
agent は cache-put を defgeneric として追加したが cache-get や defmethod が抜けていて
test file が compile しない。 verify reason **不変**。

`max-consecutive-failed-patches` (#45) は **発火せず** — consecutive 失敗の最大は
2 (turns 9-10)、 threshold 3 未満。

### Round 2 (replan after step 1 failure)

```
plan: [test-make-cache, test-cache-put, test-cache-get]  (前回と似た形)
step 0 (test-make-cache): LIMIT-EXHAUSTED :max-consecutive-failed-patches
develop-end :LIMIT-EXHAUSTED 1/3
```

#### Round 2 step 0 詳細

- explore phase: 8 explore-llm-responses + 1 explore-action-error
- main agent: 4 turns, **patch_count = 0 / patch_attempts = 3** (全 fail)
- turns 2, 3: **Reader error: expected ) when input ended** (3 連続失敗)
- turn 4: "Internal error during fs-write-file: Invalid pathname"
- **`:max-consecutive-failed-patches` 発火** ← **#45 が works as designed** ✅

### Round 3 (replan attempt → STUCK detection)

orchestrator が新 plan を要求 → planner output の first test = "test-make-cache"
(同じ)。 orchestrator は `develop-state-last-failure-test-name` ("test-make-cache",
round 2 の失敗) と比較 → equal → **:STUCK :NO-PROGRESS 発動**、 develop loop abort。

## 1483s wall-clock の breakdown (概算)

| Phase | 推定 | 主要因 |
|---|---:|---|
| Round 1 step 0 (PASSED test-make-cache) | ~150s | 単 turn LLM call |
| Round 1 step 1 (max-patches) | ~700s | 12 turns × ~50-80s LLM call + tool round-trips |
| Round 2 explore phase | ~240s | 8 explore LLM calls |
| Round 2 step 0 (max-consecutive-failed-patches) | ~250s | 4 turns × LLM call + parse errors |
| Replan + STUCK detection | ~100s | planner LLM call (output が same test name) |
| **Total** | **~1440s** | ≈ observed 1483s |

= 「単一のループで stuck」ではなく **多 phase の cumulative wall-clock**。

## 既存 limit の挙動評価

| Limit | Round 1 step 1 | Round 2 step 0 |
|---|---|---|
| max-patches (=5) | ✅ fired (5/5 attempts) | — |
| max-consecutive-failed-patches (=3) | ❌ not fired (max streak=2) | ✅ **fired** (3/3 attempts) |
| max-turns (=50) | budget で十分 | budget で十分 |
| max-replans (=3) | 関係なし | 関係なし |
| outer :stuck check | 関係なし | round 3 で fired ✅ |

→ **既存 limit が複数組み合わせで早期 give-up を達成**。 #45 / max-patches / outer stuck
の三段構えで 1483s で abort。 但しもっと早く検出できる余地もある。

## Gap analysis: 早期検出できるか

**Round 1 step 1 が最大の wall-clock 消費** (~700s)。 ここで早期 bail できれば 50%
近く節約。 **問題の核**:

> **patches が structurally 成功するが verify reason (CFE) が同じまま不変**

Agent は progress していると思って patches を続けるが、 cumulative state が test の
要求を満たさない。 5 patches 試行を許す max-patches=5 default は consumer-friendly
だが、 **同じ root cause で 3 連続 verify-fail なら progress なし** と検出するべき。

### 提案: 新 limit `max-stalled-verify-cycles`

「**successful patch を挟んでも verify reason が変わらない** N サイクル」 を check:

- Round 1 step 1 の流れ:
  - turn 0: verify CFE (test references undefined)
  - turn 6: patch OK + verify CFE — **reason unchanged**
  - turn 8: patch OK + verify CFE — **reason unchanged AGAIN**
  - → 3 stalled verify cycles → bail

これは **#45 (consecutive failed patches)** と異なる軸 — patches が **成功して
いるのに** verify が前進しない pattern を catch。 既存 backlog #37 (evolved-failures
event) は logging side だが、 これは limit side。

実装:
- `agent-state` に `stalled-verify-streak` slot (defaults 0)
- 各 verify 後、 reason / failed_tests の root が前と同じなら incf、 違ったら 0 に reset
- `check-limits` に `(>= stalled-verify-streak max-stalled-verify-cycles)` を追加
- default = 3 (#45 と同じ感覚)

## Round 2 step 0 patch 失敗の root cause

3 turns 連続で `Reader error: expected ) when input ended`。 agent が `new_text` /
`content` で **括弧の数が合わない** Lisp form を出力。

Common cause:
- 多 form を 1 patch にまとめようとして閉じカッコ忘れ (#38 が targets していた pattern、 削除済)
- defmethod の specializer list 部の括弧数誤り
- 多 line patch を 1 行で書こうとして escape 漏れ

これは agent prompt の `lisp-patch-form` schema 説明を強化する余地。 但し parinfer
auto-repair が **これら全部 fail に分類している** (= parinfer も救えない malformation)。
agent 出力 quality 改善が必要。

## 既存 backlog との関係

- **#37 (evolved-failures event)**: 本 issue と関連。 verify reason の遷移を log するなら、
  本提案 (`max-stalled-verify-cycles`) で limit 化も自然
- **#45 (max-consecutive-failed-patches)**: round 2 で works as designed を確認 ✅
- **#41 / #50 強化**: planner が同じ test name を再生成する pattern も improvement 対象

## 提案する新規 backlog 候補 #56

### 56. max-stalled-verify-cycles — successful patches between unchanged verify failures

**Source**: 104-trial2 STUCK analysis 2026-05-25
**Axis**: cl-harness 実装

**観察**: round 1 step 1 で agent が patch_count=2 / patch_attempts=5 で max-patches に
到達。 但し 2 successful patches の間に挟まれた verify は **全て同じ COMPILE-FILE-ERROR
で reason 不変**。 patches は structurally 成功するが cumulative state が test を
満たさず stuck。

既存 #45 (`max-consecutive-failed-patches`) は patch tool 失敗を見るので catch
できない (patches は OK ですり抜け)。

**仮説**: N 連続 verify-fail で reason が同じなら、 agent の patch 戦略が **意味的に
前進していない** signal。 max-patches を消費する前に bail すれば wall-clock 節約。

**変更案**:
- `agent-state` に `stalled-verify-streak` slot
- 各 post-patch verify で `failed_tests[0].reason` (またはその root-cause symbol) を
  前 verify と比較
- 同じ → incf、 異なる → 0 に reset
- `check-limits` で `>= max-stalled-verify-cycles (default 3)` なら
  `:limit-exhausted :max-stalled-verify-cycles`

**期待効果**: 104-trial2 round 1 step 1 のような ~700s wall-clock を ~300s 以下に。

**コスト**: small + half-day (state slot + reason-equal helper + check-limits 追記 +
tests)。
