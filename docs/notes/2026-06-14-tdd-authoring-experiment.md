# TDD authoring (authoring-policy) e2e 記録 — 2026-06-14

`cl-harness-next` の **test-authoring** フェーズ(`authoring-policy`、spec
2026-06-14)を、決定論的な 12 件の canned テストではなく**実機の弱モデル
(local Qwen)で end-to-end** に駆動した記録。FSM の正しさは canned テストで
証明済みのため、本実験の問いは「弱モデルが authoring フェーズ
(author → RED-first → review → fix)を実際に最後まで回せるか」。

結論: **`:done` に到達せず(`STATUS: FAILED`)**。ただし失敗の根本原因は
Qwen の能力ではなく、`authoring-policy` が `fs-write-file` を**誤った引数キー
`file_path` で呼ぶハーネス側のバグ**(cl-mcp の必須キーは `path`)。Qwen は
**初回 author で正しい失敗テストを書けていた**。Task 10 の成果物(runner +
fixture + 本ノート)は結果に関わらずコミット対象。

## 設定

- runner: `tools/run-tdd.lisp`(standalone `ros run --load`。ミッションは自前で
  cl-mcp stdio 子を spawn するため repl-eval 下では worker pool が無効化され
  不可)。
- モデル: ローカル vLLM `Qwen/Qwen3.6-35B-A3B`(OpenAI 互換)。
  エンドポイントが広告する model id は `Qwen/Qwen3.6-35B-A3B`(`Qwen/` 接頭辞
  あり、`GET /v1/models` で確認)。`enable_thinking:false` を
  `extra-body.chat_template_kwargs` で送出。
- fixture: `~/.roswell/local-projects/clh-demo/`(package-inferred-system + rove)。
  - `src/main.lisp`: スタブ `(defun add (a b) (declare (ignore a b)) 0)`
    (定数本体 = template-fix が穴と認識できる形)。
  - `tests/main-test.lisp`: defpackage スケルトンのみ(deftest なし。policy が
    追記する)。
  - sanity: `(add 2 3)` → `0`(red-ready)を確認済み。
- ミッション goal: `Implement (add a b) to return the sum a+b, with tests.`
  acceptance: `clh-demo/tests is green`。
- governor: `:max-actions 300`、stall 系カウンタはすべて nil(authoring 専用の
  長い軌道を許容)。

### facade シンボルの確認

runner は `:use #:cl-harness-next` で以下を unqualified 使用。すべて
`next/src/main.lisp` の facade から export 済みで、**追加の package 修飾は不要**:
`mission-goal` `make-openai-provider` `make-judge-fn`
`make-cl-mcp-environment` `mission` `mission-queue` `enqueue-mission`
`run-mission` `governor`。`authoring-policy` / `review-oracle` /
`template-fix-policy` / 各 system-prompt 定数は元から package 修飾で参照。

## 実行コマンド

```bash
CL_HARNESS_LLM_BASE_URL=http://192.168.0.17:8000/v1 \
CL_HARNESS_LLM_API_KEY=dummy \
CL_HARNESS_LLM_MODEL=Qwen/Qwen3.6-35B-A3B \
MCP_PROJECT_ROOT=$HOME/.roswell/local-projects/clh-demo \
ros run --load tools/run-tdd.lisp
```

- STATUS: `FAILED`
- REASON: `could not author acceptable tests: unbalanced/unreadable reply:
  Package CLH-DEMO/SRC/MAIN does not exist.`
- log: `/tmp/tdd-3990374948.jsonl`(11 イベント)

## ログの読み(seq 単位)

| seq | type | 内容 | 判定 |
|-----|------|------|------|
| 1 | run_start | goal/acceptance | — |
| 2-4 | decision/action/obs | `fs-read-file src/main.lisp` → スタブ本文取得 | OK |
| 5-7 | decision/action/obs | `fs-read-file tests/main-test.lisp` → スケルトン取得 | OK |
| 8-9 | decision/action | `fs-write-file` で **authored deftest を書こうとする** | author 成功 |
| 10 | observation | `{"error":"path is required"}` | **書込失敗(arg key)** |
| 11 | decision | give-up(再 author で package 修飾シンボル read 失敗) | 死亡 |

### Qwen が初回 author で書いたテスト(seq 9 の write 引数)

```lisp
(deftest test-add-basic
  (ok (= (add 2 3) 5))
  (ok (= (add -1 1) 0))
  (ok (= (add 0 0) 0))
  (ok (= (add 10 -5) 5)))
```

これは goal を正しく表現した**スタブに対して落ちる**テストで、`extract-deftest-forms`
の検証も通過している(検証を通ったからこそ write 段階に進んでいる)。markdown
fence も prose も無く、shape も system prompt 通り。**author フェーズ自体は
Qwen で成立していた**。

## フェーズ別の結果

| フェーズ | 結果 | 根拠 |
|----------|------|------|
| author | **成功** | seq 9 に妥当な deftest。`extract-deftest-forms` 通過済み |
| (test 書込) | **失敗** | seq 10 `path is required` = ハーネスが `file_path` で呼んだ |
| RED-first | 未到達 | 書込が失敗したため run-tests に到達せず |
| review | 未到達 | 同上 |
| fix(template) | 未到達 | 同上 |

## 発見(根拠付き)

### F1.(根本原因)authoring-policy が `fs-write-file` を誤キー `file_path` で呼ぶ

`next/src/authoring-policy.lisp` の **2 箇所**が cl-mcp の必須引数キーを
取り違えている:

- `%author`(L220-223): `(%act "fs-write-file" (list "file_path" ... "content" ...))`
- `%ensure-skeleton`(L185-187): 同じく `"file_path"`

cl-mcp `fs-write-file` の schema は `{path (required), content (required)}`
で、`file_path` は未知キー → 必須 `path` 欠落 → `"path is required"`。
よって **authoring-policy が emit する全 `fs-write-file` が失敗する**。
今回はスケルトンが既存(`(in-package` を含む)だったため `%ensure-skeleton`
は write をスキップし `%author` 直行、その `%author` の write で露出した。

これは 2026-06-13 の複雑タスク実験 run #6 で見つかった
`lisp-read-file` を `file_path` で呼ぶバグと**同系統**(harness 側のツール
引数キー不一致)。authoring-policy にも同じ系統が残っていた。

### F2.(二次症状)再 author 時、package 修飾シンボルが CL-USER read で死ぬ

write 失敗 → `%author-written` → `%regenerate` → 再 author。その再試行で
Qwen は package 修飾シンボル(`clh-demo/src/main:add` → upcase
`CLH-DEMO/SRC/MAIN`)を含む deftest を返し、`extract-deftest-forms` は
これを CL-USER・`*read-eval*` nil で read するため
`Package CLH-DEMO/SRC/MAIN does not exist.` で例外 → これが最終 give-up
reason になった。**give-up に表示された reason は二次症状**であり、真の
ブロッカーは F1。

(F2 は F1 を直せば通常は発生しない経路だが、`extract-deftest-forms` が
未ロードの package 修飾シンボルで read エラーを起こす点自体は、弱モデルが
たまに package 修飾で返す現実に対して脆い。author system prompt は既に
「Reference the code under test by the symbols shown」と指示しているが、
強制力はない。)

## 評価 — Qwen は authoring フェーズを回せたか

- **author 単体: 回せた。** 初回で goal を表す妥当な失敗テストを、prose/fence
  なしの正しい shape で生成し、検証も通過した。
- **end-to-end: 未達。** ただし停止点は Qwen ではなくハーネスの `fs-write-file`
  引数キーバグ(F1)。このバグがある限り、どのモデルでも authoring は test 書込で
  必ず止まる。
- **prompt チューニングの必要性:** author prompt は現状で機能している(初回成功)。
  F2 を考えると「未ロード package を修飾参照しない / 素のシンボル名で書く」を
  prompt にもう一段明示する余地はあるが、F1 を直すまでは判断材料が不足。

## 次アクション(本 Task のスコープ外。記録のみ)

1. `authoring-policy.lisp` の `%author` / `%ensure-skeleton` の
   `"file_path"` → `"path"` 修正(F1)。canned テストは MCP 実環境ではなく
   record した interaction で回っているため、このキー不一致を捕捉できていない
   可能性が高い — 実環境キーに整合する fixture/契約テストの追加が望ましい。
2. F1 修正後に本 runner を再走し、RED-first / review / template-fix の各
   フェーズを初めて観測する。
3. 必要なら `extract-deftest-forms` を package 修飾シンボルに対して頑健化
   (read エラーを「素のシンボルで書け」という feedback に変換して再 author)。

---

## 追記 — F1 修正後の再走(2026-06-14, controller)

F1(arg key)を修正し(`%author`/`%ensure-skeleton` の `"file_path"` → `"path"`)、
canned transport も `fs-write-file` を `path` のみで解釈するよう厳格化(回帰を
捕捉)。canned 全 301 件緑のまま。fixture をクリーン(スタブ `add`→0、deftest 無し
スケルトン)に戻して**再走**したところ、**新たな根本ブロッカー F3** を発見。

### F3.(設計レベル)`fs-write-file` は既存 `.lisp` を上書きできない

```
;;; STATUS: FAILED
;;; REASON: ... writing tests failed: MCP error -32602:
  Cannot overwrite existing .lisp/.asd with fs-write-file; use lisp-edit-form.
```

cl-mcp の `fs-write-file` は**既存の `.lisp`/`.asd` の上書きを拒否**する安全ガードを
持つ(新規作成は可)。本設計の「毎 attempt、テストファイル全文を `fs-write-file` で
書き直す(base-content + deftests)」方式は、テストファイルが**既に存在する**(=
通常ケース。本 fixture もスケルトンが既存)と**第一書込から失敗**する。canned
transport がこのガードを模していなかったため、canned テストでは緑だった。

つまり計画の **write 機構自体が cl-mcp と非互換**。FSM のコア(author → RED-first →
review → fix 委譲、相分離による integrity)は canned で証明済みだが、実機の
テストファイル書込は別機構が要る。

### 提案する再設計(fixed-name placeholder + `lisp-edit-form` replace)

- スケルトン(新規作成 or scaffold 提供)に**固定名のプレースホルダ deftest**を含める:
  `(deftest clh-tdd-authored (ok nil))`(失敗するので最初から red、ロードも通る)。
- `%author` は Qwen の deftest 本体(assertion 群)を抽出し、固定名で再ラップ
  `(deftest clh-tdd-authored <assertions>)` して **`lisp-edit-form` の replace で
  固定名フォームを置換**(新規 file のみ `fs-write-file` でスケルトン作成)。
- これにより (a) 既存 `.lisp` 上書きガードを回避、(b) regenerate が同じ固定名の
  replace で完結(重複 deftest 累積も anchor 追跡も不要)、(c) RED-first は固定名
  `CLH-TDD-AUTHORED` を `failed_tests` に探す。
- canned transport に `lisp-edit-form` replace のモデル化と「既存 `.lisp` への
  `fs-write-file` は isError」ルールを追加し、この機構を契約テストで固定する。

この再設計は write 機構に限定された変更だが、`%author`/`%ensure-skeleton`/
スケルトン/RED-first 名/canned transport/一部テスト/fixture に及ぶため、
Task 10 の当初スコープを超える(計画の write 機構の誤りに起因)。controller が
human にエスカレーション(subagent-driven の「plan が誤りなら escalate」規定)。

### 確定した事実

- **F1(arg key)は実バグで修正済み**。canned transport を実環境キーに整合させた。
- **Qwen は author 相を回せる**(初回で goal 正しい失敗テスト生成、再現)。
- **残るブロッカーは F3(write 機構)**で、上記再設計が必要。RED-first 以降
  (review / template-fix)の実機観測は F3 解消後に持ち越し。
