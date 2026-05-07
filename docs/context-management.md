以下は、AIエージェントに渡すための **コンテキスト管理に関する推奨設計・要件定義**です。
具体的なファイル構成・クラス設計・実装コードは含めず、満たすべき性質と設計方針に絞っています。

---

# 要件定義: cl-harness コンテキスト管理

## 1. 目的

`cl-harness` の実開発支援機能において、LLMエージェントが長い開発作業を安定して進められるように、開発状態を構造化して管理する。

コンテキスト管理の目的は、LLMにすべての会話履歴・tool結果・ファイル内容を渡すことではない。

目的は以下である。

```text
- 現在の開発目的を見失わない
- 現在のサブタスクを明確にする
- 既存コード・runtime情報を適切に再利用する
- REPL探索結果とsource変更を混同しない
- 古い失敗情報と現在の失敗情報を混同しない
- 必要な情報だけを圧縮してLLMに渡す
- 最終レポートをraw conversationではなく構造化状態から生成する
```

---

## 2. 基本方針

### 2.1 会話履歴を正本にしない

LLMの会話履歴を、開発状態の正本として扱ってはならない。

開発状態は、ハーネス側が構造化して保持すること。

LLMには、現在のphase・subtask・判断内容に応じて、必要な情報だけをまとめた context view を渡す。

```text
Bad:
  全会話履歴 + 全tool結果 + 全ファイル内容を毎回渡す

Good:
  構造化されたrun stateから、現在必要な圧縮済みcontext viewを生成する
```

---

### 2.2 Raw log と Context を分離する

全証跡としての transcript / raw log と、LLMに渡す context は分離すること。

```text
Transcript:
  実行中に起きたすべての出来事の証跡

Context:
  次の判断や作業に必要な圧縮済み状態
```

Transcript は監査・デバッグ・再現性のために保存する。
Context は作業継続・判断・実装のために生成する。

Transcript をそのまま prompt に積み続けてはならない。

---

### 2.3 状態は構造化して保持する

以下の情報を、可能な限り構造化された状態として管理すること。

```text
- ユーザー要求
- 受け入れ条件
- 非目標
- 開発計画
- サブタスク
- 現在のphase
- 現在のsubtask
- project summary
- runtime vocabulary
- source summary
- REPL探索結果
- 採用した抽象
- 採用しなかった抽象
- 設計判断
- patch summary
- verification status
- unresolved risks
```

---

## 3. 管理すべきコンテキスト

### 3.1 Goal Context

ユーザーの要求・目的・受け入れ条件を保持する。

要件:

```text
- 全phaseで参照できること
- 短く圧縮された形でLLMに渡せること
- 作業途中で目的から逸脱していないか確認できること
```

含めるべき内容:

```text
- ユーザー要求
- 成功条件
- 非目標
- 変更してよい範囲
- 優先順位
```

---

### 3.2 Plan Context

開発計画とサブタスクの状態を保持する。

要件:

```text
- サブタスクの一覧を保持する
- 各サブタスクの状態を保持する
- 現在のサブタスクを明示する
- 完了済み・未完了・失敗中のサブタスクを区別する
- 必要に応じて再計画できる
```

LLMに渡す際は、全計画を毎回渡すのではなく、現在の作業に必要な部分を要約する。

---

### 3.3 Project Context

プロジェクト全体の構造を保持する。

含めるべき内容:

```text
- ASDF system
- package構成
- 主要module
- test framework
- CLI構成
- 既存agent loop構成
- coding style
```

要件:

```text
- 一度調査した内容を要約として再利用できること
- patch後に関連するsummaryを更新できること
- staleなsummaryを検出または再調査できること
```

---

### 3.4 Runtime Vocabulary Context

Common Lisp runtimeから得られる語彙・構造を管理する。

対象:

```text
- package
- exported / internal symbols
- functions
- generic functions
- methods
- classes
- macros
- conditions
- ASDF systems
- test systems
```

目的:

```text
- 既存設計に沿った実装を促す
- 不要な重複定義を避ける
- package / symbol resolution の誤りを減らす
- fileだけでは分からないruntime上の情報を活用する
```

要件:

```text
- runtime inspection結果を要約できること
- source summaryとruntime vocabularyを相互参照できること
- 現在のsubtaskに関連する語彙だけをLLMに渡せること
```

---

### 3.5 Source Context

source fileの内容を管理する。

方針:

```text
ファイル全文ではなく、top-level form / symbol 単位で扱う。
```

含めるべき内容:

```text
- file path
- 読んだ範囲
- 関連top-level form
- 関連symbol
- 現在のsubtaskとの関係
- 最終確認時点の状態
```

要件:

```text
- 必要なsource断片だけをLLMに渡せること
- 長いファイル全文を不用意に渡さないこと
- patch後にsummaryを更新できること
- source状態とruntime状態を混同しないこと
```

---

### 3.6 Exploration Context

REPL探索やruntime probingから得られた情報を管理する。

含めるべき内容:

```text
- 試した仮説
- 実行したREPL探索の要約
- 観測された事実
- 成功した仮説
- 失敗した仮説
- 得られた知見
- 採用候補の抽象
- 採用しない抽象
- sourceへ昇格済みかどうか
```

要件:

```text
- REPLログをそのままcontextにしないこと
- 探索結果をfindingとして要約すること
- REPL上で成功しただけのものとsourceに反映済みのものを区別すること
- 探索結果から設計判断を導けること
```

重要原則:

```text
REPL success != implemented
```

---

### 3.7 Design Decision Context

設計判断を保持する。

含めるべき内容:

```text
- 採用した設計
- 採用理由
- 検討した代替案
- 採用しなかった理由
- macro / DSL を使う、または使わない理由
- class / generic function を使う、または使わない理由
- 既存設計との整合性
```

要件:

```text
- 後続subtaskで同じ議論を繰り返さないこと
- 抽象化のしすぎを抑制できること
- 最終レポートに反映できること
```

---

### 3.8 Patch Context

source変更の履歴を管理する。

含めるべき内容:

```text
- 変更したファイル
- 変更したtop-level form
- 変更理由
- diff要約
- 関連subtask
- patch後の検証状態
```

要件:

```text
- patch全文を毎回LLMに渡さないこと
- 通常時は要約を渡すこと
- review / integration / failure analysis 時には詳細diffを参照できること
- patchとverification結果を関連付けること
```

---

### 3.9 Verification Context

load / test / clean verification の状態を管理する。

含めるべき内容:

```text
- 最新のload-system結果
- 最新のrun-tests結果
- 最新のclean verification結果
- 現在activeなfailure
- 解決済みfailure
- warning / style-warning
- error condition
```

要件:

```text
- 現在activeな失敗を明示すること
- 解決済み失敗をactive failureとして扱わないこと
- 古いtest logをそのまま渡し続けないこと
- failure analysis時には、直近patchと失敗内容を結びつけること
```

---

## 4. 状態の階層化

コンテキストは以下の3層に分けること。

```text
Global Context
Phase Context
Turn Context
```

### 4.1 Global Context

開発全体で常に有効な情報。

例:

```text
- goal
- acceptance criteria
- non-goals
- project summary
- current plan summary
- important design decisions
```

短く圧縮し、必要に応じて毎回LLMに渡す。

---

### 4.2 Phase Context

現在のphaseに必要な情報。

例:

```text
Planning phase:
  goal, constraints, project summary

Exploration phase:
  current subtask, runtime vocabulary, relevant source summaries, exploration rules

Implementation phase:
  current subtask, accepted abstractions, relevant source forms, patch constraints

Testing phase:
  implemented changes, existing test style, current failures

Integration phase:
  patch summaries, changed files, verification status, unresolved risks
```

---

### 4.3 Turn Context

次のLLM呼び出しだけに必要な情報。

例:

```text
- 直近のtool結果
- 次に判断すべきこと
- 出力形式
- 使用可能なtool
- 現在の制約
```

Turn Context は短命であり、長期状態としてそのまま積み続けない。

---

## 5. Context View 生成

各LLM呼び出しでは、現在のphaseとsubtaskに応じた context view を生成すること。

要件:

```text
- 現在の作業に必要な情報だけを選ぶ
- 古い情報は要約する
- activeな問題を優先する
- 解決済みの問題は必要な場合のみ含める
- REPL状態、source状態、clean verification状態を区別する
```

Context view には少なくとも以下を含める。

```text
- goal summary
- current phase
- current subtask
- relevant constraints
- relevant project/runtime/source summaries
- relevant design decisions
- latest verification status
- requested output format or next action
```

---

## 6. 圧縮・要約方針

### 6.1 Tool結果

長いtool出力はそのまま再利用しない。

要約対象:

```text
- test log
- stack trace
- file content
- REPL transcript
- macro expansion
- search results
```

要約では以下を残す。

```text
- 重要な観測事実
- active failure
- error condition
- 関連symbol
- 関連source location
- 次の判断に必要な情報
```

---

### 6.2 REPL Transcript

REPL transcript は証跡として保存するが、LLMに再利用する場合は finding に変換する。

悪い例:

```text
REPL入力と出力をそのまま大量に渡す
```

良い例:

```text
Hypothesis:
  aggregation can be implemented as a pure function

Probe:
  tried sample result records in scratch runtime

Finding:
  pure function is sufficient for current requirement

Decision:
  promote ordinary function, not macro or class hierarchy
```

---

### 6.3 File Content

ファイル全文を不用意に渡さない。

Common Lispでは、できるだけ以下の単位で圧縮する。

```text
- package
- symbol
- top-level form
- function
- generic function
- method
- class
- macro
- test
```

---

### 6.4 Completed Subtasks

完了済みサブタスクは、詳細履歴ではなくsummaryに圧縮する。

含める内容:

```text
- 何を完了したか
- 何を変更したか
- 追加したテスト
- 検証結果
- 後続subtaskに影響する設計判断
```

---

### 6.5 Resolved Failures

解決済みのfailureは、現在activeなfailureとして扱わない。

必要な場合のみ、回帰防止や背景情報として短く含める。

---

## 7. Runtime State / Source State / Verified State の分離

以下を明確に分離して管理すること。

```text
Runtime State:
  REPL上で観測・試作されたもの

Source State:
  source fileに永続化された変更

Verified State:
  clean runtimeでload/test済みの挙動
```

要件:

```text
- REPLで成功しただけの定義を実装済みと見なさない
- sourceに書いたが未検証の変更をverifiedと見なさない
- clean verification済みの状態を最終判断に使う
```

この分離は、bottom-up development workflow において特に重要である。

---

## 8. Failure Context

失敗時には、通常のcontext viewではなく failure analysis 用のcontext viewを作ること。

含めるべき内容:

```text
- 何をしようとしていたか
- 直近で何を変更したか
- どの検証で失敗したか
- 現在activeなfailure
- 関連するerror condition
- 関連するsource / runtime情報
- 直前の仮説
- 次に確認すべき仮説
- rollbackまたは再計画が必要か
```

要件:

```text
- 過去の無関係な失敗を混ぜない
- 直近patchと現在failureを関連付ける
- 必要に応じてruntime probingを促す
```

---

## 9. Staleness 管理

コンテキストは古くなる可能性があるため、stalenessを管理すること。

古くなり得る情報:

```text
- source summary
- runtime vocabulary
- project summary
- test status
- patch前の設計前提
```

要件:

```text
- source変更後、関連summaryを更新または無効化する
- runtime reset後、runtime vocabularyを必要に応じて再取得する
- clean verification前のruntime観測を最終事実として扱わない
- 古い情報を現在の状態としてLLMに渡さない
```

---

## 10. Reporting との関係

最終レポートは、raw conversation history からではなく、構造化されたrun stateから生成すること。

レポートに含めるべき内容:

```text
- goal
- plan
- completed subtasks
- failed / skipped subtasks
- exploration findings
- accepted abstractions
- rejected abstractions
- design decisions
- changed files
- tests added
- verification result
- remaining risks
```

これにより、LLMの発話履歴に依存しない、再現性のあるレポートを生成できる。

---

## 11. 受け入れ条件

コンテキスト管理機能は、少なくとも以下を満たすこと。

```text
- LLM会話履歴を開発状態の正本にしていない
- 構造化されたrun stateを保持している
- phase / subtaskごとにcontext viewを生成できる
- 長いtool結果を要約して再利用できる
- REPL探索結果をfinding / decisionとして保存できる
- runtime state と source state を区別できる
- source state と verified state を区別できる
- 完了済みsubtaskをsummary化できる
- 解決済みfailureをactive failureと混同しない
- patch後に関連contextを更新または無効化できる
- 最終レポートを構造化状態から生成できる
```

---

## 12. 非目標

初期実装では以下は必須ではない。

```text
- vector DB / RAG
- 長期記憶
- プロジェクト横断の永続知識ベース
- 全履歴の意味検索
- 複数LLM間の共有メモリ
- IDE連携
- 完全な自動要約品質評価
```

初期段階では、1回の `develop` 実行内で安定して状態管理できればよい。

---

## 13. 最終的に目指す姿

`cl-harness` は、LLMに大量の履歴を渡して作業を続けさせるのではなく、ハーネス自身が開発状態を管理し、LLMには必要なcontext viewだけを渡す。

目指す状態は以下である。

```text
Raw events are logged.
Development state is structured.
Context is generated per phase.
LLM sees only the relevant compressed view.
Clean verification determines final truth.
```

特に、Common Lisp開発では次の分離を重視する。

```text
REPLで観測したこと
sourceに永続化したこと
clean runtimeで検証されたこと
```

この3つを明確に分けることで、REPL駆動・ボトムアップ開発をAIエージェントに安全に扱わせることができる。

---

## 14. 実装状況

| Phase | 内容 | 状態 | 関連 plan |
|---|---|---|---|
| A | 中央 `develop-state` クラスの導入と `develop` の thread 化 | landed (2026-05-06) | `docs/plans/2026-05-06-phase-a-develop-state.md` |
| B (source/patch/failure) | `source-fact` / `patch-record` / `failure-ledger` の追加とインストルメント | landed (2026-05-07) | `docs/plans/2026-05-07-phase-b-source-patch-failure.md` |
| B (runtime-vocabulary) | 構造化 packages / exports / classes / generic functions / conditions / ASDF systems (REPL introspection 経由) | not started | TBD |
| C | `make-context-view` による phase/subtask ごとの圧縮 view 生成 (planning / exploration / implementation の 3 phase + planner / explore / agent prompt-builder への opt-in 配線) | landed (2026-05-07) | `docs/plans/2026-05-07-phase-c-context-view.md` |
| D | tool 結果圧縮 (run-tests / fs-read-file / lisp-read-file / clgrep-search 等の summarizer 強化) + `compact-history` の agent loop 配線 (per-LLM-call、閾値 `run-limits.max-context-tokens` 既定 50000) | landed (2026-05-07) | `docs/plans/2026-05-07-phase-d-tool-result-compression.md` |
| E | staleness 管理、構造化 reporting | not started | TBD |

Phase A の `develop-state` は §3.1 (Goal) / §3.2 (Plan) / §3.7 (Design Decision) /
§3.9 (Verification) の保持先として機能する土台。Phase B は §3.5 (Source) /
§3.8 (Patch) / §3.9 + §8 (Failure ledger active/resolved) を加え、agent loop /
orchestrator から自動記録するインストルメントを設置した。Phase C は §4
(Global / Phase / Turn 階層) / §5 (Context View 生成) を 3 phase 分
(planning / exploration / implementation) 実装し、3 つの prompt-builder
(planner / explore / agent) に **opt-in で配線**した — 既存の
ad-hoc 文字列組み立てを残しつつ、`:develop-state` kwarg が渡された場合のみ
新経路を使う設計で、`cl-harness:fix` の standalone path への影響をゼロにした。
testing phase は implementation と同じ run-agent loop で扱われるため
`:implementation` formatter に折り込んだ。
Phase D は §6 (圧縮) のうち §6.1 (Tool 結果) と §6.3 (File content) を
実装した — `%truncate-large-text` ヘルパーで `fs-read-file` /
`lisp-read-file` / `clgrep-search` / `code-find` / `code-describe` /
`code-find-references` / `inspect-object` の 7 ツール出力を 1500 char で
切り捨て (truncation footer 付き)、`summarize-run-tests` は 5 件超の失敗に
"(N more failures truncated)" footer を付与、`compact-history` を
`step-turn` の `complete-chat` 直前で閾値超過時のみ起動する。
§6.2 (REPL transcript → finding 化) は Phase B の `ADOPTED:/REJECTED:/
DEFERRED:` マーカー parse (`parse-abstraction-decisions`) で部分カバー、
完全な `(hypothesis probe finding decision)` 構造化は Phase E。
§3.3 (Project) / §3.4 (Runtime Vocabulary) / §3.6 (Exploration) /
§6.4 (完了 subtask summary) / §6.5 (resolved failures 参照) /
§9 (Staleness) / §10 (Reporting) は後続 phase で実装する。

**注**: Phase C は orchestrator → planner-fn の `:develop-state` 配線を
意図的に保留している。`plan-development` は kwarg を受け付けるものの、
`develop` のループは現状 kwarg を渡していないため、`:planning` formatter
は test 経由でのみ exercise される。develop-state を planner-fn に流すと
プロンプトの section 順序が変わる（mode-nudge が prior-plan / failure-
context の後ろに移動する）ため、後続 phase で実モデルに対して検証した上で
有効化する。
