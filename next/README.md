# cl-harness-next を自分の Common Lisp プロジェクトに使う — チュートリアル

このドキュメントは、実験的な **`cl-harness-next`**（`next/` 配下のシステム）を
あなた自身の Common Lisp プロジェクトに対して動かすための、ゼロから始める
一本道のチュートリアルです。本文中のランナースクリプトは、ローカル LLM
（vLLM, `Qwen/Qwen3.6-35B-A3B`）と本物の `cl-mcp` stdio 子プロセスを使って
**エンドツーエンドで実走し `:done` まで到達することを確認済み**です（実出力を §6・§7 に掲載）。

> 安定版の `cl-harness`（`fix` / `develop` / `bench` / `scaffold` の CLI）を探している
> なら、リポジトリ直下の [`../README.md`](../README.md) を見てください。`next` は
> その CLI とは別の、自律ループの再設計基盤です。

---

## 1. cl-harness-next とは / 何ができないか

`cl-harness-next` は「**失敗しているテストを、クリーンなイメージで緑になるまで
自律的に修正する**」ための runtime-native なハーネスです。1 ミッション = 1 つの
「赤いテストを緑にする」仕事、と考えてください。

- **CLI はありません。** 安定版の `cl-harness fix --project-root ...` のような
  入口は `next` には無く、利用は **`run-mission` を中心としたライブラリ API** です
  （`mission` を作り、environment / policy / governor の *factory* を注入して呼ぶ）。
- **自律度は「ダイヤル」で選びます**（低い順）: `template-fix`（FSM が手順・完了判定・
  ターゲット選択まで 100% 所有し、LLM はメソッド本体を埋めるだけのステートレスな
  オラクル。スタブ穴埋め専用）/ `scripted`（FSM が手順と完了判定を所有、LLM はパッチ
  内容を出す）/ `guided`（アジェンダに対し LLM が次の一手を選ぶ）/ `self-directed`
  （LLM がループ全体を所有）。`adaptive` はこれらを「自律度の高い順」に重ね、停滞したら
  1 段下げます（最下段に `template-fix` を置けば、弱いモデルでも最後はそこへ落ちます）。
- **すべての実行は単一の JSONL イベントログに記録**され、これがミッションの唯一の
  真実です（suspend/resume はこのログだけで成立します）。
- **experimental** です。API は spec
  [`../docs/superpowers/specs/2026-06-11-autonomous-harness-redesign-design.md`](../docs/superpowers/specs/2026-06-11-autonomous-harness-redesign-design.md)
  に沿って育っています。

**fix 型がベース。テスト著作は `authoring-policy`（§8）で**: 既定は fix 型
（既に失敗テストがある状態を緑にする）ですが、`authoring-policy` を使うと
**goal からテストを著作 → 実装して緑にする TDD ブートストラップ**まで回せます
（弱モデル Qwen3.6 で実機完走を確認）。一方、ゴール文から大きな機能をプランナーが
サブゴールに分解してゼロから作る用途は、引き続き安定版の `cl-harness develop` の
領分です。

---

## 2. 前提

- **SBCL + Roswell + Quicklisp**。`ros` と `sbcl` が PATH にあること。
- **`cl-mcp` が Roswell から起動できる**こと
  （`ros run -s cl-mcp -e "(cl-mcp:run :transport :stdio)"` が動く）。`next` は
  ミッションごとに**自前の `cl-mcp` stdio 子プロセスを spawn** します。別途サーバを
  立てる必要はありません。
- **OpenAI 互換の LLM エンドポイント**（`/v1/chat/completions` を喋るもの:
  OpenAI / Groq / ローカル vLLM / llama.cpp / Ollama / LM Studio など）。
- **この `cl-harness` リポジトリが ASDF から見える**こと。Roswell の
  `~/.roswell/local-projects/` 配下に置けば `(asdf:load-system :cl-harness-next)` で
  ロードできます。
- **ミッションは必ず standalone プロセスで走らせる**こと。`cl-mcp` の `repl-eval`
  からミッションを回してはいけません — `repl-eval` はタイムアウト後も評価スレッドが
  生き残るため、ミッション級の長いジョブには不向きです（実機運用での知見）。
  本チュートリアルは `ros run --load <script>` で走らせます。

---

## 3. 題材プロジェクトを用意する

`next` が直接いじれるのは **package-inferred-system + rove** で構成された ASDF
プロジェクトです。ここでは最小の題材 `clh-demo` を使います
（`~/.roswell/local-projects/clh-demo/`）。

```
clh-demo/
├── clh-demo.asd
├── src/
│   └── main.lisp
└── tests/
    └── main-test.lisp
```

`clh-demo.asd`:

```lisp
(asdf:defsystem "clh-demo"
  :class :package-inferred-system
  :depends-on ("clh-demo/src/main"))

(asdf:defsystem "clh-demo/tests"
  :class :package-inferred-system
  :depends-on ("rove" "clh-demo" "clh-demo/tests/main-test")
  :perform (asdf:test-op (o c)
             (declare (ignore o c))
             (uiop:symbol-call :rove :run :clh-demo/tests/main-test)))
```

わざとバグを入れた `src/main.lisp`（`add` が引き算になっている）:

```lisp
(defpackage #:clh-demo/src/main
  (:use #:cl)
  (:export #:add))

(in-package #:clh-demo/src/main)

(defun add (a b)
  "Add two numbers."
  (- a b))                ; ← バグ: 本来は (+ a b)
```

`tests/main-test.lisp`:

```lisp
(defpackage #:clh-demo/tests/main-test
  (:use #:cl #:rove)
  (:import-from #:clh-demo/src/main #:add))

(in-package #:clh-demo/tests/main-test)

(deftest add-adds
  (ok (= 5 (add 2 3)))
  (ok (= 0 (add 0 0))))
```

ミッションを走らせる前に、テストが本当に**赤**であることを確認します:

```bash
ros run -s clh-demo/tests -e '(asdf:test-system :clh-demo/tests)'
# × 0) Expect (= 5 (ADD 2 3)) to be true.   (= 5 (ADD 2 3)) → ADD 2 3 = -1
# × 1 of 1 test failed
```

自分のプロジェクトで試す場合は、安定版 CLI の `cl-harness scaffold` でこの形の
スケルトンを生成できます（LLM 不要）。

---

## 4. 環境変数

ランナーは LLM 接続情報を環境変数から読みます。加えて、`cl-mcp` 子プロセスが
ファイル操作（パッチ適用）の基準にする **`MCP_PROJECT_ROOT`** を、対象プロジェクトの
絶対パスに向けます。

```bash
export CL_HARNESS_LLM_BASE_URL=http://192.168.0.17:8000/v1   # 例: ローカル vLLM
export CL_HARNESS_LLM_API_KEY=dummy                           # エンドポイント次第
export CL_HARNESS_LLM_MODEL=Qwen/Qwen3.6-35B-A3B
export MCP_PROJECT_ROOT=/home/you/.roswell/local-projects/clh-demo
```

`MCP_PROJECT_ROOT` を設定しておくと、spawn された `cl-mcp` 子がその環境変数を
継承してプロジェクトルートを認識します（`fs-set-project-root` を別途呼ばずに済む）。

---

## 5. ランナースクリプト

これが本チュートリアルの中心です。下のスクリプトを `run-next-mission.lisp` として
保存します。1 つの scripted-fix ミッションを組み立てて `run-mission` で回し、
`:done` なら終了コード 0 で抜けます。

```lisp
;;;; run-next-mission.lisp — standalone cl-harness-next mission runner

(require :asdf)
(asdf:load-system :cl-harness-next)

(defpackage #:run-next-mission
  (:use #:cl #:cl-harness-next))
(in-package #:run-next-mission)

(defun env-or-die (name)
  (or (uiop:getenv name)
      (error "environment variable ~A is not set" name)))

(defparameter *project-root* (env-or-die "MCP_PROJECT_ROOT"))
(defparameter *system* "clh-demo")
(defparameter *test-system* "clh-demo/tests")

;;; --- 1. LLM プロバイダ -----------------------------------------------------
;;; enable_thinking:false は Qwen3 の thinking を止め、completion 予算を隠れた
;;; 推論で食い潰させないための指定（実機実験 III/IV の知見）。
(defun thinking-off-extra-body ()
  (let ((ctk (make-hash-table :test 'equal))
        (top (make-hash-table :test 'equal)))
    (setf (gethash "enable_thinking" ctk) 'yason:false)
    (setf (gethash "chat_template_kwargs" top) ctk)
    top))

(defparameter *provider*
  (make-openai-provider
   :base-url   (env-or-die "CL_HARNESS_LLM_BASE_URL")
   :api-key    (env-or-die "CL_HARNESS_LLM_API_KEY")
   :model      (env-or-die "CL_HARNESS_LLM_MODEL")
   :max-tokens 8192
   :extra-body (thinking-off-extra-body)))

;;; --- 2. system prompt ------------------------------------------------------
;;; 注: 現行版では診断ビューに **パッチツールの引数スキーマが自動注入** され
;;; （context-compiler の render-tool-schemas / 通称 N1）、応答が壊れていても
;;; obtain-action が数回まで再サンプリングします（N2）。そのため以下の手動追記は
;;; **必須ではなく補強** です（capable なモデルなら最小プロンプトでも動きます）。
;;; 弱いモデルでは、正確なスキーマと（無関係な）実例の追記が park（3 連続パッチ
;;; 失敗）をさらに減らします。scripted ループには read ステップが無いので、
;;; 「ゴールから完全な修正フォームを書いて lisp-edit-form replace で置換せよ」と
;;; 誘導しておくのも有効です。
(defun build-fix-prompt (root)
  (concatenate 'string
   +scripted-fix-system-prompt+
   (string #\Newline) (string #\Newline)
   "PATCH TOOL ARGUMENT SCHEMAS — use these EXACT argument keys:" (string #\Newline)
   "- lisp-edit-form (PREFER THIS): {\"file_path\":..., \"form_type\":\"defun\", "
   "\"form_name\":..., \"operation\":\"replace\", \"content\":\"<complete corrected form>\"}"
   (string #\Newline)
   "- lisp-patch-form: {\"file_path\":..., \"form_type\":\"defun\", \"form_name\":..., "
   "\"old_text\":..., \"new_text\":...}" (string #\Newline)
   "Use an ABSOLUTE file_path. The project root is " root
   " ; source files are under " root "/src/ ." (string #\Newline)
   "You cannot read files in this scripted loop, so derive the corrected form "
   "from the goal and emit the COMPLETE defun via lisp-edit-form replace." (string #\Newline)
   "Worked example (an UNRELATED function, do not copy it literally):" (string #\Newline)
   "{\"type\":\"tool_call\",\"tool\":\"lisp-edit-form\",\"arguments\":{\"file_path\":\""
   root "/src/main.lisp\",\"form_type\":\"defun\",\"form_name\":\"mul\","
   "\"operation\":\"replace\",\"content\":\"(defun mul (a b) (* a b))\"},"
   "\"thought\":\"mul should multiply its two arguments\"}"))

(defparameter *fix-system-prompt* (build-fix-prompt *project-root*))

;;; --- 3. diagnose-fn: provider × system prompt → (view → 生 JSON 文字列) -----
;;; make-judge-fn が「(プロンプト文字列 → 応答文字列)」の関数を返す。これが
;;; scripted-fix-policy の :diagnose-fn 契約そのもの。
(defparameter *diagnose-fn*
  (make-judge-fn *provider* :system-prompt *fix-system-prompt*))

;;; --- 4. ファクトリ ---------------------------------------------------------
(defun environment-factory (mission log)
  (declare (ignore mission))
  ;; :command を省略 → 既定の stdio コマンドで cl-mcp を spawn。
  ;; :runtime-native で load-system / run-tests / pool-kill-worker（クリーン検証）と
  ;; lisp-* パッチツールが使える。:event-log を渡すと action/observation が記録される。
  (make-cl-mcp-environment :condition :runtime-native :event-log log))

(defun policy-factory (mission)
  (declare (ignore mission))
  (make-instance 'scripted-fix-policy
                 :system *system*
                 :test-system *test-system*
                 :diagnose-fn *diagnose-fn*
                 :clear-fasls t))   ; fasl の秒精度ステイルを無効化

(defun governor-factory (mission)
  (declare (ignore mission))
  (make-instance 'governor
                 :max-actions 40
                 :max-consecutive-failed-patches 3))

;;; --- 5. mission + run ------------------------------------------------------
(defun main ()
  (let* ((log-path (merge-pathnames
                    (format nil "clh-next-~A.jsonl" (get-universal-time))
                    (uiop:temporary-directory)))
         (mission (make-instance 'mission
                                 :id "demo-fix-1"
                                 :goal "Make clh-demo/tests pass: (add a b) must return the sum a+b."
                                 :acceptance-criteria (list "clh-demo/tests is green")
                                 :log-path log-path))
         (queue (make-instance 'mission-queue)))
    (enqueue-mission queue mission)
    (format t "~&;;; event log: ~A~%" log-path)
    (finish-output)
    (multiple-value-bind (status reason)
        (run-mission mission queue
                     :environment-factory #'environment-factory
                     :policy-factory #'policy-factory
                     :governor-factory #'governor-factory
                     :max-steps 50)
      (format t "~&;;; mission status : ~A~%;;; reason : ~A~%" status reason)
      (finish-output)
      (uiop:quit (if (eq status :done) 0 1)))))

(main)
```

### 各部の要点

| 部品 | 関数 / クラス | 役割 |
|------|---------------|------|
| LLM プロバイダ | `make-openai-provider` | `base-url` / `api-key` / `model` は必須。`max-tokens`（既定 8192）、`extra-body`、`reasoning-effort` は任意。 |
| diagnose-fn | `make-judge-fn` | `provider` と `:system-prompt` から「文字列→文字列」関数を作る。scripted の `:diagnose-fn` 契約に一致。 |
| environment | `make-cl-mcp-environment` | `:command` 省略で既定 stdio cl-mcp を spawn。`:condition` で許可ツール集合を選ぶ（`:file-only` / `:generic-mcp` / `:runtime-native`）。`:event-log` で記録。 |
| policy | `scripted-fix-policy` | 必須 `:system` `:test-system` `:diagnose-fn`。`:clear-fasls t` は両検証オラクルに伝播。 |
| governor | `governor` | `:max-actions` / `:max-patches` / `:max-consecutive-failed-patches`（既定3）/ `:max-consecutive-identical-actions`（既定4）。停滞・予算超過で介入。 |
| 実行 | `run-mission` | `mission` と `queue` に 3 つの factory を渡す。`(values mission-status reason)` を返す（`:done` / `:parked` / `:failed`）。 |

`:condition` は許可ツールのゲートです: `:file-only`（フルファイル書き換えのみ）/
`:generic-mcp`（+ `lisp-*` 構造的パッチ・`clgrep-*`）/ `:runtime-native`（+ `repl-*`・
`code-*`・`inspect-*`・`pool-*`）。scripted-fix はクリーン検証で `pool-kill-worker` を
使うため `:runtime-native` が必要です。

---

## 6. 実行する

環境変数を設定して standalone プロセスで起動します:

```bash
CL_HARNESS_LLM_BASE_URL=http://192.168.0.17:8000/v1 \
CL_HARNESS_LLM_API_KEY=dummy \
CL_HARNESS_LLM_MODEL=Qwen/Qwen3.6-35B-A3B \
MCP_PROJECT_ROOT=/home/you/.roswell/local-projects/clh-demo \
ros run --load run-next-mission.lisp
```

実際の出力（Qwen3.6-35B-A3B、本物の `cl-mcp` 子プロセス）:

```
;;; event log: /tmp/clh-next-3990308104.jsonl
;;; mission status : DONE
;;; reason : clean verification green
```

終了コードは 0。`clh-demo/src/main.lisp` の `add` が `(- a b)` から `(+ a b)` へ
修正され、クリーンイメージでテストが緑になりました。

---

## 7. 何が起きたかを読む（イベントログ）

ミッションの全行程は `log-path`（上の例では `/tmp/clh-next-*.jsonl`）に 1 行 1
イベントの JSONL で残ります。上の成功 run は **25 イベント**でした:

| seq | type | 内容 |
|-----|------|------|
| 1 | `run_start` | goal / acceptance_criteria |
| 2 | `decision` | ベースライン検証を取る（incremental oracle を consult） |
| 3–6 | `action` / `observation` | `load-system`（clear_fasls）→ `run-tests` |
| 7 | `oracle_result` | `verification` **赤**（ここで diagnose へ） |
| 8 | `decision` | diagnose: 1 回だけ LLM を呼ぶ |
| 9 | `action` | **`lisp-edit-form`**（モデルが出したパッチ。下記） |
| 10 | `observation` | パッチ適用結果 |
| 11–15 | `decision`/`action`/`observation` | パッチを検証: `load-system` → `run-tests` |
| 16 | `oracle_result` | `verification` **緑**（incremental） |
| 17 | `decision` | クリーンイメージで確認（clean oracle を consult） |
| 18–23 | `action`/`observation` | **`pool-kill-worker`** → 新規 `load-system` → `run-tests` |
| 24 | `oracle_result` | `clean-verification` **緑** — `"1 tests passed (clean image)"` |
| 25 | `decision` | `finish — clean verification green` |

seq 9 でモデルが実際に出したパッチ（`action` イベントの `arguments`）:

```json
{
  "file_path": "/home/wiz/.roswell/local-projects/clh-demo/src/main.lisp",
  "form_type": "defun",
  "form_name": "add",
  "operation": "replace",
  "content": "(defun add (a b)\n  (+ a b))"
}
```

つまり scripted ダイヤルは **verify → diagnose → patch → verify → clean-verify** という
固定手順を FSM が所有し、LLM は「パッチ内容」だけを埋めます。この run では LLM 呼び出しは
diagnose の **1 回**だけでした。

ログを覗くワンライナー例:

```bash
# イベント種別を順に
python3 -c 'import json,sys; [print(json.loads(l)["seq"], json.loads(l)["type"]) for l in open(sys.argv[1])]' /tmp/clh-next-*.jsonl

# 最終判定（clean-verification）だけ
grep clean-verification /tmp/clh-next-*.jsonl
```

`run-mission` の戻り値（status / reason）と、このログがミッションの全記録です。ログ
だけあれば suspend/resume も可能です（spec §9）。

---

## 8. ダイヤルを差し替える / テストを著作する

### authoring-policy（goal からテストを著作 → 実装、TDD ブートストラップ）

ここまでは「既に失敗テストがある」前提でしたが、`authoring-policy`（`:mode :tdd`）は
その**前段**を担います。fix ダイヤルの**上のモード**で、1 ミッション内で:

1. **author** — goal から `deftest` を生成（LLM はテストの本体だけを書く body オラクル）
2. **integrity gate** — **RED-first**（著作テストが現コードで赤いこと）を機械確認
   ＋ **LLM テストレビュア**（`review-oracle`）で goal との整合を `:consult`
3. **fix** — 内側の fix ダイヤル（既定 `template-fix`）へ委譲してコードを緑に

**オラクル健全性は「相分離」で確保**: テストは phase 1 でゲート済み凍結、fix は
`src/` のみ対象なので fix 中にテストを弱められません（自作テスト＋自作コードの
緑偽装を構造的に排除）。テストファイルへの書込は cl-mcp の「既存 `.lisp` 上書き禁止」
に従い `lisp-edit-form`（固定名 deftest の insert/replace）で行います。

```lisp
(asdf:load-system "cl-harness-next/src/template-policy")   ; 内側 fix に使用

(defun policy-factory (mission)
  (make-instance 'cl-harness-next/src/authoring-policy:authoring-policy
   :mode :tdd
   :goal (mission-goal mission)
   :system "clh-demo" :test-system "clh-demo/tests"
   :source-file "src/main.lisp" :test-file "tests/main-test.lisp"
   :test-package "clh-demo/tests/main-test"
   :author-fn (make-judge-fn
               *provider*
               :system-prompt cl-harness-next/src/authoring-policy:+test-author-system-prompt+)
   :reviewer (make-instance 'cl-harness-next/src/review-oracle:review-oracle
              :judge-fn (make-judge-fn *provider*)
              :profile (list :id :tests-review :strictness :strict
                             :instructions "Approve only tests that genuinely assert the goal."))
   :fix-policy (make-instance 'cl-harness-next/src/template-policy:template-fix-policy
                :system "clh-demo" :test-system "clh-demo/tests"
                :snippet-fn (make-judge-fn
                             *provider*
                             :system-prompt cl-harness-next/src/template-policy:+template-snippet-system-prompt+)
                :source-files (list "src/main.lisp") :clear-fasls t :k 3)
   :clear-fasls t :k 3))
```

- **用途**: 対象は**スタブ穴埋め**（内側が template-fix のため。`src/main.lisp` に
  `(defun add (a b) 0)` のような定数本体スタブがある状態から、goal を満たす実装へ）。
- **実機実証**: ローカル Qwen3.6 で「goal → 失敗テスト著作 → RED-first/review ゲート →
  template-fix で実装 → clean green」を**完走**（`tools/run-tdd.lisp`、§10 の実験ノート）。
- `authoring-policy` はファサード（`cl-harness-next`）に `authoring-policy` /
  `+test-author-system-prompt+` を公開済み。

> 以下は fix ダイヤル間の差し替え（テスト著作が不要で、既に失敗テストがある場合）。

ダイヤルの差し替えは、**`policy-factory` が返すポリシーを変えるだけ**です
（environment / governor / mission の配線はそのまま）。scripted より**下げる**
（`template-fix`）ことも、**上げる**（`guided` / `adaptive`）こともできます。

### template-fix（最下段 — LLM はメソッド本体だけを書く）

scripted でも「修正フォームを正しく組み立てる」エージェンシーをモデルに頼っています。
それすら不安定な弱いモデル向けに、**エージェンシーを 100% ハーネス側へ寄せた**最下段が
`template-fix` です。FSM が「対象スタブの発見 → 1 つずつ本体生成依頼 → 編集 → ロード →
テスト → 完了判定」を所有し、LLM は **1 メソッドの本体 s 式だけ**を返す body オラクルに
なります。

> **用途はスタブ穴埋め専用**です。対象は「本体が定数 / `declare` のみ＝プレースホルダ」の
> `defmethod` / `defun`（例: `(defmethod area ((s square)) 0)`）。clh-demo の `add` のように
> *本体が非自明だが間違っている* バグ修正は対象外で、そちらは scripted / guided の領分です。

`template-fix-policy` はファサード（`cl-harness-next`）に**再エクスポートされていない**ので、
サブシステムを明示ロードし**修飾名**で使います（完全な実走スクリプトは
[`../tools/run-template.lisp`](../tools/run-template.lisp)）。

```lisp
;; ファサード非公開 — サブシステムを明示ロード。
(asdf:load-system "cl-harness-next/src/template-policy")

;; LLM は「メソッド本体だけ」を返す body オラクル。専用 system prompt を使う。
(defparameter *snippet-fn*
  (make-judge-fn
   *provider*
   :system-prompt cl-harness-next/src/template-policy:+template-snippet-system-prompt+))

(defun policy-factory (mission)
  (declare (ignore mission))
  ;; :source-files を読み、スタブ defmethod/defun・class 定義・(in-package …) を
  ;; 自前で発見（DISCOVER）。注入したいなら :targets に make-fix-target のリストを渡す。
  (make-instance 'cl-harness-next/src/template-policy:template-fix-policy
                 :system *system* :test-system *test-system*
                 :snippet-fn *snippet-fn*
                 :source-files (list "src/main.lisp")
                 :clear-fasls t :k 3))   ; k = 1 フォームあたりの再試行上限
```

`adaptive` の `:levels` 最下段にこの `template-fix-policy` を置けば、上位段（guided →
scripted）が give-up した時に自動でここへ落ちます（§1 の demote）。

### guided（LLM がアジェンダに対し次の一手を選ぶ）

`step-fn` は `make-judge-fn` で `+guided-system-prompt+` を使って作ります。
`:agenda`（`make-subgoal` のリスト、既定は `(default-fix-agenda)`）と
`:invariants`（破ってはいけない制約の文字列リスト）は任意です。

> `+guided-system-prompt+` も `+scripted-fix-system-prompt+` と同様にパッチツールの
> 引数スキーマは含みません。小さなモデルでは §5 と同じ要領で `step-fn` 用の
> system prompt にスキーマと実例を追記しておくと、誤引数による停滞を避けられます。

```lisp
(defparameter *step-fn*
  (make-judge-fn *provider* :system-prompt +guided-system-prompt+))

(defun policy-factory (mission)
  (declare (ignore mission))
  (make-instance 'guided-policy
                 :system *system*
                 :test-system *test-system*
                 :step-fn *step-fn*
                 :clear-fasls t))
```

### adaptive（停滞したら 1 段下げる、推奨デフォルト）

`:levels` に「自律度の高い順」でポリシーを並べます。governor が `progress-stalled`
（連続パッチ失敗・検証空回り・同一アクション連発）を検知すると 1 段 demote します。

```lisp
(defun policy-factory (mission)
  (declare (ignore mission))
  (make-instance 'adaptive-policy
                 :levels (list
                          (make-instance 'guided-policy
                                         :system *system* :test-system *test-system*
                                         :step-fn *step-fn* :clear-fasls t)
                          (make-instance 'scripted-fix-policy
                                         :system *system* :test-system *test-system*
                                         :diagnose-fn *diagnose-fn* :clear-fasls t))))
```

> 対象が**スタブ穴埋め**なら、この `:levels` の末尾にさらに `template-fix-policy` を
> 足すと最強の安全網になります（guided → scripted → template-fix）。連鎖 demote は
> 1 ステップで最下段まで届くので、上位 2 段が give-up しても template-fix まで落ちます。
> clh-demo の `add` は非スタブのバグ修正なので、この例は guided → scripted のままです。

### どれを使うか（実機データ、Qwen3.6-35B-A3B）

**clh-demo（1 関数のバグ修正）** の初期測定:

| ダイヤル | 結果 | actions | LLM 呼び出し |
|----------|------|---------|--------------|
| `scripted` | `:done`（安定） | 9 | 1 |
| `guided` | 修正は完遂するが「完了の自己宣言」ができず park/give-up になりがち | 6〜16 | 5〜17 |
| `adaptive`（guided→scripted） | **`:done`**（demote 1 回） | 14〜15 | 8 |

**clh-histogram（CLOS クラス＋スタブ 5 メソッドの穴埋め）** という一段重いタスクでは、
差がさらに極端になりました:

| ダイヤル | 結果（5 メソッド） |
|----------|--------------------|
| `scripted` / `guided` / `adaptive` | `:given-up` / `:parked` — **0/5** |
| **`template-fix`** | **`:done` — 5/5**（`total` / `top-key` の maphash 込み、再現） |

> エンドツーエンド検証は scripted パス（clh-demo）を §6・§7 に、template-fix パス
> （clh-histogram）を実機記録
> [`../docs/notes/2026-06-13-next-complex-task-experiment.md`](../docs/notes/2026-06-13-next-complex-task-experiment.md)
> に掲載。guided / adaptive の clh-demo 数値は
> [`../docs/notes/2026-06-13-live-fire-experiments.md`](../docs/notes/2026-06-13-live-fire-experiments.md)
> 由来です。
>
> **中心的知見**: 弱いモデルが詰まるのは **コード生成**ではなく **エージェンシー層**
> （計画・tool-call の組み立て・観測→行動・完了の自己宣言）です。Qwen3.6 はメソッド本体は
> 書けても、agency 系ダイヤルでは clh-histogram を 0/5 でした。`template-fix` は agency を
> 丸ごとハーネス側へ移し、LLM をステートレスな body オラクルに縮約することで 5/5 に到達します。
> **自律度はモデルの能力に合わせて下げるのが定石** — その極北が template-fix です。

---

## 9. トラブルシューティング（実機由来）

- **`:parked` "consecutive failed patches"**: モデルがパッチツールの引数スキーマを
  誤推測している兆候。現行版は診断ビューにスキーマを自動注入し（N1）、壊れた応答を
  再サンプリングする（N2）ので以前より起きにくくなっていますが、なお park する弱い
  モデルには §5 のように system prompt に**正確なスキーマと実例を追記**すると安定します
  （本チュートリアルも初期の試走でこれに当たり、追記で `:done` に到達しました）。
  それでも修正フォームを組み立てられないモデルでは、エージェンシーをハーネス側に
  寄せた **`template-fix` ダイヤル**（§8）が最終手段になります。
- **`:parked` の意味と resume**: governor が park し、human request をキューに積みます。
  再開は parked ミッションを **`run-mission` で再度走らせる**こと（より大きな envelope を
  返す `governor-factory` を渡す）。使った予算はログから再生され「使用済み」として復元されます。
- **fasl の秒精度ステイル**: ASDF の鮮度判定は `file-write-date`（秒精度）。低レイテンシだと
  パッチが直前コンパイルと同一秒に落ちて再コンパイルされず「永遠に赤」になり得ます。
  `scripted-fix-policy` / `verification-oracle` に **`:clear-fasls t`** を渡して回避します。
- **worker pool は親プロセス依存**: `cl-mcp` の `repl-eval` の中からミッションを spawn すると
  worker pool が無効化され、`pool-kill-worker` が no-op になってクリーン検証が名目化します。
  **必ず standalone プロセス**（`ros run --load`）から走らせてください。
- **thinking 暴走 / `content` 空**: 推論モデル（Qwen3 系・gpt-oss・o1）は thinking で
  completion 予算を使い切り `content=""`（`:empty-content`）を返すことがあります。
  §5 の `enable_thinking:false`、`:max-tokens` を上げる、診断ビューを薄くしすぎない、で緩和します。
- **`file_path` が解決しない / パッチが当たらない**: `MCP_PROJECT_ROOT` を対象プロジェクトの
  絶対パスに設定し、パッチの `file_path` も絶対パスにします（§4・§5）。

---

## 10. 次に読む

- spec: [`../docs/superpowers/specs/2026-06-11-autonomous-harness-redesign-design.md`](../docs/superpowers/specs/2026-06-11-autonomous-harness-redesign-design.md)
  — L0〜L5、policy pack、governor、ダイヤルの設計。
- template-fix spec: [`../docs/superpowers/specs/2026-06-13-template-fix-policy-design.md`](../docs/superpowers/specs/2026-06-13-template-fix-policy-design.md)
  — 最下段ダイヤルの FSM・本体抽出・スタブ発見・既知の限界。
- test authoring spec: [`../docs/superpowers/specs/2026-06-14-test-authoring-design.md`](../docs/superpowers/specs/2026-06-14-test-authoring-design.md)
  — `authoring-policy` の FSM・RED-first/review ゲート・相分離 integrity。
- 実機記録（scripted/guided/adaptive の落とし穴）: [`../docs/notes/2026-06-13-live-fire-experiments.md`](../docs/notes/2026-06-13-live-fire-experiments.md)。
- 実機記録（template-fix で clh-histogram 5/5）: [`../docs/notes/2026-06-13-next-complex-task-experiment.md`](../docs/notes/2026-06-13-next-complex-task-experiment.md)。
- 実機記録（TDD ブートストラップ完走）: [`../docs/notes/2026-06-14-tdd-authoring-experiment.md`](../docs/notes/2026-06-14-tdd-authoring-experiment.md)
  — Qwen3.6 が author→fix→green を完走。途中で見つけた cl-mcp 制約（`fs-write-file` の `.lisp` 上書き禁止）と再設計も記録。
- 安定版 CLI と conditions / トランスクリプト: [`../README.md`](../README.md)。
