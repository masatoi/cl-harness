# bench-cycle スキル — develop-bench → log 解析 → 3-axis 改善提案

**Date:** 2026-05-23
**Author:** Satoshi Imai
**Status:** Draft for implementation
**Related:**
- `docs/improvement-backlog.md` — 本 skill が継続的に append する出力先
- `docs/benchmarks/results-2026-05-23-*-verification.md` — 本 skill の出力 doc が踏襲する shape の見本
- `.claude/skills/comprehensive-test/SKILL.md` — 既存 project-local skill の参考形式

## 1. 動機

bench4–7 で示された次のフロー:

```
bench 走行 → JSONL log 精査(G1/G2/G3)→ 失敗の根因特定 →
3 軸(bench target / log content / 実装)で改善候補抽出 → docs 記録
```

このサイクルを「ベンチを 1 回回したら見たもの全部 docs に残す」レベルで反復したい。
手動で 4 回まわした結果(bench4→7)、毎回 ~30-60 分の作業のうち大部分は
「JSONL を読んで narrative を組み立て、3 軸テンプレートに当てはめる」という
**機械的かつ高 fidelity な反復** だった。skill 化に適している。

スキルを使うことで:
- bench cycle 1 回 = 1 コマンド(`/bench-cycle 102-counter-class 104-cache-simple`)
- 出力は `docs/benchmarks/results-<DATE>-*.md` と `docs/improvement-backlog.md` への追記
- 次のセッションが docs を読むだけで現状を継承できる

### 1.1 設計判断: 自己完結型 1 スキル

検討した代替:

- **Phase 分離スキル群**(`/bench-run` / `/bench-analyze` / `/bench-propose`)—
  柔軟だが manual 操作が増え、フロー全体を毎回再構築するコストがかかる
- **Hybrid: main skill + per-phase subagent** — context 汚染防止に良いが、
  subagent dispatch コストと axis 相関見落としリスク

採用: **自己完結型 1 スキル**(main agent が全 phase を直列実行)。
セッション内で実フローと最も近く、context 圧迫は通常運用(1-2 fixture)では
発生しない(bench7 で 102+104 合計 ~200KB、Opus 1M 窓に対して余裕)。

context 圧迫が将来問題になったら、Phase 3(JSONL extract)を subagent に
委任する形で retrofit 可能。

## 2. 配置

`.claude/skills/bench-cycle/` 配下、プロジェクトローカル:

```
.claude/skills/bench-cycle/
├── SKILL.md                          # メインの skill instruction
├── templates/
│   ├── driver.lisp.template          # bench 走行用 sbcl driver
│   ├── results.md.template           # results doc の skeleton
│   └── backlog-item.md.template      # backlog 追記 1 候補の shape
```

既存 `.claude/skills/comprehensive-test/` / `.claude/skills/dogfooding-cl-mcp/`
と同じパターン。

## 3. SKILL.md frontmatter

```yaml
---
description: Run cl-harness develop-bench on one or more fixtures with full G1/G2/G3 logging, then analyze the JSONL transcripts and produce 3-axis improvement proposals (bench target, log content, cl-harness implementation). Append findings to docs/improvement-backlog.md and write a new docs/benchmarks/results-<DATE>-*.md. Use when iterating on cl-harness reliability via the bench → log → propose cycle.
allowed-tools: Bash, Read, Write, Edit, AskUserQuestion, mcp__cl-mcp__fs-set-project-root, mcp__cl-mcp__repl-eval, mcp__cl-mcp__fs-read-file, mcp__cl-mcp__fs-list-directory
---
```

## 4. Phase 構造

### 4.1 Phase 1: bench plan

1. `$ARGUMENTS` を空白で split → fixture-id リスト
2. 各 ID について `develop-benchmarks/<id>/develop-task.json` の存在確認
   (`fs-list-directory` または `fs-read-file`)。1 件でも不在ならエラー、
   利用可能 ID 一覧を表示して終了
3. `repl-eval` 経由で `(uiop:getenv "CL_HARNESS_LLM_BASE_URL")` 等を確認。
   いずれか欠けたらエラー、export を促して終了
4. driver script を `/tmp/bench-cycle-<EPOCH>.lisp` に書き出し(§5 template)
5. JSONL log-path stem を `/tmp/bench-cycle-<EPOCH>` で予約
6. user に開始サマリを返す:
   ```
   bench-cycle starting:
     fixtures: 102-counter-class, 104-cache-simple
     driver:   /tmp/bench-cycle-1758000000.lisp
     log stem: /tmp/bench-cycle-1758000000
     timeout:  per-fixture 30min, total 60min
   ```

### 4.2 Phase 2: bench run

1. `ros run --` で driver を起動(`Bash` の `run_in_background=true`)
2. background-task completion notification を**待つ**(poll しない)
3. notification 受信後、`/tmp/bench-cycle-<EPOCH>.log` から fixture ごとの
   `FINAL <id>: ...` 行を grep
4. 各 fixture の summary `.lisp` ファイル(driver が落とす)を Read
5. status / replans / steps / impl-reviews / impl-rejections / elapsed を抽出

### 4.3 Phase 3: JSONL extract

各 fixture について:

1. develop-level JSONL を Read。 `develop-end` payload (status / completed_steps / total_steps / limit_hit) を抽出
2. develop-level の `transcript_path` フィールドを列挙、per-step JSONL を全て Read
3. per-step JSONL から下記イベントを抽出して整理:
   - **`verify` events**: `failed_tests` 配列の各エントリ(test_name / reason / source / form)
   - **`patch` events**: turn / file / diff(全文。後段で truncated もありうるが原則保持)
   - **`tool-error` events**: turn / tool / message(先頭 300 char で truncate)
   - **`limit-exhausted` event**: limit kind
   - **`run-end` event**: 7 counters + token_total + elapsed
4. turn 順の "narrative" を構築:

   ```
   step N "<test_name>":
     turn 0: initial verify failed — <reason>
     turn 3: tool-call <tool> → error: <message>
     turn 5: patch applied — <file>, diff summary
     turn 7: verify after patch — <pass/fail counts, new reason>
     ...
     run-end: <limit_hit>, patches=X/attempts=Y, elapsed=Z
   ```

JSONL 自体は main agent context に取り込まず、Read 1 回で必要な field だけ
抽出(Read 後に discard を意識)。1 fixture あたり ~100KB が標準。

### 4.4 Phase 4: 3-axis improvement proposal

Phase 3 の narrative を入力に、main agent が各 fixture について以下を生成:

#### 4.4.1 fixture ごとに

```markdown
## <fixture-id> findings

### 真の根因(verify failure G1 から)

- <test_name>: <reason>
- (複数あれば列挙)

### 改善候補

#### A. bench target 軸
- 案 1: <変更 / 追加 fixture / 設定変更>
- 案 2: ...

#### B. log content 軸
- 案 1: <追加すべき event / field / オプション化提案>
- 案 2: ...

#### C. cl-harness 実装軸
- 案 1: <planner prompt / orchestrator / agent / cli のどこに何を>
- 案 2: ...
```

各案は **観察 → 仮説 → 変更案 → 期待効果 → コスト見積もり** の 5 点で記述
(`docs/improvement-backlog.md` の既存候補と shape を揃える)。

#### 4.4.2 全 fixture 集約 cross-cutting findings

複数 fixture で **同じ failure mode** が出ていれば cross-cutting 候補として
別 section に集約(bench4-7 で確認された "NAME-CONFLICT がループ" 等の
パターン)。

### 4.5 Phase 5: アーティファクト書き出し

1. **results doc** 新規作成:
   - path: `docs/benchmarks/results-<DATE>-bench-cycle-<TOPIC>.md`
   - `<DATE>` = today (`YYYY-MM-DD`)
   - `<TOPIC>` = fixture-id を `-` で join、長すぎる場合は最初の id +
     `-and-N-others`
   - content: §5 template

2. **backlog append**:
   - target file: `docs/improvement-backlog.md`
   - 末尾に `## <DATE> bench-cycle 由来` セクションを追加
   - Phase 4 で出した候補のうち、**既存 backlog に重複しないもの** だけ
     を追記。重複判定の具体ルール:
     - skill が `docs/improvement-backlog.md` を Read
     - 既存 `### N. <title>` の `<title>` 部分を抽出
     - 新候補のタイトルが既存タイトルと完全一致(文字列 `equal`)or
       両方を lowercase + 空白 trim した上で先頭 20 char が一致する場合
       「重複」とみなす
     - 重複時は新規追加せず、results doc 側に「既存 backlog #N 参照」と注記

3. **commit せず**:
   - skill 内では Write のみ
   - 最後の user 向け report に `git add docs/benchmarks/... docs/improvement-backlog.md && git commit -m "..."` の推奨コマンドを含める

4. **user report**:
   ```
   bench-cycle complete:
     - results doc: docs/benchmarks/results-2026-05-23-bench-cycle-102-104.md (X lines)
     - backlog: +N proposals
     - fixtures: 102 :STUCK, 104 :PASSED
   Suggested next: git add ... && git commit
   ```

## 5. Templates

### 5.1 `driver.lisp.template`

```lisp
;;;; Auto-generated by bench-cycle skill at <TIMESTAMP>
;;;; Fixtures: <FIXTURES>

(require :asdf)

(defun ts ()
  (multiple-value-bind (sec min hr day mon yr) (get-decoded-time)
    (format nil "~4,'0D-~2,'0D-~2,'0DT~2,'0D:~2,'0D:~2,'0D"
            yr mon day hr min sec)))

(format t "~&[~A] loading cl-harness ...~%" (ts))
(asdf:load-system :cl-harness)
(format t "~&[~A] loaded.~%" (ts))

(defparameter *stem* "<LOG_PATH_STEM>")

(defun run-fixture (task-id)
  (let* ((task-path (merge-pathnames
                     (format nil "~A/" task-id)
                     #P"<DEVELOP_BENCHMARKS_DIR>/"))
         (task (cl-harness/src/develop-bench:load-develop-task task-path))
         (sandbox (cl-harness/src/develop-bench:prepare-develop-task-sandbox task))
         (test-file (merge-pathnames "tests/main-test.lisp" sandbox))
         (log-path (format nil "~A-~A.jsonl" *stem* task-id))
         (summary-path (format nil "~A-~A-summary.lisp" *stem* task-id))
         (start (get-internal-real-time)))
    (format t "~&[~A] === ~A START ===~%" (ts) task-id)
    (finish-output)
    (handler-case
        (let* ((result (cl-harness:develop
                        :goal (cl-harness/src/develop-bench:develop-task-goal task)
                        :project-root (namestring sandbox)
                        :system (cl-harness/src/develop-bench:develop-task-system task)
                        :test-system (cl-harness/src/develop-bench:develop-task-test-system task)
                        :test-file (namestring test-file)
                        :review-policy :auto
                        :max-impl-review-revisions 2
                        :log-llm-requests <LOG_LLM_REQUESTS>
                        :max-replans <MAX_REPLANS>
                        :log-path log-path))
               (elapsed (float (/ (- (get-internal-real-time) start)
                                  internal-time-units-per-second)))
               (state (cl-harness:develop-result-develop-state result))
               (decisions (cl-harness/src/state:develop-state-review-decisions state))
               (summary
                 (list :task task-id
                       :status (cl-harness:develop-result-status result)
                       :replans (cl-harness:develop-result-replan-count result)
                       :steps (length (cl-harness:develop-result-step-results result))
                       :impl-reviews
                       (count-if (lambda (d)
                                   (eq :implementation
                                       (cl-harness:review-decision-kind d)))
                                 decisions)
                       :impl-rejections
                       (count-if (lambda (d)
                                   (and (eq :implementation
                                            (cl-harness:review-decision-kind d))
                                        (eq :rejected
                                            (cl-harness:review-decision-status d))))
                                 decisions)
                       :elapsed-sec elapsed
                       :sandbox (namestring sandbox)
                       :log-path log-path)))
          (with-open-file (out summary-path :direction :output
                               :if-exists :supersede :if-does-not-exist :create)
            (format out "~S~%" summary))
          (format t "~&[~A] ~A DONE: ~S~%" (ts) task-id summary)
          (finish-output)
          summary)
      (error (c)
        (format t "~&[~A] ~A ERROR: ~A~%" (ts) task-id c)
        (finish-output)
        (list :task task-id :error (princ-to-string c)
              :elapsed (float (/ (- (get-internal-real-time) start)
                                 internal-time-units-per-second)))))))

(format t "~&[~A] driver entry~%" (ts))
(finish-output)
(let ((results (list <FIXTURE_CALLS>)))
  (format t "~&========================================~%")
  (dolist (r results) (format t "FINAL ~A: ~S~%" (getf r :task) r))
  (format t "========================================~%")
  (finish-output))
(format t "~&[~A] driver exit~%" (ts))
(finish-output)
```

`<FIXTURE_CALLS>` には `(run-fixture "<id1>") (run-fixture "<id2>") ...` を展開。

### 5.2 `results.md.template`

```markdown
# bench-cycle: <FIXTURES_LIST>

**Date**: <DATE>
**Code**: cl-harness <branch> (<sha>)
**Settings**: review-policy=auto, max-impl-review-revisions=2, log-llm-requests=<X>, max-replans=<N>
**Driver**: <DRIVER_PATH>

## 結果サマリ

| Task | Status | Steps | impl-reviews | Elapsed |
|---|---|---:|---:|---:|
| <fixture-1> | <status> | <steps> | <reviews> | <s> |
| ... |

## <fixture-1> 詳細

### 真の根因(G1 failed_tests)

- <test_name>: <reason> (<source.file>:<line>)
- ...

### Patch trail

| turn | tool | summary |
|---|---|---|
| ... |

### Tool errors

- turn <N>: <tool> — <message>
- ...

### Run-end counters

```
status=<...>, limit_hit=<...>, turns=<N>, patches=<X>/<Y>, tokens=<T>, elapsed=<S>
```

### 改善候補

#### A. bench target 軸
- ...

#### B. log content 軸
- ...

#### C. cl-harness 実装軸
- ...

(<fixture-2> 以降同様)

## Cross-cutting findings

(複数 fixture に共通する failure mode + 横断改善案)

## 推奨次アクション

1. <優先度の高い候補>
2. ...
```

### 5.3 `backlog-item.md.template`

```markdown
### <番号>. <短いタイトル>

**Source**: bench-cycle <DATE>, fixture(s) <FIXTURES>
**Axis**: bench target | log content | implementation

**観察**: <JSONL からの直接引用 1-2 行>

**仮説**: <なぜ起きたか>

**変更案**:
- <具体的な変更 path / shape>

**期待効果**: <unblock するか / 何が変わるか>

**コスト**: <small / medium / large + 工数感>
```

## 6. 設定パラメータ

引数解析(Phase 1):

| 引数 | 意味 | default |
|---|---|---|
| 位置引数(fixture-id) | bench 対象 1 以上 | required |
| `--max-replans N` | develop 引数の `:max-replans` | 3 |
| `--no-log-llm-requests` | G3 をオフにする | G3 on(default) |

slash command args は `$ARGUMENTS` で 1 つの文字列として渡される
(例: `"102-counter-class 104-cache-simple --max-replans 1"`)。
skill の Phase 1 内で whitespace split し、`--` プレフィックスのトークンを
flag として、それ以外を fixture-id として扱う。`--max-replans` は次の
トークンを N として消費。`--no-log-llm-requests` は引数を取らない flag。

## 7. エラーハンドリング

| 状況 | 対応 |
|---|---|
| 引数なし | usage + 利用可能 fixture-id 一覧を表示、exit |
| fixture-id 不在 | 該当 ID と利用可能 ID を表示、exit |
| 環境変数欠落 | `CL_HARNESS_LLM_*` を export するよう促す、exit |
| bench timeout(>1 hour) | 中途データで Phase 3 以降を試行。`status=:timeout` で記録 |
| 個別 fixture の cl-harness:develop が ERROR | summary に error 記録、他 fixture は継続 |
| JSONL の壊れた行 | skip、Phase 4 で「データ不足のため軸 X は推定」明示 |
| `docs/improvement-backlog.md` 不在 | warn 出力、results doc のみ生成、backlog append 省略 |

## 8. Out of scope

- **fix-bench**(本 skill は develop-bench focus、`/fix-cycle` 等は別 skill にできる)
- **multi-trial / variance bound**(N=1、統計的処理は別作業)
- **cross-model 比較**(`CL_HARNESS_LLM_MODEL` 切替の A/B は別 skill)
- **auto-commit**(skill 内では write のみ)
- **JSONL 古い形式の互換層**(G1/G2/G3 が無い transcript への遡及対応不要)
- **bench fixture の自動追加**(新 fixture 提案は results doc に書くが、ファイル生成までは skill しない)

## 9. テスト戦略

skill 自体に対する自動テストは設けない(skill execution はトップレベル LLM
の挙動なので、deterministic な assert を書きにくい)。

代わりに **dogfooding ベース**:

- 初回 landing 後すぐ `/bench-cycle 102-counter-class` を 1 回実行し、
  output が `results-2026-05-23-bench-cycle-102-counter-class.md` として
  生成されることを目視確認
- bench 自体は bench7 と同等の挙動になることを期待(102 で `:LIMIT-EXHAUSTED`、
  MOP 系の 3 軸提案が出ること)

## 10. 既存 skill との関係

| 既存 skill | 関係 |
|---|---|
| `comprehensive-test` | パターンを踏襲(SKILL.md + templates フォルダ構造、Bash + cl-mcp tool 群)|
| `dogfooding-cl-mcp` | 関係なし(別目的)|
| `superpowers:brainstorming` | 本 skill 本体ではなく、本 skill が出した「改善候補」をその後の brainstorming → spec → plan サイクルに渡す source として連携 |
| `superpowers:subagent-driven-development` | 同上、出した候補の実装フェーズで使う |

bench-cycle 自体は brainstorming → spec → plan を **起動しない**。あくまで
「素材を docs に置く」までで止まる。次の改善実装は user 判断で別途
brainstorming スキルを起動するパスを取る。

## 11. リスク

| リスク | 緩和策 |
|---|---|
| LLM endpoint が長時間 timeout でフリーズ | per-fixture 30 分、合計 1 時間で skill が abort し、部分データで Phase 3 へ |
| 大量 fixture 指定で context overflow | 通常運用 1-2 fixture を前提。3 つ以上指定時に user 確認(`AskUserQuestion`)を入れる |
| backlog 重複追加 | Phase 5 で simple substring match による既存重複検査。完全 dedup ではなく "近い候補があれば既存番号を参照" の指示を出力に含める |
| skill が独自に planner/orchestrator に介入 | しない設計。skill は **read-only と write-only**(JSONL read、docs write)、cl-harness 本体の状態には触らない |
| bench 実行中の cl-mcp pool 競合 | bench は独自 cl-mcp subprocess を spawn(driver の `cl-harness:develop` default 挙動)。skill 起動時の cl-mcp worker pool は触られない |

## 12. 実装順序(writing-plans で詳細化)

おおよその区切り:

1. `.claude/skills/bench-cycle/` ディレクトリ作成
2. `templates/driver.lisp.template` を作成(bench7 driver の generalize)
3. `templates/results.md.template` を作成(verification doc の generalize)
4. `templates/backlog-item.md.template` を作成
5. `SKILL.md` を作成(Phase 1-5 を step-by-step で記述、引数解析含む)
6. 既存 `comprehensive-test/SKILL.md` の format と整合確認
7. dogfooding: `/bench-cycle 102-counter-class` 1 回実行して output 確認

`.claude/skills/` への追加なので、コードは Lisp ではなく markdown (+ Lisp template)。テストコード追加なし。
