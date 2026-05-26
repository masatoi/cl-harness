# test_change_request review architecture (DR-2026-05-27)

このノートは、 `cl-harness:develop` の **`test_change_request` ゲートの設計** を
記述する。 2026-05-27 design review (元文書: `/tmp/cl-harness-development-design-review.md`、
PR 履歴: commits `d6fa5a9` / `b3ef5b1` / `b1fee38`) で発見された 5 件の弱点に対し、
high-priority 2 件は実装、 medium 3 件は docstring 化 / 機能追加で対応した結果の
**現在の設計** をここに固定する。

## 1. 文脈

`cl-harness:develop` ループでは agent が `:finish` / `:tool-call` 以外に
**`:test-change-request`** をエミットできる。 これは「planner が初期生成した test
だけでは acceptance criteria を満たせない (missing coverage)」 と agent が判断した
場合の signal で、 追加で新 deftest を 1 件 author するように reviewer に申し立てる。

承認されれば test file に append され、 develop ループは同 step を rerun する
(= verify ループに新 deftest が見えるようになり、 agent はそれを通すように
implementation を進める)。

このメカニズムは便利だが、 **test スイートが verify の source-of-truth** になっている
以上、 LLM の判断だけで test を改変できる経路は **plan / implementation 改変よりも
危険度が高い**。 design review の結論はこの危険を反映した二重防御アーキテクチャ。

## 2. 不変条件 (invariants)

`test_change_request` 経路は以下を **同時に** 満たさない限り承認されない。

| # | Invariant | Layer |
|---|---|---|
| **I1** | test_source が exactly one `(deftest ...)` の top-level form であること (unqualified; `(rove:deftest ...)` は ROVE package が load されている時のみ accept、 そうでなければ read error → reject) | L1 (deterministic) |
| **I2** | test_source body の任意ノードに `(skip ...)` / `(rove:skip ...)` が含まれないこと | L1 (deterministic) |
| **I3** | test_source が valid Lisp として read 可能であること | L1 (deterministic) |
| **I4** | test_source は既存テストを modify / overwrite せず、 純粋に **追加** であること (= additive-only) | L1 部分 + L2 |
| **I5** | 新 test の名前が既存 test 名と衝突しないこと (silent overwrite 防止) | L1 (deterministic, **`%extract-deftest-names-from-file`** で test file 走査) |
| **I6** | 新 test が acceptance criteria に listed されていない feature をカバーしないこと (scope drift 防止) | L2 (LLM) |
| **I7** | 新 test が acceptance criteria と矛盾しないこと (inverse assertion 等の disguised weakening 排除) | L2 (LLM) |

L1 と L2 は **直列の二重防御**: L1 で structurally invalid な payload を deterministic に
弾き、 L1 を通った payload に対して L2 (LLM strict review) が semantic check を行う。
L2 が approve しても L1 が reject すれば結局 reject される。

## 3. アーキテクチャ層

```
┌─────────────────────────────────────────────────────────────┐
│  Agent emits :test-change-request action                    │
│  - action.test_source : string                              │
│  - action.criteria    : list of AC ids                      │
│  - action.rationale   : agent's "why this test is missing"  │
└─────────────────────────────────────────────────────────────┘
                          │
                          ▼
┌─────────────────────────────────────────────────────────────┐
│  L2: review-development-artifact :kind :test-change         │
│  src/review.lisp                                            │
│  +test-change-review-system-prompt+                         │
│  - 6 falsifiable rejection conditions (numbered for cite)   │
│  - "STRICT MODE — reject whenever any of these hold"        │
│  - 並列に I4 / I5 / I6 / I7 を semantic に check             │
│  Returns review-decision (:approved | :rejected) + feedback │
└─────────────────────────────────────────────────────────────┘
                          │
                ┌─────────┴─────────┐
                ▼                   ▼
        :approved (continue)    :rejected (early exit)
                │                   │
                ▼                   │
┌──────────────────────────────────┐│
│  L1: validate-test-source         ││
│  src/orchestrator.lisp            ││
│  - read source as single Lisp form││
│  - check car is deftest symbol   ││
│  - walk tree, reject (skip ...)  ││
│  - reject multiple top-level     ││
│  Signals planner-error on        ││
│  violation                       ││
└──────────────────────────────────┘│
                │                   │
                ▼                   ▼
┌─────────────────────────────┐ ┌────────────────────────────┐
│ Approved + L1 passes:        │ │ Rejected (or L1 failed):   │
│ - materialize-test-source    │ │ - increment counter        │
│ - increment counter           │ │ - return :REJECTED         │
│ - return :APPROVED            │ │   <feedback string>        │
│ - %execute-step reruns step   │ │ - %execute-step feeds      │
│   with cleared feedback       │ │   feedback into next       │
└─────────────────────────────┘ │   iteration's issue via    │
                                │   %enriched-issue          │
                                └────────────────────────────┘
```

`%execute-step` のループ条件:

- 共有カウンタ `develop-state-test-revision-count` (run-wide budget)
- 上限 `max-test-revisions` (default 3, CLI/orchestrator 共通)
- 上限到達後は agent の terminal status (`:test-change-request`) でループ脱出
- ループ内では `test-change-feedback` local variable が次回 issue 構築に反映される

## 4. issue 強化階層 (%enriched-issue)

agent が 1 step 内で複数 retry する場合、 issue text の prefix に **複数の feedback
section が cumulative に乗り得る**。 rendering 順は **newest / most-specific first**:

```
## Prior test-change review feedback        ← Finding 5 (新規, 最高優先)
## Prior implementation review feedback     ← 既存 impl-retry
## Prior exploration (read-only)            ← explore memo
## Task                                     ← 元 plan-step.issue
```

優先順位の根拠:
- `test-change` feedback は **agent が直前に要求した内容に対する直接の判定** — 最も具体的
- `impl-review` feedback は **直前の patch に対する判定**
- `exploration` memo は **step 開始前の探索結果** (read-only context)
- `## Task` は **plan-step の原文** (不変)

## 5. 二つの review default

CLI と core API で `:review-policy` の default が **意図的に異なる**:

| 入口 | default | 意図 |
|---|---|---|
| `cl-harness:develop` (CLI facade, `src/cli.lisp`) | `:auto` | user-facing run は plan / test / impl review gates を default で有効化 |
| `cl-harness/src/orchestrator:develop` (core API) | `:none` | programmatic caller / test stub は LLM call なしで動かす |

programmatic caller が CLI と同等の挙動を望む場合は **明示的に `:review-policy :auto`** を
渡す必要がある (両 docstring で相互参照)。

## 6. test-revision budget の semantic

`max-test-revisions` (default 3) は **run-wide** であり per-step ではない。 即ち:

- step 0 が 3 回 test_change_request を行うと、 step 1 以降は budget 不足で
  `test_change_request` できない (terminal :test-change-request になる)
- 設計判断としての rationale は **total LLM cost を bound する** こと
- 個別 step に対する semantic としては不自然だが、 N=3 default は実用上問題になっていない
  (empirical 観察: 1 step あたり typical 0-1 test-revision request)

将来 empirical に困るパターン (step ごとに 2-3 件の追加 test が legitimate に必要) が
出てきた場合は `MAX-TEST-REVISIONS-PER-STEP` を新設して per-step に counter を reset
することを backlog に残す。

## 7. 関連 source-of-truth pointers

- `src/orchestrator.lisp:validate-test-source` (L1 deterministic gate)
- `src/orchestrator.lisp:%maybe-handle-test-change-request` (entry point; multi-values
  return: `:APPROVED` / `:REJECTED <feedback>` / `NIL`)
- `src/orchestrator.lisp:%enriched-issue` (issue text builder with stacked feedback)
- `src/orchestrator.lisp:%execute-step` (main step loop, reject feedback path)
- `src/review.lisp:+test-change-review-system-prompt+` (L2 LLM strict prompt)
- `src/review.lisp:review-system-prompt-for` (stage-aware dispatcher)
- `src/cli.lisp:develop` (CLI facade, :auto default)
- `tests/orchestrator-test.lisp:validate-test-source-*` (L1 deterministic tests)
- `tests/review-test.lisp:test-change-review-uses-strict-prompt` (L2 LLM prompt pin)
- `tests/orchestrator-test.lisp:enriched-issue-with-review-feedback` (feedback stacking)

## 8. 既知の non-implemented checks

L2 LLM に依存している不変条件は、 paired bench data (`#38 N=10 paired`, `#54/#55`)
から **LLM が prompt の指示を完全には遵守しない** ことが分かっている。 即ち
**I6 / I7 は failure-prone** (semantic check が必須なので deterministic 化困難)。
LLM judgment を信頼するしかない (但し prompt strict)。

I5 (name collision) は元々 L2 だけに任せていたが、 Implementation review
(2026-05-27, Finding H1) で deterministic 化された:
`%extract-deftest-names-from-file` が test file を `*PACKAGE*` = `:CL` で
tolerant-read し、 既存 deftest 名 (upcased) を抽出。 `%maybe-handle-test-change-request`
が新 deftest 名と STRING-EQUAL で比較し、 衝突時は L1 planner-error として
reject feedback path に乗せる。 false negative の余地 (read error で scan が
早期終了するケース) は残るが、 その場合も L2 prompt の rejection condition 3
(silent overwrite risk) が backup として機能する。

## 9. design review 5 findings (closed)

| # | Finding | Status | Commit |
|---|---|---|---|
| 1 | additive-only deterministic gate | ✅ 実装済 | d6fa5a9 |
| 2 | :test-change strict prompt | ✅ 実装済 | d6fa5a9 |
| 3 | review-policy default mismatch | ✅ docstring | b3ef5b1 |
| 4 | max-test-revisions run-wide budget | ✅ docstring | b3ef5b1 |
| 5 | test_change_request reject feedback path | ✅ 実装済 | b1fee38 |

元 review 文書 (`/tmp/cl-harness-development-design-review.md`) と各 commit の
diff を併せ読むことで設計判断の根拠が完全に追跡できる。

## 10. Implementation review followup (Implementation review 2026-05-27)

design review の各 finding 実装に対して別途 implementation review を行い
(`/tmp/cl-harness-implementation-review.md`)、 4 件の弱点を指摘:

| # | Issue | Severity | Status |
|---|---|---|---|
| H1 | 既存 test name 衝突検査が deterministic に未実装 (I5 が L2 LLM 依存) | High | ✅ 実装済 — `%extract-deftest-names-from-file` + collision check |
| M1 | `(rove:deftest ...)` 受領時 substring check `(search "(deftest " source)` が validator と不整合、 ROVE 未 load 環境では read error | Medium | ✅ 実装済 — substring check 削除、 docstring で qualified form の environment dependency を明示 |
| M2 | L1 structural reject (`validate-test-source` の `planner-error`) が agent feedback loop に乗らない | Medium | ✅ 実装済 — `handler-case` で `:REJECTED <feedback>` に変換 |
| L1 | `develop-state-test-revision-count` slot docstring が approved 限定の古い記述 | Low | ✅ 実装済 — attempted/consumed budget の semantic を反映 |

各 fix には対応する unit test を追加:
- `validate-test-source-returns-test-name-as-second-value` (H1 前提)
- `extract-deftest-names-from-file-helper` (H1 helper)
- `maybe-handle-test-change-rejects-on-name-collision` (H1 end-to-end)
- `maybe-handle-test-change-rejects-validator-failure-as-feedback` (M2 end-to-end)
