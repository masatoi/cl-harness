# Spec: 自律エージェント向けハーネス再設計(グリーンフィールド構想)

- 日付: 2026-06-11
- 種別: 構想 spec(greenfield アーキテクチャビジョン)
- 状態: ユーザー承認済み設計。実装計画は未着手
- 関連: `docs/cl-harness-prd.md`(現行 PRD)、
  `docs/context-management.md`(コンテキスト管理要件)、
  `docs/improvement-backlog.md`(教訓の出所)

---

## 1. 背景と動機

現行 cl-harness(v0.6.0)は「ハーネスが制御フローを所有する」設計である。
`develop` では planner がプランとテストを生成し、orchestrator がステップ単位で
実行し、段階別 review gates と多数の budget が暴走を防ぐ。LLM は各役割の
穴埋めであり、シーケンスはハーネスが台本化する。

この設計は小〜中規模ローカル LLM(PRD P3)には有効だが、自律性の高い
エージェント(frontier クラス)には台本が足枷になる。また、現在人間+
Claude Code が手動運用している自己改善サイクル(bench → ログ分析 →
改善提案 → 適用 → 再測定)は、ハーネス自身の構造に組み込まれていない。

本 spec は、cl-harness を「より自律的なエージェントのためのハーネス」
としてゼロベースで再設計した場合のアーキテクチャを定義する。

## 2. 設計決定(確認済み)

| 論点 | 決定 |
|---|---|
| 自律性の軸 | 全体構想。特に自己改善の自律化に重点 |
| モデル前提 | 能力適応型 — autonomy dial を設計の中心に置く |
| 既存実装との関係 | グリーンフィールド設計(移行パスは本 spec の対象外) |
| 自己変更権限 | プロンプト/設定の変更は統計的裏付けつきで自動。ハーネス自身のコード変更は提案(patch/PR)生成まで。適用は人間承認 |

## 3. 設計原則

### 3.1 継承する原則(現 PRD の核)

```text
- REPL は仮説検証に使う
- source file が唯一の永続的変更である
- 最終判定は clean runtime で行う
```

### 3.2 新たに加える原則

1. **制御の所有権はモデル能力の関数である。**
   手順をハーネスが持つかエージェントが持つかは固定ではなく、
   切り替え可能な dial である。
2. **ハーネスは決定せず、検証する。**
   gate(パイプラインの段)を oracle(いつでも照会でき、最終的に
   通過必須な審判)に置き換える。
3. **すべての実行は実験である。**
   全 run が「使用 artifact のフィンガープリント + メトリクス」を
   記録し、自己改善ループの学習基盤になる。
4. **プロンプト・ポリシー・budget はコードではなくデータである。**
   バージョン管理された artifact にし、自己改善ループが安全に
   変異できる対象にする。

## 4. レイヤーアーキテクチャ

```text
┌────────────────────────────────────────────────────────┐
│ L5 Meta        自己改善ループ(artifact optimizer)     │
├────────────────────────────────────────────────────────┤
│ L4 Mission     ゴールキュー・実行ライフサイクル・      │
│                中断再開・人間との非同期ポート          │
├────────────────────────────────────────────────────────┤
│ L3 Agent       agent kernel + control policies         │
│                (scripted / guided / self-directed)     │
│                ← autonomy dial                          │
├────────────────────────────────────────────────────────┤
│ L2 Services    world model・context compiler・memory・ │
│                oracles・governor(資源管理)           │
├────────────────────────────────────────────────────────┤
│ L1 Environment CL runtime via cl-mcp                    │
│                observation/action space・隔離          │
├────────────────────────────────────────────────────────┤
│ L0 Substrate   LLM providers・event log(event         │
│                sourcing)・artifact store・metrics     │
└────────────────────────────────────────────────────────┘
```

各層は下の層のみに依存する。L5 は専用機構ではなく、「対象プロジェクトが
ハーネスの artifact である mission」として L1〜L4 の同じ基盤上で動く
(ドッグフーディング構造)。

## 5. L1: 環境(Environment)

- cl-mcp の tool 群を **observation/action space** として厳密にラップする。
- 現行の tool policy 3条件(file-only / generic-mcp / runtime-native)は
  「action space の制限」としてこの層に定義し、上位層から独立させる。
- 隔離: run ごとに cl-mcp subprocess(stdio)+ git worktree。
- **エージェント接続プロトコル**: L1/L2 と L3 の境界を薄いプロトコルに
  しておき、将来は外部エージェント(Claude Code 等)を同じ環境+
  オラクルに接続してベンチ比較できるようにする。
- source の書き込みは構造化編集 tool(`lisp-edit-form` /
  `lisp-patch-form`)のみに制限する(action space の制約として表現)。

## 6. L3: agent kernel と autonomy dial

kernel は `observe → context 取得 → decide → act → record` の最小ループ
のみを持つ。`decide` の所有者が control policy として差し替わる。

| dial | decide の所有者 | ハーネスの役割 | 想定モデル |
|---|---|---|---|
| `scripted` | ハーネスの FSM | 現行 develop 相当の台本 | 小型ローカル |
| `guided` | エージェント(次の一手の選択) | アジェンダ(未達サブゴール+不変条件)を保持 | 中型 |
| `self-directed` | エージェント(計画ごと) | 資源・オラクル・記録のみ | frontier |

### 6.1 adaptive dial

governor の進捗メトリクス(停滞・振動・budget 消費率)に基づき、実行中に
dial を降格できる。例: self-directed で 3 サイクル進捗なし → guided に
降格して同じ world model から再開。状態が会話履歴ではなく構造化 state に
あることが、途中切り替えの前提条件である。

### 6.2 研究仮説の拡張

3 つの dial が同一の環境・オラクル・メトリクスを共有するため、
autonomy level 自体が ablation 変数になる。PRD の研究仮説
(runtime-native vs file-centric)に加え、「どのモデルサイズから
どの自律度が成立するか」を測定できる。

## 7. L2: oracles(gate の再設計)

現行 review gates をパイプライン段から 4 種のオラクルに再定義する。

| oracle | 性質 | 内容 |
|---|---|---|
| verification | 決定論 | load / test / clean-verify |
| invariant | 決定論 | AST レベル不変条件(additive-only test change、`skip` 禁止など。現行 `validate-test-source` の一般化) |
| review | LLM judge | 段階別 strictness(plan=soft, tests=strict, test-change=strictest)を **oracle profile** というデータとして保持 |
| progress | 決定論 | 進捗・振動・budget 消費率の監視(governor) |

設計上の転換点:

- エージェントは**オラクルを事前照会できる**。照会結果は world model への
  観測として一元的に入るため、「棄却フィードバックが executor に届かない」
  類の配線問題(現行 backlog #3)が構造的に消える。
- dial により oracle は advisory(self-directed: 助言)にも
  blocking(scripted: 必須通過)にもなる。最終成功判定に限り、
  verification oracle の clean verify 通過は全 dial で必須。

## 8. L2: world model・context compiler・memory

### 8.1 Event sourcing

全ての観測・アクション・オラクル照会結果・decide の判断を append-only の
**event log**(L0)に記録する。これが唯一の正本である。transcript と
run state の二重管理をやめ、event log 一本に統一する。再開・リプレイ・
監査はすべてここから導出する。ディスク表現は JSONL を維持する
(既存分析ツールとの互換)。event schema は粗粒度に保ち、版を付ける。

### 8.2 World model

event log からの導出投影(projection)。最低限以下を含む。

```text
- ゴールと受け入れ条件・非目標
- アジェンダ / プラン(所有者は dial 依存)
- source facts(コード構造の要約)
- runtime findings(REPL 探索台帳。staleness 追跡つき —
  patch・reload で無効化された探索結果は「要再検証」にマーク)
- failure ledger(現在の失敗と過去の失敗の区別)
- patch 履歴(before/after/diff/reason)
- verification 状態
- 未解決リスク・オープンな疑問
```

projection の再構築はメモリ内のみで行う(永続化は event log のみ)。

### 8.3 Context compiler

`(役割, dial, 判断点, トークン予算) → context view` の**純関数**。
world model だけから生成する。小型モデルには小さく密な view、frontier には
広い view を同じ基盤から compile する。コンテキストサイズが会話の長さと
無関係に有界であることが、長期稼働(L4)の前提条件である。

### 8.4 Memory(run 横断)

2 層構成。mission 終了時(およびチェックポイント時)に書き戻し、
context compiler が次の run で消費する。

- **project memory**: project summary・runtime vocabulary・その
  プロジェクト固有の過去 failure modes・規約
- **harness memory**: モデル別の癖、プロジェクト横断の教訓

vector DB は使わない。構造化データ(sexp / JSONL)として持つ。

## 9. L4: mission 層(長期・複数タスク稼働)

- **goal queue**: mission = ゴール + 受け入れ条件 + budget envelope +
  dial 設定(または auto)。バックログとして積める。
- **ライフサイクル**: `created → running → parked → done/failed`。
  event sourcing により suspend/resume は「event log の続きから
  projection を再構築する」だけで成立する。
- **人間ポートは非同期**: 承認要求・エスカレーション(オラクル間の矛盾、
  budget 枯渇、dial 降格の底打ち)はキューに積まれ、エージェントは
  mission を park して別の mission に移れる。人間は同期的なゲート係から
  非同期な承認者・例外処理者になる。
- 単発 CLI 実行は「mission 1 個のキュー」として同じ構造で動く。
  常駐型は必須ではなく可能な運用形態の一つ。

## 10. L5: 自己改善ループ(重点軸)

現在 `bench-cycle` スキルで手動運用しているサイクルを、
**champion/challenger 方式の artifact 最適化**として組み込む。

### 10.1 Artifact store と policy pack(L0)

プロンプト・oracle profile・budget・dial 規則・context compiler 設定を
**policy pack** という版管理されたデータ束にする(semver + 内容
フィンガープリント)。全 run が使用 pack のフィンガープリントを記録する。

### 10.2 ループの 5 段

```text
1. bench scheduler   fixture suite を paired design で実行
                     (同一 fixture で champion vs challenger、N 反復)
2. transcript miner  event log から failure mode を抽出。浪費 turn の
                     分類、tool error パターン、停滞シグネチャ、budget
                     枯渇原因。improvement-backlog 相当のランク付き
                     レポートを自動生成
3. variant generator (LLM)特定 failure mode を狙った artifact 変異を
                     提案。各変異は「予測効果つきの仮説」として記録
4. statistical judge paired 比較で成功率とコスト(tokens / turns /
                     wall-clock)のデルタを判定。有意性閾値を要求
                     (現行 N=10 再測定実務の規約化)。逐次検定による
                     early stopping でベンチコストを抑制
5. promoter          統計的裏付けのある勝者のみ昇格
```

### 10.3 権限境界(設計決定 §2 に対応)

- プロンプト/設定変更 → active pack へ**自動昇格**。
- ハーネスのコード変更 → 証拠ドシエ(根拠 run・予測効果・測定結果)
  付きの提案 patch/PR を生成し、**人間承認待ち**。

### 10.4 安全機構

- 昇格後も champion/challenger を併走させ、実運用メトリクスが退行したら
  自動ロールバック。
- 一度に変異させる artifact は 1 つ(効果の帰属を清潔に保つ)。
- 全昇格の監査ログ(どの run のどの証拠で昇格したか)。
- fixture の階層化: スクリーニング用の安価な smoke fixture →
  確証用フルスイート。held-out fixture を確保し過適合を監視。

## 11. Lisp ネイティブ実装方針

- **全レイヤー境界を CLOS protocol に**: `control-policy`・`oracle`・
  `projection`・`provider`・`memory-store` を generic function 群の
  protocol として定義。差し替えは defclass + defmethod で完結する。
- **governor 介入を condition/restart で表現**: budget 枯渇・停滞検出・
  オラクル間矛盾を condition として signal し、restart として
  `demote-dial` / `replan` / `park-mission` / `ask-human` / `abort` を
  確立する。restart の選択は mission 層(または人間ポート)が行う。
- **policy pack は sexp データ**: スキーマ検証して読み込む。runtime
  `eval` は不使用(データとしてのみ)。ライブイメージへ hot-reload 可能。
- **ハーネス自身がライブイメージ**: mission queue と world model は
  REPL から inspect 可能。運用者は SLIME で稼働中 mission の world model
  を観測できる —「ライブランタイムを第一級の観測対象にする」哲学を
  自分自身に適用する。

## 12. 継承する教訓の棚卸し

既存実装(~12,000 行)に埋まった教訓は、コードではなく**データと要件**
として新設計に移植する。

| 教訓 | 出所 | 新設計での置き場所 |
|---|---|---|
| clean verification 必須(REPL false success 対策) | PRD RISK-003 | verification oracle の定義(全 dial で必須) |
| test-change の 2 層防御(AST gate + strict LLM review) | DR-2026-05-27 | invariant oracle + review oracle profile(strictest) |
| 段階別 review strictness(plan=soft / tests=strict / test-change=strictest) | PRD §19 | oracle profile(policy pack 内のデータ) |
| NAME-CONFLICT 時の worker reset self-heal | backlog #2 | L1 環境の self-heal 規則 |
| qualified-symbol 指針(`:cl`/`:rove` 以外を qualify) | backlog #1 | 初期 policy pack のプロンプト内容 |
| review 棄却フィードバックの executor への配線 | backlog #3 | oracle 照会結果が world model 観測になる構造で解消 |
| run-wide と per-step の budget 区別 | PRD §19 | governor の budget envelope 設計 |
| `.lisp` 書き込みは構造化編集 tool に限定 | backlog #4 | L1 action space の制約 |
| test-file 絶対パスの明示 | backlog #5 | context compiler の view 内容 |
| 振動・停滞検出(failed-patches / stalled-verify) | PRD §19 budgets | progress oracle のシグネチャ |
| 会話履歴を正本にしない context 管理 | context-management.md | event sourcing + world model として一般化 |
| postmortem logging(failed_tests・content_summary・llm-request opt-in) | PRD §8.10.1 | event log スキーマ要件 |

## 13. 非目標

```text
- multi-agent スワーム / エージェント間交渉
- vector DB / embedding RAG
- GUI / web ダッシュボード(REPL とファイルを先行)
- CL 以外のターゲット言語
- worktree + subprocess を超える sandbox(引き続き trusted localhost)
- ハーネス自身のコード変更の自動昇格
- 非 SBCL 対応
- 既存実装からの移行パス(本 spec はグリーンフィールド構想)
```

## 14. リスクとトレードオフ

1. **既存教訓の喪失**(グリーンフィールド最大のリスク): §12 の棚卸し表で
   データ・要件として移植する。
2. **3 policy の維持コスト**: kernel とサービスを共有するため各 policy は
   薄い。scripted は小さな FSM、guided は主にアジェンダサービス+
   プロンプト。
3. **L5 のベンチ統計コスト**: paired design + 逐次検定 early stopping +
   fixture 階層化で抑制。
4. **dial 途中降格の正しさ**: scripted FSM が途中から引き継げるだけの
   情報が world model に常にあることが要求される。world model 設計への
   健全な圧力だが、実装上の難所。
5. **L5 の Goodhart 化**(fixture への過適合): held-out fixture と
   昇格後の実運用メトリクス監視(退行ロールバック)で抑える。
6. **event sourcing の複雑さ**: projection 再構築はメモリ内のみ、
   event schema は粗粒度+版付きに保つ。

## 15. 成功指標

```text
- 同一 fixture suite を 3 つの dial で実行し、モデル×dial の
  成功率・コスト行列が取得できる
- self-directed 実行が停滞時に guided へ降格し、同じ world model
  から作業を継続できる
- mission の suspend → プロセス再起動 → resume が event log のみ
  から成立する
- L5 が統計的裏付けつきでプロンプト変更を 1 件以上自動昇格し、
  監査ログから根拠 run を追跡できる
- L5 がハーネスコード変更の提案 patch を証拠ドシエつきで 1 件以上
  生成できる
- 退行時の自動ロールバックが動作する
```
