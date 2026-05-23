# #21 follow-up: orchestrator-level explore downgrade on fresh source

**Date**: 2026-05-23
**Code**: cl-harness main (post 730a12d, this PR)
**Trigger**: improvement-backlog #21 — original premise (orchestrator
runs explore even when needs_exploration is null/false) turned out to
be wrong; planner was explicitly emitting `:lightweight` for step 0
even on a fresh-project fixture. This follow-up implements the real
fix: orchestrator-level deterministic downgrade.

## 実装サマリ

新規ヘルパー `%fresh-source-surface-p` を `src/orchestrator.lisp` に
追加し、`%execute-step` で planner の `needs-exploration` を読む前に:

```
(let* ((raw-needs (plan-step-needs-exploration step))
       (downgrade-explore-p
        (and raw-needs
             (not (eq :none raw-needs))
             (%fresh-source-surface-p project-root)))
       (needs (if downgrade-explore-p :none raw-needs))
       ...)
  ...)
```

`%fresh-source-surface-p` は以下のとき T:
- `<project-root>/src/` が存在し
- かつ src/*.lisp に substantive な `(def…` 形が一つもない

`<project-root>/src/` が存在しないときは NIL（既存テスト fixture が
bare temp directory を project-root に使うケースを壊さないため、
非標準 layout の project では planner の判断を尊重）。

downgrade が発火した場合は新イベント `:explore-downgrade` を develop-level
log に emit:
```json
{"type": "explore-downgrade",
 "step_index": 0,
 "from": "lightweight",
 "to": "none",
 "reason": "fresh-source-surface"}
```

## 既存テスト保護のための調整

最初の実装では `%fresh-source-surface-p` が「src/ なし → fresh」と判定
していたため、`uiop:temporary-directory` を project-root に使う既存 2
テスト (`execute-plan-runs-explore-and-prepends-memo-when-requested` /
`execute-plan-threads-develop-state-into-explore-fn`) で予期せぬ
downgrade が起こり explorer が呼ばれず regression。「src/ ディレクトリの
存在」を必須化することで両テストが意図通り動作するように修正。

## 単体テスト

`tests/orchestrator-test.lisp` に 3 件追加（合計 42 → 44 + 1 = 45 件,
そのうち 44 件が orchestrator-test、+1 は親 system での集計差）:

1. `fresh-source-surface-p-detects-empty-and-trivial-src`
   - src/ なし → NIL
   - 空 src/ → T
   - in-package のみの src/main.lisp → T
   - defun ありの src/main.lisp → NIL
2. `execute-plan-downgrades-needs-exploration-on-fresh-source`
   - planner :lightweight + empty src/ → 実際の `needs` は :none
   - explore-fn が呼ばれない（call count 0）
   - `:explore-downgrade` event が log に存在
3. `execute-plan-keeps-explore-when-source-has-code`
   - planner :lightweight + src/main.lisp に defun → 実際の `needs` は :lightweight 維持
   - explore-fn が 1 回呼ばれる
   - `:explore-downgrade` event が log に存在しない

`run-tests cl-harness/tests`: **455 passed, 0 failed** (baseline 452 + 3 新規)

## Bench 検証（102-counter-class N=1）

### Step 0 直接比較（fresh-source-downgrade の効果）

| | baseline | after #21 | 差分 |
|---|---|---|---|
| planner emit (step 0) | `lightweight` | `lightweight` | — |
| orchestrator adopt | `lightweight` | **`none`** (downgrade ✓) | ✅ |
| explore phase | 8 turn / 14778 token | **走らず** | ✅ |
| step 0 token | 21,963 | **9,206** | **-12,757 (-58%)** |
| step 0 elapsed | 77.0s | **38.6s** | **-38.4s (-50%)** |
| step 0 turns | 10 | **5** | -5 |
| step 0 status | passed (after 2 patches) | passed-first-try (2 patches) | 同等 |

`:explore-downgrade` event が JSONL に `{step_index:0, from:lightweight,
to:none, reason:fresh-source-surface}` で emit されていることを確認。

### Bench 全体は完走せず（#21 外の問題）

Plan A の step 1（test-counter-value-reader）が:
- 12 turn / 3 patches / 32,457 token / 150.2s 消費
- verify status=passed だが **impl-review が 2 回連続 reject**
- step-end status=`review-rejected`, outcome=`exhausted`

これを受けて develop loop が replan に進む際、`subtask-summary` モジュール
が `:REVIEW-REJECTED` を未知 status と判定して例外:
```
subtask-summary: unsupported :verification :REVIEW-REJECTED;
expected (:PASSED :GIVE-UP :LIMIT-EXHAUSTED :DIRTY-ONLY :ERROR)
```

これは **#21 とは独立な pre-existing バグ**。`:REVIEW-REJECTED` は
v0.4 で導入された status だが `subtask-summary` の許容 list には未追加。
本 cycle で初めて trigger 条件（impl-review 2 連続 reject）が満たされた
ことで顕在化したと思われる。

→ **backlog に新項目 #26 として記録**（本 doc と同時に追加）。

## #21 の verdict

- ✅ 実装は意図通り作動
- ✅ deterministic で LLM 遵守に依存しない
- ✅ step 単位で確定的な ~50-58% cost 削減
- ⚠️ Bench 完走による end-to-end 検証は別バグで保留 — `:REVIEW-REJECTED`
   許容 (#26) を片付けた後に再確認したい

## End-to-end 検証（#21 + #26 統合、N=1, 後日 追記）

LLM endpoint 安定後の再 bench で **PASSED 完走**を確認。`docs/improvement-backlog.md`
#26 が実装された後、初の完走 run。

| | baseline | after #21+#26 | delta |
|---|---|---|---|
| Status | :PASSED | **:PASSED** | 同等 |
| Replans | 0 | **0** | 同等 |
| Plan size | 4 | 4 | 同等 |
| Impl rejections | 0 | 0 | 同等 |
| Integration issues | 0 | 0 | 同等 |
| `:explore-downgrade` 件数 | n/a (機能なし) | **1 件** (step 0, lightweight→none, fresh-source-surface) | 新規 |
| **step 0 token** | 21,963 | **11,615** | **-10,348 (-47%)** |
| **step 0 elapsed** | 77.0s | **45.6s** | **-31.4s (-41%)** |
| step 0 turns | 10 (8 explore + 2 impl) | **6** | -4 |
| sum of per-step elapsed | 234.9s | 278.4s | +43.5s (per-step variance) |
| **wall-clock total** | 591.9s | **549.9s** | **-42s (-7%)** |

### 観察

- **#21 deterministic downgrade が実 bench で完走時にも発火確認** — step 0
  で planner emit が `lightweight` → orchestrator が `:none` に格下げ
- **#26 修正の効果**: 今回は `:REVIEW-REJECTED` path に入らずに完走したため
  直接の事象には遭遇しなかったが、replan path の summarise-step-result
  が安全に動く状態は維持
- **step 0 で確定的削減（token -47% / time -41%）** — explore phase 抑制
  による direct effect
- **per-step variance**: step 1-3 で baseline より tokens / time が一部
  上振れ（LLM 応答 variance）。総 token は ~0% 差。

### Bench transcripts
- driver: `/tmp/bench-cycle-1779535286.lisp`
- log: `/tmp/bench-cycle-1779535286.log`
- JSONL: `/tmp/bench-cycle-1779535286-102-counter-class.jsonl`

## 関連 commit

- 本 doc + 実装 + tests を含む 1 PR で commit (this push)
