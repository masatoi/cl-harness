# cl-harness 改善バックログ — 2026-05-23 時点

bench cycle(bench4–7)と各 final code review で抽出された未着手の改善候補。
priority は subjective、概ね「上位ほど次に取り組む価値が大きい」順。

---

## 高優先度: bench で再現性のある failure mode

### 1. planner prompt の qualified-symbol scope を拡張(#1-extended)

**根拠**: bench7 で 102-counter-class が `:LIMIT-EXHAUSTED`。planner が
`class-slots`(SB-MOP)/`find-class`(CL builtin)を unqualified で書き、
test package で内部 intern → undefined.

**現状の guidance** は `<system>:symbol` のみカバー(planner.lisp の
`+default-planner-system-prompt+`)。

**変更案**:
- prompt に「**`:cl` / `:rove` 以外のすべての symbol を qualify**」と明示
- 例として `sb-mop:class-slots` / `cl:find-class` を追加
- Soft 維持(validation 追加せず)

**期待効果**: 102 の MOP 使用テストが unblock される。さらに将来
fixture が `alexandria:` 等を使うケースもカバー。

**コスト**: prompt に 1-2 段落追加。1-day 規模。

---

### 2. NAME-CONFLICT auto-worker-reset hook(#3)

**根拠**: bench5(104)と bench7(102)の両方で観測。test ファイルの
defpackage を agent が `:use` / `:import-from` で更新すると、前段の
verify でテストファイルが READ されて内部 intern 済シンボルが
**`NAME-CONFLICT`** を起こし、agent の修正は正しいのに budget を喰う。

**変更案**:
- `verify-task` の system-load 失敗時に reason に `NAME-CONFLICT` または
  `broken package state` が含まれていたら自動で `pool-kill-worker reset=t`
  を 1 度発動 → 再 verify
- もしくは agent system prompt に「NAME-CONFLICT を見たら `pool-kill-worker`
  を叩け」と明示
- 1 回限りの "self-heal" でループ防止

**期待効果**: 104(bench5)/102(bench7)の特定 turn が unblock される。

**コスト**: 中(verify-task の reason 解析 + 自動 reset 実装 + ループ
防止)。2-3 days。

---

### 3. test-change-request 棄却フィードバックの executor へのルーティング

**根拠**: review-feedback-routing spec §10 で out-of-scope 化したまま。
実装レビュー側は inner-loop でルーティングしているが、test-change-request
側は棄却時に executor に何も伝わらない。

**変更案**:
- `%maybe-handle-test-change-request` で棄却時に **reviewer feedback を
  executor の次 turn の user message として挿入**(impl-review と同形)
- 既存 review-feedback-routing 設計の対称化

**期待効果**: executor が「なぜ test 追加が拒否されたか」を学習して
別アプローチに切り替えられる。

**コスト**: 小(設計対称、コード ~50 行)。1-day 規模。

---

## 中優先度: 構造的負債 / Operational

### 4. agent system prompt の tool 使用ガイダンス改善(#4-α)

**根拠**: 何度かの bench で観測 — agent が `fs-write-file` で .lisp 上書き
試行 → エラー("use lisp-edit-form")→ 1 turn 浪費。また `lisp-edit-form` の
`form_name` 指定でしばしばミス(例: `defclass simple-cache () not found`)。

**変更案**:
- system prompt の tool description に「`.lisp` / `.asd` 編集は最初から
  `lisp-edit-form` / `lisp-patch-form` を使う」と明示
- `form_name` の指定規約を明文化(defclass は class 名のみ、defmethod は
  specializer 含む等)

**期待効果**: 1-2 turn / step の節約。max-patches 制約下で地味に効く。

**コスト**: prompt 修正のみ。half-day。

---

### 5. agent への `--test-file` パス明示(#5)

**根拠**: bench5/6 で agent が `tests/main.lisp`(間違ったパス)を読みに行く
ケース観察。正しいパスは `--test-file` で渡されているが prompt に出ていない
可能性。

**変更案**:
- develop 経由の agent 起動時、初期 user prompt に「テストファイル: <絶対パス>」
  を明記
- 既存 `project-inventory` から推測させず、解決済みパスを宣言

**期待効果**: 1 turn / step の節約、ファイル名間違いによる tool-error 回避。

**コスト**: 小。agent initial prompt 1 行追加。

---

### 6. scaffold/planner が test defpackage に `:import-from` を pre-bake(#2)

**根拠**: planner-qualified-symbols は test 側を触らずに済ます方針だが、
代替策として「scaffold or planner が test の defpackage に必要な
`:import-from` を埋める」もある。

**変更案**:
- scaffold 時に `<system>` package を `:use` するか / `:import-from` の
  スタブを置く
- もしくは planner が出力する `symbols_to_export` を test defpackage に
  反映する hook

**期待効果**: #1 が機能している限り低優先だが、planner が忘れた場合の
backstop。

**コスト**: 中。scaffold 改修 + planner output 拡張。

---

## 低優先度: コード衛生 / Doc

### 7. cli.lisp / bench.lisp の formatter ノイズ cleanup

**根拠**: postmortem-logging Task 7 で `lisp-edit-form` が cli.lisp /
bench.lisp に `uiop/stream:` 等のサブパッケージ参照を撒いた。動作には
影響ないが style 一貫性を欠く。

**変更案**:
- `lisp-patch-form` で `uiop/stream:temporary-directory` →
  `uiop:temporary-directory`、`uiop/os:getenv` → `uiop:getenv`、
  `uiop/image:quit` → `uiop:quit` 等に戻す
- 一回りの cleanup commit

**コスト**: 小。1-2 hours。

---

### 8. CLI handler 自体の rove テスト追加

**根拠**: scaffold / postmortem-logging で観察された **clingon qualifier
regression**(getopt / make-option / make-command の `clingon:` プレフィックス
脱落)を構造的に防ぐため。

**変更案**:
- `tests/cli-main-test.lisp` を新設(または既存 test ファイルに合流)
- `(fix-command)` / `(bench-command)` / `(develop-command)` / `(scaffold-command)` が
  例外を投げず option list を返すことを assert
- option name 一覧の regression detect も組み込む

**期待効果**: 「pretty-print が package qualifier を落としても compile 時に
気付かないが runtime 起動で死ぬ」 class の bug を CI で catch。

**コスト**: 小。deftest 4-5 個。

---

### 9. `alt/` ディレクトリの整理

**根拠**: postmortem-logging final review で「repo 直下に `alt/` という
追跡されてない ディレクトリがある」と flag された。

**変更案**:
- 中身を確認、必要なら `.gitignore` に追加、不要なら削除

**コスト**: 5 分。

---

### 10. G3 (`:llm-request`) の redaction policy

**根拠**: postmortem-logging spec §10 で out-of-scope 化。opt-in なので
user 責任だが、API key 等が prompt に含まれる可能性は残る。

**変更案**:
- 別 spec: API key / 認証 token のパターン検出 → `***REDACTED***` 置換
- env / config で正規表現リスト指定可

**コスト**: 中。1-2 days。低優先度(opt-in なので即時リスクなし)。

---

### 11. `CL_HARNESS_LOG_LLM_REQUESTS` の falsy リスト拡張

**根拠**: 現状 `"" "0" "false" "FALSE"` のみ。`"no"` / `"off"` / 末尾空白
は truthy 扱い。

**変更案**:
- リストを `"" "0" "false" "no" "off"` に拡張、`equalp` で case-insensitive
  比較に
- 末尾空白 trim も検討

**コスト**: 5 分。低優先度(false-positive activation は stderr 警告 +
log 巨大化止まり)。

---

## 検証 / Methodology

### 12. fix / bench で develop と同等の review-policy をかける検討

**根拠**: 現状 `cl-harness:fix` には review-policy 概念がない。develop の
review-pipeline が pass-rate を向上させた可能性は bench3 で示唆された。

**変更案**:
- fix loop にも spec 生成 + plan review を導入する設計検討
- ただし fix の "失敗テスト → patch" シンプル契約を壊さないか慎重に判断

**コスト**: 大(設計 → 実装)。中優先度。

---

### 13. scaffold → develop → fix end-to-end benchmark suite

**根拠**: 以前 brainstorm で保留した案。現状 fix-bench と develop-bench は
独立。

**変更案**:
- `end-to-end-benchmarks/` を新設
- 1 task = goal + mutation(bug 混入)+ fix-issue を一体化
- pass-rate を「3 段全部通過」で測る

**コスト**: 大(fixture 設計 + bug 混入機構 + runner)。中優先度。

---

## bench cycle で観察された "成功条件"

bench4 → bench7 の累積で見えた、cl-harness が **特定 fixture を unblock**
するために必要だった要素:

1. **解像度の高いログ**(G1 + G2 + G3): どこで詰まったかが判別可能
2. **planner の qualified-symbol 遵守**: test の package shadow 問題回避
3. **十分な per-step patch budget**: 1 step で複数 form 追加が必要なケースの実態
4. **多段の retry 機構**: impl-review-retry / test-change loop / outer replan

これら 4 つが揃って初めて 104 が `:PASSED`(bench7)。逆に言えば、これらの
どれか 1 つが欠けると別 fixture では `:STUCK` が再発するし、新しい
failure mode が露呈する(bench7 の 102 が良い例)。

bench cycle の次の壁は **MOP/CL builtin の qualify**(#1-extended)と
**NAME-CONFLICT self-heal**(#3)を片付けると、102-counter-class が
unblock される見込み。
