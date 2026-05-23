# max-patches-budget (default 3→5) 適用後の検証ベンチ

**Date**: 2026-05-23
**Model**: `Qwen/Qwen3.6-35B-A3B` (SGLang @ 192.168.0.17:8000)
**Code**: cl-harness post-merge of `max-patches-budget` (`f7f3ddd`)
**Settings**: `:review-policy :auto`, `:max-impl-review-revisions 2`,
`:log-llm-requests t`, **`:max-replans 3`** (default に戻した),
default `:max-patches 5` (本 PR で 3→5)。Single trial.
**Fixtures**: 102-counter-class, 104-cache-simple
**Driver**: `/tmp/rfr-bench7.lisp`

## 結果サマリ

| Task | Status | Steps | Replans | impl-reviews | Elapsed |
|---|---|---:|---:|---:|---:|
| 102-counter-class | `:LIMIT-EXHAUSTED` | 1 / 3 | 1 | 0 | 883 s |
| **104-cache-simple** | **`:PASSED`** ✅ | 3 / 3 | 0 | 3 (all approved) | 552 s |

## bench 経時比較(同 fixture 越し)

| Fixture | bench5 | bench6 | **bench7** | 何が変わったか |
|---|---|---|---|---|
| 102 — passed steps | 0 | 4 | **1** | bench6: 4 steps クリア → bench7: 1 step 後 :LIMIT-EXHAUSTED |
| 104 — passed steps | 0 | 0 | **3 = ALL** | **完全突破** ✅ |
| 104 — status | :STUCK | :STUCK | **:PASSED** | bench history で初の "pass" |

## 104-cache-simple — `:PASSED` 達成

**改善 #1(planner-qualified-symbols)+ #6(max-patches default 5)の合わせ技で完全突破**:

- 3 step plan(`test-make-cache-and-class` / `test-cache-put-get` / `test-equal-keys`)
- 全 step が `passed-first-try`(impl-review-retry 不要)
- 0 replans、no `:STUCK` 経由なし
- elapsed 552s(bench5 = 792s で :STUCK、bench6 = 707s で :STUCK)

bench history を辿ると:
- **bench4**(2026-05-23 朝、何の改善も無し): :STUCK
- **bench5**(postmortem-logging G3 で診断): :STUCK 詰まる原因が判明
- **bench6**(planner-qualified-symbols 後): :STUCK だが原因が「test 内部 intern」から「src 未実装 + tool error」にシフト
- **bench7**(max-patches 5 後): **`:PASSED`** ✅

ロギング → 診断 → 個別改善 → 個別検証 → 別問題発見 → 個別改善 ... の累積で 1 fixture が完全通過に到達。

## 102-counter-class — 退行は新 failure mode による

bench6 では 4 steps `:passed` まで届いたが、bench7 では 1 step で `:LIMIT-EXHAUSTED`。
退行の真因は **planner がより精緻なテストを書くようになり、新たな未解決問題に
ぶつかった** こと。

### bench7 で planner が書いた test_source(抜粋)

```lisp
(deftest test-counter-class-slot-structure
  (testing "class has count slot"
    (ok (find 'counter/src/main::count
              (mapcar #'sb-mop:slot-definition-name
                      (class-slots (find-class 'counter:counter)))))))
```

ここで:
- `counter:counter` は qualified ✅(#1 のおかげ)
- `class-slots`(SB-MOP)は **unqualified**
- `find-class`(CL builtin)は **unqualified**
- `sb-mop:slot-definition-name` は qualified だが、`class-slots` も同様に `sb-mop:` であるべき

test ファイルの defpackage は `(:use #:cl #:rove)` のみ。`class-slots` は MOP
由来で `:cl` には含まれない → test package に内部 intern される →
`COUNTER/TESTS/MAIN-TEST::CLASS-SLOTS undefined` で失敗。

### 連鎖した失敗

1. turn 0 verify: 通常の class 未定義エラー
2. agent が `(defclass counter () (count :initform 0))` を追加(`count` は
   slot 名のはず、`:initform 0` も slot-option のはず、しかし list で囲っていない
   →`:INITFORM is a keyword` というSBCLマクロ展開エラー)
3. turn 4 verify: SYSTEM-LOAD 失敗(上記 defclass のシンタックスエラー)
4. agent が defclass を修正
5. turn 5 verify: `COUNTER/TESTS/MAIN-TEST::CLASS-SLOTS undefined`(MOP 問題)
6. agent が test に `:use #:sb-mop` 追加
7. turn 10 verify: **NAME-CONFLICT**(bench5 の 104 と同じパターン — test ファイル
   READ で `CLASS-SLOTS` が内部 intern 済、その後 `:use #:sb-mop` で外部から
   `SB-MOP:CLASS-SLOTS` が import されて衝突)
8. patch-attempts=5(新 budget)使い切り → :max-patches → :limit-exhausted

## 改善候補(別 PR)

### #1-extended: planner プロンプトを **CL builtin / 標準ライブラリ symbol も
qualify する** よう拡張

bench7 が露呈した盲点。`class-slots` / `find-class` / `slot-definition-name` 等の
MOP / CLOS introspection 系を unqualified に書くと test package で
intern されて死ぬ。

**変更案**:
- 既存 prompt の qualified-symbols 段落に
  「**ALL symbols that are not in :CL or :ROVE** must be qualified, including
  CLOS / MOP / SB-MOP / 標準実装ライブラリ」を追記
- 例にも `cl:find-class` / `sb-mop:class-slots` 等の qualified 形を追加

これは planner-qualified-symbols spec の **scope 拡張**。Soft 維持。

### #3 reprise(改善 findings に既出): NAME-CONFLICT 救済 hook

102 step-0 turn 10 の NAME-CONFLICT は bench5 の 104 と全く同じパターン。
verify エラーに `NAME-CONFLICT` が含まれる場合 `pool-kill-worker` を自動発動
すれば agent の budget を消費せず救える。

未着手のまま発生し続けているので、優先度を上げて取り組む価値あり。

## ロギング自体の評価(再・再)

bench history で **同一 fixture の失敗 mode が変わっていく** ことを追跡できた
のは G1 + G3 のおかげ。

| ベンチ | 同 fixture の真の根因 | ロギング無しで判別可能か |
|---|---|---|
| bench4 102 | (不明、`:STUCK` のみ) | 不可 |
| bench5 102 | `<TEST-PKG>::MAKE-COUNTER undefined` | G1 で判明 |
| bench6 102 | qualified 化済、`max-patches` で詰む | G1 で `<SRC-PKG>:` プレフィックスを観察 |
| bench7 102 | MOP 系 unqualified + NAME-CONFLICT | G1 で reason を観察、G3 で planner test_source も観察 |

各イテレーションで「次の壁」を **正確に特定できた** ことが、累積で 104 を pass
させる原動力になった。

## まとめ

- **104-cache-simple が初めて `:PASSED`** ✅(複数改善の合わせ技)
- 102 は新 failure mode に当たり退行したが、それは planner がより精緻に
  なったことの副作用。新スコープの改善で対応可能
- bench history 上で develop の pass 率が単純な数字以上の意味を持ち始めた:
  「特定 fixture が unblock されるまでに 4 イテレーション必要だった」
- 次の自然な改善候補 = **#1-extended(MOP/CLOS 系も qualify)** または
  **#3(NAME-CONFLICT auto-reset)**
