# planner-qualified-symbols 適用後の検証ベンチ

**Date**: 2026-05-23
**Model**: `Qwen/Qwen3.6-35B-A3B` (SGLang @ 192.168.0.17:8000)
**Code**: cl-harness post-merge of `planner-qualified-symbols` (`3ec2ffc`)
**Settings**: `:review-policy :auto`, `:max-impl-review-revisions 2`,
`:log-llm-requests t`, `:max-replans 1`. Single trial.
**Fixtures**: 102-counter-class, 104-cache-simple(bench5 と同じ 2 件)
**Driver**: `/tmp/rfr-bench6.lisp`

## 目的

planner プロンプト改修(qualified-symbol soft guidance)の **実効性検証**。
postmortem-logging findings(`results-2026-05-23-postmortem-logging-findings.md`)で
特定した improvement #1 が live LLM で機能するかを確認する。

## 結果サマリ

| Task | Status | Steps passed / total | impl-reviews | Verify-fail reason(代表) |
|---|---|---|---:|---|
| 102-counter-class | `:LIMIT-EXHAUSTED` | **4 / 7**(round1 で 3/4, round2 で 1/3) | 4 | `MAKE-COUNTER` 仕様変更検証中の細部 |
| 104-cache-simple | `:STUCK` | **0 / 1** | 0 | `CACHE/SRC/MAIN:MAKE-CACHE undefined` |

bench5 比較:

| Fixture | bench5 (pre-#1) | bench6 (post-#1) | 差分 |
|---|---|---|---|
| 102 — passed steps | **0** | **4** | **+4** ✅ |
| 102 — impl-reviews | 0 | 4 | **+4** ✅ |
| 104 — passed steps | 0 | 0 | unchanged |
| 104 — verify reason | `<TEST-PKG>::SYM undefined` | `<SRC-PKG>:SYM undefined` | **質が変わった** |

## #1 の効果 — 確認

planner が出した test_source(materialize 後の `tests/main-test.lisp` から抜粋):

```lisp
(deftest test-counter-class-and-reader
  (testing "default initial value"
    (ok (eql 0 (counter:counter-value (make-instance 'counter:counter))))))

(deftest test-make-counter
  (testing "custom initial value"
    (ok (eql 5 (counter:counter-value (counter:make-counter 5)))))
  ...)
```

**全シンボル参照が `counter:` / `cache:` で qualified** されている。Soft prompt
guidance が live LLM で守られた ✅。

bench5 までは `(eql 0 (counter-value (make-counter)))` と unqualified で
書かれ、test の defpackage が `counter:make-counter` を import していない
ために `<TEST-PKG>::MAKE-COUNTER undefined` で詰まっていた。今は test
defpackage を一切触らずに src 側で symbol 解決完了。

## 102-counter-class の進展(大幅前進)

bench5 では `:STUCK` で **0 step passed**。bench6 では:

- Round 1 (4-step plan):
  - step 0 `test-counter-class-and-reader`: **passed**
  - step 1 `test-make-counter`: **passed**
  - step 2 `test-increment`: **passed**
  - step 3 `test-reset-counter`: `:limit-exhausted` (max-patches)
- Round 2 (replan、3-step plan):
  - step 0 `test-class-constructor-reader`: **passed**
  - step 1 `test-generics-methods`: `:limit-exhausted`
- max-replans 切れ → `:LIMIT-EXHAUSTED`

合計 **4 steps passed**(=4 impl-reviews fired)。

詰まったのは最後の 1 step(`reset-counter` or `generics-methods` の細部)
だけ。`max-replans 2` 既定(本ベンチは 1)なら通り抜ける可能性が高い。

## 104-cache-simple — 詰まり方が変わった

bench5: `MAKE-CACHE` が test package に内部 intern される問題
bench6: `MAKE-CACHE` は qualified で書かれており、test は **CACHE/SRC/MAIN:MAKE-CACHE**
(src 側の external symbol)を見にいく。しかし src/main.lisp にまだ未実装で
`undefined` 失敗。

agent の挙動(G2+G3 から再構成):
- turn 5: `fs-write-file` 試行 → エラー("use lisp-edit-form")
- turn 6: `lisp-edit-form` で `(defclass simple-cache () ())` 追加成功
- turn 7: 続けて `make-cache` 追加を試みるが **`lisp-edit-form` で
  `"Form defclass simple-cache () not found"` エラー**(form_name の
  unique 指定がずれた可能性)
- patch_attempts=3 で `:max-patches` 終了

つまり「**1 step に必要なフォームが複数**で、agent が 1 つ目を成功させても
2 つ目で tool error を起こしてから max-patches に到達」という failure mode に
変わった。

これは **改善 #1 のスコープ外** で、別系統の改善候補:

### #4-α(改善 findings 由来): agent が `lisp-edit-form` の form-name
解決を失敗するパターンの誘導改善

system prompt で「`insert_after` には正確な form の name と type を渡す。
defclass の場合 form_name には class 名のみ、specializers なし」等を
明示する余地あり。または form_name の解決ロジック側の改善(正規化、
fuzzy match 等)。

### #6(新候補): 1 plan-step で複数 form を追加する必要があるケース

102 では「class + 4 generic functions + reader」が 1 step として scoped
されることがあり、agent は順に追加する必要があるが `max-patches 3` だと
不足する。planner が step を「1 step = 1-2 form 追加」に分割するよう
指示する、または `max-patches` の default を 5 程度に引き上げる検討。

## ロギング自体の評価(再)

| Gap | この bench で活躍 |
|---|---|
| G1 `failed_tests` | ✅ verify reason の package prefix で「#1 が効いた / 別問題に変わった」を 1 秒で判定 |
| G2 `content_summary` | ✅ tool 呼び出しの追跡で有用 |
| G3 `:llm-request` | ✅ 詳細は今回未使用だが、深掘り余地あり |

特に G1 が「**before/after の質的差分**を露出させる」価値が今回も大きい。

## まとめ

- improvement #1 は **設計通り機能**。Soft guidance を LLM が守り、test_source が
  qualified になった
- 102 は前進: 0 → 4 passed steps、bench5 比で大幅改善
- 104 は次の壁: lisp-edit-form の form-name 解決エラーで max-patches 喰い
- 次の自然な改善ターゲット: **agent 側の form-name 指定ガイダンス改善**
  (#4-α)、または **per-step の複数-form ケースで max-patches 上げる**(#6)
- 104 のような fixture を unblock するには #4-α か #6 が次に必要

#1 単独で 102 が `:passed` には届かなかったが、それは「最後の 1 step」の
細部の差で、`max-replans` を default 3 に戻せば届く可能性が高い。次回
ベンチでは `:max-replans 3` で再走を試す価値あり。
