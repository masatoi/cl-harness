# Context management code review (2026-05-25)

Read-only review of cl-harness の LLM コンテキスト管理 surface。実 bench なし、
コード読みのみ。判断は「rational か / smell があるか / 計測されているか」の 3 軸。

## Scope (今回 read した範囲)

| File | Lines | Role |
|---|---:|---|
| `src/compact.lisp` | 110 | Pure data transform: head/tail keep + middle digest |
| `src/agent.lisp:1264-1310` | — | `%maybe-compact-messages`, LLM call wrap |
| `src/agent.lisp:743-780` | — | `initial-user-prompt` (develop-state aware) |
| `src/agent.lisp:853-870` | — | tool result truncation cap (1500 chars) |
| `src/agent.lisp:1478-1505` | — | run-agent loop, message threading |
| `src/context-view.lisp` | 529 | Phase-aware context view (planning/exploration/implementation) |
| `src/state.lisp` (slot defs) | 390 | develop-state ledgers |
| `src/inventory.lisp` (signature) | 141 | gather-project-inventory, 5000 byte default |

## 全体構造の verdict

> **structurally reasonable, but largely unmeasured, with one significant semantic gap.**

**Strong points**:
- Compaction は per-LLM-call で **non-destructive** (agent の内部 messages 不変, JSONL transcript full preserved) — debugging から context を失わない
- Phase-aware context-view (planning ≠ implementation ≠ exploration の 3 phase) は **good engineering** — planner には inventory + summary、implementer には active-failures + patches、というように artifact 種類を分けている
- Step-filtered ledger rendering: agent at step N が step M の noise を見ない — `%related-to-step-p` で per-render filter
- Tool result の 1500 char cap (`+default-tool-result-cap+`) で per-result bound
- Token estimate (chars/4) は fast 且つ relative budgeting には十分

**Top concern (semantic gap)**:
- Compaction の "digest" は **literal placeholder** で content 0:
  ```
  [history compacted: 25 earlier messages (~6000 tokens) elided to fit
  the context window. Recent context preserved below.]
  ```
- = 中間 25 turn 分の **情報量 ゼロ** で agent に渡る。発火した瞬間 read された file、過去の verify 失敗理由、 探索結果が消える
- file 内の docstring も "richer summariser would call the LLM ... left for v0.4" と認知済
- 計測 (発火頻度) もないので「実害が出ているか」も不明

## Smells / inconsistencies (詳細)

### A. Compaction quality (semantic)

**観察**: `%digest-message` (`src/compact.lisp:63-74`) は count + token 推定だけを返す。中間 turn の **意味的 content は完全に lost**。

**判定**: 計画的な "v0.4 follow-up" として認識されている placeholder だが、 max-context-tokens=4000 default だと **発火閾値が低い** ため、N=10 sweep のような長め run で頻発する可能性。誰も観測していない。

**改善ヒント**:
- 最小コスト: 中間 turn の tool-error message を抽出して digest に concat (例: `"tool errors: A, B, C; tests failed: T1, T2"`)
- 真の summarisation は別 LLM call necessary (cost trade-off)

### B. Internal messages list は unbounded

**観察**: `run-agent` loop (`src/agent.lisp:1505`) は `(setf messages next-messages)` で `step-turn` の返した append-only list を採用。compaction は `%complete-chat-with-logging` 内で **コピーに対してだけ** 行う。

**結果**:
- agent loop の `messages` 変数は **turn 数に比例して memory** を消費 (max-turns=50 だと 50 round-trip 分が常駐)
- compaction はその copy だけを縮める = LLM payload は bounded
- **設計意図と合致** (JSONL は full history を log するべきで、agent state にも残しておきたい)
- ただし JSONL transcript と内部 messages の **2 重保持** は冗長

**判定**: rational だが、memory pressure を測るなら別。今は問題なし。

### C. develop-state ledgers は per-step ではなく per-run で append-only

**観察** (`src/state.lisp:208-220`):
- `source-facts`, `patch-records`, `runtime-vocabulary`, `repl-findings` 全て list、 develop-state-record-* で `push` (append-only)
- 全 plan-step 通じて 1 つの list に flat に蓄積
- per-step filter は **render 時のみ** (`%related-to-step-p`)

**結果**:
- step N での source-fact が 30 個でも、step N+1 view は `%filter-source-facts` で step N の要素を捨てる
- ただし develop-state 内には **過去の全要素が残る** → render 都度 N times O(facts) のフィルタ
- 5-step × 10 facts/step = 50 facts、render 時に毎回 5 倍 scan = 大した cost ではない

**判定**: 現規模では fine。10+ step plan で N²的 cost が顕在化する可能性は理論上あり。実 fixture set では未到達。

### D. Implementation view の "completed-subtask-summaries" は monotonic

**観察** (`src/context-view.lisp:189-195, 504-516`): `:implementation` phase view が `(%completed-subtask-summaries state)` で **全 prior passed steps** を含む。

**結果**: step 10 だと subtask summaries 9 件、各 N 行 → step 後半で prompt 肥大

**現状での実害**: 我々の bench fixture は max 4-5 step だから問題なし。fixture 規模が増えたら出る。

**判定**: 既知の trade-off。`+completed-subtask-summary-limit+` 的 cap が欲しいが今は不要。

### E. Planner view の runtime-vocab は unfiltered (全 run-vocab)

**観察** (`src/context-view.lisp:303-305`): `:planning` view は `(develop-state-runtime-vocabulary state)` で **全 facts (oldest-first)** を含む。

**意図**: planner が warm start で「agent が既に何を探ったか」を知る → 二度探りを避ける

**結果**: replan 時、 step 1-N の runtime-vocab を全部 inject。 typical 5-10 facts は OK だが、 deeply-explored project では bloat する

**判定**: design intent は justified、cap がないのは smell だが現規模で害なし

### F. Stale flag は読まれるが書く mechanism が見えない

**観察**: `source-fact-stale-p` / `runtime-vocab-fact-stale-p` を render 時に check (`[STALE]` prefix) しているが、**stale を set する path がコード review 範囲で見つからず**。

**疑い**: cosmetic feature (常に nil)。本当に staleness 検知ロジックが背景にあるか未確認。

**改善ヒント**: stale を set する code path が無いなら slot 削除 (誤解の元)。

### G. Threshold (max-context-tokens) は cliff edge

**観察**:
- 4000 tokens 以下: 何も発火しない
- 4001 tokens: いきなり `compact-history` 発火、middle 全部 → 1 digest

**結果**: gradual compaction なし。 turn 5 で 3999 tokens / turn 6 で 4500 tokens の場合、 turn 6 で **中間 6 turn 分が一気に digest** に。 lossy step が abrupt。

**改善ヒント**: keep-tail を threshold superscalar に増やす、or 各 turn で 1-2 個ずつ古い turn を「半分要約」する gradient strategy。だが design complexity 増える。

### H. **計測 (visibility) が一切ない** — 最大の問題

| Event | 現状 |
|---|---|
| `compact-history` 発火 | **JSONL event 無し** |
| 各 LLM call 直前の message size (tokens 推定) | `:llm-request` event に `messages_count` のみ、 token 数なし |
| ledger growth (source-facts 個数 etc.) | 露出なし、`step-end` event で出していない |
| view 化された prompt の最終 size | 計測なし |

→ 「compaction が役立っているか」「どれだけ発火しているか」「どこで bloat しているか」を **既存 JSONL からは推測できない**。

これは **A の意味的 gap より cheap な improvement opportunity** (10 LOC ぐらいの instrumentation で大幅 visibility)。

### I. `max-context-tokens` default 4000 は **Qwen3.6 (32k 窓) には小さすぎる**

**観察**: backlog #34 (`src/config.lisp:46-64`) で 50000 → 4000 に下げたのは 103-fizz-buzz で **2800 token prompt で LLM hang** が起きたから (= endpoint 側 pathological behavior 回避)。

**結果**:
- pathological behavior 回避は理解
- 但し 4000 だと Qwen の窓の **12.5% しか使ってない** = compaction が頻発する設定
- **発火率を測れば、4000 の妥当性 vs hang リスクの trade-off が見える**

**改善ヒント**: 計測 (H) 後、 token usage 分布から safe upper bound を再評価。 model 別 default も検討可。

## 評価サマリ

| 軸 | 評価 |
|---|---|
| **コンテキスト構造の design intent** | ✅ rational (phase-aware, step-filtered, JSONL preserved) |
| **compaction algorithm** (head/tail keep) | ⚠ 構造 OK だが digest content 0 (semantic gap A) |
| **per-LLM-call の token bound** | ✅ enforced |
| **memory footprint (develop-state)** | ⚠ unbounded growth だが現規模で実害なし (C/D/E) |
| **threshold tuning** | ⚠ 4000 は保守的、未測定 (I) |
| **観測性 (instrumentation)** | ❌ ほぼ無し (H) |
| **stale 機能** | ❌ 動いているか不明 (F) |

## 推奨優先順位 (実 bench 前にやれること / 軽量)

1. **(H) `:compact` JSONL event + message size に token 推定 field 追加** (10-30 LOC)
   - 現状の発火頻度 / message size 分布が見える
   - cost: 半日、risk: ゼロ
   - これ無しで他の改善 (A, I) を tune するのは盲打ち

2. **(A) digest content の最小強化** — 中間 turn の tool-error を 1 行 summary
   - 例: `[history compacted: 25 messages elided. Errors in elided block: lisp-patch-form (3x), fs-write-file (1x). Tests reported missing: cache-put, cache-get.]`
   - 完全 summarisation は不要、 surface signal だけ拾う
   - cost: 1-2 hour

3. **(I) max-context-tokens の measurement-based 再評価** — instrumentation (1) 後、bench data から safe upper bound 抽出
   - hang 再発 risk を hard upper bound に縛りつつ余裕拡大

4. **(F) stale flag 検証** — set する path が無ければ delete (誤解防止)
   - cost: 30 min

5. **paired bench** (real validation) — `max-context-tokens` を 4000 / 8000 / 16000 で sweep
   - context management の effect を見る (今は仮説 A/B/C 区別できない)
   - cost: bench ~3 sweep × 1 hour = 3 hours

## 結論

> 「コンテキスト管理の方向性は合理的だが、 effect は計測されていない」

特に **(H) instrumentation 無し** が次に取り組むべき最大のレバー。 これ無しで context-management 系の variations を bench で測ろうとしても dependent variable が見えない。

実 bench の前に **(H) → (A) の最小改善 → next bench に instrumented data を持ち込む** という順序が最 ROI。
