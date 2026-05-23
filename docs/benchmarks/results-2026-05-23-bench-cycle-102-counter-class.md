# bench-cycle: 102-counter-class

**Date**: 2026-05-23
**Code**: cl-harness main (730a12dcf35fb6f45617720548695e8365aa5eb5)
**Settings**: review-policy=auto, max-impl-review-revisions=2, log-llm-requests=on, max-replans=3
**Driver**: /tmp/bench-cycle-1779512928.lisp
**Skill version**: bench-cycle (.claude/skills/bench-cycle/)

## 結果サマリ

| Task | Status | Steps | impl-reviews | impl-rejections | Elapsed |
|---|---|---:|---:|---:|---:|
| 102-counter-class | :PASSED | 4 | 4 | 0 | 591.9s |

Replans=0、integration issues=0 でクリーンパス。但し以下の通り内部に
**改善余地のある観測**が複数（特に explore phase の 14k token 浪費）。

## 102-counter-class 詳細

### 真の根因(G1 failed_tests)

PASSED 完走のため最終的な failure はなし。但し中間 verify では:

- step 0 turn 0: `TEST-MAKE-COUNTER-DEFAULT`: `MAKE-COUNTER is undefined`
- step 0 turn 9: 同上 — patch 直後も未解決（impl 不完全）
- step 1 turn 0: `TEST-MAKE-COUNTER-CUSTOM-VALUE`: `invalid number of arguments: 1`
- step 1 turn 3: `TEST-MAKE-COUNTER-DEFAULT`: `Invalid initialization argument :COUNT` （regression — `:initarg` 未宣言）
- step 2 turn 0: `TEST-INCREMENT`: `INCREMENT is undefined`
- step 2 turn 3: `TEST-INCREMENT`: `no applicable method for #<GENERIC-FUNCTION INCREMENT (0)>` （defgeneric のみで method 未追加）
- step 3 turn 0: `TEST-RESET-COUNTER`: `RESET-COUNTER is undefined`
- step 3 turn 3: `TEST-RESET-COUNTER`: `no applicable method ...` （step 2 と同パターン）

### Patch trail

| step | turn | tool | summary |
|---|---:|---|---|
| 0 | 9 | lisp-edit-form | src/main.lisp +3/-0（defclass 追加だが make-counter まで届かず） |
| 0 | 10 | lisp-edit-form | src/main.lisp +3/-0（make-counter 追加 → pass） |
| 1 | 3 | lisp-patch-form | src/main.lisp +2/-2（make-counter に optional arg、回帰導入） |
| 1 | 4 | lisp-patch-form | src/main.lisp +1/-1（slot に `:initarg :count` 追加 → pass） |
| 2 | 3 | lisp-edit-form | src/main.lisp +2/-0（defgeneric increment のみ） |
| 2 | 4 | lisp-edit-form | src/main.lisp +2/-0（method increment 追加 → pass） |
| 3 | 3 | lisp-edit-form | src/main.lisp +2/-0（defgeneric reset-counter のみ） |
| 3 | 4 | lisp-edit-form | src/main.lisp +3/-0（method reset-counter 追加 → pass） |

### Tool errors

| step | turn | tool | message |
|---|---:|---|---|
| 0 | – (explore turn 1) | – | `top-level JSON value must be an object` (explore-action-error: LLM が code-fence ```json ... ``` で array トップレベルを返し parser 失敗) |
| 0 | 4 | fs-read-file | `Internal error during fs-read-file: The file /tmp/develop-bench-102-counter-class-1737998-1/tests/main.lisp does not exist` （実際は `tests/main-test.lisp`） |
| 0 | 8 | fs-write-file | `Cannot overwrite existing .lisp/.asd with fs-write-file; use lisp-edit-form.` |
| 2 | 2 | fs-write-file | （同上）`Cannot overwrite existing .lisp/.asd ...` |

### Run-end counters

```
step 0: status=passed, turns=10, patches=2/attempts=3, reads=7, repl=0, tool_calls=10, token=21963, elapsed=77.0s
        (うち explore phase: 8 turns, 14778 tokens, memo="", status=limit-exhausted)
step 1: status=passed, turns=4,  patches=2/attempts=2, reads=2, repl=0, tool_calls=4,  token=8185,  elapsed=36.7s
step 2: status=passed, turns=4,  patches=2/attempts=3, reads=1, repl=0, tool_calls=4,  token=9959,  elapsed=66.4s
step 3: status=passed, turns=4,  patches=2/attempts=2, reads=2, repl=0, tool_calls=4,  token=9427,  elapsed=54.8s
develop合計: token≈49.5k, elapsed≈591.9s (内 explore≈14.8k token は memo 空)
```

### 改善候補

#### A. bench target 軸

- **102-counter-class の sibling no-exploration fixture 追加** — step 0 で explore が 8 turn × 14778 token 消費して memo 空。
  - 仮説: explore phase の cost-benefit を測る baseline がない。同 fixture を `explore_required=false` で固定し A/B 取れる仕組みが欲しい。
  - 変更案: `develop-benchmarks/102b-counter-class-no-explore/` を追加、`develop-task.json` に `"explore-required": false` を明示。develop-bench runner が読んで planner output を上書き / 制約。
  - 期待効果: 同 fixture で「explore 有・無」の token / elapsed 差を直接測定可能。explore phase の実効価値を継続評価できる。
  - コスト: small。half-day（fixture 1 個追加 + driver の field 解釈）。

- **develop-task.json に `expected-step-count` / `expected-replans` 期待値 field** — 観察された step=4, replans=0 が「正しい設計か」を bench 自身が宣言する仕組みがない。
  - 仮説: 将来 planner が変な分割（step=8 等）を出した時、PASSED でも regression として検出したい。
  - 変更案: `develop-task.json` に optional な `"expected-step-count": 4` / `"expected-replans-max": 0` を追加。develop-bench summary で actual と diff を出力（PASSED かつ過剰乖離は warning）。
  - 期待効果: planner regression が PASSED に紛れて見過ごされる確率を下げる。
  - コスト: small。1-day。

#### B. log content 軸

- **`explore-end` の memo が空のとき `partial-findings` を埋める** — 観察: step 0 の `explore-end status=limit-exhausted memo=""`。8 turn 観察した file/path が捨てられている。
  - 仮説: explore agent が「memo にまとめる」フェーズに到達せず budget が切れている。生 observation を捨てずに最小限の構造化 dump を残せば次フェーズが活用可能。
  - 変更案: `explore-end` event に `partial-findings: {files_listed: [...], files_read: [...], symbols_seen: [...]}` を追加（explore phase 中の tool-result から自動収集）。`memo` が空でもこのフィールドで agent context を継承可能に。
  - 期待効果: explore 失敗時の "0 → 1" 情報量を確保。次フェーズが盲目スタートしない。
  - コスト: medium。1-2 days（log writer + agent prompt の continuation hook）。

- **`explore-action-error` を構造化** — 観察: `message="top-level JSON value must be an object"` だけで、何が parser 失敗したか不明。
  - 仮説: LLM が code-fence + array を出した。これは structured-output 系では頻発するパターン。
  - 変更案: `explore-action-error` に `parser`（例 "json-tool-call"）, `raw_excerpt`（先頭 200 char）, `expected_shape`（例 "single tool-call object"）を追加。
  - 期待効果: 「LLM の何が悪かったか」が log だけで判別可能になり、prompt 調整 / parser 寛容化の判断材料に。
  - コスト: small。half-day。

- **`patch` event に form_type / form_name / operation を追加** — 観察: 現状 `tool` と `file` と `diff` のみ。step 2/3 で発生した "defgeneric 追加だけで method 抜け" パターンは diff 文字列を grep しないと検出不能。
  - 仮説: form-level metadata があれば「defgeneric を追加した step では同じ turn 内に defmethod も追加されているか」を bench-cycle 解析側で自動判定できる。
  - 変更案: `patch` event に `form_type: "defgeneric"`, `form_name: "increment"`, `operation: "insert_after"` を追加。これらは既に `lisp-edit-form` の引数として渡されているはず。
  - 期待効果: anti-pattern の自動検出（"defgeneric without method" を rule で炙り出せる）。
  - コスト: small。half-day（cl-harness/src/orchestrator か patch logger）。

- **`tool-error` に `category` field** — 観察: `code=-32602` と `-32603` だけでは "policy violation" と "filesystem not-found" の区別が困難。
  - 仮説: cross-fixture 分析時に "policy 違反系" vs "情報不足系" の発生率を分けて追跡したい。
  - 変更案: `tool-error` に `category: "policy-violation" | "file-not-found" | "internal-error" | ...` を追加。cl-mcp 側のエラー message から正規化マッピング、または cl-harness の orchestrator が分類。
  - 期待効果: bench-cycle 横断で failure mode の度数集計が可能に。
  - コスト: small。half-day（マッピング table + emitter）。

- **`clean-verify` event に `failed_tests` array を verify と対称に持たせる** — 観察: 現状 `keys=['failed','passed','status','ts','turn','type']` のみ。
  - 仮説: integration check が失敗した時に reason がわからないと debug 不能。今回は 0 issues なので顕在化していないが、対称性を担保すべき。
  - 変更案: `clean-verify` を `verify` event と同じ schema に揃える（`failed_tests`, `source` 等を含む）。
  - 期待効果: 将来 clean-verify failure 時の root cause 解析が `verify` と同じ方法で可能に。
  - コスト: small。half-day。

#### C. cl-harness 実装軸

- **planner が `needs_exploration: false` or null を出した時に explore phase を skip する default** — 観察: step 0 の `step-start.needs_exploration=None`（plan event の steps[0] でも null）にもかかわらず explore phase が 8 turn 走り 14778 token を消費。
  - 仮説: orchestrator が `needs_exploration is None` を "fall back to run explore" と解釈している（または default が true）。explicit false でない限り走るロジックでは "false にできない vague な fixture" で常に explore コストが発生する。
  - 変更案: orchestrator（`src/develop/orchestrator.lisp` 相当）で `(or step.needs-exploration nil)` を判定し、null / false なら explore phase 自体を skip。planner prompt 側でも「明示的に true / false のいずれかを出力」と要求。
  - 期待効果: 今回の 102 fixture で step 0 から 14778 token 削減（~30% カット）。簡単な fixture では explore 0 化。
  - コスト: small-medium。1-day（orchestrator の分岐 + planner prompt 修正 + 既存 fixture re-bench で regression 確認）。

- **explore parser をトップレベル array に寛容化、または agent prompt で single-object を明示** — 観察: explore turn 1 で `top-level JSON value must be an object`。
  - 仮説: agent が複数 tool_call を array で返し、parser は object 期待だった。これは構造化出力で頻発する failure mode で、agent を責めるより parser/prompt 側で吸収すべき。
  - 変更案: 二択。(a) parser 寛容化: array なら先頭要素を採用、または各要素を順次実行（batch mode）。(b) prompt 厳格化: explore system prompt に「ALWAYS respond with a single top-level JSON object containing one tool_call」を明示。両方やってもよい。
  - 期待効果: explore 1 turn 浪費を回避。同じ failure mode が他 fixture で再発する確率も削減。
  - コスト: small。half-day（parser または prompt のいずれか / 両方）。

- **explore phase の partial memo flush on limit-exhausted** — 観察: budget 切れの瞬間に memo="" のまま phase 終了 → 次フェーズに観察結果が伝わらない。
  - 仮説: explore agent は最後の turn で「memo を出力する」ステップに辿り着けない設計。budget 切れの直前に強制的に observation を要約させる safety net が必要。
  - 変更案: explore 最終 turn（budget 残 1）に到達したら system message として「次の応答は memo を必ず出力せよ。tool_call 不可」を inject。または explore 終了時に orchestrator 側で `tool-result` 履歴を簡易フォーマットして `partial_memo` に詰める。
  - 期待効果: explore が "0 情報" で終わるケースを撲滅。次フェーズの planner / executor が context を活用可能に。
  - コスト: medium。1-2 days（orchestrator 改修 + 既存 explore prompt 互換性）。

- **defgeneric+method 同時定義ヒントを agent prompt に追加** — 観察: step 2, 3 で同一パターン（defgeneric 追加 → "no applicable method" → method 追加）が出現。各 1 turn 浪費。
  - 仮説: agent system prompt に CL 固有のリマインダがなく、defgeneric 単独で test pass すると誤認している。
  - 変更案: agent system prompt（`src/agent/system-prompt.lisp` 相当）に "CL では `defgeneric` を追加しただけでは method は存在しない。test が method を要求する場合は同 turn で `defmethod` も追加せよ" を 1 段落追加。
  - 期待効果: 102 fixture の step 2, 3 がそれぞれ 1 turn 短縮。同様 pattern の fixture でも効果あり。
  - コスト: small。prompt 1 段落追加。half-day（prompt 修正 + 1 fixture re-bench）。

- **initarg/slot 対応のリマインダを agent prompt に追加** — 観察: step 1 turn 3 で `make-counter` を `:count` initarg 利用に変更したが defclass slot に `:initarg :count` を付けず regression（`TEST-MAKE-COUNTER-DEFAULT` を壊した）。
  - 仮説: 既存テストを破壊する pattern は本来 impl-review で catch されるはずだが、review 4 件全部 `:passed-first-try` で素通り。
  - 変更案: agent system prompt に「`make-instance ... :initarg-name value` を書く時は同 turn 内で対応する slot に `:initarg :initarg-name` を確認 / 追加」を明示。さらに impl-review prompt に「全 existing test を壊していないか」を明示的 check 項目に加える。
  - 期待効果: step 1 turn 3→4 の往復削減 + 他 fixture でも slot/initarg ミスマッチを予防。
  - コスト: small。prompt 2 箇所修正。half-day。

## Cross-cutting findings

単 fixture なので本来 cross-fixture finding はないが、**同 fixture 内 cross-step**
で以下が観察された:

- **「fs-write-file on existing .lisp」を agent が複数 step（0, 2）で試行** — 既存 backlog #4「agent system prompt の tool 使用ガイダンス改善」が同 failure mode をカバー済。本 cycle で「2 step 連続で同 violation」が観察されたことは backlog #4 の優先度を上げる根拠になる。
- **「defgeneric without method」が step 2, 3 で連続発現** — 上記 C-axis 提案 "defgeneric+method 同時定義ヒント" に集約。1 fixture 内 2 回観察は単発ではない。
- **「test ファイル名の取り違え（main.lisp vs main-test.lisp）」を step 0 で観察** — 既存 backlog #5「agent への `--test-file` パス明示」が同 failure mode をカバー済。

## 推奨次アクション

1. **C1（planner needs_exploration=null/false 時 skip）**: step 0 の 14.8k token 即削減。 small-medium / 1-day。
2. **C4（defgeneric+method 同時定義ヒント）**: 同 fixture 内 2 step で繰り返し観察された pattern。 small / half-day。
3. **B3（patch event に form metadata）**: 今後 bench-cycle 解析を自動化する基盤になる。 small / half-day。
4. それ以降は backlog 参照。

## 既存 backlog との関係

- 新規 backlog 候補: 10 件（A 軸 2, B 軸 5, C 軸 5 — うち C4/C5 は agent prompt 拡張、ただし existing #4 とは別トピック）
- Existing backlog #4 referenced: "agent system prompt の tool 使用ガイダンス改善(#4-α)"（fs-write-file on .lisp の重複）
- Existing backlog #5 referenced: "agent への `--test-file` パス明示(#5)"（tests/main.lisp 誤名の重複）
- 重複検出ルール: lowercase + trim 後の先頭 20 char 一致 — C 軸新規 5 件はいずれも `#4` の "agent system prompt " 接頭辞と衝突しないよう題名を調整済。
