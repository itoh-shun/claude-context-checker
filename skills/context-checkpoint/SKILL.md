---
name: context-checkpoint
description: コンテキスト圧縮の前後で「失っていい情報」と「残すべき情報」を整理し、checkpointファイルへの書き出しと/compact用の指示文生成を行う。Triggers on context checkpoint, /compact 準備, コンテキスト圧縮, 圧縮前, 圧縮の準備, ctx warn, ctx critical, 60% 75% コンテキスト
user-invocable: true
---

# Context Checkpoint — コンテキスト圧縮の半自動化スキル

`context-checker` フック群と対になるスキル。**フックが警告を上げた / 自動圧縮が迫っている / ユーザーが `/compact` を打つ前** に呼び出される。

このスキルは次の3つを行う：

1. **現在の作業状態を点検する**（タスク、編集中ファイル、未解決の質問、テスト結果）
2. **checkpoint markdown を書き出す**（フックの自動 checkpoint より人間可読・構造化されたもの）
3. **`/compact <instructions>` 用の指示文を生成する**（最後の打鍵は人間）

最後の `/compact` 実行はユーザーに委ねる。本スキルが勝手に圧縮を発動させない。

## 入力の確認

呼び出されたら、まず以下を確認する。

- 現在のコンテキスト使用率（statusline、または `~/.claude/tmp/context-checker/{session_id}.json` の `used_pct`）
- 直近のフック checkpoint があるか（`~/.claude/checkpoints/context-checker/{session_id}.latest` → markdown へのパス）
- 進行中のタスク（TaskList で取得）
- 直近の編集対象ファイル（フック checkpoint の「Files touched」セクション、または `git status`）

## checkpoint の書き出し

`~/.claude/checkpoints/context-checker/manual-{session_id}-{YYYYMMDD-HHMMSS}.md` に以下の形式で保存する。

```markdown
# Manual Checkpoint — <timestamp>

## いまやっていること
- ゴール: <一文>
- フェーズ: <調査 / 設計 / 実装 / 検証 / レビュー対応>
- 完了したサブタスク: <箇条書き>
- 残タスク: <箇条書き>

## 触っているファイル
- `path/to/file.ext` — <この回で何を変えた / 何を変える予定か>

## 仮説 / 決定 / 制約
- 採用した方針: <一文>
- 却下した方針: <一文 + 理由>
- 外部制約: <ライブラリのバージョン、ユーザーの好み、過去メモリ>

## 未解決
- 質問: <ユーザーへの確認待ち項目>
- 失敗中: <落ちているテスト・エラーメッセージ・再現手順>

## 復旧手順
1. このファイルを読む
2. `git status` / `git diff` を実行
3. <次にやるべき具体コマンドや次の一手>
```

各セクションは**埋められないなら省略**する。空欄を埋めるための憶測は書かない。

## /compact 指示文の生成

`/compact <instructions>` の `<instructions>` 部分を1〜3段落で組み立て、ユーザーに提示する。原則：

- **何を残すか**を肯定形で書く（例：「現在進行中の hooks 実装の決定事項とファイルパス」）。「何を捨てるか」は書かない（要約モデルがそれに引っ張られる）
- 上記 checkpoint ファイルへの**絶対パスを必ず含める**（圧縮後に Read で復元できるように）
- 進行中タスクの**識別子（TaskCreate の ID）**を残す
- ユーザーがフィードバックした重要事項があれば短く再掲

雛形：

```
<作業内容>セッションの圧縮指示:
- ゴールと採用方針を保持: ~/.claude/checkpoints/context-checker/manual-<session>-<ts>.md
- 進行中タスク: TaskList ID #2-#4
- 直近のユーザー指示: 「<ユーザーの最後の重要発言を1行>」
- 未解決の検証項目: <あれば1行>
要約後、上記 checkpoint ファイルを最初に読み、現在地を再確定してから次の手を打つこと。
```

最後に、**ユーザーが実際に `/compact` を打つかどうか確認する**。ユーザーが打たない選択をしたら、checkpoint ファイルパスだけ提示してスキルを終える。

## フック側の挙動（参考）

このスキルが前提としているフックの動作：

- **statusLine**: 各ターンで `~/.claude/tmp/context-checker/{session_id}.json` に `used_pct` を記録
- **UserPromptSubmit**: 60% / 75% を上向きにまたいだとき1回だけ通知を注入（同レベル内では繰り返さない）。statusLine を入れていない場合は transcript のトークン使用量から推定した値を使う
- **PreCompact**: `~/.claude/checkpoints/context-checker/{session_id}-{ts}.md` に直近の user/assistant メッセージ・編集ファイル・bash 履歴をダンプし、`{session_id}.latest` にパスを記録
- **PostCompact**: 圧縮直後に `.latest` のパスを stdout 注入。これを読めば失われた文脈を取り戻せる

閾値は環境変数 `CONTEXT_CHECKER_NOTICE_PCT` / `CONTEXT_CHECKER_WARN_PCT` で変更できる。

なお `~/.claude/settings.json` の `env` に `CLAUDE_AUTOCOMPACT_PCT_OVERRIDE` を設定している場合、自動圧縮はデフォルトより早く発動する。例えば `70` を設定していると、75% の警告が出る前に自動圧縮が走ることがある。その環境では `CONTEXT_CHECKER_WARN_PCT` を自動圧縮の閾値より下げておくとよい。

## やらないこと

- スキルから `/compact` を直接実行する（API がない）
- フックから skill を起動する（API がない）
- 自動 checkpoint を上書きする（フックのものは別パス）
- 通常会話のたびに発動する（フック通知 or ユーザー明示呼び出し時のみ）
