# 要件定義書: cl-harness 実開発支援機能

## 1. 目的

`cl-harness` を、既存テストを通すための bug fixing / benchmark harness から、Common Lisp プロジェクトの実開発を支援できる development harness に拡張する。

実現したい開発体験は次である。

```text
ユーザー要求
→ 計画
→ サブタスク分解
→ 必要に応じた runtime / REPL 探索
→ 実装
→ テスト追加
→ 統合
→ clean runtime による検証
→ レポート
```

特に、Common Lisp らしい **REPL駆動・ボトムアップ開発**を、AIエージェントの開発ループに組み込むことを重視する。

---

## 2. 背景

現在の `cl-harness` は、主に次のような用途に向いている。

```text
既存の failing test がある
→ 原因を調査する
→ source を修正する
→ test を通す
```

これは bug fixing や benchmark には有効である。

しかし、実開発では以下のようなタスクが多い。

```text
- 新機能を追加する
- 既存設計に沿って拡張する
- テストがまだない機能を実装する
- 実装前に適切な抽象を探る
- 小さな部品を作りながら設計を固める
- 複数の変更を統合する
```

そのため、`cl-harness` には、既存テスト修正だけでなく、計画・探索・実装・統合を扱う上位ワークフローが必要である。

---

## 3. 基本方針

### 3.1 トップダウン開発を支援する

ユーザー要求から開発計画を作り、サブタスクに分解し、順に実装・統合できること。

```text
goal
→ plan
→ subtasks
→ implementation
→ integration
→ verification
```

### 3.2 ボトムアップ開発を支援する

必要に応じて、REPLやruntime introspectionを用いて小さな実験を行い、そこから抽象や設計方針を発見できること。

```text
runtime inspection
→ REPL exploration
→ candidate abstraction
→ source implementation
→ verification
```

### 3.3 両者を統合する

最終的には、以下のような混合フローを実現する。

```text
Top-down orchestration
+ Bottom-up discovery
+ Clean-runtime verification
```

トップダウンで目的と統合方針を管理し、サブタスク単位では必要に応じてボトムアップ探索を使う。

---

## 4. 必須要件

### 4.1 Planning

ユーザーの要求から、開発計画を作成できること。

計画には少なくとも以下を含める。

```text
- 目的
- 受け入れ条件
- サブタスク
- 調査すべき既存コード・runtime要素
- テスト方針
- リスク
- 必要に応じた探索の要否
```

計画は、人間または後続エージェントが読んで実行できる形式で保存されること。

---

### 4.2 Orchestration

複数のサブタスクを管理し、開発全体を進行できること。

必要な機能は以下。

```text
- サブタスクの状態管理
- サブタスクごとの適切な作業方針の選択
- 探索・実装・テスト・統合の順序制御
- 失敗時の再計画または停止判断
- 最終検証の強制
```

最初から本格的なmulti-agent並列実行は不要。
単一エージェントでもよいが、内部的に役割やフェーズを分けて扱えること。

---

### 4.3 Runtime Inspection

Common Lisp runtime から、既存コードの語彙や構造を調査できること。

対象には以下を含める。

```text
- package
- symbol
- function
- generic function
- method
- class
- macro
- ASDF system
- test system
```

目的は、エージェントが既存設計を無視して新しい構造を勝手に作ることを防ぐことである。

---

### 4.4 REPL Exploration

実装前または実装中に、REPLで小さな仮説検証を行えること。

REPL exploration は以下の目的に使う。

```text
- データ変換の試作
- 小さな関数の挙動確認
- API境界の検討
- CLOS設計の検討
- macro / DSL が必要かどうかの判断
- 既存runtime状態の確認
```

ただし、REPL上の成功を最終成果として扱ってはならない。

---

### 4.5 Source Promotion

REPLで得た発見や試作を、必要なものだけsource codeへ昇格できること。

要件は以下。

```text
- REPL上の一時定義をそのまま成果としない
- 採用する抽象と採用しない抽象を区別する
- sourceへ反映する前に既存設計との整合性を確認する
- source変更後は必ずload/testで検証する
```

---

### 4.6 Abstraction Control

ボトムアップ開発では、抽象化のしすぎを防ぐこと。

少なくとも以下を記録・判断できること。

```text
- 採用した抽象
- 採用しなかった抽象
- 通常関数で十分か
- class / generic function が必要か
- macro / DSL が本当に必要か
- 既存の命名・package・設計と整合しているか
```

macro / DSL の導入は特に慎重に扱うこと。
初期段階では、明確な理由なしにmacroを追加しないこと。

---

### 4.7 Implementation

計画または探索結果に基づいて、source codeを変更できること。

要件は以下。

```text
- 既存コードの構造に沿って実装する
- 変更範囲を必要最小限にする
- Common Lisp の package / ASDF / test system を考慮する
- 変更理由を記録する
```

---

### 4.8 Test Generation

既存の failing test がない場合でも、実装内容に対応するテストを追加できること。

要件は以下。

```text
- 既存のtest frameworkに合わせる
- 追加した関数・機能を検証する
- 既存挙動を壊していないか確認する
- 必要に応じてintegration testを追加する
```

---

### 4.9 Integration

複数の変更を統合し、全体として一貫した状態にできること。

要件は以下。

```text
- サブタスク間の変更衝突を確認する
- package export / import を確認する
- ASDF依存関係を確認する
- test systemに必要な変更が入っているか確認する
- 最終的に全体テストを実行する
```

---

### 4.10 Clean Verification

最終成功判定は、必ずclean runtimeで行うこと。

要件は以下。

```text
- REPL上の一時状態に依存しない
- source fileから新しくloadできる
- test systemがcleanに実行できる
- 成功・失敗を明確に記録する
```

---

### 4.11 Reporting

実行結果を後から確認できる形で保存すること。

レポートには少なくとも以下を含める。

```text
- ユーザー要求
- 作成した計画
- 実行したサブタスク
- 探索した内容
- 採用した抽象
- 採用しなかった抽象
- 変更した内容
- 追加したテスト
- 検証結果
- 残課題
```

---

## 5. 開発モード

少なくとも以下のモードを扱えること。

### 5.1 Top-down mode

計画とサブタスク分解を重視する。

```text
要求
→ 計画
→ 実装
→ 統合
→ 検証
```

### 5.2 Bottom-up mode

REPL探索と抽象発見を重視する。

```text
要求
→ runtime調査
→ REPL探索
→ 抽象候補
→ 実装
→ 検証
```

### 5.3 Mixed mode

デフォルトの実開発モード。

```text
要求
→ 計画
→ 必要な部分だけ探索
→ 実装
→ テスト
→ 統合
→ clean検証
```

---

## 6. 非目標

初期実装では、以下は必須ではない。

```text
- 本格的なmulti-agent並列実行
- GUI
- Emacs連携
- GitHub issue / PR 自動作成
- 長期記憶
- vector DB / RAG
- 完全なsandbox security
- 大規模リファクタリングの完全自動化
- macro / DSL の積極的な自動生成
```

---

## 7. 受け入れ条件

この機能は、最低限以下を満たせば成立とする。

```text
- ユーザー要求から開発計画を作れる
- 計画をサブタスクに分解できる
- 必要に応じてruntime / REPL探索を行える
- 探索結果から採用すべき抽象を選べる
- 採用しない抽象も記録できる
- source codeを変更できる
- 必要なテストを追加できる
- clean runtimeでload/testできる
- 実行結果をレポートとして残せる
- 既存のfix / bench機能を壊さない
```

---

## 8. 最終的に目指す姿

`cl-harness` を次の状態にする。

```text
Before:
  failing test repair / benchmark harness

After:
  Common Lisp runtime-native development harness
```

実現したい本質は次である。

```text
AIエージェントが、
Common Lisp runtimeを観察し、
REPLで小さく試し、
抽象を発見し、
必要なものだけsourceへ反映し、
テストを追加し、
clean runtimeで検証する。
```

これにより、`cl-harness` は単なるcoding agent wrapperではなく、Common LispのREPL駆動・ボトムアップ開発文化をAIエージェントの実行ループに組み込むための専用ハーネスになる。
