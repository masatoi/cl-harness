# cl-harness-next 実機実験記録 — 2026-06-13

SP1–SP8 完了直後の `cl-harness-next` を、初めて実環境(実 cl-mcp stdio 子プロセス
+ 実 LLM)で連続運転した記録。ユニットテスト 229 件が緑でも実環境でしか出ない欠陥が
多数あり、その全てが当日中にテスト付きで main に反映された(229 → 249 件)。

- 実行環境: ローカル vLLM(`Qwen/Qwen3.6-35B-A3B`、OpenAI 互換)、
  fixture は `~/.roswell/local-projects/clh-demo/`(`add` が `(- a b)` になっている
  1 ファイル 2 アサーションの最小プロジェクト)
- 実行方式: 長時間ジョブは standalone ros プロセス(`/tmp/clh-*.lisp`)で実行。
  cl-mcp の `repl-eval` はタイムアウト後も評価スレッドが生き残るため、
  ミッション級のジョブには不向き(本記録の運用上の発見の一つ)

---

## 実験 I: scripted dial 実機デモ

**結果**: 缶詰診断(Demo A)・実 LLM 診断(Demo B、LLM 1 回・26 秒)とも
`:done` "clean verification green"。

**発見**:

1. **stale fasl(秒精度)**: ASDF の鮮度判定は `file-write-date`(秒精度)。
   ゼロレイテンシの缶詰診断ではパッチが直前コンパイルと同一秒に落ち、
   再コンパイルされず「永遠に赤」。逆方向(対トライアルの free-green、実験 II)もある。
2. **cl-mcp `clear_fasls` が package-inferred-system で無効**: 実装が
   `(asdf:load-system name :force t)` で、ASDF の `:force t` は指名システムのみ強制
   (依存サブシステム = 実コードは対象外)。cl-mcp 側を修正
   (fasl を output translation 配下から実削除、PR #115、マージ済み)し、
   harness 側は verification oracle に `:clear-fasls` オプションを追加。
3. **stdio 子 cl-mcp の worker pool は親プロセス依存**: cl-mcp の worker 内から
   spawn すると pool 無効(`pool-kill-worker` が no-op → clean verify が名目化)。
   standalone プロセスから spawn すれば pool 有効で本物のクリーン検証になる。
4. **Qwen の thinking 暴走**: 薄い failure-analysis ビューを渡すと thinking が
   max_tokens を食い尽くし content=null(`:empty-content` リトライ→事実上のハング)。

## 実験 II: improve-once(L5)2 周

**cycle 1 — PROMOTED**: ナイーブ診断プロンプトの champion(誤引数ループで
2×PARKED + 1×FAILED)に対し、proposer の :prompt 変異(スキーマ明示 + /no_think)が
対トライアル 3 勝 0 敗 → net +3 で自動昇格。audit log に両 fingerprint 付き昇格イベント。

**cycle 2 — REJECTED**(miner v2 込み・evidence 自動注入): proposer の提案は
「スキーマ強制」を謳いつつ自前の例示が誤スキーマで `/no_think` も欠落した劣化版。
0 勝 3 敗 → net −3 で棄却、champion 防衛。
**初回 run は free-green artifact(champion 末尾の修正版コンパイルと次トライアルの
バグ復元が同一秒 → challenger の baseline が緑のまま)で :inconclusive に偽装されており、
trial-fn の fixture reset に fasl 削除を入れた再実行で正しい :rejected が出た。**
教訓: ベンチの完全性が判定を変える。challenger の不自然に少ない action 数は汚染シグナル。

**miner v2**(この周回の必要から実装): error-samples / error-argument-samples /
give-up-reason / park-reason / `:give-ups` `:parks` モード /
`summarize-failure-evidence` — improve-once が evidence を proposer プロンプトに自動注入。

## 実験 III: guided dial 9 runs — view 改善の連鎖

各 run の失敗が L2 view の欠陥を 1 つずつ特定し、その場で修正・マージした。

| run | 失敗モード | 反映(コミット) |
|---|---|---|
| 1 | 読み取り結果が view に皆無 → read ループ | `c71704f` source facts に内容(480 字)+ dedupe、failure reason を description+values から合成 |
| 2 | stale な旧ソースが「未修正」に見える → patch ループ | `34829b8` stale 内容を抑制し再読ヒントに |
| 3 | パッチ前の赤い検証情報が騙す → 再読ループ | `89f53b7` 「[predates the last patch — re-run tests]」注釈 |
| 4 | max-tokens 2048 で応答切断 | (runner 設定) |
| 5 | 消えない re-read ヒントに従い続ける | `5db44ad` superseded stale fact は view から落とす |
| 6 | 失敗したツール呼び出しが不可視 → 混乱して thinking 暴走 | `f0569ca` isError 結果も `last-action-error` に(transport と対称) |
| 7 | finish 宣言の判断点で thinking 暴走(`/no_think` 貫通) | (runner: `chat_template_kwargs: {"enable_thinking": false}`) |
| 8 | thinking OFF: 高速・自己修正するが finish 不能 + 応答切断 | (runner: 行動経路付き agenda) |
| 9 | **90 秒でテスト緑に到達**、しかし緑 run-tests を 12 連発 | → 実験 IV へ |

**中心的発見**: このモデルは guided で「修正作業」は完遂できるが
「完了の自己宣言」ができない。thinking ON では判断点で暴走、OFF では跳躍不能。
scripted(FSM が完了判定を所有)では同モデルが安定成功 —
**自律度はモデル能力に合わせて下げるべき**という spec の中心仮説の最初の実データ。

## 実験 IV: adaptive dial — spec §6.1 の実機実証

**run A(弱構成 guided → scripted)**: パッチツール名のみ・スキーマ無しの
guided が誤引数パッチ 3 連敗 → `progress-stalled` → **demote-dial**(ログに dial
イベント)→ scripted が実 LLM 診断で `:done` clean green。14〜15 actions、LLM 8 回。

**盲点 2 件**: ①ツール知識ゼロの guided は「試みず読みループ」になり、
②run 9 の green ping-pong も、いずれも governor の progress 語彙
(失敗パッチ/失敗 verify の stall)に映らない — どちらも「何も失敗していない」。

**ガード実装**(`44328ae`): 両者は「同一(tool+正規化引数)アクションの連続」
という共通構造を持つ。governor に `identical consecutive actions` カウンタを追加
(デフォルト閾値 4、`:progress` カテゴリ → adaptive の demote 対象)。

**run B(run 9 と同一構成 + 新ガード)**: 緑 run-tests 4 連発でガード発火 →
demote → scripted は緑 baseline を確認し**診断 LLM 0 回で**クリーンゲート →
`:done`。**run 9 で無限 grind だった構成が 14 actions で完走に変わった。**

## ダイヤル比較(Qwen3.6-35B-A3B × clh-demo、初データ)

| dial | 結果 | actions | LLM calls |
|---|---|---|---|
| scripted | :done(安定) | 9 | 1 |
| guided | 修正完了するが完了宣言不能(park/give-up) | 6〜16 | 5〜17 |
| adaptive (guided→scripted) | **:done**(demote 1 回) | 14〜15 | 8 |

## あわせて入った機構(post-SP8、本日 main マージ分)

- miner v2 + evidence 自動注入(`79304b8` `be15340`)
- verification oracle `:clear-fasls` + 両 policy へのスレッディング(`c8d40a7`)
  ※ cl-mcp 側修正(PR #115)とセット
- park/abort 終端イベント — ミッションが黙って終わらない(`e0e12db`)
- view の観測内容搬送 4 連(`c71704f` `34829b8` `89f53b7` `5db44ad`)
- ツールエラーの last-action-error 反映(`f0569ca`)
- governor identical-action ガード(`44328ae`)

## 残バックログ

- llm-step-policy の fail-closed 寛容度: parse 失敗 1 回で give-up は
  マルチステップでは厳しすぎる可能性(K 回まで last-action-error に載せて続行)
- bench の汚染検出: 両 pack の action プロファイル乖離(free-green 型)を警告
- 逐次検定 / early stopping(bench v2)、`drain` ループ + dossier ファイリング
- 多 fixture 化と「モデル × 自律度」マトリクスの系統測定(improve-once と接続)
- guided の agenda/invariants を policy pack 化(現在は呼び出し側データ —
  L5 の変異対象に載せる)
