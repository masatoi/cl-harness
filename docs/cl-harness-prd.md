# PRD: cl-harness

## 1. 概要

`cl-harness` は、Common Lisp プロジェクト向けの runtime-native coding agent harness である。

既存の多くの coding agent は、ファイルシステム、shell、テストログを中心にした次のようなループで動作する。

```text
read files → edit files → run tests → read logs → edit again
```

一方、Common Lisp の実際の開発体験は、REPL、ASDF、package、CLOS、macro、condition/restart、ライブイメージを中心に構成される。

`cl-harness` は、`cl-mcp` を Common Lisp runtime interface として利用し、LLM が Common Lisp 開発者らしい REPL 駆動の仮説検証ループでコードを調査・修正・検証できるようにする。

`cl-mcp` は、JSON-RPC 2.0 over stdio/TCP/HTTP により、AI agents が Common Lisp 環境に対して REPL evaluation、system loading、file operations、code introspection、structure-aware editing を行える MCP server である。 また、REPL evaluation with object inspection、structured error context、stack frames、local variables、structure-aware Lisp editing、structured test runner、worker pool isolation などを提供する。

`cl-harness` は `cl-mcp` の上位層として、以下を担当する。

```text
- LLM provider との通信
- agent loop の制御
- cl-mcp tool の選択・制約・呼び出し
- Common Lisp 固有 workflow の適用
- runtime probing と source patching の分離
- clean verification
- benchmark execution
- transcript / metrics logging
```

---

## 2. プロダクトビジョン

### 2.1 最終目標

`cl-harness` の最終目標は、次である。

> Common Lisp の REPL 駆動開発を、LLM coding agent の標準実行ループにする。

より具体的には、`cl-harness` は、Common Lisp のライブランタイム、ASDF、package、CLOS、macro expansion、condition/restart system を第一級の観測対象として扱う coding agent harness を目指す。

---

### 2.2 コアコンセプト

従来型 coding agent:

```text
files → edit → build/test → logs → retry
```

`cl-harness`:

```text
runtime → inspect → probe → patch source → reload → test → clean verify
```

`cl-harness` は、REPL を単なる補助ツールではなく、**仮説検証の中心**として扱う。

ただし、最終的な正しさは REPL 上の成功ではなく、clean runtime における load/test 成功で判定する。

---

## 3. 背景と課題

### 3.1 背景

Common Lisp は、以下のような特徴を持つ。

```text
- ライブイメージを持つ
- REPL 駆動開発が一般的
- ASDF による system 管理
- package system による symbol 管理
- CLOS による dynamic dispatch
- macro による構文拡張
- condition/restart による構造化されたエラー処理
- runtime introspection が強力
```

これらは、人間の Common Lisp 開発者にとっては大きな強みである。

しかし、汎用 coding agent は多くの場合、Common Lisp プロジェクトを他言語と同じように、ファイルとテストログの集合として扱う。

その結果、次のような問題が起きやすい。

```text
- package context を誤る
- symbol resolution を誤る
- defmethod / generic function を通常関数のように扱う
- macroexpand せずに DSL を推測で修正する
- REPL で小さく検証せず、大きな patch を生成する
- style-warning / condition / restart の情報を活かせない
- REPL 上の状態と source file の整合性を管理できない
```

---

### 3.2 解決したい課題

`cl-harness` は、以下の課題を解決する。

```text
P1. Common Lisp 固有の runtime 情報を LLM agent が活用できない
P2. 汎用 coding agent は file-centric であり、REPL 駆動開発に最適化されていない
P3. ローカル LLM / 小〜中規模 LLM では、大量ファイル・大量ログを扱うと性能が落ちる
P4. REPL probing と source patching の整合性を管理する仕組みがない
P5. runtime-native approach の有効性を定量評価する benchmark harness がない
```

---

## 4. 研究仮説

`cl-harness` は、以下の仮説を検証するための実験基盤でもある。

> LLM coding agent は、ファイルシステム中心の観測・編集ループよりも、実行中ランタイムから得られる構造化情報を利用することで、Common Lisp 固有の修正タスクにおいて、より少ないコンテキスト、少ない試行回数、小さい patch で正しい修正に到達できる。

特に、以下のタスクでは runtime-native approach の優位性が期待される。

```text
- package / symbol resolution
- macro expansion が関係するバグ
- CLOS method dispatch が関係するバグ
- ASDF load-order / dependency のバグ
- condition / restart handling のバグ
- 実行時オブジェクト状態に依存するバグ
```

---

## 5. 対象ユーザー

### 5.1 Primary users

```text
- Common Lisp 開発者
- cl-mcp 利用者
- ローカル LLM を使って Common Lisp 開発を自動化したい開発者
- Common Lisp プロジェクトの保守者
```

### 5.2 Secondary users

```text
- LLM coding agent の研究者
- runtime-native agent architecture に関心のある開発者
- Smalltalk / Clojure / Erlang / Julia 等の live runtime agent に関心のある研究者
```

---

## 6. スコープ

## 6.1 MVP スコープ

MVP は、Common Lisp で実装する。

MVP の目的は、**cl-mcp を使った runtime-native Common Lisp bug fixing loop を実証し、file-centric baseline と比較できる状態にすること**である。

MVP で対応するもの:

```text
- cl-mcp HTTP transport への接続
- OpenAI-compatible Chat Completions API への接続
- Common Lisp 製 CLI
- ASDF/Rove project の小規模 bug fixing
- runtime probing
- source patch
- load/test
- clean verification
- JSONL transcript logging
- benchmark runner
- file-only / generic-mcp / runtime-native の3条件比較
```

MVP で対応しないもの:

```text
- GUI
- Emacs/SLIME 統合
- multi-agent
- vector DB / RAG
- 長期記憶
- Claude Code 互換 UI
- 複数 provider の完全対応
- 並列 benchmark execution
- 完全な CLOS/MOP workflow
- 完全な ASDF graph visualizer
- security sandbox
```

---

## 6.2 v1.0 スコープ

v1.0 では、MVP を発展させ、以下を目指す。

```text
- package / macro / CLOS / ASDF / condition workflow の実装
- 複数 LLM provider 対応
- benchmark suite 50〜100 tasks
- human approval mode
- safe patch mode
- cl-mcp capability profile
- model size 別評価
- ablation study 支援
```

---

## 7. システム構成

### 7.1 全体構成

```text
+-----------------------------+
| LLM Provider                |
| OpenAI-compatible / Groq    |
| local vLLM / NIM            |
+-------------+---------------+
              |
              v
+-----------------------------+
| cl-harness                  |
| Common Lisp agent harness   |
|                             |
| - agent loop                |
| - workflow engine           |
| - tool policy               |
| - context builder           |
| - verifier                  |
| - benchmark runner          |
| - logger                    |
+-------------+---------------+
              |
              v
+-----------------------------+
| cl-mcp                      |
| MCP server for Common Lisp  |
|                             |
| - repl-eval                 |
| - inspect-object            |
| - load-system               |
| - run-tests                 |
| - lisp-read-file            |
| - lisp-edit-form            |
| - code-find                 |
+-------------+---------------+
              |
              v
+-----------------------------+
| SBCL / ASDF / Project       |
+-----------------------------+
```

---

### 7.2 責務分離

#### cl-mcp の責務

```text
- Common Lisp runtime への structured tool API 提供
- REPL evaluation
- object inspection
- ASDF system loading
- Lisp-aware file reading
- structure-aware editing
- test runner
- worker pool isolation
```

#### cl-harness の責務

```text
- LLM との通信
- agent loop 制御
- tool 使用 policy
- workflow recipe
- context compression
- runtime probing の計画
- source patch の適用判断
- clean verification
- benchmark 実行
- transcript / metrics 保存
```

---

## 8. 機能要件

## 8.1 CLI

### REQ-CLI-001: fix command

`cl-harness` は、指定された Common Lisp project に対して修正タスクを実行できること。

例:

```bash
cl-harness fix \
  --project-root . \
  --system my-app \
  --test-system my-app/tests \
  --issue "Fix failing user serialization test" \
  --model qwen/qwen3.5-coder \
  --base-url http://127.0.0.1:8000/v1 \
  --mcp-url http://127.0.0.1:3000/mcp
```

必須オプション:

```text
--project-root
--system
--test-system
--issue
--model
--base-url
--mcp-url
```

---

### REQ-CLI-002: bench command

`cl-harness` は、benchmark suite を実行できること。

例:

```bash
cl-harness bench \
  --suite ./benchmarks/basic \
  --condition runtime-native \
  --model qwen/qwen3.5-coder \
  --base-url http://127.0.0.1:8000/v1 \
  --mcp-url http://127.0.0.1:3000/mcp
```

対応 condition:

```text
file-only
generic-mcp
runtime-native
```

---

### REQ-CLI-003: dry-run mode

MVP では optional とする。

`--dry-run` 指定時、source patch を実際には書き込まず、提案 patch と検証計画のみを出力する。

---

## 8.2 LLM Provider

### REQ-LLM-001: OpenAI-compatible API

MVP では、OpenAI-compatible Chat Completions API に対応する。

必須:

```text
- /v1/chat/completions
- model 指定
- base-url 指定
- api-key 指定
- temperature 指定
- max tokens 指定
- token usage logging
```

MVP では streaming は不要。

---

### REQ-LLM-002: Provider abstraction

内部的には、将来 provider を追加できる interface を定義する。

Common Lisp 上では、概念的に以下の protocol を持つ。

```lisp
(defgeneric complete-chat (provider messages &key model temperature max-tokens tools))
(defgeneric provider-name (provider))
```

MVP では OpenAI-compatible provider のみ実装する。

---

## 8.3 MCP Client

### REQ-MCP-001: cl-mcp HTTP connection

MVP では cl-mcp HTTP transport に接続する。

必須操作:

```text
- tools/list
- tools/call
```

cl-mcp は stdio、TCP、HTTP transport を提供しているが、MVP では HTTP のみ必須とする。

---

### REQ-MCP-002: Required cl-mcp tools

MVP では、以下の cl-mcp tools を利用できること。

```text
- fs-set-project-root
- load-system
- run-tests
- lisp-read-file
- lisp-patch-form
- lisp-edit-form
- repl-eval
- inspect-object
- code-find
- code-describe
- code-find-references
- pool-kill-worker
```

---

## 8.4 Agent Loop

### REQ-AGENT-001: Turn-based loop

`cl-harness` は、LLM と tool execution の turn-based loop を実装する。

各 turn は以下からなる。

```text
1. context を構築する
2. LLM に次の action を問い合わせる
3. action を validate する
4. tool call または patch を実行する
5. 結果を summarize する
6. transcript に記録する
7. success / failure / continue を判定する
```

---

### REQ-AGENT-002: Action format

LLM からの出力は、構造化された action として扱う。

MVP では JSON 形式を推奨する。

例:

```json
{
  "type": "tool_call",
  "tool": "run-tests",
  "arguments": {
    "system": "my-app/tests"
  },
  "reason": "Establish the current failing test before editing."
}
```

action type:

```text
tool_call
patch
final_answer
give_up
```

---

### REQ-AGENT-003: Limits

MVP では、暴走防止のため以下の制限を持つ。

```text
max-turns
max-tool-calls
max-patches
max-read-files
max-repl-evals
max-wall-clock-seconds
```

---

## 8.5 Tool Policy

### REQ-POLICY-001: file-only mode

`file-only` mode では、runtime introspection を禁止する。

許可 tools:

```text
- fs-set-project-root
- lisp-read-file
- lisp-patch-form
- lisp-edit-form
- run-tests
- load-system
```

禁止 tools:

```text
- repl-eval
- inspect-object
- code-describe
- code-find
- code-find-references
```

目的:

```text
file-centric baseline を作る
```

---

### REQ-POLICY-002: generic-mcp mode

`generic-mcp` mode では、cl-mcp tools を利用可能にするが、専用 workflow guidance は行わない。

目的:

```text
cl-mcp tools を単に与えるだけでどれだけ改善するかを測る
```

---

### REQ-POLICY-003: runtime-native mode

`runtime-native` mode では、Common Lisp 専用 workflow に基づいて tool usage を誘導・制約する。

必須原則:

```text
- まず test failure を観測する
- runtime probing を行う
- source patch は構造的編集 tool に限定する
- patch 後に reload/test する
- 最終判定は clean verification とする
```

---

## 8.6 Workflow

### REQ-WF-001: Test failure workflow

MVP 必須。

処理:

```text
1. load-system
2. run-tests
3. failed_tests を抽出
4. source location を読む
5. 関連 form を読む
6. LLM に原因仮説を作らせる
7. 必要に応じて runtime probing
8. patch
9. run-tests
10. clean verification
```

---

### REQ-WF-002: Package/symbol workflow

MVP 必須。

対象:

```text
- undefined-function
- undefined-variable
- symbol not found
- package export 漏れ
- package import/use の不整合
```

利用する観測:

```text
- code-describe
- code-find
- repl-eval: find-symbol
- repl-eval: symbol-package
- repl-eval: package-use-list
- lisp-read-file: defpackage
```

---

### REQ-WF-003: Macro expansion workflow

MVP 必須。

対象:

```text
- macro double evaluation
- gensym 漏れ
- 変数捕捉
- macro expansion が期待と異なるケース
```

MVP では `repl-eval` 経由で `macroexpand-1` または `macroexpand` を呼ぶ。

将来的には `macroexpand` 専用 cl-mcp tool を追加する。

---

### REQ-WF-004: CLOS workflow

MVP では optional。

v1.0 では必須候補。

対象:

```text
- wrong specializer
- missing method
- :before / :after / :around method interaction
- slot initarg / accessor mismatch
```

---

### REQ-WF-005: ASDF workflow

MVP では optional。

v1.0 では必須候補。

対象:

```text
- system dependency 漏れ
- test-system dependency 漏れ
- load order 問題
```

---

## 8.7 Runtime Probing

### REQ-RUNTIME-001: REPL evaluation

`runtime-native` mode では、LLM が仮説検証のために `repl-eval` を使えること。

ただし、MVP では以下を推奨する。

```text
- timeout を必ず設定する
- package を明示する
- destructive operation は避ける
- 出力長を制限する
```

---

### REQ-RUNTIME-002: Object inspection

`repl-eval` が object id を返した場合、必要に応じて `inspect-object` を呼べること。

対象:

```text
- CLOS instance
- hash-table
- list
- array
- structure object
```

---

## 8.8 Source Patching

### REQ-PATCH-001: Structure-aware editing

source modification は原則として以下の tool を使う。

```text
- lisp-patch-form
- lisp-edit-form
```

理由:

```text
- top-level form 単位で編集できる
- Lisp の構造を壊しにくい
- 差分を局所化できる
```

cl-mcp は Eclector CST parsing と parinfer repair を用いた structure-aware Lisp editing を提供する。

---

### REQ-PATCH-002: Patch limit

MVP では、1 task あたりの patch 数に制限を設ける。

デフォルト:

```text
max-patches = 3
```

---

### REQ-PATCH-003: Patch diff logging

すべての patch は diff として保存する。

保存対象:

```text
- before
- after
- unified diff
- file path
- form type
- form name
- reason
```

---

## 8.9 Verification

### REQ-VERIFY-001: Incremental verification

patch 後、以下を実行する。

```text
1. load-system
2. run-tests
```

---

### REQ-VERIFY-002: Clean verification

最終成功判定の前に clean verification を実行する。

処理:

```text
1. pool-kill-worker
2. load-system
3. run-tests
```

cl-mcp は eval-dependent tools を isolated child SBCL process で実行し、worker pool isolation を提供する。 これを利用して、REPL 上の stale state に依存しない確認を行う。

---

### REQ-VERIFY-003: Success condition

成功条件:

```text
- patch が source file に反映されている
- clean load-system が成功する
- clean run-tests が成功する
- task limits を超えていない
```

---

## 8.10 Logging

### REQ-LOG-001: JSONL transcript

すべての実行は JSONL として保存する。

event type:

```text
run_start
llm_request
llm_response
tool_call
tool_result
patch
verification
metric
run_end
```

### §8.10.1 拡張: postmortem-logging (2026-05-23)

- `:verify` event payload に `failed_tests` 配列を追加(rove framework が
  返す test_name / description / form / values / reason / source キー)。
  passed 時はキー省略。
- `:tool-result` event payload に `content_summary`(成功時、~1500 char
  まで truncate)を追加。エラー時は従来通り `error_text` のみ(排他)。
- 新規 event `:llm-request` を追加。`run-config-log-llm-requests-p` が
  truthy のときのみ `complete-chat` 直前に emit、payload は
  `messages`(role/content の配列)と `messages_count`。
- Opt-in 制御: kwarg `:log-llm-requests` / CLI flag `--log-llm-requests` /
  env `CL_HARNESS_LOG_LLM_REQUESTS`。CLI 起動時に有効化を検出すると
  stderr に一度だけ警告。
- 設計詳細: `docs/superpowers/specs/2026-05-23-postmortem-logging-design.md`

---

### REQ-LOG-002: Metrics

MVP で保存する metrics:

```text
- status
- turns
- llm_calls
- tool_calls
- repl_eval_count
- test_run_count
- file_read_count
- patch_count
- changed_files
- changed_lines
- input_tokens
- output_tokens
- wall_clock_ms
- clean_verification_passed
```

---

## 8.11 Benchmark

### REQ-BENCH-001: Task spec

benchmark task は YAML または JSON で定義する。

例:

```yaml
id: package-export-001
project_root: ./cases/package-export-001
system: sample-app
test_system: sample-app/tests
issue: "Fix the failing test caused by an unexported symbol."
limits:
  max_turns: 20
  max_tool_calls: 80
  max_patches: 3
success:
  type: run-tests
  system: sample-app/tests
```

---

### REQ-BENCH-002: Conditions

benchmark は以下の条件で実行できる。

```text
file-only
generic-mcp
runtime-native
```

---

### REQ-BENCH-003: Initial benchmark suite

MVP では 10〜20 tasks を含む。

初期カテゴリ:

```text
- package-export
- package-shadowing
- macro-double-eval
- macro-gensym
- simple-test-failure
- condition-handler
- asdf-dependency
- runtime-state
```

---

## 9. 非機能要件

## 9.1 実装言語

`cl-harness` は Common Lisp で実装する。

想定処理系:

```text
SBCL 2.x
```

---

## 9.2 ASDF system

プロジェクトは ASDF system として提供する。

想定 system:

```text
cl-harness
cl-harness/tests
```

---

## 9.3 依存ライブラリ候補

MVP では以下の依存を想定する。

```text
dexador          ; HTTP client
yason            ; JSON
alexandria       ; utilities
cl-ppcre         ; text processing
local-time       ; timestamp
uiop             ; portability / subprocess / path
rove             ; tests
```

CLI 実装には、必要に応じて以下を検討する。

```text
clingon
unix-opts
```

---

## 9.4 Portability

MVP では SBCL を対象とする。

理由:

```text
- cl-mcp が SBCL 2.x を主対象としている
- sb-introspect 等の利用がある
- worker process / runtime introspection との相性
```

将来的には他処理系対応を検討するが、MVP では対象外。

---

## 9.5 Security

MVP では trusted localhost development tool とする。

cl-mcp 自体も、`repl-eval` が host image 上で任意の Common Lisp code を実行するため、localhost-only trusted tool として扱うべきであると説明している。

`cl-harness` も同じ前提を継承する。

MVP では以下は保証しない。

```text
- malicious project からの保護
- arbitrary code execution 防止
- container sandbox
- network isolation
```

ただし、誤操作防止として以下は行う。

```text
- project-root を明示する
- write operation を structure-aware tool に限定する
- patch 数を制限する
- destructive shell command は提供しない
```

---

## 9.6 Reproducibility

研究用途のため、再現性を重視する。

必須:

```text
- task spec 保存
- model name 保存
- base-url 保存
- prompt 保存
- tool call 保存
- patch 保存
- metrics 保存
- clean verification result 保存
```

---

## 10. 内部設計

## 10.1 Package 構成案

```text
cl-harness
cl-harness/config
cl-harness/cli
cl-harness/model
cl-harness/model/openai-compatible
cl-harness/mcp
cl-harness/agent
cl-harness/policy
cl-harness/workflow
cl-harness/workflow/test-failure
cl-harness/workflow/package-symbol
cl-harness/workflow/macro
cl-harness/context
cl-harness/patch
cl-harness/verify
cl-harness/bench
cl-harness/log
```

---

## 10.2 主要 CLOS class 案

```lisp
(defclass run-config ()
  ((project-root :initarg :project-root :reader run-config-project-root)
   (system :initarg :system :reader run-config-system)
   (test-system :initarg :test-system :reader run-config-test-system)
   (issue :initarg :issue :reader run-config-issue)
   (condition :initarg :condition :reader run-config-condition)
   (limits :initarg :limits :reader run-config-limits)))

(defclass model-provider () ())

(defclass openai-compatible-provider (model-provider)
  ((base-url :initarg :base-url :reader provider-base-url)
   (api-key :initarg :api-key :reader provider-api-key)
   (model :initarg :model :reader provider-model)))

(defclass mcp-client ()
  ((url :initarg :url :reader mcp-client-url)))

(defclass agent-state ()
  ((turn :initform 0 :accessor agent-state-turn)
   (context :initform nil :accessor agent-state-context)
   (metrics :initform nil :accessor agent-state-metrics)
   (patches :initform nil :accessor agent-state-patches)
   (status :initform :running :accessor agent-state-status)))

(defclass tool-policy ()
  ((mode :initarg :mode :reader policy-mode)))

(defclass run-logger ()
  ((path :initarg :path :reader logger-path)))
```

---

## 10.3 主要 generic function 案

```lisp
(defgeneric complete-chat (provider messages &key temperature max-tokens))
(defgeneric call-tool (client tool-name arguments))
(defgeneric list-tools (client))
(defgeneric allowed-tool-p (policy tool-name))
(defgeneric summarize-tool-result (tool-name result))
(defgeneric run-agent (config provider mcp-client logger))
(defgeneric verify-task (config mcp-client logger))
(defgeneric run-benchmark-suite (suite provider mcp-client condition))
```

---

## 11. MVP 実行フロー

### 11.1 fix command flow

```text
1. CLI arguments を parse
2. run-config を作成
3. model-provider を初期化
4. mcp-client を初期化
5. transcript logger を作成
6. fs-set-project-root
7. load-system
8. run-tests
9. initial context を構築
10. agent loop 開始
11. tool call / patch / verification を反復
12. clean verification
13. final report 出力
14. JSONL / metrics / patch diff 保存
```

---

### 11.2 runtime-native loop

```text
observe:
  run-tests, load-system, error_context, failed_tests を取得

orient:
  failure category を推定する

probe:
  repl-eval, code-describe, code-find, macroexpand 等で仮説検証

patch:
  lisp-patch-form / lisp-edit-form で source patch

verify:
  load-system → run-tests

clean verify:
  pool-kill-worker → load-system → run-tests
```

---

## 12. MVP benchmark cases

初期 benchmark suite は以下を含む。

```text
package-export-001
  defpackage の :export 漏れ

package-shadowing-001
  別 package の同名 symbol を誤参照

macro-double-eval-001
  macro 引数が二重評価される

macro-gensym-001
  gensym 漏れにより変数捕捉が起きる

simple-boundary-001
  関数の境界条件バグ

condition-handler-001
  handler-case が広すぎて serious-condition を握り潰す

asdf-dependency-001
  test system の dependency 漏れ

runtime-state-001
  runtime object state を inspect すると原因が分かるバグ

source-runtime-001
  REPL では動くが clean load で失敗するバグ

method-dispatch-001
  MVP optional。wrong defmethod specializer
```

---

## 13. 成功指標

## 13.1 MVP 成功条件

MVP は、以下を満たせば完了とする。

```text
- Common Lisp で実装されている
- cl-mcp HTTP transport に接続できる
- OpenAI-compatible API に接続できる
- fix command が動作する
- bench command が動作する
- runtime-native loop で少なくとも 5 tasks を修正できる
- 10〜20 benchmark tasks を実行できる
- file-only / generic-mcp / runtime-native の比較ができる
- clean verification が実装されている
- JSONL transcript と metrics が保存される
```

---

## 13.2 評価指標

benchmark で測定する指標:

```text
- success rate
- clean verification success rate
- turns
- LLM calls
- tool calls
- repl-eval count
- test run count
- file read count
- patch count
- changed files
- changed lines
- input tokens
- output tokens
- wall-clock time
```

---

## 14. Out of Scope

MVP では以下を対象外とする。

```text
- malicious code からの sandboxing
- remote multi-user server
- GUI
- IDE integration
- Emacs package
- multi-agent planning
- 自動 issue scraping
- GitHub PR 作成
- vector DB
- long-term memory
- non-SBCL support
- non-HTTP cl-mcp transport
- native Anthropic / Gemini provider
```

---

## 15. リスク

### RISK-001: Common Lisp 実装による API client 周りの工数

OpenAI-compatible API client、HTTP、JSON、streaming などは Python より Common Lisp の方が実装・保守コストが高い可能性がある。

対策:

```text
- MVP では streaming を捨てる
- OpenAI-compatible API の最小 subset に限定する
- dexador + yason で単純な blocking request にする
```

---

### RISK-002: LLM 出力の構造化が不安定

LLM が JSON action を壊す可能性がある。

対策:

```text
- action parser で validation
- JSON parse 失敗時は repair prompt
- 最大 retry 回数を設定
- MVP では action schema を単純化
```

---

### RISK-003: REPL state に依存した false success

REPL 上では成功するが、clean load では失敗する可能性がある。

対策:

```text
- clean verification を必須化
- pool-kill-worker を使う
- final success は clean run-tests のみに基づく
```

---

### RISK-004: cl-mcp tool 不足

macro/CLOS/ASDF 専用 introspection tool が不足する可能性がある。

対策:

```text
- MVP では repl-eval で代替
- 頻出する probing は後で cl-mcp tool 化する
```

---

### RISK-005: benchmark が恣意的になる

Common Lisp 固有タスクに寄せすぎると、汎用性を疑われる可能性がある。

対策:

```text
- 単純バグ、package、macro、CLOS、ASDF など複数カテゴリを含める
- file-only が勝つタスクも含める
- task category 別に分析する
```

---

## 16. 開発ロードマップ

### Phase 0: Skeleton

```text
- ASDF project 作成
- package 構成作成
- CLI skeleton
- config object
- logging skeleton
```

### Phase 1: MCP / LLM connection

```text
- cl-mcp HTTP client
- tools/list
- tools/call
- OpenAI-compatible chat client
- simple prompt roundtrip
```

### Phase 2: Basic fix loop

```text
- fs-set-project-root
- load-system
- run-tests
- lisp-read-file
- LLM action parsing
- lisp-patch-form
- verification
```

### Phase 3: Runtime-native loop

```text
- repl-eval probing
- inspect-object
- code-describe / code-find
- macroexpand via repl-eval
- clean verification
```

### Phase 4: Benchmark runner

```text
- task spec loader
- condition switching
- metrics aggregation
- JSONL transcript
- result summary
```

### Phase 5: MVP benchmark suite

```text
- 10〜20 tasks
- file-only / generic-mcp / runtime-native 比較
- 初期評価レポート作成
```

---

## 17. MVP 判定基準

MVP v0.1 は、以下を満たした時点で完了とする。

```text
- `cl-harness fix` が動作する
- `cl-harness bench` が動作する
- cl-mcp HTTP transport に接続できる
- local OpenAI-compatible API に接続できる
- Common Lisp project の failing test を読み、patch し、clean verification できる
- JSONL transcript が保存される
- 10 個以上の benchmark cases がある
- 3 condition 比較ができる
```

---

## 18. 命名

現時点の仮称:

```text
cl-harness
```

代替候補:

```text
cl-agent
cl-runtime-agent
lisp-harness
repl-agent
```

研究色を出すなら `cl-harness` がよい。
実用 CLI としてのわかりやすさを優先するなら `cl-agent` も候補になる。

---

## 19. まとめ

`cl-harness` は、Common Lisp 専用の runtime-native coding agent harness である。

MVP では、以下に集中する。

```text
- Common Lisp 実装
- cl-mcp の利用
- OpenAI-compatible LLM API
- runtime probing
- source patch
- clean verification
- benchmark logging
- file-only / generic-mcp / runtime-native 比較
```

プロジェクトの核は、次の設計原則である。

```text
REPL は仮説検証に使う。
source file が唯一の永続的変更である。
最終判定は clean runtime で行う。
```

## §19 Scaffold subcommand

`cl-harness scaffold` is a post-MVP addition that emits the minimal
ASDF + rove project skeleton needed by `cl-harness develop`. It is
deterministic, LLM-free, and intentionally separate from the
`develop` command's contract — see
`docs/superpowers/specs/2026-05-22-scaffold-command-design.md` for
the design rationale and behavior matrix.

### §19.1 Files emitted

- `<project-root>/<system>.asd` — main + test ASDF systems, both
  `:class :package-inferred-system`, with rove auto-discovery in
  the test-system's `:perform (test-op ...)` clause.
- `<project-root>/src/main.lisp` — `(defpackage #:<system>/src/main
  (:nicknames #:<system>) (:use #:cl) (:export))` + `(in-package …)`.
- `<project-root>/tests/main-test.lisp` — rove defpackage stub.
- `<project-root>/.gitignore` — `*.fasl`, `*.fasl-tmp`, `.cache/`.

### §19.2 Behavior

- All 3 tracked files (asd + src + tests; `.gitignore` is
  untracked) absent → write all 4 files, return `:written`.
- All 3 present → no-op, return `:already-present`.
- Partial → refuse with `scaffold-partial-state` (exit 1); `--force`
  overrides and overwrites.
- Invalid system name (must match `^[a-z][a-z0-9-]*$` and not end
  with `-`) → exit 2.

### §19.3 Out of scope (intentional)

- `:export` symbol inference (handled by planner, separate spec).
- Auto-chaining from `develop` (kept separate by design).
- Multi-file src layouts.
- Backups on `--force`.

### Implementation review feedback loop

After each plan-step's verification passes (`run-tests` returns
green), an LLM-driven implementation review gate runs. If the
review rejects, `%execute-step` re-runs the same step with the
review feedback prepended to the issue string (under a "## Prior
implementation review feedback" header). The retry budget is
controlled by `:max-impl-review-revisions` (default 2; CLI flag
`--max-impl-review-revisions`). On budget exhaustion the step is
marked `:review-rejected` and the outer replan loop takes over.
This avoids regenerating the entire plan when the reviewer's
correction is local to a single step's implementation.

この原則を満たす MVP ができれば、`cl-harness` は単なる Common Lisp 用 agent wrapper ではなく、runtime-native coding agent architecture の研究・実用基盤として成立する。
