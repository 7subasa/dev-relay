---
name: setup
description: dev-relay が使う道具（Codex CLI、Cursor CLI、jq、Herdr）の状態を調べ、足りないものの入れ方を案内し、コードを送ってよい提供元と、追加のレビュアーを使うかを選択式で設定する。インストール直後、レビュアーが選ばれない・飛ばされるとき、「dev-relay のセットアップ」と言われたときに使う。
---

# dev-relay: setup

dev-relay が使う道具の状態を調べ、足りないものを案内し、設定を決める。

- 利用者に選んでもらうところは、すべて選択式にする（AskUserQuestion）。自由記述で答えさせない。
- Codex CLI、Cursor CLI、`jq` は、このスキルでは入れない。インストールとログインに契約と対話が要るため。入れ方を示すだけにする。
- 入れるのは Herdr（`hc`）だけ。利用者が手順3で選んだときに限る。

## 手順

### 1. 道具の状態を調べる

`dev-relay doctor` を実行し、結果を表にして見せる。

| 道具 | 状態 | 無いとどうなるか |
|---|---|---|

- `tool.codex`、`tool.cursor`、`tool.jq`、`tool.herdr` の値を状態の列に書く。
- 無いとどうなるか: Codex CLI は、レビュアーに Codex を選べない。Cursor CLI は、Cursor 経由のレビュアーを選べない。`jq` は、Cursor のレビュアーが動かない（Codex だけ、または Claude だけなら要らない）。Herdr は、レビューの途中経過を端末で見られないだけで、手順は同じように動く。
- どちらの CLI も無くても、Claude のレビュアーで最後まで進む。

### 2. 足りない道具の入れ方を示す

実行はしない。入れ方を示すだけにする。

- Codex CLI: `npm i -g @openai/codex` のあと `codex login`
- Cursor CLI: 公式の案内（https://cursor.com/docs/cli/overview）に従って入れ、`cursor-agent login`
- `jq`: Cursor のレビュアーを使うときだけ要る

### 3. Herdr を入れるか尋ねる

`tool.herdr=not-installed` のときだけ行う。すでに入っているなら、手順4へ進む。

最初に、インストール先を求める: `${HC_INSTALL_DIR:-$HOME/.local/bin}`。以下の説明、確認、PATH の案内には、すべてこの値を使う（`~/.local/bin` と決め打ちしない）。

尋ねる前に、次を利用者に示す。

- 実行するコマンドは `curl -fsSL https://releases.herdr.dev/core/install.sh | sh`。
- 入ると、レビューの途中経過を端末で見られる（Claude Code を Herdr の端末の中で起動したとき）。無くても、このプラグインは同じ手順で動く。
- インストーラがすること（2026-11-11 に中身を読んで確認した）:
  - インストール先に `herdr-core` と、`hc` という名前のリンクを置く。
  - macOS では、署名を確かめたうえでアプリの形（Herdr Core.app）で入れる。
  - ダウンロードしたファイルは SHA-256 で照合する。
  - PATH やシェルの設定ファイルは書き換えない。
  - 新しく入れたときは、常駐するプロセスを起動しない。
  - `curl` と `tar` が要る。対応は macOS と Linux。ライセンスは Apache-2.0。更新は `hc update`。

選択肢は2つにする。

- 入れる
- 入れない

選ばれた方で進める。

- 「入れる」: 上のコマンドを実行し、`<インストール先>/hc --version` で確かめる。インストール先が PATH に無ければ、PATH に足す必要があることを伝える（設定ファイルは書き換えない）。
- 「入れない」: そのまま手順4へ進む。

### 4. 利用者の既定の送り先を決める

コードを送ってよい提供元の、利用者の既定を決める。設定が無いうちは、コードを外部に送らず、Claude のレビュアーで進む。

`config.vendors` が `unset` のときに尋ねる。すでに決まっているときは、今の値を見せて、変えるかを尋ねる（選択肢は「変える」「変えない」）。

選択肢は次の3種類。「いつも同じ一覧」の中身は、手順1で分かった入っている道具から組み立てる。

- リポジトリごとに尋ねる（`ask`）
- いつも同じ一覧を使う（例: `openai`。Cursor CLI もあれば `openai,cursor,xai` や `openai,cursor,xai,google` も選択肢に出す）
- 外部には送らない（`none`）

答えを `dev-relay config vendors --user <一覧|none|ask>` で書く。

### 5. このリポジトリの送り先を決める

今のディレクトリが git リポジトリ（`git.repo=yes`）で、次のどちらかのときに行う。

- 利用者の既定が `ask`（手順4で `ask` を選んだ。または、前から `ask` で、手順4で「変えない」を選んだ）。
- 利用者が、このリポジトリだけ送り先を変えたいと言っている（利用者の既定が一覧や `none` でも行う）。

このリポジトリにすでに設定があるとき（`repo.vendors.source=repo`）は、今の値を見せて、変えるかを尋ねる（選択肢は「変える」「変えない」）。

このリポジトリで送ってよい提供元を、選択式で尋ねる。選択肢は手順4と同じ作り方で、「外部には送らない（`none`）」を含める。答えを `dev-relay config vendors --repo <一覧|none>` で書く。

リポジトリごとの設定は、利用者の既定より優先する。

### 6. 追加のレビュアーを使うか決める

Cursor CLI が使えるとき（`tool.cursor=ok` かつ `tool.jq=ok`）だけ行う。

利用量に応じて課金されうるレビュアーを使うかを尋ねる。選択肢は次の2つ。

- 使わない（`off`。既定）
- メインセッションの判断で使う（`auto`）

答えを `dev-relay config metered off` または `dev-relay config metered auto` で書く。

### 7. 結果を確かめる

`dev-relay doctor` をもう一度実行し、役割ごとに選ばれるレビュアーと、飛ばされた候補の理由を見せる。

- `role.design-review`、`role.code-review`、`role.code-review-extra` の値と、それぞれの `skipped` を表にする。
- 理由が `vendor-not-allowed` なら、手順4か5の答えで許可していない提供元があるということ。意図どおりかを利用者に確かめてもらう。
- 変えたいときは、`/dev-relay:setup` をもう一度実行するか、`dev-relay config` を直接使う。設定はプラグインの外に保存されるので、プラグインを更新しても消えない。
