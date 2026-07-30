# context-checker

コンテキスト残量を見張り、圧縮を生き延びる。

コンテキストウィンドウの使用率を表示し、逼迫したら1回だけ警告し、transcript が要約で
消える直前に「いま何をしていたか」を checkpoint として書き出す Claude Code プラグイン。
圧縮によって作業の文脈が無言で失われるのを防ぐ。

English version: [README.md](README.md)

## 構成

| コンポーネント | イベント | 動作 |
| --- | --- | --- |
| `statusline.py` | status line | `[OK] ctx 24% \| Opus 5 \| my-project` を表示し、使用率をフックが読める形で記録する |
| `prompt-submit.py` | `UserPromptSubmit` | 60% を上向きにまたいだとき1回、75% でもう1回だけ警告を注入する。同レベル内では繰り返さない |
| `pre-compact.py` | `PreCompact` | checkpoint markdown を書き出す（直近の user メッセージは逐語、assistant は切り詰め、編集ファイル、実行コマンド） |
| `post-compact.py` | `PostCompact` | その checkpoint のパスを Claude に伝える。要約が落とした文脈をここから復元できる |
| `context-checkpoint` | skill | 構造化された checkpoint を作り、`/compact <instructions>` の文面を起草する。実行するかは人間が決める |

Python 3 標準ライブラリのみ。依存パッケージなし、通信なし。

## インストール

### 1. プラグインを追加

```
/plugin marketplace add <your-github-user>/context-checker
/plugin install context-checker@context-checker
```

これで3つのフックと skill が有効になる。

### 2. status line を追加（必須・手動）

**Claude Code のプラグインは status line を提供できない** — プラグインの settings で
サポートされるのは `subagentStatusLine` だけで、メインの `statusLine` は対象外。
status line がないとフックが読む使用率が存在しないので、`~/.claude/settings.json` に
自分で追記する：

```json
{
  "statusLine": {
    "type": "command",
    "command": "python3 \"$HOME/.claude/plugins/marketplaces/context-checker/hooks/statusline.py\""
  }
}
```

パスは実際のインストール先に合わせること（`/plugin` で確認できる）。
プラグイン機構を使わず導入する場合は [docs/manual-install.md](docs/manual-install.md) を参照。

この手順を飛ばした場合、無言で無効化されるのではなく**セッションにつき1回**その旨を通知する。
`CONTEXT_CHECKER_CONTEXT_WINDOW` に窓サイズ（トークン数）を設定すれば、transcript から
使用率を推定する経路も使える（[精度](#精度) を参照）。

## 設定

すべて任意。環境変数から読む（`settings.json` の `env` でよい）：

| 変数 | 既定値 | 意味 |
| --- | --- | --- |
| `CONTEXT_CHECKER_NOTICE_PCT` | `60` | 1段目の警告閾値 |
| `CONTEXT_CHECKER_WARN_PCT` | `75` | critical 警告の閾値 |
| `CONTEXT_CHECKER_STATE_TTL_DAYS` | `14` | この日数を超えたセッション state ファイルを削除 |
| `CONTEXT_CHECKER_CONTEXT_WINDOW` | 未設定 | transcript 推定に使う窓サイズ（トークン数） |

`CLAUDE_AUTOCOMPACT_PCT_OVERRIDE` を設定している場合、自動圧縮は既定より早く発動する。
`CONTEXT_CHECKER_WARN_PCT` をそれより下に置かないと、防ぎたかった圧縮のあとに
critical 警告が届くことになる。

## 書き出すファイル

```
~/.claude/tmp/context-checker/<session>.json         使用率スナップショット（TTL で削除）
~/.claude/tmp/context-checker/<session>.seen.json    どの閾値まで警告済みか
~/.claude/checkpoints/context-checker/<session>-<ts>.md   圧縮前 checkpoint
~/.claude/checkpoints/context-checker/<session>.latest    最新 checkpoint へのポインタ
```

checkpoint は自動削除しない。作業内容そのものなので、消すかどうかは利用者の判断に委ねる。

## 精度

status line の数値は Claude Code 自身が算出した値で、正確。

transcript からの推定は「窓サイズを明示したときだけ」使う。理由は以下のとおり。

Claude Code が公開している使用率の計算式は入力トークンのみを数える：
`input_tokens + cache_creation_input_tokens + cache_read_input_tokens`。
この値は transcript に記録されている。しかし**分母となる窓サイズは記録されていない**。
transcript のどこにも現れず、モデル ID からも決まらない。同じ `claude-sonnet-5` でも
アカウントによって 200k 窓のことも 1M 窓のこともある。

status line の実測値と transcript の両方が残っている実セッション53件で検証したところ、
窓サイズが正しければ 52件が誤差1ポイント以内に収まった（中央値 0.30pt）。
一方、モデル ID から窓サイズを推測する実装では誤差が70ポイントを超え、
実使用率19%のセッションで CRITICAL を出した。
そのため本プラグインは推測しない。窓サイズの宣言がなければ、パーセンテージも出さない。

なおこの検証データは単一アカウントのもので、全セッションが 1M 窓だった。つまり検証できたのは
「トークン計算式の正しさ」であって「窓サイズの範囲」ではない。それがまさに要点で、
式は信頼できるが、分母は利用者が与えるしかない。

## テスト

```
bash tests/smoke.sh
```

使い捨ての `HOME` の下で、モックペイロードに対して全フックを実行する。表示、閾値の
またぎと非重複、窓サイズ宣言の有無による推定の切り替え、sidechain の除外、checkpoint の
中身、state の刈り取り、壊れた stdin への耐性を検証する。

## 制約

- status line は手動設定が必要（Claude Code 側の制約であって、設計上の選択ではない）
- `PreCompact` は transcript を読むので、checkpoint に入るのはディスクに書かれた内容まで
- フックから skill は起動できないため、`context-checkpoint` は警告文をトリガーに呼ばれる

## ライセンス

MIT — [LICENSE](LICENSE) を参照。
