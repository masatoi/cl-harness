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
| C | `make-context-view` による phase/subtask ごとの圧縮 view 生成 (planning / exploration / implementation の 3 phase + planner / explore / agent prompt-builder への opt-in 配線) | landed (2026-05-07) | `docs/plans/2026-05-07-phase-c-context-view.md` |
| D | tool 結果圧縮 (run-tests / fs-read-file / lisp-read-file / clgrep-search 等の summarizer 強化) + `compact-history` の agent loop 配線 (per-LLM-call、閾値 `run-limits.max-context-tokens` 既定 50000) | landed (2026-05-07) | `docs/plans/2026-05-07-phase-d-tool-result-compression.md` |
| E | 構造化 reporting (`format-develop-state-report` で develop-state 全 ledger を markdown 化) + `source-fact-stale-p` 述語 (staleness foundation) | landed (2026-05-07) | `docs/plans/2026-05-07-phase-e-structured-reporting.md` |
| F | `source-fact-stale-p` の context-view 配線 (`:exploration` formatter で `[STALE]` prefix を render-time 付与) | landed (2026-05-07) | `docs/plans/2026-05-07-phase-f-staleness-annotation.md` |
| G | runtime-vocabulary ledger (`runtime-vocab-fact` + `develop-state-runtime-vocabulary`); agent loop が `code-find` / `code-describe` / `code-find-references` 結果から best-effort 抽出して push、`:exploration` view は `[STALE] [kind] PKG:name` で render-time 注釈、`:planning` view は warm-start vocabulary summary を `project-inventory` テキストと併存表示 | landed (2026-05-07) | `docs/plans/2026-05-07-phase-g-runtime-vocabulary.md` |
| H | repl-finding ledger (`(hypothesis probe finding decision)` + promotion linkage `repl-finding-mark-promoted`); action parser が `{"type":"finding"}` を受理し explore loop は `%record-finding-from-action` で persist、orchestrator post-step が hypothesis substring 一致した patch で `promoted-to-source-p` を flip、`:exploration` view は全 finding に `[PROMOTED]` 注釈、`:implementation` view は未 promote の "Findings to implement" のみ ("REPL success != implemented" §3.6) | landed (2026-05-08) | `docs/plans/2026-05-07-phase-h-repl-finding-ledger.md` |
| H' (step-index threading) | source-fact / runtime-vocab / patch-record recorder の `:related-step-index` を `(develop-state-current-step-index ...)` から読むよう修正 (Phase A の orchestrator 配線を読むだけ); Phase H final review で発覚した cross-phase ギャップを解消 | landed (2026-05-08) | `docs/plans/2026-05-08-step-index-threading-followup.md` |
| I | structured `project-summary` slot on `develop-state` (`gather-project-summary` wraps the existing inventory builder) wired into `:planning` view; agent post-patch hook marks dirty on `.asd` / `defpackage` patches; render-time `[STALE]` annotation on the section header when dirty; structured summary appears before the existing `project-inventory` text block (augments, not replaces) | landed (2026-05-08) | `docs/plans/2026-05-07-phase-i-project-summary.md` |
| J | `subtask-summary` record (派生のみ; develop-state には保存しない) + `summarise-step-result` builder; `:implementation` view が `:passed` 完了 step を "Completed subtask summaries" として render し、最新 `+resolved-failures-context-limit+` (既定 3) の resolved failure を "Recently resolved failures (regression watch)" として render する; 両 block は空時には emit されず view が byte-identical | landed (2026-05-08) | `docs/plans/2026-05-07-phase-j-subtask-summary.md` |

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
完全な `(hypothesis probe finding decision)` 構造化は Phase F。

Phase E は §10 (Reporting) を実装した — `format-develop-state-report`
が `develop-state` から markdown レポートを生成し (sections: Goal /
Plan / Completed steps / Patches applied / Active failures /
Resolved failures / Integration issues / Source facts)、空セクションは
elide される。CLI は新 `format-develop-report-structured` wrapper を
opt-in で公開し、既存 `format-develop-report` を置き換えない。
`source-fact-stale-p` 述語が staleness の foundation として導入され、
レポート内では集計 (`N stale detected`) として消費される — context-view
への filter 統合は Phase F に分離。

Phase F は §9 (Staleness) を source-fact について実装した —
`:exploration` formatter が render-time に `source-fact-stale-p` を
評価し、stale な fact のパス先頭に `[STALE]` prefix を付与する
(annotate-not-filter 方針)。`make-context-view` 構築時には
staleness を判定せず、`:implementation` formatter は意図的に
変更していない (resolution は別 ledger で扱う)。

Phase G は §3.4 (Runtime Vocabulary) を実装した — `runtime-vocab-fact`
record (kind / name / package / source-file / summary / via-tool /
probed-at / related-step-index) + `develop-state-runtime-vocabulary`
slot + `runtime-vocab-fact-stale-p` 述語を導入し、agent loop が
`code-find` / `code-describe` / `code-find-references` の tool 結果を
best-effort で観測駆動で push する (malformed result は無音 skip、
`%vocab-kind-from-string` は `find-symbol` 経由で keyword pollution を
回避)。`:exploration` view は Phase F 同パターンで `[STALE] [kind]
PKG:name` を render-time 注釈、`:planning` view は run 全体で観測した
warm-start vocabulary summary を既存の `project-inventory` テキストと
併存させる。受動的な REPL 出力パースや能動的な image-walking は別
phase に分離。

Phase H は §3.6 (Exploration Context) と §6.2 (REPL transcript →
finding) を実装した — `repl-finding` record (4 必須テキスト
field + `promoted-to-source-p` flag + `linked-patch` /
`linked-source-fact`) と `develop-state` への `repl-findings`
slot を導入。`src/action.lisp` の parser が `{"type":"finding",
...}` envelope を受理し (4 sub-field を非空文字列として
validate)、`run-explore-agent` の loop は `%record-finding-from-
action` で persist する (loop は継続、`:finish` のように terminal
ではない)。orchestrator post-step path は `%promote-matching-
findings` で hypothesis 文字列が patch の diff-summary に
substring 一致した場合だけ `repl-finding-mark-promoted` を呼ぶ
(case-fold, idempotent — 一度 promote された finding は再度
clobber されない)。`:exploration` view は全 finding を render し
promoted には `[PROMOTED]` prefix で render-time 注釈、
`:implementation` view は未 promote の finding だけを
"Findings to implement (REPL-confirmed, not yet shipped)" として
表示する ("REPL success != implemented" の §3.6 ルールを
view 層で強制)。`:planning` view は変更していない (finding は
step-local)。fuzzy match や受動的な transcript mining は別 phase。

Phase H final review で **cross-phase の step-index threading
gap** が露呈した: `agent.lisp` の source-fact / runtime-vocab /
patch-record recorder 3 箇所は `:related-step-index nil` を
hard-code していたため、step フィルタ通過する Phase C/F/G/H の
view では実 production データが unconditional に drop していた
(test fixture が hand-build で step-index を入れていたため
気付かれなかった)。`develop-state-current-step-index` は
orchestrator が Phase A で既に setf 済なので、recorder 側は
それを読むだけ。step-index threading follow-up phase
(`docs/plans/2026-05-08-step-index-threading-followup.md`,
landed 2026-05-08) で 3 recorder を一括修正、runtime-vocab は
helper 抽出 (`%record-runtime-vocab-from-tool-call`)。なお
`%vocab-facts-from-tool-result` の input shape bug (yason が JSON
array を vector として parse する関係で `code-find` の `{results:
[...]}` が拾えていない) が同時に発覚、別 phase で対処予定。

Phase I は §3.3 (Project Context) を実装した — `project-summary`
record (`project-root` / `system` / `test-system` / `asd-files` /
`source-files` / `test-files` / `text` / `gathered-at` /
`dirty-p`) と `develop-state` の単一値 slot (これが
context-management refactor で初めての非リスト slot、`:accessor`
直行)、`gather-project-summary` ヘルパー (既存の
`gather-project-inventory` テキスト ビルダーを wrap、reader path
は UIOP のまま)、`develop-state-mark-project-summary-dirty`
NIL-safe flipper を導入。agent loop の patch-record recorder
直後に `%maybe-mark-summary-dirty` フックを inline で配置し
(orchestrator post-step 集約より per-patch atomic で軽い)、
`%asd-path-p` (case-insensitive) または `defpackage` form-type
が一致した場合に dirty を flip する。`:planning` view は構造化
summary を `## [STALE] Project summary` ヘッダー付き (render-time
判定) で先頭に出力、既存の `## Project inventory` テキストは
そのまま後続 (augments, not replaces)。`:exploration` /
`:implementation` view は変更していない。

Phase J は §6.4 (Completed Subtasks) と §6.5 (Resolved Failures
references) を実装した — `subtask-summary` record (`step-index` /
`test-name` / `what-changed` / `tests-added` / `verification` /
`design-impact` / `summarised-at`) と `summarise-step-result`
builder を `src/subtask-summary.lisp` に追加。develop-state には
**保存しない** (派生データ; step-results / patch-records /
abstraction-decisions は既存の slot から読む)。`:implementation`
view は `:passed` 完了 step を `summarise-step-result` で要約し
"## Completed subtask summaries" 配下に `step <N> (<test-name>):
<status>` + `changed: ...` / `design: ...` の indent bullet として
render。`failure-ledger-resolved` から最新 N 件 (既定
`+resolved-failures-context-limit+` = 3、newest-first) を
"## Recently resolved failures (regression watch)" として render
する。両 block は空時に emit せず、空 develop-state に対しては
view 出力が byte-identical。なお Task 2 で `subtask-summary →
orchestrator` の compile-time 依存が
`orchestrator → explore → context-view → subtask-summary →
orchestrator` の load-time 循環を生むことが判明したため、当初は
`subtask-summary.lisp` で `develop-step-result` の slot を
`find-symbol` + `slot-value` で runtime 解決していた (これは
develop-step-result extraction follow-up で解消、下記参照)。

これで context-management refactor の `docs/context-management.md`
で identify した sections (§3.1-3.9 / §4 / §5 / §6 / §8 / §9 /
§10) は **すべて MVP 実装が landed** し、付随するクリーンアップも
完了した。Phase A〜J + 3 つの follow-up (step-index threading /
Phase C wiring / vocab-facts shape fix) + develop-step-result
extraction が landed 済の最終状態。

Phase C wiring follow-up (landed 2026-05-08): 上記の §14 表外と
して個別行を起こさず、Phase C 行と本パラグラフを参照。具体的には
`src/orchestrator.lisp` の 2 箇所の `funcall planner-fn` で
`:develop-state state` を渡すよう更新した — initial-plan 呼び出しと
replan 呼び出しの両方。これで `develop` の実 production プロンプト
が `cl-harness/src/context-view:context-view->string` `:planning`
経由で組み立てられる (legacy ad-hoc 文字列組み立ては
`%build-user-prompt` の `(t ...)` branch に残し、`:develop-state`
を渡さない standalone caller / test stub / bench harness の
planner-fn callback 用に保持)。section 順序は legacy と微妙に
異なる (mode-nudge が context-view block の後ろに移動) が、内容は
同じ。`develop-threads-develop-state-into-planner-fn` deftest が
両 call site で `develop-state` インスタンスが渡されていることを
assert する。

Vocab-facts shape fix (landed 2026-05-08): Phase G の
`%vocab-facts-from-tool-result` (`src/agent.lisp`) が「`code-describe`
の result には `"results"` キーが無い」場合に空リストを返してしまう
バグを修正。原因は `(gethash "results" result)` が NIL を返した時に
`(listp NIL)` が T になり、`t` フォールバック branch (単発 fact 抽出
を outer hash に対して実行) が unreachable だったこと (Phase J 当時
の merge commit メッセージは「yason vector parsing」と記述したが
これは誤診; 検証の結果 yason は JSON array を list として返す)。
修正は `gethash` の 2 値返却 `present-p` で **キー有無** を判定する
形に変更: `:results` キー有 → イテレート、無 → outer に対する単発
fact 抽出にフォールバック。これで `code-describe` 経由の runtime-
vocab 観測も production で実際に記録されるようになった。テスト
`agent-records-runtime-vocab-fact-on-code-describe-via-plural-helper`
と `agent-records-runtime-vocab-empty-results-yields-no-facts` が
2 つの分岐を assert する。

develop-step-result extraction follow-up (landed 2026-05-08):
Phase J Task 2 が回避していた load-time 循環を構造的に解消した。
`defclass develop-step-result` を新ファイル `src/step-result.lisp`
(package `cl-harness/src/step-result`, 依存ゼロ) に分離し、
orchestrator はそこから `:import-from` + `:export` で再公開する
形に変更。`:import-from` は symbol identity を共有するので
`cl-harness/src/orchestrator:develop-step-result-X` を package-
qualified で書いていた既存 caller (`src/cli.lisp` /
`tests/subtask-summary-test.lisp`) は変更なしで動作する。
`subtask-summary.lisp` は `find-symbol` + `slot-value` の runtime
解決を撤去し、`:import-from #:cl-harness/src/step-result` で
4 つの reader を compile-time import するクリーンな形に戻した。
これにより slot 名 typo は compile-time エラーとして surface する
ようになり、Phase J Task 2 で reviewer が懸念した "static safety
の欠如" が解消した。public API 不変、テスト数も不変。

Phase G/H/I prompt enrichment follow-up (landed 2026-05-08):
v0.5.0 のライブ verification (Qwen/Qwen3.6-35B-A3B) で発覚した
3 つの「machinery は実装済だが production で exercise されない」
ギャップを解消した。
- **Phase G** prompt: agent system prompt の `:runtime-native` mode に
  `code-find` / `code-describe` / `code-find-references` を vocabulary
  probe の第一選択として推奨する段落を追記。"vocabulary"
  keyword + 3 つの tool 名を含む。
- **Phase H** prompt: explore system prompt の action schema に
  `{"type":"finding","hypothesis":..,"probe":..,"finding":..,"decision":..}`
  shape を追加し、Workflow rule 2 と 3 の間に「probe で hypothesis を
  確認した時点で finding を emit すべし」の段落を挿入。"REPL success"
  → "shipped behaviour" の promote semantics も明示。
- **Phase I** wiring: `cl-harness/src/orchestrator:develop` が
  `make-develop-state` 直後に `gather-project-summary` を best-effort
  (`handler-case (... (error () nil))`) で呼び、
  `develop-state-set-project-summary` で slot を populate する。
  これで `:planning` view が legacy inventory text と structured
  summary を併記する。

prompt-only 変更が中心なので unit test は keyword 含有のみ assert
(4 deftests 追加: 357 → 361)。実 LLM 動作は manual verify。

Transport failure-mode coverage follow-up (landed 2026-05-08):
v0.5.1 のライブ verification で発覚した dexador 10s timeout のような
transport-layer 故障モードを CI で網羅できるよう、新ファイル
`tests/transport-test.lisp` に **29 deftests** を追加 (361 → 390)。
`%classify-llm-failure` (model.lisp) が HTTP 401/429/4xx/5xx と
response shape 異常を reason keyword に分類し、`complete-chat` は
usocket transport conditions (`timeout-error` / `connection-refused-
error` / 親 `socket-error`) を typed `model-error` に wrap する。
orchestrator は `model-error` を catch して `develop-result :reason`
に伝播 (`:empty-content` のみ `:give-up`、それ以外は `:error`)。
`agent-state` / `develop-state` / `develop-result` に opt-in
`:reason` slot を追加 (NIL on success path、classification keyword
on `:error/:give-up`)。empty-content (planner / agent loop どちらでも)
は即 `:give-up :empty-content` で安定停止。length truncation +
non-empty content は既存どおり parse-action へ forward (再 prompt 経路
で吸収)。レポート formatter (`format-develop-report` /
`format-develop-report-markdown`) が `:reason` を `(reason: :<kw>)` で
inline 注釈する。`tools/chaos-probe.lisp` は real LLM endpoint への
3 シナリオ (P1 max-tokens=1 / P3 unreachable URL / P4 bad API key)
手動 runner で、Qwen/Qwen3.6-35B-A3B + SGLang 上で **P1 (empty-content)
が PASS**、P3/P4 は endpoint 固有挙動 (loopback の closed port が
ECONNREFUSED でなく connect-timeout 化 / SGLang が API key 検証を行わない)
で expected reason と実機挙動が一致しないが、ハーネス側の分類ロジック
自体は正しく機能している。Phase H の prompt 誘導と異なり transport-
layer は **deterministic に CI で検証可能** な点が大きな前進。

LLM retry policy follow-up (landed 2026-05-08):
v0.5.1 後の transport-failure-mode-coverage マージ (`0596936`) で
指摘された 3 件目の reviewer follow-up を着地。
`complete-chat` が transient な MODEL-ERROR (:http-server-error /
:rate-limited / :transport-timeout) で **1 回だけ自動 retry** する
ようになった。`make-openai-provider :retry-p nil` で完全無効化可能。
backoff なし、リトライ回数固定 1 — 最小サーフェスでの保険。
:malformed-response / :transport-unavailable は当面対象外
(production データを見て後続 phase で広げる)。`tools/chaos-probe.lisp`
は `:retry-p nil` を渡して意図的失敗の probe 時間を倍化させない。
+6 deftests (391 → 397)。

Planner failure-context enrichment follow-up (landed 2026-05-09):
fib プロジェクトの EXPORT name-conflict が :STUCK / :NO-PROGRESS で
固まる事例から浮上した v0.5 の replan-feedback 漏れを塞いだ。
`%failure-context` が `agent-state-final-verify` の load-system error /
run-tests failures、および新設の `agent-state-last-tool-errors` ring
(N=3、agent-LLM 起源の isError=true 結果のみ) を多段落形式で planner に
届けるようになった。`:PLANNING` view も `## Active failures` ブロックを
レンダリングし、`:IMPLEMENTATION` view との renderer 共有を再活用する。
+11 deftests (397 → 408)。当初設計 `(c'-β)` の prompt-side recovery
recipe は別 phase に温存。
