# postmortem-logging — 失敗セッションの原因追跡情報拡充

**Date:** 2026-05-23
**Author:** Satoshi Imai
**Status:** Draft for implementation
**Related:**
- `docs/benchmarks/results-2026-05-23-review-feedback-routing-effect.md` — 本 spec のきっかけになった失敗 cell 分析
- `docs/cl-harness-prd.md` §8.10 REQ-LOG-001 — JSONL transcript 規約

## 1. 動機

bench4(`results-2026-05-23-review-feedback-routing-effect.md`)で `:STUCK` / `:LIMIT-EXHAUSTED` 終了した cell の事後分析を行った際、JSONL transcript から再構成できる情報には 3 つの構造的なギャップがあることが判明した:

1. **`:verify` event は passed/failed の件数しか持たない** — どのテストが何で落ちたかは在中の `failure-ledger` (in-memory) にしか無く、JSONL からは読めない。
2. **`:tool-result` event は `is_error` flag だけ** — エラー時の `error_text` は入るが、成功時のツール返り値は記録されない。「エージェントが `lisp-read-file` で何を見たのか」が再現できない。
3. **`:llm-request` event が存在しない** — `:llm-response` の対が無いため、各ターンで LLM が何をプロンプトとして受け取ったかが復元不可。

bench4 ではこれら 3 ギャップにより、103-fizz-buzz-off の `max-patches` 到達は再現できる(patch 試行 3 回、diff も残っている)が、「**それらのパッチで具体的にどのテストが何故落ちたか**」「**エージェントは直前に何を見て次のパッチを書いたか**」までは追えなかった。本 spec はこの 3 ギャップを埋める。

### 1.1 設計判断: なぜ既存イベント拡張か(approach A)

検討した代替:
- **approach B**: G2 を「raw output 1500 char + summarized view」両取り。1 イベントが 2 観点を抱え、single source of truth が崩れる。
- **approach C**: 失敗テスト用に新規 `:verify-failure` イベント、成功 tool result 用に新規 `:tool-result-content` イベントを追加。consumer が `step_index`/`turn` で join する必要があり、「1 verify-task = 1 event」だった単純な対応が崩れる。

既存ロギングは event-sourcing 系の設計(`src/log.lisp`)で、各イベントが「1 つの起きた事を完全記述」する責務を負っている。本 spec はこの原理を維持しつつ、現在イベントが**まだ表現しきれていない属性を加算する**操作。新規イベント型は G3 の `:llm-request` のみ — これは `:llm-response` の対欠如を埋める asymmetry 修正。

### 1.2 スコープ

- **G1 (verify failure details)**: always-on(コスト軽)
- **G2 (success tool-result content)**: always-on(コスト中、Phase D 圧縮済み)
- **G3 (llm-request payload)**: **opt-in**(コスト重、機密情報リスク)

## 2. 全体方針

```
既存 :verify event       ──→  failed_tests 配列を追加 (G1)
既存 :tool-result event  ──→  content_summary フィールドを追加 (G2)
:llm-response の対       ──→  新規 :llm-request event を追加 (G3, opt-in)
```

Lisp 処理系の常時メモリには何も蓄積しない(`src/log.lisp` の `log-event` 設計 — hash-table を 1 イベント分構築→encode→破棄)。コストは disk のみ。

### 2.1 サイズ見積もり(1 step あたり)

| Gap | 追加バイト | 倍率 |
|---|---|---|
| G1 | ~300-3000 B(失敗テスト 1-10件 × ~300 B) | +5–30% |
| G2 | ~3-45 KB(tool 5-30回 × 0-1500 char) | ~2x |
| G3 | ~50-1000 KB(message history × turn) | ~100x |

G1+G2 は always-on で容認、G3 のみ opt-in。

## 3. G1: `:verify` event 拡張

### 3.1 Schema

現状:
```json
{"ts":"...","type":"verify","turn":6,"status":"test-failed","passed":0,"failed":2}
```

変更後(失敗時):
```json
{"ts":"...","type":"verify","turn":6,"status":"test-failed","passed":0,"failed":2,
 "failed_tests":[
   {"test_name":"fizz-buzz-fizz-multiples",
    "description":"3の倍数でFizzを返す",
    "form":"(equal \"Fizz\" (fizz-buzz-at 3))",
    "values":["\"Fizz\"","3"],
    "reason":"got 3 (integer) instead of \"Fizz\"",
    "source":{"file":"/tmp/.../tests/main-test.lisp","line":12}}]}
```

成功時(`status="passed"`)は `failed_tests` フィールドは省略(yason は NIL を null としてエンコードするより省略する shape を選択 — `agent.lisp` 側で alist 構築時に `(when failed-tests ...)` でガード)。

### 3.2 Data source

`verify-result` 構造体の `verify-result-test` slot は `run-tests` ツールが返す test_result(`failed_tests` 配列付きの hash-table または構造体)を保持している。`agent.lisp` の verify event emit 箇所で、この既存中間値から `failed_tests` を抽出。

各エントリの shape は rove framework が返す形に揃える(`test_name` / `description` / `form` / `values` / `reason` / `source`)。これは現在の `summarize-tool-result` でも参照されているフィールド名と一致。

### 3.3 Non-rove framework

`run-tests` ツールは現在 rove のみサポート(`src/test-runner-core.lisp` 由来)。FiveAM や Prove を将来サポートした場合、`failed_tests` 配列の存在は保証されない。本 spec は **rove-only 前提**。framework agnostic 化は別 spec。

## 4. G2: `:tool-result` event 拡張

### 4.1 Schema

現状(成功時):
```json
{"ts":"...","type":"tool-result","turn":2,"tool":"lisp-read-file","is_error":null}
```

変更後(成功時):
```json
{"ts":"...","type":"tool-result","turn":2,"tool":"lisp-read-file","is_error":null,
 "content_summary":"<defpackage ...>\n<in-package ...>\n<defun fizz-buzz (n) ...>\n[... truncated, 245 chars elided ...]"}
```

失敗時(変更なし):
```json
{"ts":"...","type":"tool-result","turn":4,"tool":"lisp-patch-form","is_error":true,
 "error_text":"MCP error -32602: old_text not found..."}
```

成功時は `content_summary`、失敗時は `error_text` — 排他関係。

### 4.2 Data source

`agent.lisp` の `summarize-tool-result` 関数の戻り値をそのまま `content_summary` として記録する。これは:

- 既に `+default-tool-result-cap+`(1500 char)で truncate 済
- **LLM が次ターンで実際に user message として見る文字列**(= postmortem で「エージェントは何を見たか」に直接答える)
- ツール固有の summarizer がある場合(`run-tests` の failed_tests truncation 等)はそれが既に適用済

新規ロジック追加は不要 — 既に計算されている中間値を log-event 呼び出しに追加で渡すだけ。

## 5. G3: `:llm-request` event(新規、opt-in)

### 5.1 Schema

```json
{"ts":"...","type":"llm-request","turn":1,
 "messages":[
   {"role":"system","content":"You are a coding agent..."},
   {"role":"user","content":"## Task\nfix fizz-buzz step 1..."},
   {"role":"assistant","content":"Let me start by reading..."},
   {"role":"user","content":"Tool result: ..."}],
 "messages_count":4}
```

`messages` は LLM に送る完全な chat history(累積)。1 turn 1 イベント、`complete-chat` 呼び出しの直前に emit。

`messages_count` は冗長だが consumer が full history を読まずに長さを知れる便宜フィールド。

### 5.2 Opt-in 制御

優先順位(高→低、最初に truthy を採用):

1. **kwarg**: `:log-llm-requests` on `cl-harness:fix` / `bench` / `develop`(default `nil`)
2. **CLI flag**: `--log-llm-requests`(`fix-options` / `bench-options` / `develop-options` 全部に追加)
3. **環境変数**: `CL_HARNESS_LOG_LLM_REQUESTS=1`(空文字や `"0"` 等の falsy は無効)

`run-config` 構造体に新 slot `log-llm-requests-p`(boolean、default `nil`)を追加。agent loop 内で:

```lisp
(when (run-config-log-llm-requests-p config)
  (log-event logger :llm-request payload))
```

### 5.3 安全警告

opt-in を検出した瞬間 — `cli-main.lisp` の各 handler(`fix-handler` / `bench-handler` / `develop-handler`)頭で kwarg / CLI flag / env を解決した直後、`make-run-config` 呼び出し**前** — に `*error-output*` に 1 回だけ警告(§11 のリスク "警告スパム化" 緩和策と整合):

```
WARNING: --log-llm-requests is enabled. LLM message history (including
source code, file paths, and any other context the agent reads) will be
written verbatim to the JSONL transcript. Do NOT share the transcript
without review.
```

警告メッセージは `cli-main.lisp` の各 handler の頭で fix/bench/develop どれでも同じ文言。

## 6. データ抽出の場所(src/agent.lisp の変更点)

### 6.1 G1 — verify event emit 箇所の拡張

`agent.lisp` 内の verify-task 呼び出し直後の `log-event` 箇所(現在 `run-tests` ツール経路と `clean-verify-task` の合流地点)で、verify-result から failed_tests を抽出するヘルパを 1 つ追加:

```lisp
(defun %verify-failed-tests-payload (verify-result)
  "Extract failed_tests array from VERIFY-RESULT for JSONL emission.
Returns NIL when none failed (so the caller can omit the field)."
  ...)
```

verify event の payload alist 構築時に `(when failed-tests ...)` で条件付き追加。

### 6.2 G2 — tool-result event emit 箇所の拡張

`agent.lisp` の `step-turn` 内のツール呼び出し後 log-event 箇所で、既に計算済みの summarize-tool-result 戻り値を payload alist に追加。1 行追加に近い変更。

### 6.3 G3 — complete-chat 直前への追加

`agent.lisp` の `step-turn` で `complete-chat` を呼ぶ直前に、`run-config-log-llm-requests-p` をチェックして条件付きで `:llm-request` event を emit。

## 7. Backward compatibility

すべて加算的:

- 既存 JSONL consumer(`format-develop-state-report` 等)は新フィールドを参照していないので動作変わらず
- yason / JSON parser は未知フィールドを silently 無視
- `:llm-request` という新規 event type が増えるが、既存 consumer は未知 type をスキップする shape
- `run-config` への新 slot 追加 — `:initform nil` で既存呼び出しは影響なし
- CLI への新フラグ追加 — `--log-llm-requests` が未指定なら従来挙動

## 8. テスト戦略

`tests/agent-test.lisp`(または機能凝集的に `tests/log-test.lisp` 新設)に下記 deftest を追加。すべて stub-driven、LLM プロバイダ・MCP クライアント不要。

1. **`verify-event-emits-failed-tests`**
   - stub verify-result に failed_tests を入れて log-event 経路を駆動
   - 期待: emit された JSONL 行を parse すると `failed_tests` 配列に当該エントリが含まれる

2. **`verify-event-omits-failed-tests-on-pass`**
   - status="passed" の stub verify-result
   - 期待: `failed_tests` フィールドが JSONL 行に存在しない

3. **`tool-result-emits-content-summary-on-success`**
   - stub の summarize-tool-result が "DUMMY-SUMMARY" を返す
   - 期待: tool-result event の payload に `content_summary: "DUMMY-SUMMARY"`

4. **`tool-result-omits-content-summary-on-error`**
   - is_error=true、error_text 入り
   - 期待: `error_text` あり、`content_summary` なし(排他)

5. **`llm-request-emitted-when-opt-in-true`**
   - `run-config` に `:log-llm-requests t`
   - 期待: `complete-chat` 直前に `:llm-request` event が emit され、`messages` に履歴全体

6. **`llm-request-suppressed-when-opt-in-false`**
   - default の `run-config`
   - 期待: `:llm-request` event は emit されない

7. **`llm-request-warning-printed-once`**
   - `(with-output-to-string (*error-output*) ...)` で stderr capture
   - 期待: opt-in 有効化 1 回につき警告 1 行のみ(複数回 make-run-config しても 1 cli 起動につき 1 回)

8. **`log-llm-requests-cli-flag-parses`**
   - clingon command を作って `--log-llm-requests` 渡してパース
   - 期待: `run-config-log-llm-requests-p` が t

合計 8 deftests。現 baseline 444 → 452 を想定。

## 9. ドキュメント更新

- **`docs/cl-harness-prd.md`** — §8.10 REQ-LOG-001 に新フィールドと `:llm-request` event の schema 記述追加
- **`README.md`** — develop / fix / bench の log 説明セクションに新フィールド名と `--log-llm-requests` フラグを追記
- **`docs/superpowers/specs/2026-05-23-postmortem-logging-design.md`** — 本 spec(完成)

リリースノートは landing 時に判断(v0.5.4 or v0.6.0)。

## 10. Out of scope

- **既発生 transcript の遡及拡張** — 適用はこれ以降の run のみ
- **新フィールド version 体系** — `schema_version` field 等。YAGNI、必要が出れば後付け。
- **G3 payload の自動 redaction**(API key / 秘密情報の自動マスキング)— opt-in なので user 責任。redaction は別 spec(`redaction-policy`)で扱うべき大きさ。
- **failure-ledger と verify event の cross-reference 一意化** — G1 で verify event に failed_tests を入れるが、別系統で develop-state に積まれる failure-ledger との同期 / 重複排除は別 spec。
- **Transcript viewer / UI** — JSONL を可視化する別ツール。YAGNI。
- **FiveAM / Prove 等の非 rove framework サポート** — `run-tests` ツール側のスコープ。
- **Per-tool 固有 summarizer の更新** — 既存の summarize-tool-result が出力する文字列をそのまま記録するので、ツール固有の改善は別件。

## 11. リスクと緩和策

| リスク | 緩和策 |
|---|---|
| G3 で API key 等の機密情報が transcript に流出 | opt-in 必須 + stderr 警告 + README に明示警告。redaction は別 spec(scope §10) |
| ファイルサイズ膨張で disk full | G1+G2 は always-on でも step 当たり高々 50 KB / G3 は opt-in。長期 bench 用には `--log-path` で別ボリュームに逃がす運用ガイダンスを README へ |
| `verify-result-test` の構造変化に脆い | rove framework 出力に依存するため、test-runner-core の戻り値変更時に同時に更新が必要。`%verify-failed-tests-payload` をテストで shape-pinning |
| `:llm-request` event の存在で既存 consumer が壊れる | yason の未知-type 挙動でスキップされる前提。`format-develop-state-report` は既知 type のみ enumerate するので問題なし |
| 警告メッセージのスパム化(複数回 emit) | `cli-main.lisp` の handler 頭で 1 回だけ出す、`run-config` には警告ロジックを置かない(コンストラクタの副作用回避) |
| stderr capture できない環境 | `*error-output*` への `format` は ANSI CL でほぼ可搬。サンドボックス等で stderr 抑止される環境では警告が見えなくなるが、機能影響なし |

## 12. 実装順序(writing-plans で詳細化)

おおよその区切り:

1. `%verify-failed-tests-payload` helper を `src/agent.lisp` に追加 + 単体 deftest
2. `verify` event emit 箇所に payload を追加 + deftest(passed / failed 両方)
3. `tool-result` event emit 箇所に `content_summary` を追加 + deftest(success / error 両方)
4. `run-config` に `log-llm-requests-p` slot + initform NIL
5. `:llm-request` event emit + opt-in ガード + deftest(true / false 両方)
6. `*error-output*` 警告 + deftest
7. `make-openai-provider` / `make-run-config` / `fix` / `bench` / `develop` の kwarg 配管
8. clingon `--log-llm-requests` フラグ追加(fix-options / bench-options / develop-options に並列)
9. README + PRD 追記
10. mallet clean + compile-system warning ゼロ確認 + 全テスト緑(444 → 452)

各タスクは TDD で進める(失敗テスト → 実装 → 緑 → commit)。
