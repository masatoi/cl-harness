# max-patches-budget — default を 3 → 5 に引き上げ

**Date:** 2026-05-23
**Author:** Satoshi Imai
**Status:** Draft for implementation
**Related:**
- `docs/benchmarks/results-2026-05-23-planner-qualified-symbols-verification.md` — 本 spec のきっかけ
- `docs/cl-harness-prd.md` §8.4 REQ-AGENT-003 — run-limits 規約

## 1. 動機

planner-qualified-symbols のベンチ検証(`results-2026-05-23-planner-qualified-symbols-verification.md`)で、104-cache-simple が新たな failure mode で詰まった:

- planner は qualified symbol を正しく出力 ✅
- agent は `defclass simple-cache () ()` をうまく追加(turn 6)
- 続いて `defun make-cache` を追加しようとして `lisp-edit-form` が
  `"Form defclass simple-cache () not found"` エラー(form_name 解決ミス)
- patch_attempts=3 で `:max-patches` 切れ

102-counter-class でも同様の形:
- step `test-reset-counter` / `test-generics-methods` が 1 patch では足りず
  `:limit-exhausted (max-patches)`

要するに **「1 plan-step あたり最低 2 form 追加が必要」+「tool-error を 1 回挟む」** だけで現行 `max-patches 3` を超えてしまう。

### 1.1 設計判断: 単純 default 上げ(option A)

検討した代替:

- **option B**: `max-patches` を「成功 patch」の上限に変更し、tool-error は数えない。
  根本原因に直接効くが、同じ patch を無限ループするリスクが残る(他の limit
  で抑えるが追加の保証ロジック検討が要る)
- **option D**: planner が step ごとに `complexity_hint` を返して reactive に
  限界を調整。設計肥大、YAGNI

採用: **option A = default 値の単純引き上げ**。1 行変更で済み、root cause
の表れ方が「budget 不足」なので直接対症する。option B は将来必要が出たら
別 spec で扱う。

### 1.2 数値: なぜ 5 か

- 多くの fix-bench task は 1 patch で完結(現行 91.7% / 83.3% pass-rate がそれを示す)
- 104 で観測: 「2 form 追加 + tool-error 1 回」= 3 attempts、ぎりぎり詰む
- 5 なら「2 form + tool-error 2 回」または「3 form + tool-error 1 回」までカバー
- 10 等の大きすぎる値は無限ループ的振る舞いを許容する範囲が広がり cost も
  上がる。5 が "わずか緩める" バランス

## 2. 変更内容

### 2.1 ソース(1 ファイル、1 行)

`src/config.lisp` の `make-default-limits`(L57-67 付近):

変更前:
```lisp
(defun make-default-limits ()
  "Return a RUN-LIMITS object populated with conservative MVP defaults."
  (make-instance 'run-limits
                 :max-turns 20
                 :max-tool-calls 80
                 :max-patches 3              ; ← この行
                 :max-read-files 40
                 :max-repl-evals 40
                 :max-wall-clock-seconds 600
                 :max-action-parse-errors 3
                 :max-context-tokens 50000))
```

変更後:
```lisp
                 :max-patches 5              ; bumped from 3 (see 2026-05-23 spec)
```

### 2.2 テスト(1 ファイル、1 行)

`tests/main-test.lisp` の既存 `config-construction` deftest(L34-45 付近)に
default 値の assertion がある:

変更前:
```lisp
(ok (= 3 (run-limits-max-patches (run-config-limits c))))
```

変更後:
```lisp
(ok (= 5 (run-limits-max-patches (run-config-limits c))))
```

新規 deftest は追加しない — 既存 assertion で default 値 regression が捕捉される。

### 2.3 ドキュメント(`docs/cl-harness-prd.md`、2 箇所)

L729 付近(REQ-AGENT-003 のデフォルト一覧):
```text
max-patches = 3
```
→
```text
max-patches = 5
```

L871 付近(別の言及):
```text
max_patches: 3
```
→
```text
max_patches: 5
```

## 3. テスト戦略

`tests/main-test.lisp:45` の既存 assertion 更新で十分。新規 deftest 不要。

実効性検証(104 / 102 が `:passed` に届くか)は別作業のベンチで実施。
本 spec の自動テストは default 値の regression detection のみ。

## 4. Backward compatibility

完全に additive / safe:

- `:max-patches N` を **明示的に指定する caller** は影響なし(個別指定が
  常に default より優先)
- default を受け取る caller は budget が 2 増えるだけで、緊縮方向の変更
  ではない
- 既存 bench 数値(`results-2026-05-06-qwen.md` の 91.7% / 83.3% 等)は
  max-patches=3 前提の歴史的記録。retroactive 更新せず、新 default の
  pass-rate は別 bench 取得

`tests/agent-test.lisp` 内で `:max-patches 99` / `:max-patches 1` を
明示的に渡している箇所は変更不要(個別指定が優先)。

## 5. リスク

| リスク | 緩和策 |
|---|---|
| pass-rate が変動 | "改善"方向。歓迎すべき変動。bench 再走で確認 |
| token 消費が増える | 1 task あたり最大 +2 patches 分の LLM turn。fix-bench 12 task × 3 condition でも限定的(各 patch ~1-3k tokens) |
| 無限 loop 的挙動を許容しやすくなる | 既存 `max-turns 20`, `max-tool-calls 80`, `max-action-parse-errors 3` で抑え込み済。max-patches のみが loop の唯一のガードではない |
| 既存テストフィクスチャの数値依存 | `tests/main-test.lisp:45` の 1 assertion のみ依存。他の箇所は明示指定なので影響なし |

## 6. Out of scope

- **option B**(tool-error を patch budget に数えない semantic 変更)— 別 spec の余地
- **option D**(planner が complexity_hint を返して per-step adaptive 調整)— YAGNI
- **既存 bench 数値の retroactive 更新** — 歴史的記録は不変
- **`max-patches` の other defaults との関係再評価** — 例: max-patches を上げたら
  max-tool-calls も上げるべきか等。今は依存薄い前提で別作業
- **fix / develop CLI の `--max-patches` フラグ** — 既存通り kwarg + cli は受け
  入れ可、surface 不変

## 7. 実装順序(writing-plans で詳細化)

3 commit 程度の小さい変更:

1. `src/config.lisp` の value 変更 + `tests/main-test.lisp` の assert 更新を
   同 commit で
2. `docs/cl-harness-prd.md` の 2 箇所更新
3. mallet clean + 全テスト緑(452 → 452)確認

## 8. Verification(本 spec 適用後)

自動テストでは default 値の regression のみ確認できる。実効性検証は手動:

1. develop-bench 102-counter-class / 104-cache-simple を `:max-replans 1` で再走
2. 期待: 104 が `:passed` に届く(または step-0 が verify 緑になる)、
   102 の最後の step が通り抜ける可能性
3. 確認: per-step JSONL の `:run-end` payload で `patch_attempts` が 4-5 の
   範囲に増え、その上で `status="passed"` が出ること

ベンチは本 spec の merge 後、別作業で。
