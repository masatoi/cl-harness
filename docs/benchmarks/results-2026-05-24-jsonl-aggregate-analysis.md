# JSONL aggregate analysis: ~60 develop-level runs across 4 bench cycles

**Date**: 2026-05-24
**Scope**: re-analysis of existing bench transcripts (zero new LLM cost)
**Code window**: 0368f1e (pre-#38-removal) ～ 1f29778 (post-#38-removal)
**Provider**: Qwen3.6-35B-A3B
**Source bench cycles**:
- `bench-sweep-n3-1779574396-*` (N=3 × 7 fixtures = 21 cells, 0368f1e)
- `bench-45-verify-1779599390-*` (3 fixtures × N=3 = 9 cells, fd02eaa)
- `bench-46-paired-104b-*` (6 cells, paired)
- `bench-n10-104b-*` (10 × 2 arms = 20 cells, N=10 paired)
- `bench-cycle-1779568317-*` (Qwen v3, 2 cells)
- 関連 step transcripts全展開
**Goal**: 次の改善 backlog 候補を、追加 bench なしで surface する

## 集計サマリ

### Develop-level outcomes (55 runs)

| Status | Count |
|---|---:|
| :passed | 37 (67%) |
| :give-up | 8 (15%) |
| :limit-exhausted | 8 (15%) |
| :review-rejected | 2 (4%) |

### Step-level outcomes (161 step results)

| Status | Count |
|---|---:|
| :passed | 122 (76%) |
| :give-up | 19 (12%) |
| :limit-exhausted | 15 (9%) |
| :review-rejected | 5 (3%) |

### Limit-hit distribution (step-level)

| Limit | Count |
|---|---:|
| :max-patches | 8 |
| :max-turns | 3 |
| **:max-consecutive-failed-patches** (#45) | **3** ← 既に 3 件発火 |
| :max-wall-clock | 1 |

### Patch quality

- ok: 247 (66%)
- **fail: 127 (34%)** ← 3 つに 1 つの patch が rejected
- Total: 374

### Verify failure categories (427 failure events)

| Category | Count | % |
|---|---:|---:|
| **undefined-function** | 287 | 67% |
| other (assertion / misc) | 56 | 13% |
| unknown | 55 | 13% |
| compile-file-error | 16 | 4% |
| no-applicable-method | 7 | 2% |
| undefined-class / load-failed / missing-dep | 6 | 1% |

### Top undefined-function symbols (= agent が定義し損なった/定義 path 違い symbol)

| Symbol | Count |
|---|---:|
| CACHE/SRC/MAIN:MAKE-CACHE | 66 |
| CACHE/SRC/MAIN:CACHE-PUT | 62 |
| CACHE/SRC/MAIN:CACHE-GET | 48 |
| COUNTER/SRC/MAIN:MAKE-COUNTER | 22 |
| COUNTER/SRC/MAIN:RESET-COUNTER | 20 |
| COUNTER/SRC/MAIN:INCREMENT | 14 |
| DOUBLE / VALIDATE-EMAIL / FORMAT-CURRENCY 各 12 | 36 |
| FIZZ-BUZZ / GREET | 10 |
| **COUNTER/TESTS/MAIN-TEST::CLASS-SLOTS** | **3** ← planner stub helper |
| **ARGLIST / FUNCTION-LAMBDA-LIST** | **5** ← 同上 |

## Tool error の真の分布 (top 10)

| Error | Count | % | Category |
|---|---:|---:|---|
| **fs-write-file が .lisp/.asd を refuse** | **66** | **29%** | agent workflow misuse |
| **lisp-patch-form `old_text` mismatch** | **27** | **12%** | agent gen mismatch / tool feedback |
| **Patch malformed (trailing content)** | **11** | **5%** | agent output / parinfer |
| lisp-read-file: file not found | ~20 | 9% | wrong path / tests not yet created |
| lisp-read-file: Is a directory | 8 | 3% | tool feedback |
| fs-list-directory permission | 8 | 3% | path resolution |
| Reader error: unbalanced parens | 7 | 3% | patch quality |
| Form not found (edit-form) | ~6 | 3% | tool feedback |
| Symbol ARGLIST not found in CL | 5 | 2% | planner stub |
| content: multiple top-level forms | 4 | 2% | agent guidance |

総 tool errors: 230 across ~70 step transcripts (mean 3.3 / step)

## 改善候補 (新規 backlog 案)

### #48. **agent system prompt に fs-write-file 制限を明示** (high impact)

**観察**: tool error 全体の **29% (66/230)** が「fs-write-file is for Lisp」混同。
agent は新しい file (src/main.lisp が既に in-package 行のみ存在) を「ゼロから書く」感覚で
fs-write-file を呼ぶが、tool 側で `Cannot overwrite existing .lisp/.asd` と reject。
ほぼ毎回 lisp-edit-form の insert-* で 1 turn 後に成功するが、**1-turn / step を浪費**。

**変更案**: system-prompt の "Allowed tools" section に明示:
```
fs-write-file:
  - Use only for files that do NOT exist yet (typically new test-only files).
  - For .lisp / .asd files that exist (even if they only contain in-package),
    use lisp-edit-form with operation: "insert-after" or "insert-before".
  - Symptom of misuse: "Cannot overwrite existing .lisp/.asd" tool-error.
```

**期待効果**: 各 step で agent が 1st patch attempt を確実に lisp-edit-form に向ける。
N=10 paired bench で OFF arm でも turn 5-7 で初 patch する pattern (= reads + 1 wrong tool +
correct tool) → 直接 lisp-edit-form を呼べば turn 3-4 で完了。

**コスト**: small + 1 hour (prompt 修正 + agent-test で wording pin + bench)。

### #49. **lisp-patch-form `old_text` mismatch 時の近似 match suggestion** (medium impact)

**観察**: tool error の **12% (27/230)** が `old_text not found in DEFUN FOO form`。
agent は file content の正確な再現を要求されるが whitespace / 改行 / 周辺 token のいずれかで
mismatch。 現在のエラーは "matching is exact and whitespace-sensitive" の generic hint のみ。

**変更案**: cl-mcp 側の `lisp-patch-form` で mismatch 時に diff 提案を返す:
```
old_text not found in DEFUN CACHE-PUT form.
Closest substring in form (Levenshtein/diff):
  ⟨expected⟩
  (cache-put cache key value)
  ⟨actual⟩
  (cache-put (cache key value)
The actual form's first 200 chars: <...>
```

**期待効果**: agent が 2nd attempt で正しい old_text を生成する確率が上がる。
N=10 で平均 patch fail rate 34% → 25% に下がれば 13% pass rate 改善見込み。

**コスト**: medium + 1-2 days (cl-mcp 側 helper + tool error payload schema 拡張)。
これは cl-mcp 側変更なので別 repository task。

### #50. **planner test stub の MOP / 非標準 helper 排除** (existing #41 強化)

**観察**: ARGLIST / FUNCTION-LAMBDA-LIST / CLASS-SLOTS 等を planner が test 内で参照
(`exported-symbols` 等は別 issue)。**5/427 verify failures** (1%) と頻度低だが、
出現すると step 内で **完全に解決不能** (agent が CL に追加実装することはない)。

実例:
- `COUNTER/TESTS/MAIN-TEST::CLASS-SLOTS` (3 occurrences)
- `GREET/TESTS/MAIN-TEST::ARGLIST` (2)
- `DOUBLE/TESTS/MAIN-TEST::FUNCTION-LAMBDA-LIST` (1)

**処置**: 既存 backlog #41 (planner test stub に未定義 helper を含めない) を **priority up**。
本データで具体的 symbol list が判明したので prompt に negative example として埋め込み可能:
```
Tests must use only standard CL functions and rove primitives.
Do NOT call: class-slots, arglist, function-lambda-list, exported-symbols,
slot-value (use accessors), or any MOP function.
```

**期待効果**: planner が MOP/non-standard helper を含む test を生成しなくなり、解決不能 stuck
が消える。step-level :stuck の一部 (~5%) を救済。

**コスト**: small + half-day (planner prompt 修正 + planner-test regression)。

### #51. **agent prompt: ファイル状態 check の hint** (low-medium impact)

**観察**: lisp-read-file の "file not found" / "Is a directory" / fs-list-directory の
permission denied 等が **34/230 (15%)**。agent が exists を確認せずに read を試みる。

**変更案**: system-prompt の workflow section に明示:
```
Before attempting to write/edit a file, run lisp-read-file with collapsed=true
to confirm it exists and to see existing top-level forms. If lisp-read-file
returns "file not found", create the file via fs-write-file first (only for
new files; see fs-write-file note above).
```

**期待効果**: 各 step の前半 turn の試行錯誤 (5-10% wall-clock) 削減。

**コスト**: small + 1 hour (prompt + test)。

### #52. **lisp-edit-form: form not found 時に近似 form-name suggestion** (low impact, complement to #49)

**観察**: ~6 occurrences of "Form defclass simple-cache not found in src/main.lisp"。
form-name typo / form 未生成 / 別 file の confusion 等。

**変更案**: cl-mcp 側で `lisp-edit-form` が form-not-found 返却時、同 file 内の top-level
form name 一覧を返す。

**期待効果**: agent の次 attempt 精度向上。

**コスト**: small + half-day (cl-mcp 側、#49 と同種なのでセット実装可)。

## Cross-cutting observations

### A. **34% の patch fail rate が agent quality 改善の最大の lever**

`patches_fail / total = 127/374 = 34%`。仮に半減できれば:
- patch budget が事実上 2 倍に
- wall-clock も比例 (失敗 patch の re-attempt 分が消える)
- pass rate も比例向上

→ #48 (fs-write-file 誤用 1 turn 節約) + #49 (old_text suggest) + #52 (form-name suggest)
の **3 件で patch fail の 65-70% をカバー** する。

### B. **`:max-consecutive-failed-patches` (#45) は既に 3 件 fire**

bench history で 3 cells が #45 limit で早期 give-up。各 ~600-800s で abort できており、
無限 patch spiral から救出している。前回 sweep (pre-#45) では同 pattern が ~2000-2700s
まで burn して :MAX-PATCHES で die していた。#45 は **wall-clock を ~3x 節約** している
証拠 (N=多ではないが directional)。

### C. **undefined-function 67% は agent prompt より test シナリオ依存**

verify failure の 67% (287/427) が undefined-function だが、内訳は agent が「step ごとに 1
symbol ずつ追加する」段階で観測される自然な進行。これは failure ではなく progress signal。
但し以下 2 サブカテゴリは明確な improvement target:
- 同 step 内で **3+ 回同 symbol が undefined** → patch が機能していない / wrong package
- planner stub の non-CL helper (#41/#50 領域)

### D. **agent はほぼ独力で copy-paste 漏れを修正できる**

high-fail-step examples で agent は 3 failed patches 後でも 2 successful patches で軟着陸
することが多い。Qwen3.6 は **error feedback を読んで自己修正する能力はある** ので、
tool 側 feedback の richness 改善 (#49 / #52) が直接 quality に effect する。

## 推奨優先度

| # | 内容 | 影響 | コスト | ROI |
|---|---|---|---|---|
| #48 | fs-write-file workflow guidance | high (29% of errors) | small | ★★★ |
| #50 (=#41 強化) | planner stub MOP 排除 | medium (stuck 救済) | small | ★★★ |
| #51 | file exists check hint | medium-low | small | ★★ |
| #49 | old_text 近似 suggest (cl-mcp) | medium | medium | ★★ |
| #52 | form-name 近似 suggest (cl-mcp) | low | small | ★★ |

**今 cycle 推奨**: #48 と #50 を small 実装、次 bench で empirical 検証 (#46 fixed-plan
で paired)。#49/#52 は cl-mcp 側で別 repo task。

## 既存 backlog との関係

- **#41 を強化** (本 doc #50): MOP helper の具体 list 判明
- **#45 が works as designed** を実証 (3 fire 観察)
- **#46 が works as designed** を実証 (paired bench 6+20 cells 成立)
- **#40 (complete-chat retry)** は本 data では発火頻度低、優先度 下げてよい

## 副次成果

- N=10 paired bench data が backlog candidate generation に直接利用可能
- bench-cycle skill (`/bench-cycle`) の output JSONL が長期的に value 持つ data store
- 13k+ step transcripts は zero-cost で改善源として retrievable
