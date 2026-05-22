# review-feedback-routing 設計

**Date:** 2026-05-22
**Author:** Satoshi Imai
**Status:** Draft for implementation
**Related:** `docs/superpowers/specs/2026-05-22-scaffold-command-design.md`(先行ランドした scaffold)

## 1. 動機

`cl-harness develop` の implementation review (`%review-implementation` in `src/orchestrator.lisp:497`) は LLM が verify 緑になった実装をさらにレビューし、棄却すると step status を `:review-rejected` に上書きする。しかし、レビュアの **棄却フィードバック文字列は次の処理経路に渡らない**:

- `%failure-context` (orchestrator.lisp:882) は verify エラー + tool-error ring のみを集約し、レビュー文言を含まない。
- run-agent は同 step に再起動されず、外側 `develop` ループの `:max-replans 3` 経由で planner が呼ばれる。プラン全体が組み直されるため verify 緑だった実装は丸ごと捨てられる。

結果: 「変数名を NAME に統一して」のような **小さな修正で済む棄却理由でも plan 全体が再生成される**。コストが重く、リビュア指摘の文言情報が消える。

### 1.1 設計判断: なぜ run-agent inner-loop か

3 つの案を検討した:

| 案 | 棄却フィードバック先 | コスト | 既存パターンとの整合 |
|---|---|---|---|
| A: run-agent inner-loop(本 spec) | 同 step を run-fn 再起動し issue に feedback 注入 | 小(LLM 数ターン追加) | `%maybe-handle-test-change-request` と同形 |
| B: planner failure-context 強化 | `%failure-context` に review feedback 文字列を加え plan 再生成 | 大(plan 全体やり直し) | 既存 replan 経路を使うので最小実装 |
| C: 両方(inner-loop → 使い果たしたら planner) | A + B | 中 | 最も多層、コード複雑 |

選択 **A**:
- 既存 `%maybe-handle-test-change-request` が「レビュー → 同 artifact を直す」インナーループパターンを採用済み。整合的。
- verify が緑になった実装は基本的に正しく、レビューは微調整を求めるケースが多い。plan 再生成は過剰。
- 既存 `%enriched-issue` (orchestrator.lisp:307) の "Prior exploration" prepend パターンを再利用できる。

### 1.2 スコープ

本 spec は **implementation review の棄却フィードバックのみ** を扱う。次の 2 つは別 spec(§9 Out of scope):

- Test-change-request 棄却の executor へのフィードバック経路
- Plan/test review の per-step 粒度化

## 2. データフロー

```
%execute-step
  └─ run-agent (turn loop) → state
       ├─ status != :passed  → 外側へ(現状どおり)
       └─ status == :passed
            └─ %review-implementation (LLM review)
                 ├─ approved → :passed return(現状どおり)
                 └─ rejected with feedback
                      ├─ retry-budget remain → run-agent 再起動(enriched-issue に feedback prepend、loop continue)
                      └─ budget exhausted    → status :review-rejected で外側 develop ループへ
                                              (既存の :max-replans 3 fallthrough を維持)
```

inner-loop は **既存の test-change-request loop と同じレキシカル位置**(`%execute-step` 内 `(block run-step (loop ...))` 1 箇所、orchestrator.lisp:606-624)に追加する。test-change と implementation-review は同 step 内で両方発生し得るため `cond` で分岐し排他処理する。

## 3. シグネチャ変更(API 非破壊)

### 3.1 `%review-implementation` の戻り値拡張

現状:

```lisp
(defun %review-implementation (step state review-fn provider develop-state)
  "Return true when implementation review approves STATE."
  ...)
```

変更後 — 2 値返却にする(`%review-plan-and-tests` と対称):

```lisp
(defun %review-implementation (step state review-fn provider develop-state)
  "Return (VALUES APPROVED-P FEEDBACK)."
  (if (or (not (%review-enabled-p develop-state))
          (not (eq :passed (%read-status-from-state state))))
      (values t nil)
      (let ((decision (%call-review review-fn :implementation ...)))
        (values (review-decision-approved-p decision)
                (review-decision-feedback decision)))))
```

`review-decision-feedback` は既存スロット(`src/review.lisp:81`)。新規データ構造は不要。

### 3.2 `%enriched-issue` の多引数化

現状:

```lisp
(defun %enriched-issue (step memo)
  ...)
```

変更後:

```lisp
(defun %enriched-issue (step memo &key review-feedback)
  "Build the issue string. When MEMO is non-empty prepend a
`Prior exploration:' block. When REVIEW-FEEDBACK is non-empty
prepend a `Prior review feedback:' block. Both can be present;
review-feedback is shown first (most recent / most specific)."
  ...)
```

既存呼び出し(`%execute-step` 1 箇所)は `:memo memo` のみ。`:review-feedback` は default NIL なので破壊変更ではない。

組み合わせ時の出力テンプレート:

```
## Prior implementation review feedback (current step retry N of M)
<reviewer feedback text>

## Prior exploration (read-only)
<memo>

## Task
<original issue>
```

セクションは空のとき省略。

### 3.3 `%execute-step` への新 kwarg

```lisp
(defun %execute-step (step run-fn project-root system test-system
                      condition test-file logger
                      provider mcp-client run-limits explore-fn
                      &key develop-state
                           (review-fn #'review-development-artifact)
                           (max-test-revisions 3)
                           (max-impl-review-revisions 2))   ;; ← 追加
  ...)
```

`:max-impl-review-revisions 0` で完全無効化(従来挙動と等価、後方互換性の安全弁)。

### 3.4 `execute-plan` / `develop` への新 kwarg

両関数のシグネチャに `(max-impl-review-revisions 2)` を追加し、`%execute-step` まで貫通。

`src/cli.lisp:develop` も同 kwarg を受けて orchestrator-level に pass-through。

### 3.5 CLI フラグ

`src/cli-main.lisp:develop-options` に追加:

```lisp
(clingon:make-option :integer :long-name "max-impl-review-revisions"
                     :description "maximum implementation-review retry rounds before :review-rejected (default 2)"
                     :initial-value 2 :key :max-impl-review-revisions)
```

`develop-handler` で `(clingon:getopt cmd :max-impl-review-revisions)` を `(develop ...)` 呼び出しに pass-through。

## 4. inner-loop 具体形

`%execute-step` 内 `(block run-step (loop ...))` を以下に置き換える(現状 L606-624):

```lisp
(state
 (unwind-protect
      (block run-step
        (loop
          with impl-retry-count = 0
          with review-feedback = nil
          for issue = (%enriched-issue step memo
                                       :review-feedback review-feedback)
          for rc = (make-run-config :project-root project-root
                                    :system system
                                    :test-system test-system
                                    :issue issue
                                    :condition condition
                                    :limits (or run-limits
                                                (make-default-limits)))
          for state = (funcall run-fn rc provider mcp-client
                               policy step-logger
                               :develop-state develop-state)
          do (cond
               ;; 1) test-change-request — 既存パス
               ((and develop-state
                     (< (develop-state-test-revision-count develop-state)
                        max-test-revisions)
                     (%maybe-handle-test-change-request
                      step state test-file review-fn provider develop-state))
                (%log-develop-event logger :test-change-applied ...))

               ;; 2) verify :passed だが implementation review 棄却
               ((and (eq (%read-status-from-state state) :passed)
                     (< impl-retry-count max-impl-review-revisions))
                (multiple-value-bind (approved-p feedback)
                    (%review-implementation step state review-fn provider
                                            develop-state)
                  (cond
                    (approved-p
                     (return-from run-step state))
                    (t
                     (incf impl-retry-count)
                     (setf review-feedback feedback)
                     (%log-develop-event
                      logger :impl-review-retry
                      (alist-hash-table
                       `(("step_index" . ,(plan-step-index step))
                         ("retry_count" . ,impl-retry-count)
                         ("feedback" . ,(%truncate-text feedback 1500)))
                       :test 'equal))))))

               ;; 3) それ以外 — 外側へ
               (t (return-from run-step state)))))
   (close-run-logger step-logger)))
```

ポイント:
- 既存の `:review-rejected` への status 書き換え(L626-632)はそのまま残す。budget 切れで loop を抜けた直後にその分岐が走り、status を `:review-rejected` に上書きする。外側 `develop` ループの `:max-replans 3` フォールスルー経路は不変。
- `rc` は loop 毎に作り直す(issue 文字列が変わるため)。`make-run-config` は軽量なので問題なし。
- `pool-kill-worker` 等のワーカー初期化は **やらない**。既存 test-change ループと同じ「fresh run-fn 呼び出し」だけで、cl-mcp ワーカー側の REPL state はそのまま継続する。

## 5. JSONL ロギング

### 5.1 新規イベント

```
{"type": "impl-review-retry",
 "step_index": 3,
 "retry_count": 1,
 "feedback": "Variable naming inconsistent — use NAME not USER..."}
```

`feedback` は `%truncate-text feedback 1500` で 1500 char truncated(他のツール結果と同じ閾値)。

### 5.2 既存 `:step-end` payload 拡張

```
{"type": "step-end",
 ...
 "review_retries": 2,            ;; ← 新規(0..max-impl-review-revisions)
 "review_final_outcome": ...}    ;; ← 新規 :passed-after-retry / :exhausted / :passed-first-try / :n-a
```

`:review_final_outcome` 値:
- `"passed-first-try"` — レビューせず通過(または初回 approve)
- `"passed-after-retry"` — N 回 retry 後に approve
- `"exhausted"` — budget 切れて `:review-rejected`
- `"n-a"` — そもそも `%review-enabled-p` が false(レビュー無効)

## 6. develop-state は変更しない

`develop-state` 構造体に `:impl-review-revision-count` 等の slot は **追加しない**。

理由:
- per-step ローカル状態(`%execute-step` の loop-local 変数)で十分。
- develop-state は run 全体を跨ぐ累積データ用(test-revision-count もそうだが、こちらは「同 step 内で何回 test-change を受け付けたか」ではなく「develop 全体で test-change が何回起きたか」のグローバルカウンタ)。impl-review は per-step リトライなので、ライフタイムが違う。
- JSONL イベント(§5)で observability は確保される。レポート集計が必要なら transcript パースで対応可。

将来 develop 全体での累積メトリクスが必要になったら slot 追加を検討する(YAGNI)。

## 7. エラーハンドリング

- レビュー呼び出し中の `model-error`(LLM transport 失敗): 既存の `complete-chat` の retry policy(v0.5.2)に従う。それでも fail なら inner-loop の外側 `handler-case` が拾い、develop run 全体が `:status :error :reason <kind>` で終わる。inner-loop で特別な catch はしない。
- `review-fn` が独自 condition を raise した場合: 同上、外側 `handler-case` でハンドリング。
- run-fn 自身の失敗: 既存どおり、state.status を見て外側へ。
- `:max-impl-review-revisions 0`: review はする(L626-632 の status 上書きが残るので)が retry はしない。従来挙動と等価。

## 8. テスト戦略

`tests/orchestrator-test.lisp` に **6 deftest 追加**。すべて stub-driven、LLM プロバイダ不要。

1. **`impl-review-inner-loop-approves-on-second-attempt`**
   - stub `review-fn` を 1 回目 reject、2 回目 approve に切替
   - stub `run-fn` は常に verify :passed を返す
   - 期待: run-fn が同 step に 2 回呼ばれ、最終 status `:passed`、JSONL に `:impl-review-retry` 1 件

2. **`impl-review-inner-loop-exhausts-budget`**
   - review-fn 常に reject、`:max-impl-review-revisions 1`
   - 期待: run-fn が 2 回呼ばれ(初回 + 1 retry)、status `:review-rejected`、JSONL に `:impl-review-retry` 1 件

3. **`impl-review-enriched-issue-contains-feedback`**
   - run-fn が受け取った RC の issue 文字列を spy
   - 2 回目の呼び出しの issue が `"## Prior implementation review feedback"` を含む
   - 1 回目の issue は含まない

4. **`impl-review-disabled-when-budget-zero`**
   - `:max-impl-review-revisions 0`
   - review-fn 常に reject
   - 期待: run-fn 1 回のみ、status `:review-rejected`(レビューはした、retry しなかった)

5. **`impl-review-disabled-when-policy-none`**
   - `:review-policy :none`
   - 期待: review-fn 呼ばれず、status `:passed`、retry なし

6. **`impl-review-respects-test-change-priority`**
   - run-fn が `:test-change-request` で返した step → test-change ループに入り、その後 verify 緑、その後 review 棄却 → inner-loop へ
   - 期待: test-change の materialize と impl-review-retry の両方が JSONL に出る、最終的に終了

合計 +6 deftests、現 437 → 443 expected。

## 9. ドキュメント更新

- `docs/cl-harness-prd.md` の develop section に「review-rejected step は inner-loop でリトライされる(最大 `:max-impl-review-revisions` 回)」を 1 段落追記
- `README.md` の `cl-harness develop` 説明に `--max-impl-review-revisions` を追加
- リリースノート(v0.5.3 か v0.6.0 — landing 時判断)

## 10. Out of scope

- **Test-change-request 棄却フィードバックの executor へのルーティング** — 別 spec として後続。本 spec の inner-loop パターンが先例として再利用される予定。
- **Plan/test review の per-step 粒度化** — 現状の単一 feedback blob は許容範囲。リファクタの動機が薄い。
- **`:review-policy` の値分岐セマンティクス**(`:auto` vs `:llm-review` 等) — 別 spec。現状 non-:none は全て同じパス。
- **多段レビュア(コードと文書を別 LLM が見る等)** — YAGNI。
- **per-step メトリクス集計の develop-state slot 化** — YAGNI(§6)。

## 11. リスクと緩和策

| リスク | 緩和策 |
|---|---|
| inner-loop が無限ループ化 | budget(`:max-impl-review-revisions`、default 2)で必ず終端する。`incf` を `cond` 内に置く配置で「分岐を取り損ねる」ことが構造的に起きない |
| レビュー feedback が空文字列で issue を膨らませる | `%enriched-issue` が空文字列のとき section をスキップする条件分岐をテストでカバー(deftest 3) |
| LLM が feedback を「攻撃的に解釈」してテスト書き換え等の挙動を取る | run-agent の既存 policy(`generic-mcp` / `runtime-native`)は変更しない。tool 許可リストはそのまま。reviewer feedback はあくまで issue 文字列の一部 |
| retry のコスト爆発 | budget が default 2 のため最大 3 turns(初回 + 2 retry)。`:max-impl-review-revisions 0` で opt-out 可。CI ベンチで cost をモニター |
| 既存テストの回帰 | `:max-impl-review-revisions 2` が default になるが、`:review-policy :none` 時は inner-loop が発動しないので fix-bench / 既存 develop-bench は影響を受けない |

## 12. 実装順序(writing-plans で詳細化)

おおよその区切り:

1. `%review-implementation` の戻り値を `(values approved-p feedback)` に拡張(既存呼び出し元 1 箇所も対応)
2. `%enriched-issue` に `:review-feedback` キーワード追加
3. `%execute-step` の loop body 書き換え + 新 kwarg
4. `execute-plan` / `develop` / `cli.lisp:develop` の kwarg 配管
5. JSONL イベント追加(`:impl-review-retry` + `:step-end` の review_retries / review_final_outcome)
6. 6 deftests を `tests/orchestrator-test.lisp` に追加
7. CLI フラグ `--max-impl-review-revisions` 追加
8. README + PRD 追記
9. mallet clean + compile-system warning ゼロ確認 + 全テスト緑(437 → 443)

各タスクは TDD で進める(失敗テスト → 実装 → 緑 → commit)。
