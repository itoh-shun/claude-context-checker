# context-checker

コンテキスト残量を見張り、圧縮を生き延びる。

コンテキストウィンドウの使用率を表示し、逼迫したら1回だけ警告し、transcript が要約で
消える直前に「いま何をしていたか」を checkpoint として書き出す Claude Code プラグイン。
圧縮によって作業の文脈が無言で失われるのを防ぐ。

English version: [README.md](README.md)

## 構成

| コンポーネント | イベント | 動作 |
| --- | --- | --- |
| `statusline.py` | status line | コンテキスト使用率・自動圧縮ポイント・モデル・effort・プラン上限を表示し、使用率をフックが読める形で記録する |
| `subagent-statusline.py` | subagent status line | エージェント各行の生トークン数を、そのエージェント自身の窓に対する割合に置き換える |
| `prompt-submit.py` | `UserPromptSubmit` | 閾値を上向きにまたぐたび1回だけ警告を注入する。同レベル内では繰り返さない |
| `pre-compact.py` | `PreCompact` | checkpoint markdown を書き出す（直近の user メッセージは逐語、assistant は切り詰め、編集ファイル、実行コマンド） |
| `post-compact.py` | `PostCompact` | その checkpoint のパスを Claude に伝える。要約が落とした文脈をここから復元できる |
| `context-checkpoint` | skill | 構造化された checkpoint を作り、`/compact <instructions>` の文面を起草する。実行するかは人間が決める |

Python 3 標準ライブラリのみ。依存パッケージなし、通信なし。

```
[WARN] ctx 62% → auto 70% | Opus 5 (1M context) | high·think | 5h 27% · 7d 35% | my-project
```

```
[OK]   Explore · search auth flow · 6%
[WARN] code-reviewer · review diff · 62%
```

後者はエージェントパネル。`48.1k` というトークン数だけでは判断できない
（1M 窓なら余裕、200k 窓なら半分近い）ので、各行に割合を出す。閾値はメインバーと同一。

## インストール

### 1. プラグインを追加

```
/plugin marketplace add itoh-shun/claude-context-checker
/plugin install context-checker@context-checker
```

これで3つのフック・skill・subagent status line が有効になる。

### 2. メインの status line を追加（必須・手動）

**Claude Code のプラグインはメインの status line を提供できない** — プラグインの settings で
サポートされるのは `subagentStatusLine` だけ。エージェント行が最初から動いてメインバーが
動かないのはこのため。status line がないとフックが読む使用率が存在しないので、
`~/.claude/settings.json` に自分で追記する：

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
| `CONTEXT_CHECKER_NOTICE_PCT` | `60`／自動圧縮の15pt手前 | 1段目の警告閾値 |
| `CONTEXT_CHECKER_WARN_PCT` | `75`／自動圧縮の5pt手前 | critical 警告の閾値 |
| `CONTEXT_CHECKER_STATE_TTL_DAYS` | `14` | この日数を超えたセッション state ファイルを削除 |
| `CONTEXT_CHECKER_CONTEXT_WINDOW` | 未設定 | transcript 推定に使う窓サイズ（トークン数） |
| `CONTEXT_CHECKER_STATUSLINE_SEGMENTS` | `ctx,model,session,limits,cwd` | status line に出すセグメントと順序 |
| `CONTEXT_CHECKER_RATE_LIMIT_MIN_PCT` | `0` | この%に達するまでプラン上限の表示を隠す |

### 自動圧縮ポイントへの追従

自動圧縮が70%で発動する環境で75%に固定して警告しても意味がない。防ぐはずだった圧縮の
**あとに** critical 警告が届く。そこで `CLAUDE_AUTOCOMPACT_PCT_OVERRIDE` が設定されている
場合は閾値がそれに追従する（notice は15pt手前、critical は5pt手前）。
`CONTEXT_CHECKER_*_PCT` を明示すればそちらが優先される。

status line には基準にしているポイントを表示する：

```
[WARN] ctx 62% → auto 70% | ...
```

Claude Code は組み込みの自動圧縮閾値をフックに公開していないため、変数が未設定なら
矢印は出さず、既定の 60/75 で動く。

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

使い捨ての `HOME` の下で、モックペイロードに対して62アサーションを実行する。表示と
セグメント選択、閾値のまたぎと非重複、自動圧縮ポイントからの閾値導出、窓サイズ宣言の
有無による推定の切り替え、sidechain の除外、subagent 行の描画と桁数制限、checkpoint の
中身、state の刈り取り、壊れた stdin への耐性。さらに `hooks.json` と `settings.json` の
コマンド文字列をシェル経由で実行し、`${CLAUDE_PLUGIN_ROOT}` が実際に展開されることも確認する。

## 制約

- メインの status line は手動設定が必要（Claude Code 側の制約であって、設計上の選択ではない）。
  subagent 側はプラグインに同梱される
- エージェントごとの割合表示には Claude Code v2.1.205 以降が必要。モデル未解決の行は
  でっちあげた数値を出さず、既定の描画のままにする
- `PreCompact` は transcript を読むので、checkpoint に入るのはディスクに書かれた内容まで
- フックから skill は起動できないため、`context-checkpoint` は警告文をトリガーに呼ばれる

## ライセンス

MIT — [LICENSE](LICENSE) を参照。
