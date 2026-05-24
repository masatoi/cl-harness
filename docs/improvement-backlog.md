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

---

## 2026-05-23 bench-cycle 由来

bench-cycle skill による 102-counter-class N=1 run（:PASSED 完走）で
**内部に観察された 12 件の改善余地**。results doc:
`docs/benchmarks/results-2026-05-23-bench-cycle-102-counter-class.md`。

### 14. 102-counter-class の sibling no-exploration fixture 追加

**Source**: bench-cycle 2026-05-23, fixture(s) 102-counter-class
**Axis**: bench target

**観察**: step 0 で `needs_exploration=null` にもかかわらず explore phase が
8 turn × 14778 token を消費し `memo=""` `status=limit-exhausted` で終了。
explore phase の cost-benefit を A/B 測定する baseline がない。

**仮説**: 同一 fixture を「explore あり / なし」で実行できる pair があれば、
explore phase の実効価値を継続的に測定可能。現状は fixture ごとに 1 設定
しか持てない。

**変更案**:
- `develop-benchmarks/102b-counter-class-no-explore/` を追加
- `develop-task.json` に `"explore-required": false` を明示
- develop-bench runner が当該 field を読んで planner output を override
- 既存 102-counter-class はそのまま（baseline 維持）

**期待効果**: 同 fixture で「explore 有・無」の token / elapsed 差を直接
比較できる。explore phase 関連の改善（C1, C3 等）の effect size を
継続評価する material になる。

**コスト**: small + half-day（fixture 1 個追加 + runner の field 解釈）。

### 15. develop-task.json に expected-step-count / expected-replans 期待値 field

**Source**: bench-cycle 2026-05-23, fixture(s) 102-counter-class
**Axis**: bench target

**観察**: 観察された `step=4, replans=0` が「正しい設計か」を bench 自身が
宣言していない。将来 planner が同 fixture に対して step=8 を出した場合、
PASSED でも regression として検出する手段がない。

**仮説**: PASSED/STUCK の binary 判定では planner の "structural quality"
regression が見えない。期待値を fixture 側に書いておけば bench summary で
diff として可視化できる。

**変更案**:
- `develop-task.json` に optional な `"expected-step-count": 4`
  `"expected-replans-max": 0` を追加
- develop-bench summary で actual と diff を併記、PASSED かつ過剰乖離は
  warning として記録（exit code は変えない）

**期待効果**: planner regression が PASSED に紛れて見過ごされる確率を低減。

**コスト**: small + 1-day。

### 16. explore-end の memo を limit-exhausted 時に partial-findings で埋める

**Source**: bench-cycle 2026-05-23, fixture(s) 102-counter-class
**Axis**: log content

**観察**: step 0 の `explore-end status=limit-exhausted memo=""`。8 turn で
`fs-list-directory`, `fs-read-file` を計 7 回呼んでいるが、観察結果が
event log と memo のどちらにも要約として残らない。

**仮説**: explore agent が「memo にまとめる」step に到達できないまま budget
切れ。生 observation を構造化して捨てない仕組みがあれば次フェーズ
（planner / executor）が活用できる。

**変更案**:
- `explore-end` event に `partial-findings:
   {files_listed: [...], files_read: [...], symbols_seen: [...]}` を追加
- explore phase 中の `tool-result` から orchestrator が自動収集

**期待効果**: explore 失敗時の "0 → 1" 情報量確保。次フェーズが盲目スタート
しない。後続の analyzer（bench-cycle skill 等）も partial-findings を直接読める。

**コスト**: medium + 1-2 days（log writer + agent prompt の継承 hook）。

### 17. explore-action-error を構造化（parser / raw_excerpt fields）

**Source**: bench-cycle 2026-05-23, fixture(s) 102-counter-class
**Axis**: log content

**観察**: explore turn 1 で `explore-action-error message="top-level JSON
value must be an object"` のみ。何が parser を失敗させたかは G3 LLM 応答
（`explore-llm-response`）まで遡らないと不明。

**仮説**: LLM が code-fence + array を出力する failure mode は structured-output
系で頻発する。エラーから直接 raw excerpt と expected shape が読めれば prompt
調整 / parser 寛容化の判断が即可能。

**変更案**:
- `explore-action-error` に以下 fields を追加:
  - `parser`: parser identifier（例 `"json-tool-call-v1"`）
  - `raw_excerpt`: failed input の先頭 200 char
  - `expected_shape`: 期待形式の短い説明（例 `"single tool-call object"`）

**期待効果**: G3 を ON にせずとも parser 失敗の原因が log だけで判別可能。

**コスト**: small + half-day。

### 18. patch event に form_type / form_name / operation を追加

**Source**: bench-cycle 2026-05-23, fixture(s) 102-counter-class
**Axis**: log content

**観察**: 現状 `patch` event は `tool`, `file`, `diff` のみ。step 2/3 で
発生した「defgeneric 追加 → no applicable method → method 追加」パターン
は diff 文字列を grep しないと検出不能。

**仮説**: form-level metadata があれば「同一 step 内で defgeneric を追加
したのに defmethod が追加されていない」等の anti-pattern を rule で自動
検出可能になる。これらは既に `lisp-edit-form` の引数として渡されている。

**変更案**:
- `patch` event に以下 fields を追加:
  - `form_type`: `"defgeneric" | "defmethod" | "defclass" | ...`
  - `form_name`: 例 `"increment"` / `"reset-counter"`
  - `operation`: `"replace" | "insert_before" | "insert_after"`

**期待効果**: bench-cycle 解析の自動化基盤。"defgeneric without method" 等
の anti-pattern を rule ベースで炙り出せる。

**コスト**: small + half-day（cl-harness/src/orchestrator または patch
logger 側、引数を保持して emit するだけ）。

### 19. tool-error に category field を追加

**Source**: bench-cycle 2026-05-23, fixture(s) 102-counter-class
**Axis**: log content

**観察**: tool-error の `code=-32602` / `-32603` だけでは "policy violation"
と "filesystem not-found" の区別が困難。今回 step 0 で 2 種類の error
（`fs-write-file on .lisp` = policy / `tests/main.lisp does not exist`
= not-found）が同 step に出現した。

**仮説**: cross-fixture 分析では failure mode の度数集計が重要。category
が分かれば policy 違反系（agent prompt 改善で潰せる）と情報不足系
（fixture / runner 側の改善で潰せる）を別軌道で追跡可能。

**変更案**:
- `tool-error` event に `category` field を追加:
  - `"policy-violation"` / `"file-not-found"` / `"argument-error"` /
    `"internal-error"` / `"timeout"`
- cl-mcp 側の message から正規化 mapping、または cl-harness orchestrator
  が分類

**期待効果**: bench-cycle 横断で failure mode の発生率を分けて集計可能に
なる。改善 effort の振り分け先が見える化。

**コスト**: small + half-day。

### 20. clean-verify に failed_tests array を追加（verify と対称）

**Source**: bench-cycle 2026-05-23, fixture(s) 102-counter-class
**Axis**: log content

**観察**: `clean-verify` event keys は `failed, passed, status, ts, turn,
type` のみ。`verify` event とは違って `failed_tests` array を持たない。
今回は 0 issues で顕在化していないが、対称性を欠く。

**仮説**: 将来 integration check（全 test fresh-image 実行）が失敗した
場合、reason が即座に分からないと debug 不能。verify と同じ schema に
揃えるべき。

**変更案**:
- `clean-verify` を `verify` event と同じ JSONL schema に揃える
- `failed_tests: [{test_name, reason, source, ...}]` を含む

**期待効果**: 将来 clean-verify failure 時に同じツール / 同じ解析パスで
root cause を追える。

**コスト**: small + half-day。

### 21. ~~planner が needs_exploration=null/false を出した時 explore phase を skip~~ → 実装済 (2026-05-23, 別アプローチ)

**Status**: ✅ **実装済** — `docs/benchmarks/results-2026-05-23-21-followup-fresh-source-downgrade.md` 参照。

**当初観察の修正**: 元の前提（orchestrator が null/false を「run explore」
として処理）は誤り。`%execute-step` のゲートは既に `(and explore-fn needs
(not (eq :none needs)))` で null/`:none` を skip 設計。真因は planner が
fresh project の step 0 でも `:lightweight` を明示的に emit していたこと。

**採用解**: `prompt 改修`路線は LLM 遵守不安定で N=1 variance に埋もれる
ため revert。代わりに **`%fresh-source-surface-p` ヘルパー + 自動
downgrade** を `%execute-step` に実装。`<project-root>/src/` 配下に
substantive な `(def…` 形が一つもない時は planner の `:lightweight` /
`:deep` を `:none` に強制格下げし、`:explore-downgrade` event を log。

**確認された effect**（102-counter-class N=1, step 0 直接比較）:
- step 0 token: 21,963 → 9,206（**-58%**）
- step 0 elapsed: 77.0s → 38.6s（**-50%**）
- step 0 turns: 10 → 5

**残課題**: Bench 全体完走は別バグ #26 で保留。

---

**元の archive 内容（参考のため残置）**:

**観察**: step 0 で plan event の `steps[0].needs_exploration=null`
（step-start でも `needs_exploration=None`）にもかかわらず explore phase
が 8 turn × 14778 token 消費して `memo=""` で終了。develop 全体 token の
~30% が ここで蒸発している。

**仮説**: orchestrator（`src/develop/orchestrator.lisp` 相当）が
`needs_exploration is None` を「fall back to run explore」と解釈している。
explicit false でない限り走る default では、vague な fixture では常に
explore コストが発生する。

**変更案**:
- orchestrator で `(or step.needs-exploration nil)` を判定し、null / false
  なら explore phase を skip
- planner prompt 側でも「`needs_exploration` は true / false のいずれかを
  明示せよ」と要求
- 既存 fixture を re-bench して regression がないことを確認

**期待効果**: 今回の 102 fixture で step 0 から 14778 token 即削減（develop
全体の ~30%）。簡単 fixture では explore 0 化。

**コスト**: small-medium + 1-day（orchestrator 分岐 + planner prompt 修正
+ 全 fixture re-bench）。

### 22. explore parser をトップレベル array に寛容化 / agent prompt で single-object 明示

**Source**: bench-cycle 2026-05-23, fixture(s) 102-counter-class
**Axis**: implementation

**観察**: explore turn 1 で `top-level JSON value must be an object`。
G3 で確認した raw content は ```` ```json [ {tool_call}, {tool_call}, ...]
``` ```` 形式の配列。parser は object 期待で fail。1 turn 浪費。

**仮説**: LLM が複数 tool_call を array で返す failure mode は structured-output
系で頻発する。agent を責める以上に parser / prompt 側で吸収するのが堅い。

**変更案**: 二択（両方やってもよい）:
- (a) **parser 寛容化**: トップレベル array なら先頭要素を採用、または各
  要素を順次実行（batch mode）
- (b) **prompt 厳格化**: explore system prompt に「ALWAYS respond with a
  single top-level JSON object containing one tool_call」を明示

**期待効果**: explore 1 turn 浪費の回避。他 fixture でも同 failure mode
が再発する確率を削減。

**コスト**: small + half-day（parser または prompt のいずれか / 両方）。

### 23. explore phase の partial memo flush on limit-exhausted

**Source**: bench-cycle 2026-05-23, fixture(s) 102-counter-class
**Axis**: implementation

**観察**: explore budget 切れの瞬間に `memo=""` のまま phase 終了 → 次
フェーズ（planner / executor）に観察結果が伝わらない。今回は 8 turn の
explore がほぼ純粋なコストとして失われた。

**仮説**: explore agent は最後の turn で「memo を出力する」step に辿り着
けない設計。budget 切れ直前に強制的に observation を要約させる safety
net が必要。

**変更案**:
- explore 最終 turn（budget 残 1）に到達したら system message として
  「次の応答は memo を必ず出力せよ。tool_call 不可」を inject
- または explore 終了時に orchestrator 側で `tool-result` 履歴を簡易
  フォーマットして `partial_memo` フィールドに詰める（B-axis #16 と相補）

**期待効果**: explore が "0 情報" で終わるケースを撲滅。次フェーズが
context を活用可能に。

**コスト**: medium + 1-2 days（orchestrator 改修 + 既存 explore prompt
互換性）。

### 24. defgeneric+method 同時定義ヒントを agent prompt に追加

**Source**: bench-cycle 2026-05-23, fixture(s) 102-counter-class
**Axis**: implementation

**観察**: step 2 turn 3 で defgeneric increment 追加 → verify
`no applicable method for #<GENERIC-FUNCTION INCREMENT (0)>` → turn 4 で
method 追加 → pass。step 3 でも `reset-counter` で完全に同じ pattern
が再発（1 fixture 内 2 回）。各 1 turn 浪費。

**仮説**: agent system prompt に CL 固有のリマインダがなく、defgeneric
単独で test pass すると誤認している（または "1 turn 1 form" の慣性で
defmethod を別 turn に分けている）。

**変更案**:
- agent system prompt（`src/agent/system-prompt.lisp` 相当）に 1 段落:
  「CL では `defgeneric` を追加しただけでは method は存在しない。test が
  method dispatch を要求する場合は同一 turn 内で `defmethod` も追加せよ。
  `lisp-edit-form` を 2 回続けて呼ぶか、ファイルへの一連の patch を 1
  turn にまとめる」

**期待効果**: 102 step 2/3 でそれぞれ 1 turn 短縮（合計 ~2 turn × ~10s
= ~20s + ~3k token 削減）。同 pattern の future fixture でも効果。

**コスト**: small + half-day（prompt 1 段落 + 同 fixture re-bench）。

### 25. initarg/slot 対応のリマインダを agent prompt に追加

**Source**: bench-cycle 2026-05-23, fixture(s) 102-counter-class
**Axis**: implementation

**観察**: step 1 turn 3 で `make-counter` を `(make-instance ... :count v)`
利用に変更したが defclass slot に `:initarg :count` を付けず regression
（`TEST-MAKE-COUNTER-DEFAULT` を壊した: `Invalid initialization argument
:COUNT`）。turn 4 で fix。impl-review 4 件全て `:passed-first-try` で
このタイミングの regression は素通り。

**仮説**:
- agent prompt に initarg / slot 対応の注意がない
- impl-review prompt が「変更が既存 test を壊していないか」を明示的に
  check していない

**変更案**:
- agent system prompt に「`make-instance ... :initarg-name value` を書く
  ときは同 turn 内で対応する slot に `:initarg :initarg-name` を確認 /
  追加」を明示
- impl-review prompt の check 項目に「**全 existing test を破壊して
  いないか**」を追加（または impl-review が verify 結果を読んで判定）

**期待効果**: step 1 turn 3→4 の往復削減 + 他 fixture でも slot/initarg
ミスマッチを予防。

**コスト**: small + half-day（prompt 2 箇所修正）。

### 26. ~~subtask-summary が :REVIEW-REJECTED を未知 status として例外を投げる~~ → 実装済 (2026-05-23)

**Status**: ✅ **実装済** — `src/subtask-summary.lisp` の
`+supported-verification-statuses+` リストに `:review-rejected` を 1 行
追加し、`tests/subtask-summary-test.lisp` に positive test 1 件追加
(`make-subtask-summary-accepts-review-rejected`)。
コメントの「Mirrors DEVELOP-STEP-RESULT-STATUS」と整合。

End-to-end bench 完走による効果確認は LLM endpoint 不調（4 連続 I/O
timeout）で保留 — endpoint 復旧後に 102-counter-class re-bench で確認
すべき。

---

**元の archive 内容（参考のため残置）**:

**Source**: bench-cycle 2026-05-23 follow-up (#21 検証), fixture(s) 102-counter-class
**Axis**: implementation

**観察**: step 1 で impl-review が 2 回連続 reject → step-end status=
`review-rejected`, outcome=`exhausted` → develop loop が replan に進む際、
`subtask-summary` モジュールが以下の例外:
```
subtask-summary: unsupported :verification :REVIEW-REJECTED;
expected (:PASSED :GIVE-UP :LIMIT-EXHAUSTED :DIRTY-ONLY :ERROR)
```

**仮説**: `:REVIEW-REJECTED` は v0.4 で導入された step status だが
`subtask-summary` の許容 list には未追加。impl-review が exhausted で
reject に終わるケースは bench fixtures でまだ稀で、これまで顕在化して
いなかった。

**変更案**:
- `subtask-summary` モジュールの `:verification` 許容 list（恐らく ecase
  / member の式）に `:review-rejected` を追加
- もしくは `:review-rejected` を `:give-up` 同等として扱う mapping を
  入口で適用

**期待効果**: 102-counter-class の bench full-run が完走可能になり、
#21 の effect を end-to-end で測定可能に。他 fixture でも impl-review
exhaustion からの replan path が安定。

**コスト**: small。half-day（場所特定 + 1 行追加 + 既存テスト確認）。

---

## 2026-05-23 bench-cycle 由来 (103-fizz-buzz)

bench-cycle skill で 103-fizz-buzz N=1 を実行（:PASSED 完走、3 steps,
0 replans, 450.7s）。step 1, 2 が initial verify 即 pass で no-op に
なり、wall-clock の 85% が review pipeline LLM コール消費という観察。
results doc: `docs/benchmarks/results-2026-05-23-bench-cycle-103-fizz-buzz.md`。

### 27. 103b-fizz-buzz-large-n sibling fixture を追加

**Source**: bench-cycle 2026-05-23, fixture(s) 103-fizz-buzz
**Axis**: bench target

**観察**: 現状 103 fixture は実装が単純すぎ、planner の step 過剰分割
（step 1/2 は step 0 の patch で既に pass、no-op）の弊害が観測しにくい。

**仮説**: N>=100 のような stream output / 大きな list を扱う variant を
入れれば、planner の step 設計品質を観測しやすい fixture が増える。

**変更案**:
- `develop-benchmarks/103b-fizz-buzz-large-n/` を追加
- goal text: 「N=100 までを 1 行ずつ stdout に出力する `fizz-buzz`」
- test_source で大量出力 (e.g. captured stdout 文字列の長さ + 末尾行)
  を確認

**期待効果**: planner の step 設計 quality を測定可能な fixture が
追加され、bench-cycle 横断の signal になる。

**コスト**: small + half-day。

### 28. step-end event に initial_verify_passed boolean を追加

**Source**: bench-cycle 2026-05-23, fixture(s) 103-fizz-buzz
**Axis**: log content

**観察**: 103 step 1, 2 で initial verify が即 pass、agent loop は 0 turn
で抜けた。これを `turns=0` から推定したが、独立 field がなく解析側で
自動検出しにくい。

**仮説**: 「前 step の patch によって後続 step も既に成立した」状態を
専用フィールドで宣言できれば、planner の over-fragmentation を解析側で
度数集計可能。

**変更案**:
- `step-end` event に `initial_verify_passed: true|false` 追加
- 判定: turn=0 の verify event status=passed なら true
- `orchestrator.lisp` の step-end emit 箇所に 1 field 追加

**期待効果**: bench-cycle 解析で「実質 no-op だった step の比率」を
直接集計でき、planner 設計の品質 metric として使える。

**コスト**: small + half-day。

### 29. verify event を pre-verify / post-verify で区別

**Source**: bench-cycle 2026-05-23, fixture(s) 103-fizz-buzz
**Axis**: log content

**観察**: 現状はすべて `verify` type、turn 値で「初回 verify か patch 後 verify か」
を区別する。意味が違うものに同じ type を割り当てており、filter / 集計が
書きにくい。

**仮説**: 「step の最初に必ず走る verify」と「patch ごとの確認 verify」は
意味が違うので type で分離するべき。

**変更案**:
- event type を `pre-verify` (turn=0 の initial verify) / `verify`
  (patch 後) に分割
- 後方互換のため `verify` をそのまま残し、別 type を併用する案も可

**期待効果**: G1 解析で type-based filter が直接書ける。bench-cycle skill
の Python 側分析コードが簡潔になる。

**コスト**: small + half-day。

### 30. planner prompt に step 間 acceptance criteria 非重複 guidance

**Source**: bench-cycle 2026-05-23, fixture(s) 103-fizz-buzz
**Axis**: implementation

**観察**: 103 の plan で step 0 (test-fizz-buzz-n15, "all four output
categories") が step 1 (divisibility-only) と step 2 (non-divisible) の
test を test レベルで subsume → step 1/2 は initial verify で即 pass、
no-op。

**仮説**: planner system prompt に「各 step の deftest は前 step の test
が既に保証する事象を再確認しないこと」を明示すれば、独立した
acceptance criterion 単位の分割になる。

**変更案**:
- `+default-planner-system-prompt+` および `prompts/planner.md` の Rules
  セクションに 1 行追加:
  > Each step's test_source must check a behavior NOT already implied
  > by earlier steps' tests. If you can't think of one, the previous
  > step is the only step you need.

**期待効果**: 103 のような trivial fixture で no-op step が無くなり、
wall-clock 短縮（impl-review LLM call が無駄に発火しなくなる）。他
fixture でも planner の冗長分割を抑制。但し過去（#21 関連）の experience
通り、prompt-only fix は LLM 遵守不安定。effect は確認 bench 必須。

**コスト**: small + half-day（prompt 1 段落 + 1 fixture re-bench）。

### 31. ~~trivial-task path: review pipeline の short-circuit~~ → 一部実装済 (2026-05-24)

**Status**: ✅ **部分実装** — `:review-policy :light` を追加。当初設計
（spec + plan-review + tests-review 全部 skip）は 103-fizz-buzz の
実 bench で **impl-review が develop-spec=nil 時に strict-reject に
default する**ことが判明したため改訂。最終 semantics:

| review-policy | spec | plan-review | tests-review | impl-review | test-change |
|---|:-:|:-:|:-:|:-:|:-:|
| `:none` | ❌ | ❌ | ❌ | ❌ | ❌ |
| **`:light`** | ✅ | ❌ | ❌ | ✅ | ✅ |
| `:auto` | ✅ | ✅ | ✅ | ✅ | ✅ |

**Effect**: 2 LLM call (plan-review / tests-review) 削減見込み。実 bench
での wall-clock 計測は今日の LLM endpoint 不安定 + N=1 variance で
inconclusive。endpoint 安定時の再 bench でクロスチェック推奨。

**実装ファイル**: `src/orchestrator.lisp` (`%plan-tests-review-enabled-p`
helper), `src/state.lisp` (`+supported-review-policies+` 拡張)、
test 2 件追加 (`tests/orchestrator-test.lisp`)。

---

**元の archive 内容（参考のため残置）**:

### 31-archive. trivial-task path: review pipeline の short-circuit

**Source**: bench-cycle 2026-05-23, fixture(s) 103-fizz-buzz
**Axis**: implementation

**観察**: 103 で wall-clock 450.7s のうち per-step 実行は 49.2s、残り
~400s が review pipeline (spec 生成 + plan-review + tests-review +
impl-review × 3) の LLM 呼び出し。実 work の **9 倍以上のオーバーヘッド**。

**仮説**: goal text と plan が十分単純な場合、review pipeline の一部 /
全部を省略して agent loop に直行できれば trivial fixture で 30-50%
wall-clock 削減。

**変更案**:
- `cl-harness:develop` に `:review-policy :light` mode を追加
- `:light` は spec 生成・plan review・tests review をスキップ、impl-review
  のみ残す
- もしくは heuristic で goal-text 文字数 / plan step 数 < N の場合に
  自動 light モード降格

**期待効果**: 100-greet / 101-double / 103-fizz-buzz 等の trivial fixture
で wall-clock 30-50% 短縮見込み。複雑 fixture（102+, 104+）には影響なし。

**コスト**: medium + 1-2 days（mode 追加 + heuristic 設計 + 既存テスト
維持 + 全 fixture re-bench で regression 確認）。

---

## 2026-05-24 由来: LLM endpoint pathological hang 対策

#31 の検証 bench 中に観察された LLM chat completion hang を分析した
結果（G3 ログ解析）、以下の pattern が判明:

- endpoint (e.g. `/models`) は終始 200 OK で応答
- 但し `/v1/chat/completions` で特定 generation が **pathological に
  長くなり、応答 timeout までハング**
- 兆候: ハング直前の turn で response token 数が普段の 2 倍、latency
  が 10 倍に急上昇（103-fizz-buzz step 1 で turn 11: 3870 tokens /
  14.2s、turn 12: 11128 chars 送信後無応答）
- turn 1 で `JSON decode failed: #\L fell through ECASE` の action-error
  も観察（LLM が prose / 説明文を出力始めた兆候）

cl-harness 側で打てる 4 つの対策を以下に追加。

### 32. ~~per-request timeout を短く + 設定可能化~~ → 実装済 (2026-05-24)

**Status**: ✅ **実装済**:
- `+default-llm-read-timeout-seconds+` を 600 → 180 (3 min) に短縮
- `default-llm-transport` に `:read-timeout` kwarg 追加
- `make-openai-provider` に `:read-timeout` kwarg 追加（per-provider
  override、custom transport との priority も明確化）
- CLI (`develop` / `fix` / `bench`) に `:read-timeout` kwarg を expose
- `tests/model-test.lisp` に `openai-provider-accepts-read-timeout-kwarg`
  test 追加 (460 passed)

実 effect の確認は別 bench で。

---

**元の archive 内容（参考）**:

### 32-archive. per-request timeout を短く + 設定可能化

**Source**: bench-cycle 2026-05-24 #31 検証, fixture(s) 103-fizz-buzz
**Axis**: implementation

**観察**: dexador の default read-timeout（~5 分推定）まで chat
completion が無応答で待ち続け、bench 全体の wall-clock を著しく
浪費。早期に fail させて retry できれば全体所要時間を圧縮可能。

**仮説**: 特定 generation だけ hang するので「30s 程度で打ち切り
→ retry」のほうが全体期待値が小さくなる（LLM の通常応答が 1-15s 程度
なので 30s 設定で false positive はほぼゼロ）。

**変更案**:
- `make-openai-provider` に `:read-timeout` パラメータ追加（default
  30s、現状 default は dexador 任せ）
- `complete-chat` 経由で dexador 呼び出しに `:read-timeout` を渡す
- CLI / develop / fix kwargs にも expose
- 既存 retry-p フラグと協調: timeout error は automatic retry の対象に

**期待効果**: hang した generation が ~5 分 → ~30 秒で fail-fast。
bench wall-clock 大幅圧縮。

**コスト**: small + half-day。

### 33. ~~per-request max_tokens を明示~~ → 実装済 (2026-05-24)

**Status**: ✅ **実装済**:
- `make-openai-provider` の `:max-tokens` default を nil → 8192 に変更
  （pathological generation cap、~2x typical legitimate response 4k）
- 明示的に nil を渡せば従来通り server default を使う
- `tests/model-test.lisp` に `openai-provider-default-max-tokens-is-8192`
  test 追加 (460 passed)
- 既存テストは backwards-compat 確保（明示 `:max-tokens` 32 を渡している
  test も問題なし）

実 effect の確認は別 bench で。

---

**元の archive 内容（参考）**:

### 33-archive. per-request max_tokens を明示

**Source**: bench-cycle 2026-05-24 #31 検証, fixture(s) 103-fizz-buzz
**Axis**: implementation

**観察**: bench 中の hung 直前 turn で response が普段の 2 倍長
（3.87k tokens）。stop 条件に達せず冗長 mode に陥ったまま hang した
可能性。

**仮説**: model に明示的 `max_tokens` を渡せば冗長 mode に入っても
有限時間で打ち切られる。tool_call 1 回相当なら 2k tokens 程度で十分。

**変更案**:
- `make-openai-provider` の `:max-tokens` を default 2048 程度に
  設定（現状 nil / endpoint default 任せ）
- `complete-chat` request body の `max_tokens` field を必ず設定
- CLI / develop / fix の `:max-tokens` kwargs 経路を確認 / 整理

**期待効果**: pathological generation も `max_tokens` で抑制 →
hang する確率が下がる、または hang しても有限時間で完了。

**コスト**: small + half-day。

### 34. ~~conversation reset between steps~~ → 実装済 (2026-05-24, reinterpretation)

**Status**: ✅ **実装済** (reinterpretation):

調査で「**step 間 reset は既に実装済**」（`run-agent` が step ごとに
fresh `agent-state` + fresh `messages` を構築）と判明。観察された
hang は **step 内 turn 12 / ~2,800 token prompt** で発生していた
が、in-step compaction 閾値 `max-context-tokens` は default 50,000
（128k-context model 向け設定）で、user の local LLM 環境では桁外れ
に緩く一度も発火しなかった。

そこで **#34 を「in-step compaction 閾値を実態に合わせて下げる +
CLI exposed」と再解釈**して実装:
- `make-default-limits` の `max-context-tokens` を 50,000 → 4,000
  に変更
- `cl-harness:develop` に `:max-context-tokens` kwarg を expose
  （per-run override 可能）
- `run-limits-default-max-context-tokens` test を新 default に更新
- 460 passed

実 effect の確認は別 bench で。

---

**元の archive 内容（参考）**:

### 34-archive. conversation reset between steps

**Source**: bench-cycle 2026-05-24 #31 検証, fixture(s) 103-fizz-buzz
**Axis**: implementation

**観察**: hang した turn 12 の prompt は 25 メッセージ・11k 文字。
step 1 で context が積み上がった結果と推測される。

**仮説**: step 間で conversation を全 reset すれば prompt 長を抑制
できる。step は独立性が高い（test name / issue / patch context は
それぞれ違う）ため、prior turns を持ち越す必然性は低い。

**変更案**:
- `%execute-step` で run-fn 呼び出し時に conversation history を
  reset
- 但し step 間で必要な context（前 step の patch summary 等）は
  別 channel（issue prefix 等）で渡す
- 既存 run-agent の context 構築フローと比較して differential を見極め

**期待効果**: 各 step 開始時の prompt が小さく保たれ、turn が進んでも
context overflow 寸前まで膨らみにくい。

**コスト**: medium + 1-2 days（既存 agent loop の context 設計を
見極めて変更、regression テスト必須）。

### 35. response prefix sanity check + early retry

**Source**: bench-cycle 2026-05-24 #31 検証, fixture(s) 103-fizz-buzz
**Axis**: implementation

**観察**: 103-fizz-buzz の bench で `JSON decode failed: #\L fell
through ECASE expression. Wanted one of (#\" #\- #\0 ... #\{ #\[ ...)`
の action-error が turn 1 で発生。LLM が JSON でなく prose を返した
兆候。

**仮説**: 1 文字目が JSON 開始トークンでない応答は構造化失敗確定なので、
最後まで読まずに即座に retry すれば早期失敗できる。streaming response
では特に有効。

**変更案**:
- response の最初の non-whitespace 文字を読んだ時点で「`{` / `[` /
  `"` / 数字 / `t` / `f` / `n`」のいずれでもなければ即 abort
- `complete-chat` 側で structured-output 期待時のみ active な
  prefix-validator option
- abort 後は automatic retry に流す（retry-p フラグと協調）

**期待効果**: pathological response (prose 開始) を最後まで読む
無駄を排除。tail-latency 圧縮。

**コスト**: medium + 1-2 days（streaming-response の前処理層追加 +
非 streaming パス互換性確保）。

---

## 2026-05-24 bench-cycle 由来 (104-cache-simple)

bench-cycle skill で 104-cache-simple を N=1 実行（:PASSED 完走、3
steps, 0 replans, 475.5s）。今日の最新 default (`#34` max-context-tokens
4000 + `#33` max-tokens 8192 + `#32` read-timeout 180s + `#21` explore
downgrade + `#31` light review-policy 利用可能 / 今回は :auto) で初の
104 clean PASSED。results doc:
`docs/benchmarks/results-2026-05-24-bench-cycle-104-cache-simple.md`。

### 36. 104b-cache-concurrent sibling fixture 追加

**Source**: bench-cycle 2026-05-24, fixture(s) 104-cache-simple
**Axis**: bench target

**観察**: 104 は単純な single-thread cache で agent が安定動作。max
prompt 1.7k token 未満で compaction も不要。より複雑な fixture が
不足。

**仮説**: concurrent / threadsafe 要件を入れた variant があれば mutex
/ atomic 等の design choice を含むより重い fixture になり、context
hoarding や hang region の挙動を観測しやすくなる。

**変更案**:
- `develop-benchmarks/104b-cache-concurrent/` 追加
- goal text: 「`bordeaux-threads` で thread-safe な cache。複数 thread
  からの concurrent put/get を破綻なく扱う」
- test_source で並行 access (2-4 thread × 1000 ops) を確認

**期待効果**: thread-safety 系設計判断を観測可能な fixture が増える。
context-heavy 状態で compaction や hang の挙動も観測しやすい。

**コスト**: small + half-day。

### 37. evolved-failures event の追加

**Source**: bench-cycle 2026-05-24, fixture(s) 104-cache-simple
**Axis**: log content

**観察**: 104 step 1 で initial verify が `CACHE-PUT undefined`、turn 3
patch 後 verify が `CACHE-GET undefined` と reason が evolve。同 test
name (`TEST-CACHE-PUT-AND-RETRIEVAL`) で fail reason が変化することは
「前 patch が effective + 追加 work 必要」状態の暗黙 signal だが、log
では直接示されない。

**仮説**: step 内で fail reason が evolve したケースを independent
event として log すれば、bench-cycle 解析側で「step が複数の implicit
acceptance criteria を内包している → 分割すべき」を rule で自動検出可能。

**変更案**:
- orchestrator の `%execute-step` 内で post-verify failed_tests を
  前回 verify failed_tests と比較
- test name が同じだが reason が異なるとき `:evolved-failure` event
  を emit
- fields: `step_index`, `test_name`, `prior_reason`, `current_reason`,
  `turn`

**期待効果**: 「step が複数 acceptance criteria を内包している」状態を
自動検出。planner の step 設計 quality metric として利用可能。複数
fixture (102, 104) で recurring pattern なので effect 範囲広い。

**コスト**: small + half-day（diff 比較 + event emit）。

### 38. ~~agent prompt に「test の全 symbol 1 turn 内」ヒント追加~~ → 実装済 (2026-05-24)

**Status**: ✅ **実装済** — `src/agent.lisp` の `system-prompt` 関数
に新セクション "Patching guidance" を追加（全 policy mode で共通）:

> Before issuing a patch, READ the failing test and enumerate every
> symbol it references (functions, classes, accessors, slots,
> constructors). If the test exercises multiple symbols (e.g. `make-x` +
> an accessor, defclass + its constructor, `cache-put` + `cache-get`),
> implement ALL of them in the SAME patch rather than adding them one
> at a time. This avoids `patch -> verify-fail with NEW missing symbol
> -> patch -> verify` cycles that burn turn budget without making
> progress.

`tests/agent-test.lisp` に `system-prompt-includes-patching-guidance`
test 追加 (全 3 policy mode で wording を pin)。461 passed.

実 effect 確認は別 bench で（102 / 104 が candidate）。

---

**元の archive 内容（参考）**:

### 38-archive. agent prompt に「test の全 symbol 1 turn 内」ヒント追加

**Source**: bench-cycle 2026-05-24, fixture(s) 104-cache-simple
**Axis**: implementation

**観察**: 104 step 0 で defclass → verify-fail (`MAKE-CACHE undefined`)
→ make-cache 追加 → pass。同 step 1 で cache-put → verify-fail
(`CACHE-GET undefined`) → cache-get 追加 → pass。**「test に出る symbol
群を 1 turn でまとめずに 1 つずつ追加 → 都度 verify 待ち」pattern が
2 step 連続で観察された。102 step 0 でも同 pattern (defclass +
make-counter)**。

**仮説**: agent system prompt に「test を読んで symbol を enumerate し
1 turn で全部 patch」せよと明示すれば、structure+constructor /
put+get 等の依存セットを 1 patch で済ませられる。

**変更案**:
- agent system prompt（`src/agent/system-prompt.lisp` 相当）に 1 段落:
  > When the test exercises multiple symbols (`make-x` + `x-accessor`,
  > `cache-put` + `cache-get`, defclass + its constructor), add **all of
  > them in the same lisp-edit-form / lisp-patch-form turn** instead of
  > waiting for verify to reveal each missing one. Read the test
  > carefully to enumerate every symbol it references before patching.
- backlog #24 (`defgeneric + method 同時定義`) と類似 pattern の
  generalization。並列扱いで OK。

**期待効果**: 104 step 0/1 + 102 step 0 等で 1-2 turn 短縮。複数 fixture
で recurring なので effect 範囲広い。

**コスト**: small + half-day（prompt 1 段落 + fixture re-bench）。

### 39. impl-review-stage で「test の全 symbol カバー」明示 check

**Source**: bench-cycle 2026-05-24, fixture(s) 104-cache-simple
**Axis**: implementation

**観察**: 104 step 0 で 1 patch 後 verify-fail の reason が `MAKE-CACHE
undefined`。test を読めば「make-cache を呼んでいる」と分かるはずだが
agent は defclass で完了したつもりに。impl-review (`:auto` / `:light`
で keep される) が catch すべきだが現状は test の symbol enumeration
を明示的 check 項目に持たない。

**仮説**: impl-review prompt に「test source の全 symbol が defined か」
を明示的 check 項目として追加すれば、incomplete impl を early reject
できる。

**変更案**:
- `src/review.lisp` の `review-development-artifact` に渡される
  impl-review prompt の check 項目に追加:
  > Does the implementation define every symbol the test references?
  > Walk through the deftest body and enumerate.
- reject 時の feedback で `missing: X, Y` を具体的に返す

**期待効果**: incomplete-impl pattern を impl-review が早期 catch。但し
impl-review LLM call 自体は cost なので effect / cost trade-off は
measure 必要（#38 prompt 変更が成功すればこの review check は不要に
なる可能性もある）。

**コスト**: medium + 1 day（prompt 修正 + bench で reject rate 観察）。

---

## 2026-05-24 bench-cycle 由来 (102-counter-class + 104-cache-simple, #38 verification cycle)

bench-cycle で #38 (patching-guidance) の empirical effect 測定を試みた結果、両 fixture とも
agent loop に到達せず measurement 不能。但しその過程で 2 件の latent bug を発見・修正、
さらに今回の failure pattern から 5 件の新規 backlog 候補を抽出。

**実装済 (本 cycle 副産物)**:
- spec-generator が array-of-objects JSON shape を accept できるよう拡張 (`src/review.lisp`)
- CLI の max-tokens 転送で nil が #33 の 8192 default を override してしまう bug を修正
  (`src/cli.lisp` fix/bench/develop 3 か所、`apply` 経由で nil 時 kwarg 省略)

results doc: `docs/benchmarks/results-2026-05-24-bench-cycle-102-counter-class-104-cache-simple.md`

### 40. complete-chat: empty content / http-client-error 時の透過的 retry

**Source**: bench-cycle 2026-05-24, fixtures 102-counter-class / 104-cache-simple
**Axis**: cl-harness 実装

**観察**: gpt-oss-20b (Groq) を reasoning model として使う develop 連続 LLM 呼び出しで
sporadic に以下が発生:
- review LLM call が `content=""` を返却 → `review JSON decode failed: end of file`
- agent turn-1 LLM call が HTTP client error を返却 → develop-result `:STATUS :ERROR`

いずれも非決定的で、同 prompt の直接呼び出しは 5/5 成功するが workflow 中ではしばしば失敗。

**仮説**: model server 側の transient flakiness。1 回の自動 retry で recoverable な
ケースが多い。現状の retry layer は HTTP-status-non-200 や timeout は拾うが、
status=200 + content="" や transport-level error の分類は再試行に流れない。

**変更案**:
- `complete-chat` の retry classifier に `:empty-content` を追加 (status=200 + content="" の時)
- `:http-client-error` を transient と分類して 1 回 retry
- 既存 #35 (response prefix sanity check) と統合検討 — どちらも「無効応答 → 即 retry」

**期待効果**: bench-cycle で empirical 測定が完走する確率を上げる。reasoning model 利用時
の usability が大幅に改善。

**コスト**: medium + 1-2 days (classifier 拡張 + retry-budget 管理 + #35 と統合)。

### 41. planner test stub: 未定義 helper (exported-symbols 等) を含めない

**Source**: bench-cycle 2026-05-24, fixtures 102-counter-class (v4) / 104-cache-simple (v3)
**Axis**: cl-harness 実装 (planner prompt)

**観察**: 両 fixture の step-0 で planner が生成した test に
`(exported-symbols :package)` を呼ぶ assertion が含まれていたが、fixture には
`exported-symbols` helper が定義されていない。verify は `EXPORTED-SYMBOLS is undefined`
で失敗 → agent が turn-1 でこの helper を実装するか test を rewrite するかの判断を
迫られ、無駄な複雑性が増える。

**仮説**: planner prompt が「test 内で標準 CL 関数のみ使え」「未定義 helper を assume するな」
と明示していない。planner LLM が「test 風」の syntactic sugar を勝手に発明している。

**変更案**:
- `src/planner.lisp` の test-generation prompt に明示:
  > Tests must use only standard CL functions and symbols defined in the project's
  > main package. Do NOT invent helper functions like `exported-symbols`. To check
  > exports, use `(find-symbol "NAME" :pkg)` and verify external status manually.
- regression test: planner output に `exported-symbols` 等の未定義 symbol が含まれない確認

**期待効果**: step-0 で「helper を実装するか test を rewrite するか」の無駄判断を回避。
複数 fixture で stable に step-0 を passable に。

**コスト**: small + half-day (prompt 修正 + planner-test 更新)。

### 42. plan-review phase JSONL event を追加 (MAX-REVIEW-REPLANS の理由可視化)

**Source**: bench-cycle 2026-05-24, fixture 104-cache-simple (v4)
**Axis**: log content

**観察**: 104 v4 が `:LIMIT-EXHAUSTED :MAX-REVIEW-REPLANS` で死亡したが、develop-level
JSONL が空 (file 自体不存在)。理由: develop の logger は plan-review phase 通過後に
open される設計のため、plan review で限界到達した時の reject feedback が記録されない。

**仮説**: plan review 用の logger を pre-emptively 開けば、reject feedback が log 化され、
何が問題で review-replans を消費したかが diagnose 可能になる。

**変更案**:
- `src/orchestrator.lisp:%plan-with-review` で logger を即時 open するか、
  per-call の `plan-review` event を別 sink (例: stderr / 専用 file) に emit
- event fields: `revision_count`, `decision_status`, `feedback_excerpt`, `replan_remaining`
- LIMIT-EXHAUSTED on MAX-REVIEW-REPLANS 時は最後の reject feedback を summary に含める

**期待効果**: 「plan review で何が拒否されたか」を post-hoc に確認可能に。bench-cycle
diagnose 効率が大きく改善。

**コスト**: small-medium + 1 day (logger lifecycle 整理 + event schema 拡張 + test)。

### 43. CLI default の max-tokens を 8192 (model.lisp default と integration)

**Source**: bench-cycle 2026-05-24, 全 fixture (本 cycle で fix 済)
**Axis**: cl-harness 実装

**観察**: `src/cli.lisp` の develop/fix/bench は `max-tokens` を kwarg として受け取るが
default が nil、それを `:max-tokens nil` として `make-openai-provider` に forward すると
#33 で設定した `(max-tokens 8192)` default を override。結果として CLI 経由で
reasoning model を使うと content="" が頻発した。

**今回の応急処置**: 3 か所で `apply` + `(when max-tokens (list :max-tokens max-tokens))`
パターンに変更し、CLI 側 nil 時は kwarg を省略するよう修正済。

**未対応**: 同パターンの latent bug が他 kwarg にも存在する可能性
(`reasoning-effort`, `extra-body`, `read-timeout` 等の現在 default nil のもの)。
明示的 nil で opt-out したいケースと未指定で fallback したいケースの区別が
contract 上曖昧。

**仮説**: kwarg forward の意図を 1 箇所で正規化 — 例えば cli helper
`%provider-kwargs-from-cli` を導入して「nil = 未指定」を明示的に扱う。

**変更案**:
- CLI helper を 1 関数に集約
- `make-openai-provider` の docstring で「nil = explicit opt-out, missing = default」
  を明示
- regression test: CLI-via-bench が reasoning model で content を返すこと
  (provider mock で検証可)

**期待効果**: 同種 latent bug の再発防止。reasoning-effort 等の今後の追加 kwarg も
safe に扱える。

**コスト**: small + half-day (helper extraction + docstring + regression test)。

### 44. bench-cycle driver template: max-tokens 明示と reasoning-effort 制御

**Source**: bench-cycle 2026-05-24, 全 fixture
**Axis**: bench target

**観察**: bench-cycle skill の driver.lisp.template が `develop` を呼ぶ時、
`:max-tokens` も `:reasoning-effort` も指定していない。reasoning model 利用時に
content="" / http-client-error の遭遇率が高い。driver で明示的に control したい。

**仮説**: driver template が `:max-tokens 16384` と `:reasoning-effort "low"` を
明示すれば、reasoning model でも completion-token に十分な budget が確保され、
sporadic な empty-content failure を抑えられる。

**変更案**:
- `.claude/skills/bench-cycle/templates/driver.lisp.template` の `cl-harness:develop`
  呼び出しに `:max-tokens 16384 :reasoning-effort "low"` を追加
- skill argument に `--reasoning-effort low|medium|high` を追加 (default low)

**期待効果**: bench-cycle が reasoning model でも安定して完走するように。
empirical 測定の S/N 比改善。

**コスト**: small + 1 hour (template 編集 + skill 引数追加)。

### 45. ~~agent patch が `ok=False` で連続する場合の早期 give-up~~ → 実装済 (2026-05-24)、empirical effect は variance に埋もれ未確認

**Status**: ✅ **実装済 (fd02eaa)** — `run-limits` に `max-consecutive-failed-patches`
(default 3) を追加、`agent-state` に `consecutive-failed-patches` streak counter を
追加。`handle-tool-call` で source-mutating tool の `isError=true` 時に increment、
success 時に reset。`check-limits` で streak が limit に達したら
`:limit-exhausted` (`limit-hit :max-consecutive-failed-patches`) を返す。

tests: 2 件追加 (TDD)。cl-harness/tests 464 passed.

**Empirical effect (102/103/104 × N=3 verification on fd02eaa)**:
- Total wall-clock: 9766s → 6362s (-35%)
- Pass rate: 4/9 (44%) → 6/9 (67%)
- >2000s pathological runs: 3 → 0
- **但し `:MAX-CONSECUTIVE-FAILED-PATCHES` 発火は 0/9** — 改善は variance / 他要因 (
  spec-generator robustness + CLI max-tokens fix の波及) の可能性。
- max consecutive failed patches observed in any step: 3 (但し step 全体が PASSED に
  軟着陸し、新 limit fire せず)
- 真の causation は fixed-plan paired bench (#46) 実装後に再評価

詳細 doc: `docs/benchmarks/results-2026-05-24-45-verification-102-103-104.md`

**元 entry**:



**Source**: bench-cycle 2026-05-24, fixture 102-counter-class (Qwen3.6 v3 run)
**Axis**: cl-harness 実装

**観察**: 102 の plan 2 / plan 3 で agent が出力した patch が 3-5 連続で `ok=False` (parinfer
auto-repair / token-match で reject)。失敗 patch ごとに verify が COMPILE-FILE-ERROR を返し、
agent はそれを修正しようと更に malformed patch を出す悪循環。最終的に :MAX-PATCHES exhaustion。

**仮説**: `lisp-edit-form` / `lisp-patch-form` が連続して `ok=False` を返したら「agent の patch
戦略がそもそも崩壊している」signal なので、早期に :GIVE-UP に流したほうが他 step の budget を
温存できる。

**変更案**:
- orchestrator で連続 `ok=False` patch 数を track
- N (例: 3) 連続したら次 turn で `give_up` finish を agent に強制 OR step を :limit-exhausted で終了
- tool-error feedback に「your last 3 patches failed structural validation; consider giving up」
  hint を追加

**期待効果**: pathological patch 連発時の wall-clock 節約。multi-step plan の場合 step 0 の浪費を
抑え、後続 step の budget を確保。

**コスト**: small + half-day (counter + early-termination + regression test)。

### 46. fixed-plan paired bench infrastructure (planner 確定化)

**Source**: bench-cycle 2026-05-24 paired #38 on/off run
**Axis**: bench target

**観察**: paired #38 on/off bench で同 fixture (104-cache-simple) でも planner が 3 種類の異なる
plan を生成 (3 steps×1-sym / 3 steps×multi-sym step1 / 1 step×implicit multi-sym)。
agent 行動の controlled comparison が不可能になり、prompt 変更の empirical effect が高 variance に
埋もれた。

**仮説**: planner の出力を fixture 側で predefined plan として与えれば (planner を skip)、
agent 段階の prompt 変更 (#38 のような) を pure に paired evaluation できる。

**変更案**:
- `develop-task.json` に optional `predefined_plan` field を追加
- `cl-harness:develop` に `:predefined-plan` kwarg 追加 (provided なら planner を bypass)
- bench-cycle skill の test cases に「multi-symbol step」「single-symbol step」両方を含む
  predefined plan を用意
- ON / OFF で N=3 ずつ走らせて wall-clock / turn / patch を比較する script を skill に追加

**期待効果**: prompt 変更の empirical effect を高 S/N で測定可能になる。#38 / #41 / #45 等の
prompt-level 改善 backlog で再現性のある evaluation が可能。

**コスト**: medium + 1-2 days (develop-task schema 拡張 + develop kwarg 追加 + skill template 拡張)。

### 47. review JSON parse: invalid escape を tolerate / retry

**Source**: bench-sweep N=3 2026-05-24, fixture 104-cache-simple trial3
**Axis**: cl-harness 実装

**観察**: 104-cache-simple trial3 で review-development-artifact 内の `complete-chat` が
返した JSON 文字列に `"\a"` のような invalid JSON escape sequence が含まれ、yason が
`ECASE fell through. Wanted one of (#\" #\\ #\/ #\b #\f #\n #\r #\t #\u)` で reject。
bench が 168s で ERROR abort。

**仮説**: LLM (Qwen3.6) が時々 non-standard escape (`\a` 等) を出力する。yason は strict
JSON parser なので invalid escape を receive すると hard error。

**変更案**:
- `src/review.lisp` の review JSON parse path で 2 段階処理:
  1. 元 string を直接 yason に渡す (現状)
  2. yason error 時、invalid escape sequence をサニタイズ (例: `\a` → `a`, `\<bad>` →
     `<bad>`) してから retry
- もしくは LLM call を 1 回 retry してから fail させる (backlog #40 と統合可能)
- regression test: invalid escape を含む文字列が review-error なく parse される

**期待効果**: sporadic な model output anomaly で bench が abort しなくなる。
N=3 sweep で 1/21 観測 (5%) → 削減できれば pass rate に直接寄与。

**コスト**: small + half-day (sanitize util + review error path + test)。

---

## 2026-05-24 bench-sweep N=3 結果 — system-wide pass rate baseline

main @ 0368f1e で 7 fixtures × 3 trials = 21 cells を実施 (Qwen3.6, ~5 hours wall-clock)。

**Aggregate pass rate: 8/21 = 38%**

| Fixture | Pass | 主要 failure mode |
|---|---:|---|
| 100-greet | 1/3 | :GIVE-UP / :LIMIT-EXHAUSTED |
| 101-double | 1/3 | :LIMIT-EXHAUSTED / :STUCK |
| 102-counter-class | 1/3 | :LIMIT-EXHAUSTED / :GIVE-UP |
| 103-fizz-buzz | 2/3 | :STUCK (1 run only) |
| 104-cache-simple | 1/3 | :LIMIT-EXHAUSTED / ERROR (yason) |
| 105-validate-email | 1/3 | :LIMIT-EXHAUSTED / :STUCK ← **初の :PASSED 観測** |
| 106-format-currency | 1/3 | :LIMIT-EXHAUSTED / :STUCK |

主要 findings:
- trivial fixture (100, 101) でも 1/3 pass で **system 全体が不安定**
- 高 wall-clock 浪費 (>2000s) の failure が複数 → backlog #45 (連続 ok=False 早期 give-up) 適用候補
- 新規 #47: yason invalid escape sequence で review JSON decode fail (1/21)
- #38 effect は依然測定困難 — fixed-plan paired bench (#46) 実装後に再評価

詳細 doc: `docs/benchmarks/results-2026-05-24-bench-sweep-n3.md`

---

## 2026-05-24 paired #38 on/off bench 結果 — #38 entry refinement

backlog #38 (`docs/improvement-backlog.md:1018` 付近) について、2026-05-24 に Qwen3.6 で
paired N=1 bench を実施 (104-cache-simple, branch `bench-38-off` を一時作成して比較)。
結果:

- structural inclusion: ✅ agent system prompt に "Patching guidance" 含むことを JSONL で確認
- empirical effect: ❌ **observe されず**
  - OFF run の multi-symbol step 1 (cache-put + cache-get test) で **evolved-failure
    pattern 発生** (turn 3: CACHE-PUT undef → turn 4: CACHE-GET undef → turn 5: pass)
  - ON re-run の multi-symbol step 0 でも **同じ evolved-failure 発生**
    (turn 11: MAKE-CACHE undef → turn 12: CACHE-GET undef → turn 13: pass)
- wall-clock: OFF 556s / ON 571s で差 ±3% (noise 範囲)

agent が #38 directive ("test の全 symbol を 1 patch でまとめろ") を遵守する行動は
ON/OFF 共に取らず。当面 #38 prompt section は維持 (negative effect も無いため削除コストの方が大きい)
だが、prominence 強化 / N≥3 + fixed plan での再評価 (本 backlog #46) が follow-up 課題。

詳細 doc: `docs/benchmarks/results-2026-05-24-bench-cycle-38-paired-104.md`

