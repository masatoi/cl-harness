# Postmortem-logging を有効にした失敗セッション分析 — 改善点抽出

**Date**: 2026-05-23
**Model**: `Qwen/Qwen3.6-35B-A3B` (SGLang @ 192.168.0.17:8000)
**Code**: cl-harness post-merge of `postmortem-logging` (`1b744b3`)
**Settings**: `:review-policy :auto`, `:max-impl-review-revisions 2`,
**`:log-llm-requests t`**(G3 有効), `:max-replans 1`. Single trial.
**Fixtures**: 102-counter-class, 104-cache-simple(bench4 で `:STUCK` だった 2 件)
**Driver**: `/tmp/rfr-bench5.lisp`

## 目的

`postmortem-logging` ブランチで G1(`failed_tests`)+ G2(`content_summary`)
+ G3(`:llm-request`)が available になった。失敗セッションの真の根因を
JSONL transcript から再構成し、improvement 候補を出す。

## 結果

| Task | Status | Steps | impl-reviews | Elapsed | 詰まった理由(G1 から) |
|---|---|---:|---:|---:|---|
| 102-counter-class | `:STUCK` | 1 | 0 | 493 s | `COUNTER/TESTS/MAIN-TEST::MAKE-COUNTER` undefined |
| 104-cache-simple  | `:LIMIT-EXHAUSTED` | 2 | 0 | 792 s | step-0: `CACHE/TESTS/MAIN-TEST::MAKE-CACHE` undefined。step-1: 修正の試みで **NAME-CONFLICT** |

JSONL ファイルサイズ:
- develop-level: 1.5–2.7 KB(変わらず)
- per-step run-agent: **62–87 KB**(G3 込み、`compact-history` 効いて `100x 爆発` は起きず)

G3 はリーズナブルなサイズで full LLM context を残せた。

## 共通根因: test defpackage と src defpackage の **未連結**

両 fixture とも `develop-benchmarks/<task>/fixture/tests/main-test.lisp` は
スカフォールドとして以下を含んでいる:

```lisp
(defpackage #:<system>/tests/main-test
  (:use #:cl #:rove))
```

planner が著者する deftest はその中で `(make-counter)` / `(make-cache)` のように
**unqualified** にシンボルを参照する。test ファイルを READ するとき、
`MAKE-COUNTER` / `MAKE-CACHE` は test package に **内部 intern** される。
verify 時に呼ばれる `<TEST-PKG>::MAKE-COUNTER` は src 側で定義された
`<SYSTEM>:MAKE-COUNTER` と **別シンボル** なので「undefined」エラーになる。

agent は **src 側に関数を定義する**で頭が一杯になり、test ファイルの
defpackage を直す発想に到達するのが遅い(102 では到達せず budget 切れ、
104 では replan 後の step-1 でようやく到達するが image-staleness で詰む)。

## 104-cache-simple の詳細 narrative(G1+G2+G3 から再構成)

**step-0**(test_name=`TEST-MAKE-CACHE`):
- turn 0: verify → `MAKE-CACHE undefined`
- turn 1-7: read tests/main.lisp(エラー: ファイルは `tests/main-test.lisp` で名前違い)、exploration 等
- turn 8: `fs-write-file` で .lisp 上書き試行(エラー: lisp-edit-form を使え)
- turn 9: `lisp-edit-form` で src/main.lisp に `(defclass simple-cache () ())` 追加
- turn 10: `lisp-edit-form` で src/main.lisp に `(defun make-cache () ...)` 追加
- patch-attempts=3 → `:limit-exhausted` :max-patches

**step-1**(test_name=`verify-required-exports`、replan 後の新 test):
- turn 0: verify → 依然 `MAKE-CACHE undefined`(src の変更は前 step 由来で残ってる、しかし test の defpackage は元のまま)
- turn 5: ついに **test defpackage に `:use #:cache` を追加するパッチ**!
- turn 5 verify → **NAME-CONFLICT**: 前 step で test ファイルの READ が `CACHE/TESTS/MAIN-TEST::SIMPLE-CACHE` を内部 intern していたため、`:use #:cache` が `CACHE/SRC/MAIN:SIMPLE-CACHE` を持ち込むと衝突
- turn 6: 軌道修正で `:import-from #:cache #:make-cache #:simple-cache` に変更
- turn 6 verify → **同じ NAME-CONFLICT**(同じ理由)
- patch-attempts=3 → `:limit-exhausted` :max-patches

**重要**: error message に書いてある hint —
`"Hint: the worker process may have a broken package state. Use pool-kill-worker to get a fresh worker, then retry run-tests."` — を agent は **無視している**。これは `pool-kill-worker` を発動できる権限の問題か、prompt の指示不足。

## Improvement 候補(優先順)

### #1: planner が test_source を **package-qualified** で書くようガイドする

最も systemic な改善。test の defpackage を変えずに済む。

**変更案**:
- `planner.lisp` の system prompt の test_source テンプレートで
  「symbols を package-qualified で書く(例: `(counter:make-counter)`)」を
  明示する。
- 例:
  ```lisp
  (deftest test-make-counter
    (testing "default initial value"
      (ok (eql 0 (counter:counter-value (counter:make-counter))))))
  ```

**効果見積もり**: 両 fixture とも初回 verify で `<test-pkg>::SYM undefined` が
出る現象がなくなる。max-patches 内で済む可能性が大きく上がる。

**コスト**: planner プロンプトの 1–2 段落追加 + 既存の develop-bench fixture の
goal 文には影響なし。

### #2: scaffold(または planner)が test defpackage に `:import-from #:<system>` のスタブを置く

代替案。test_source は unqualified のままで OK になるが、defpackage に
適切な import-from が必要。

**変更案**: 
- 既存 scaffold(2026-05-22 merge `0d2d7e1` 系)は `:export ()` だけのスタブ。
  planner が test_source を materialize する**直前**に、`src/main.lisp` の
  defpackage を読んで(または planner が出した `symbols_to_export` の
  オプションフィールドから)test defpackage の `:import-from` を更新する hook。
- 副次効果: src/main.lisp の `:export` も planner 出力で更新できる
  (現状 planner が src を直接編集しないので、export 漏れは agent が拾うが、
  src/test の symbol 同期が一元化できる)。

**効果見積もり**: #1 と同程度。実装は #1 より重い(test ファイルへの patch hook)。

### #3: NAME-CONFLICT を含む system-load エラーに対する **worker reset hook**

104-step-1 で agent が正しい解(`:import-from`)を出したのに image staleness で
fail したケースの救済。

**変更案**:
- `verify-task` の `:system-load` 失敗時に reason の中身を見て、
  `NAME-CONFLICT` または `broken package state` 系のキーワードを検出したら
  自動で `pool-kill-worker reset=t` → 再 verify をする。1 回までの "self-heal" 動作。
- もしくは agent の system prompt に「NAME-CONFLICT を見たら `pool-kill-worker` を
  叩いてから patch を再試行」と明示。

**効果見積もり**: 104 のような「修正は正しいが image dirty」失敗を 1 ステップで
救える。発生頻度が高ければ大きな改善。

### #4: agent が `fs-write-file → lisp-edit-form` のような **error → tool 切替** をもっと早く学習する

102 で turn 8 に `fs-write-file: Cannot overwrite existing .lisp/.asd...` が
出て、turn 9 で `lisp-edit-form` に切り替えた。1 turn 無駄になっただけ。

**変更案**: system prompt の tool 説明セクションで
「.lisp/.asd の編集は最初から lisp-edit-form / lisp-patch-form を使う」を強調。
fs-write-file は **新規ファイル作成のみ** 用途と明記。

**効果見積もり**: 1-2 turn 節約。max-patches 制約下では地味に効く。

### #5: agent が `tests/main.lisp` のような **存在しないパスを試す** 現象

102 と 104 両方で turn 4 付近に `tests/main.lisp` を読みに行く tool-error が
発生(正しいパスは `tests/main-test.lisp`)。これも 1 turn 浪費。

**変更案**: develop の初期 user prompt(または system prompt)に
`--test-file` の解決済みパスを明示する。agent は project-inventory から
推測してるが、**test-file は明示的に与えられているのに prompt から
落ちている**可能性。確認が必要。

**効果見積もり**: 1-2 turn 節約。

## 改善 #1 の実装提案(別 PR)

最も少ない変更で最大効果が見込めるのは **#1(planner プロンプト変更)**。
1-day 規模:

- `src/planner.lisp` の `+default-planner-system-prompt+` に test_source の
  推奨 shape として「always use package-qualified symbols」を追加
- planner-test.lisp の plan 生成テストで qualified symbol を含む shape を assert
- develop-bench の 5-6 fixture(102, 103, 104, 105, 106)で再評価

これだけで、bench4 で `:STUCK` だった 4/5 cells のうち **102 と 104 は
unblock される可能性が高い**。

## ロギング自体の評価

| Gap | この bench で活躍したか? |
|---|---|
| **G1**(`failed_tests`) | ✅ 圧倒的。`<TEST-PKG>::SYM undefined` の正確な package prefix が再構成の出発点になった。これ無しでは「カウンタ 0 = 失敗 1」までしか分からない |
| **G2**(`content_summary`) | ✅ 一部活躍。agent がどのファイルを読んだか追えた。今回は agent の探索パターンが単純(read → patch)なので限定的だが、複雑な探索 step では効くはず |
| **G3**(`:llm-request`) | ✅ patch を組み立てる prompt 文脈の確認で活躍。compact-history が効いて size も常識的(per-step ~80KB)。secret 漏洩無し(local endpoint なので API key も "foo" のみ) |

**3 ギャップすべて実用的に有用**だった。特に G1 は「最重要発見の出発点」として
機能した。

## まとめ

postmortem-logging 機能のおかげで、bench4 で `:STUCK` としか分からなかった
2 fixture から **2 つの具体的かつ systemic な改善候補**(planner の test_source
shape、worker reset hook)を抽出できた。これは「ロギングを強化する」投資の
直接的な ROI。次の最小改善は **planner プロンプトに qualified symbol 推奨を
追加する**(#1)で、これだけで bench4 の `:STUCK` cells の一部が再現せず
通る可能性が高い。
