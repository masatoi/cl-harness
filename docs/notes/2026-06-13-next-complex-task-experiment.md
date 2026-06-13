# cl-harness-next 複雑タスク dogfooding 記録 — 2026-06-13

`cl-harness-next` を、1行バグ修正(clh-demo)より重い「**既存 CLOS クラスの複数
メソッドを実装してテストを緑にする**」タスクで連続運転し、scripted と adaptive
(+ guided) を比較した記録。6 回の実走はいずれも `:done` に到達しなかったが、
各失敗が**段階的に別々の欠陥を1つずつ露出**し、ハーネス側の改善候補を明確にした。
所見は本ファイル末尾の優先度付きリストと `docs/improvement-backlog.md` に反映。

## 設定

- モデル: ローカル vLLM `Qwen/Qwen3.6-35B-A3B`(OpenAI 互換、`enable_thinking:false`)
- 題材: `~/.roswell/local-projects/clh-histogram/`(package-inferred-system + rove)。
  `histogram` クラス(slot `table` = `make-hash-table :test 'eql`、accessor
  `histogram-table`)に対し `observe` / `count-of` / `total` / `distinct` /
  `top-key` の 5 つの **defmethod がスタブ**(`0`/`nil` を返す)。`deftest` は
  10 アサーション(全て値比較、condition 不使用)。ベースラインは 8 失敗。
- 実行: standalone `ros run --load`(ミッション級ジョブは repl-eval 不可)。
  dial は env `CLH_DIAL` で切替。診断/ステップ関数は `make-judge-fn` +
  スキーマ追記済み system prompt(scripted は `+scripted-fix-system-prompt+`、
  guided は `+guided-system-prompt+`)。

## 実験の流れ — 段階的診断チェーン

各 run の失敗が次の障害を露出し、1 つ潰すと次が出る、という連鎖になった。

| # | dial | 構成 | 結果 | 根本原因 |
|---|------|------|------|----------|
| 1 | scripted | 素 | `:failed`(初回診断) | action-parse-error: JSON decode 失敗(`#\t fell through ECASE`)= モデルが不正 JSON |
| 2 | adaptive | 素 | `:failed`(step 1) | action-parse-error: EOF(guided 初手が空/切断応答)。**demote されず**死亡 |
| 3 | scripted | robust(retry) | `:failed` | `unknown action type: lisp-edit-form`(type にツール名)。素朴 retry で同一誤りを反復 |
| 4 | scripted | robust+normalize | `:parked`(4 連続失敗パッチ) | `file_path` が `src/class.lisp`(存在しない。実体は `main.lisp`) |
| 5 | scripted | robust+normalize+workspace | `:parked`(同上) | `form_type defun / form_name observe` → "Form not found"(実体は defmethod) |
| 6 | guided | robust+workspace | `:parked`(同一アクション 5 連) | `lisp-read-file` を `file_path` で呼ぶ(必須引数は `path`)→ 同一失敗ループ、**ファイルを一度も読めず** |

## 発見(根拠付き)

### H1. action パーサが fail-closed — 不正応答 1 回でミッション全体が死ぬ

scripted の `%diagnose`、guided/self-directed の `%llm-step` はいずれも
`parse-action` 失敗時に即 `%give-up`(= `:given-up` → mission `:failed`)。
run 1 はベースライン検証(緑/赤判定は健全)の直後、**最初の診断 LLM 応答が
不正 JSON だった1点**でミッション全体が落ちた。

**parse 信頼性の実測**(同一 prompt を 6 回):OK 4 / 不正 2 ≈ **33%**。
形状は ①整形/圧縮 JSON(OK)②` ```json ` フェンス(パーサが除去するので OK)
③`"type":"<toolname>"`(却下)④content 内エスケープ漏れ/EOF。
5 メソッド = 5 回以上の診断が要るため、33% でも途中失敗確率は
1−0.67⁵ ≈ **86%**。観測と一致。
(backlog 既存項目「llm-step-policy の fail-closed 寛容度」の実データ初取得。)

### H2. adaptive は give-up では demote しない — 主要 failure mode に無力

adaptive の降格は **governor の `progress-stalled` 介入**を契機にする。一方
parse 失敗や model give_up は `:give-up` decision で、governor 介入ではない。
run 2 は guided の **step 1**(初手が LLM 呼び出し)で空応答 → give-up →
`dial` イベント 0、**一度も scripted に降りずに `:failed`**。
adaptive は「弱構成が誤引数パッチで停滞 → demote」型は救えるが、
「LLM I/O が壊れて give-up」型は救えない。後者の方が弱モデルでは支配的。

### H3.(最重要)許可ツールの引数スキーマがモデルに渡っていない

全 run を貫く根本原因。environment は tools/list の **inputSchema を含む
descriptor を保持**(`environment-tools` / `environment-action-space`)している
のに、`compile-context` が作る view にも system prompt にも出していない。
モデルは各ツールの引数名を**推測**するしかなく、小モデルは外す:

- `lisp-edit-form` は `file_path`(私が prompt に明示) → モデルは正しく使えた。
- `lisp-read-file` は必須が `path` なのに、モデルは `file_path` を流用(run 6)
  → "path is required" を 10 連発 → 同一アクションガードで park、**ファイル未読**。
- `lisp-edit-form` の `form_type`/`form_name` も、既存定義を見られないため
  `defun observe`(実体は `defmethod observe ((h histogram) key)`)と誤る(run 5)。

cl-mcp ではファイルパス引数の名前すらツール間で違う(`file_path` vs `path`)。
**許可ツールの name + パラメータ(必須/型)を context に注入**するのが最大レバレッジ。

### H4. view にワークスペース/既存定義が無い → 存在しないファイル・フォームを叩く

failure-analysis view は run-tests 失敗(form と got 値)を**良質に**伝える
(下記 positive)が、**どのファイルに何が定義されているか**を含まない。
run 4 はモデルが `src/class.lisp`(histogram=class という連想)を patch →
"file does not exist" → 4 連敗 park。実体は `main.lisp`。
ワークスペースのソースファイル一覧 + 失敗シンボルの定義箇所/既存フォームを
view に載せれば、ファイル名とフォーム種別の取り違えが消える。

### H5. scripted(read ステップ無し)は「既存定義への整合実装」に構造的に不適

scripted FSM は verify→diagnose→patch のみで**ソースを観測しない**。run 4/5 で
モデルは存在しない accessor(`histogram-data`)や cons 表現を捏造し、既存クラス
(slot `table`、accessor `histogram-table`)に整合しない実装を書いた。
**clh-demo の演算子 1 個差し替えのような「ゴールから自己完結する局所修正」には
scripted が向くが、「既存の型/総称関数に合わせて実装する」には read 可能な dial
(guided/self-directed + runtime-native + 実際に読む)が要る。** ただしその dial は
H1/H3 に阻まれる(run 6)。spec の「自律度はモデル能力に合わせる」に加え、
**「タスク種別(局所修正 vs 整合実装)にも dial を合わせる」**必要を示す。

### positive(機能している部分)

- **失敗 view の品質**: run-tests の失敗は番号付きで form と got 値を列挙し、
  モデルが次に直す対象を選ぶのに十分(`Expect (= 1 (OBSERVE H :A)) ... Got: 0`)。
  ボトルネックは観測層ではなく**行動 I/O 層**。
- **governor の futility ガードが正しく機能**: 失敗パッチ連続(run 4/5)と
  同一アクション連発(run 6)を検出して park。無限ループにはならない。
- **clean gate / 検証オラクルは健全**: 緑/赤判定、clear_fasls、clean 検証は
  clh-demo 同様に正しく動作(誤判定なし)。

## 緩和の実証(caller 側)

ハーネス改修前でも、診断/ステップ関数を次でラップすると parse 層は越えられた
(H1/H6 の方向性を裏付け):

- **parse-retry**: 応答を `parse-action` で検証し、失敗なら最大 K 回 LLM を
  叩き直す(的を絞った訂正ヒント付き)。
- **type 正規化**: `"type"` が未知でも非空の `"tool"` があれば `"tool_call"`
  に書き換える(run 3 の `"type":"lisp-edit-form"` を救済)。既存の
  フェンス除去・flat-arguments フォールバックと同じ「寛容化」系統。

これで run 4–6 は parse 層を通過し、障害は H3/H4/H5(引数・ワークスペース・
dial 適合)へ前進した。**parse 寛容化だけでは完走しない**ことも確認(行動の
意味的正しさは別問題)。

## ハーネス改善提案(優先度付き)

1. **(高)許可ツールのスキーマを context に注入**(H3)。environment が既に持つ
   tools/list inputSchema から、許可ツールの name + 必須/任意パラメータを
   compiled view か system prompt に出す。最小モデルの誤引数を根絶。
2. **(高)action パーサの寛容化 + パース失敗の K 回許容**(H1/H6)。
   ①`strip-code-fence`/flat-args に続けて「type 未知 + tool あり → tool_call」
   正規化を `parse-action` に追加。②policy が parse 失敗で即 give-up せず、
   エラーを `last-action-error` に載せて K 回まで継続(give-up は K 回連続失敗時)。
3. **(中)adaptive の demote 契機に give-up/parse 失敗を含める**(H2)。
   `progress-stalled` だけでなく「policy が give-up を返した」も降格トリガに
   する(最自律 dial が I/O で詰まったら下げる)。
4. **(中)view にワークスペース情報**(H4)。ソースファイル一覧 + 失敗シンボルの
   定義箇所/既存フォーム(form_type 含む)を載せる。
5. **(設計)dial 選択をタスク種別にも対応**(H5)。「整合実装」系は read を要する
   旨を guided agenda/ドキュメントに明示。scripted を既存定義タスクの既定にしない。

## 残課題 / 次の実験

- 上記 1+2 を実装して同題材を再走し、guided/adaptive が `:done` に届くか測定。
- より強いモデル(クラウド)で同題材を走らせ、失敗が「モデル能力」か「ハーネス
  契約」かを切り分ける(H1/H3 はモデル非依存のはず)。
- 題材 `clh-histogram` は再利用可能な「整合実装」fixture として残置
  (`~/.roswell/local-projects/clh-histogram/`、スタブ状態)。
- 関連: `docs/notes/2026-06-13-live-fire-experiments.md`(clh-demo 1行修正の記録)、
  spec `docs/superpowers/specs/2026-06-11-autonomous-harness-redesign-design.md`、
  チュートリアル `next/README.md`。

## 実装フォローアップ(同日): N1+N2 を実装し再走

提案 1(N1: ツールスキーマ注入)と 2(N2: パーサ寛容化 + パース失敗の K 回許容)を
TDD で実装(全 260 テスト緑、mallet クリーン、`compile-system :force t` 警告なし)。

**実装内容**
- N2a `parse-action` 正規化: `type` 未知でも非空 `tool` があれば `tool_call` 扱い
  (`next/src/action.lisp`、test `unknown-type-with-tool-is-treated-as-tool-call`)。
- N2b `obtain-action` ヘルパ: LLM を再サンプルし `parse-action` を K 回まで試行、
  失敗を元 view に付して訂正を促す。scripted `%diagnose` と llm-step `%llm-step`
  の即 give-up を置換(`action.lisp` / `scripted-policy.lisp` / `llm-policies.lisp`、
  test `obtain-action-*` 3 件、`transient-unparseable-diagnosis-recovers`、
  `guided-transient-unparseable-action-recovers`)。
- N1 `render-tool-schemas`: 許可ツール descriptor の name + パラメータ(必須は `*`)を
  view に注入(`context-compiler.lisp`、test `render-tool-schemas-*` 3 件)。scripted
  `%diagnose` / llm-step `%step-prompt` に配線(`diagnose-view-includes-tool-schemas`、
  `guided-prompt-includes-tool-schemas`)。
- N1 補正(scripted tool スコープ): scripted は patch ツールしか受理しないので、
  view に出すツールも patch ツールに限定。さもないと N1 が repl-eval 等を提示して
  非パッチ提案を誘発し、scripted が即 give-up した(実機で確認)。

**再走(新ハーネス、clh-histogram、Qwen3.6-35B-A3B)**
- guided(素プロンプト): **N1 で引数名が正しくなった**(`fs-list-directory` を `path`
  で呼びディレクトリ列挙に成功、誤 `file_path` ループが消えた)。**N2 で parse 死なし**。
  だが当てのない探索で収束せず identical-action park —— ツール契約ではなく
  モデルの計画能力の限界(spec「弱モデルは自律度を下げよ」)。
- scripted(+ソース提示ヒント): repl-eval 誘惑は消え、`observe` を正しい
  form_name(`observe ((h histogram) key)`)で実装。しかし **scripted はソースを
  観測できない**ため、パッチが効かない理由を診断できずモデルが
  「patch history しか見えず実ソースを確認できないので直せない」と明言して give_up
  → `:failed`。

**結論**: N1+N2 は I/O 契約の欠陥(誤引数・parse 死・非パッチ提案)を解消した
(必要条件)。しかし 5 メソッドの「既存定義への整合実装」を `:done` にするには
**提案 4(N4: 現在ソースを view に載せる)が単一の残ブロッカー**で、モデル自身が
3 度の give_up でそれを明言した。N4 は scripted に read フェーズ/ソース projection を
足す非自明な変更で、本実装(N1+N2)の範囲外。次の単一の取り組み対象。

**再現**: 実験ランナーを `tools/run-next-experiment.lisp` にコミット。
`CLH_DIAL`(scripted|guided|adaptive)、`CLH_ROBUST`/`CLH_APPENDIX`/`CLH_SOURCE_HINT`
/`CLH_CANNED`(いずれも opt-in)、LLM/`MCP_PROJECT_ROOT` 環境変数で駆動。

## 実装フォローアップ②(同日): N4 ① を実装 — ハーネスは多段タスクで :done に到達

N4 の最小版(option ①)を TDD で実装(全 262 テスト緑、mallet クリーン、
`compile-system :force t` 警告なし)。

**実装内容**
- `patch-entry` に `content` スロットを追加し、`apply-interaction` が
  lisp-edit-form の `content` / lisp-patch-form の `new_text` を取り込む
  (`change-ledger.lisp`、test `patch-entries-capture-content`)。
- `compile-context` の "Recent patches" が、各フォームの**最新成功パッチの内容**
  (= 編集後フォームの現在ソース)を字下げで echo。オシレーションの古い版はメタ
  データのみ。`+patch-content-limit+`(480 字)で bound(`context-compiler.lisp`、
  test `failure-view-shows-current-patch-content`)。これでモデルは「自分が書いた
  もの」を view で確認できる。

**検証 — canned 正解パッチで `:done`**: モデルの素の信頼性とハーネスの機械を
切り分けるため、決定論的に正しいパッチ列を返す diagnose-fn(`CLH_CANNED`)で
scripted を実走。**5 フォーム(observe/count-of/total/distinct/top-key)を順に
当て → incremental green → clean-verification green → `:done`**(61 events、
独立再テストで全 10 アサーション緑)。**新ハーネス(N1+N2+N4)は多段「整合実装」
タスクを実 cl-mcp 相手に end-to-end で完遂できる**。

**実 LLM での再走(N4 込み)**: それでも Qwen3.6-35B-A3B では `:done` に届かず。
ただし失敗は毎回**別のモデル側の杜撰さ**に移った —— パス typo(`roswoll`)、幻の
optional 引数(`readtable:"COMMON-LISP"`)、空応答(EOF)、早すぎる give_up。
**ハーネス側の単一ブロッカーは解消し、律速はモデルの素の信頼性に移った**。これは
spec の中心仮説「自律度はモデル能力に従う」の裏返し: この 35B ローカルモデルは
全ハーネス支援をもってしても 5 メソッド自律実装の床を下回る。

**結論(更新)**: N1+N2+N4 で I/O 契約・観測ループのハーネス欠陥は閉じ、ハーネスは
canned 検証で多段タスクを `:done` まで完遂。残る差は**モデル能力**で、より強い
モデル(クラウド)なら同タスクを自律的に通せるはず、というのが次の検証点。
N1 の副作用(全 optional 引数を提示すると弱モデルが幻の値で埋める)は、必須引数を
強調する/optional を畳む等の改善余地として記録。

## 実装フォローアップ③: template-fix-policy — 仮説の決定的確証

「Qwen が詰まるのは**コード生成ではなくエージェント的判断**」という診断を受けて、
最下段ダイヤル **template-fix-policy** を設計・TDD 実装
(spec `docs/superpowers/specs/2026-06-13-template-fix-policy-design.md`、
全 271 テスト緑)。原則: **ハーネス FSM が agency を 100% 所有し、LLM は
「シグネチャ＋契約＋クラスで完全に穴埋め化された1点に body だけ出す」 stateless な
code-gen オラクルに退化**。LLM は tool-call JSON も計画も完了判断も一切しない。

- body 抽出はリーダベース(`extract-method-body`、Increment A)。
- FSM は per-form: tiny prompt → snippet-fn → 抽出 → **ハーネス自身が lisp-edit-form
  発行** → load → run-tests → 失敗は K 回再サンプル/再試行、駄目なら park → 最終
  clean ゲートで `:done`/`:given-up`(Increment B)。
- DISCOVER(対象発見)は当面注入(`:targets`)。決定論的ハーネスロジックの代用で、
  LLM の agency はゼロのまま。

**実機結果(Qwen3.6-35B-A3B × clh-histogram full-5、`tools/run-template.lisp`)**:

| ダイヤル | 結果 | 緑メソッド |
|---|---|---|
| scripted / guided / adaptive | `:given-up`/`:parked`(全敗) | 0/5 |
| **template-fix** | **`:done`(3/3 再現)** | **5/5** |

**同じ Qwen が、全エージェントダイヤルで 0/5 だった 5 メソッド実装を template-fix で
5/5 完走した(3 回連続)。** しかも私が「コイン投げ」と予測した `total`/`top-key`
(maphash アキュムレータ)も含めて全部正しく生成した — クラスを context に入れ、
agency を剥がして穴を精密化すれば、35B の code-gen はそれらでも十分だった
(observe のみ 1 リトライ、他は一発)。

**最終結論**: 「コード生成は Qwen でも問題ない。問題はエージェント的判断を LLM に
させていたこと」というユーザの理解は正しく、**エージェント層をハーネスに引き取れば
弱モデルでも安定して多段タスクを完遂できる**ことが実機で確証された。これは spec の
中心命題「自律度はモデル能力に従う」の最下段を実装・実証したもの。

**B2(DISCOVER ソース化)も実装済み**: `discover-targets` がソースをリーダで解析して
スタブ defmethod/defun・class・package を自力発見し、発見サブFSM(fs-read-file→解析→
per-form)に繋ぐ。注入(`:targets`)なしで real Qwen が 5/5 `:done`(再現)。これで
「ハーネスが agency を 100% 所有(何を直すかの発見も含む)」が文字通り完成。残るは
adaptive 最下段への配線＋`:give-up` demote(§7)、能力ベース開始の自動化。
