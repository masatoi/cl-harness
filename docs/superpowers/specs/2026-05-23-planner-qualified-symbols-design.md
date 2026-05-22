# planner-qualified-symbols — Soft prompt guidance for qualified test references

**Date:** 2026-05-23
**Author:** Satoshi Imai
**Status:** Draft for implementation
**Related:**
- `docs/benchmarks/results-2026-05-23-postmortem-logging-findings.md` — 本 spec の根拠データ(improvement #1)
- `docs/superpowers/specs/2026-05-22-scaffold-command-design.md` — 関連: scaffold は test defpackage を空のままにする(本 spec はその前提で書く)

## 1. 動機

`postmortem-logging` の G1(`failed_tests`)で 102-counter-class と
104-cache-simple の `:STUCK` の真因が判明した:

- planner-authored test が unqualified にシンボル参照する
  (例: `(make-counter)`)
- test ファイルが READ される時、`MAKE-COUNTER` は test の defpackage
  `cache/tests/main-test`(`:use :cl :rove` のみ)に **内部 intern** される
- agent は `<system>:make-counter` を src 側に定義・export するが、
  test 側のシンボルとは別物(`COUNTER/TESTS/MAIN-TEST::MAKE-COUNTER`
  と `COUNTER:MAKE-COUNTER` は package が違う別シンボル)
- verify は `<TEST-PKG>::MAKE-COUNTER is undefined` で失敗継続
- agent は src 側を修正することに集中し、test defpackage を直す発想に
  到達するのが遅く `max-patches` で `:STUCK`

planner が最初から `(counter:make-counter)` のように
package-qualified で書けば、test defpackage を一切編集せずに済み、
agent は src 側だけ修正すればよくなる。

## 2. アプローチ判断: Soft prompt guidance

Hard validation(`validate-test-source` で unqualified を検出して
planner-error を raise)も検討したが採用しなかった:

- **false-positive リスク**: `cl:eql` / `cl:ok` / 標準 builtins と
  package-qualify 必要なシンボルを正確に区別するには CST 解析が必要で
  実装が重い
- **planner 再呼び出しコスト**: planner-error を出して再生成する場合、
  ベンチで LLM コール 2 倍化
- **Soft の effectiveness は実証ベース**: bench で守らない頻度が高ければ
  Hard validation に escalation できる(別 spec で扱う)

採用: **Soft = planner system prompt にガイダンス文を追加し、LLM の
prompt-following を信じる**。

## 3. 変更内容

`src/planner.lisp` 内 `+default-planner-system-prompt+`(planner.lisp:50 付近)
の `Required test_source shape` テンプレートと `Rules:` セクションの間に
以下を挿入する。

挿入する文言(英語、既存 prompt と同じ tone):

```
IMPORTANT: planner-authored test_source is appended to an existing
test file whose defpackage is `<system>/tests/main-test (:use :cl
:rove)`. This package does NOT import symbols from the implementation
package automatically. Always reference target symbols with their
package-qualified form so the test reads correctly without any
defpackage edits.

Example (assuming `:system "counter"`):

  (deftest test-make-counter
    (testing "default initial value"
      (ok (eql 0 (counter:counter-value (counter:make-counter))))))

NOT:

  (deftest test-make-counter
    (testing "default initial value"
      (ok (eql 0 (counter-value (make-counter))))))  ; will error:
                                                     ; COUNTER/TESTS/MAIN-TEST::MAKE-COUNTER
                                                     ; is undefined.
```

文字列リテラルなので、Lisp 側では既存 `concatenate 'string` の
パターンに従って改行を `(string #\Newline)` で結合する形式で追加する。

## 4. テスト戦略

LLM 出力が qualified を守るかは実 LLM の挙動なので自動テストでは
証明できない。本 spec の自動テストは **prompt regression detection**
に絞る:

`tests/planner-test.lisp` に 1 deftest を追加:

```lisp
(deftest default-planner-system-prompt-includes-qualified-guidance
  (testing "system prompt mentions package-qualified test references"
    (ok (search "package-qualified"
                cl-harness/src/planner::+default-planner-system-prompt+))
    (ok (search "counter:make-counter"
                cl-harness/src/planner::+default-planner-system-prompt+))))

`cl-harness/src/planner::+default-planner-system-prompt+`(double-colon
internal accessor)を使う — この constant が export されているかは
本 spec のスコープ外で、テスト目的では internal アクセスで十分。
```

assertion は 2 件:
- ガイダンス文字列 `"package-qualified"` が prompt に入っている
- 例示 `"counter:make-counter"` が入っている

両方 search できれば、将来誰かが prompt を編集してこのガイダンスを
うっかり削除しても regression として detect できる。

実効性検証(LLM が実際に qualified で書くか)は、別途
develop-bench を re-run して 102/104 が解けるようになるか確認する
(本 spec の "Verification" 節で言及するが、自動テストには含めない)。

## 5. Backward compatibility

完全に加算的:

- `+default-planner-system-prompt+` は文字列定数。長さは増えるが
  shape は変わらない
- `validate-test-source`(orchestrator.lisp:172)は変更なし。unqualified の
  test_source も引き続き受理する
- 既存 planner-test の stub-driven テストは prompt の中身を assert
  していないので影響なし
- 既存 develop-bench fixture(`tests/main-test.lisp` の defpackage)は
  scaffold 時点の空 stub のままで動く。planner が qualified で書けば
  defpackage を一切触らずに verify が緑になる
- 過去の plan log への影響なし

## 6. リスク

| リスク | 緩和策 |
|---|---|
| LLM が prompt のガイダンスを無視して unqualified で書く | bench で実証。守らない頻度が高ければ Hard validation に escalation |
| 既存テストフィクスチャの planner 動作が変わる | stub planner-fn は LLM を呼ばないので影響なし。本 spec の影響は実 LLM ベンチのみ |
| prompt 全体が長くなり token 消費が増える | 追加分 ~250 char × 1 LLM call/plan。develop-bench 1 run あたり数百 token 増、コスト微小 |
| qualified symbol の prompt 例が "counter" 固有で他システムで混乱 | 例は assumed system="counter" と明示。LLM は他 system 名でも generalize できる |

## 7. Out of scope

- **Hard validation**(`validate-test-source` での unqualified 検出)— bench で
  必要性が判明したら別 spec で実装
- **scaffold での test defpackage `:import-from` pre-bake**(改善 #2)— 別 spec
- **既存 develop-bench fixture の更新** — planner が qualified で書く前提で
  scaffold 出力は不変
- **`run-tests` ツール側の package-resolution エラーメッセージ改善** — 別問題
- **agent system prompt 側の test-package gap への hint 追加**(改善 #4/5)—
  別 spec

## 8. 実装順序(writing-plans で詳細化)

おおよそ 1 タスクで済む小規模変更:

1. `+default-planner-system-prompt+` に qualified guidance を追加
   - `(string #\Newline)` 結合形式で既存スタイルに揃える
2. `tests/planner-test.lisp` に `default-planner-system-prompt-includes-qualified-guidance` deftest を追加
3. 全テスト緑(451 → 452)+ mallet clean を確認

3 commit 程度で landing 可能。

## 9. Verification(本 spec 適用後の検証)

自動テストでは不可。手動 / ベンチ:

1. develop-bench 102-counter-class を `:max-replans 1` で再走
2. develop-bench 104-cache-simple を同様に再走
3. 期待: 両 fixture が `:passed`(または少なくとも step-0 の verify が緑になる)
4. 確認: per-step JSONL transcript の `:verify` event で `failed_tests` の
   reason が `<TEST-PKG>::SYM undefined` でなくなっていること

ベンチは本 spec の merge 後、別 PR / 別作業で実施。
