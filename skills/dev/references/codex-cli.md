# Codex CLI リファレンス（このスキルが使う範囲）

2026年11月時点（codex-cli 0.166.0 で確認）の仕様。Codex CLI は更新が速いので、フラグが通らないときは `codex --help` / `codex exec --help` で確かめる。

## インストールと認証

```bash
npm i -g @openai/codex        # または brew install codex
codex --version
codex login                   # ChatGPT アカウントでブラウザ認証
codex login status
```

CI など対話ログインができない環境では、`CODEX_API_KEY` 環境変数で API キー認証もできる。

## このスキルの呼び方

`dev-relay review` は次の形で Codex を1回だけ実行する。

```bash
codex --no-daemon --sandbox read-only -c 'model_provider="openai"' \
  -c 'model_reasoning_effort="high"' \
  exec --skip-git-repo-check -o <結果ファイル> - < <プロンプトファイル>
```

- `exec` は非対話実行。`-` で標準入力からプロンプトを読み、`-o` で最終メッセージをファイルに書く。結果ファイルを書くのは Codex のモデルではなく CLI 本体なので、サンドボックスが読み取り専用でも結果が残る。
- `--sandbox read-only` はレビュアーに作業ツリーを変更させないため。実装者と同時に編集して衝突するのを防ぐ。
- `--no-daemon` は共有のバックグラウンドサーバーを使わずに動かす指定。Herdr (hc) の端末の中で Codex を動かすときに必要とされている。古い CLI にはこのフラグが無いので、スクリプトは `codex --help` に載っているときだけ付ける。
- `--skip-git-repo-check` は、git リポジトリの外でも実行できるようにする。設計レビューでもコードレビューでも付ける。
- グローバルフラグ（`--sandbox`、`-c`、`--model`、`--no-daemon`）はサブコマンド `exec` の前に置く。

### `model_provider="openai"` を付ける理由

Codex CLI は、利用者の設定ファイルで接続先（プロバイダー）を変えられる。`-c 'model_provider="openai"'` を付けないと、役割のファイルの候補に送り先として `openai` と書いてあっても、別の接続先に差分と設計書が送られうる。そのため必ず付けている。付けた状態で実行でき、ログに `provider: openai` と出ること、存在しないプロバイダー名を渡すと終了コード 1 で `Model provider ... not found` と出ることを確かめた。

限界:

- Codex CLI に、別のプロバイダーだけを設定している利用者は、このレビュアーを使えない（実行が失敗して、終了コード 10 になる）。
- 利用者が、OpenAI のプロバイダーの接続先 URL そのものを書き換えている場合までは確かめていない。

## 読み取り専用サンドボックスでできること

codex-cli 0.166.0 / macOS で確かめた結果。

| 操作 | 結果 |
|---|---|
| コマンドの実行（`python3 -c ...` など） | できる |
| 作業フォルダへの書き込み | できない |
| 一時フォルダ（`$TMPDIR`、`/tmp`）への書き込み | できない |
| ネットワーク | 使えない |
| `hc` への接続 | できない |

このため Codex は、キャッシュや一時ファイルを書くテストランナーを実行できないことが多い。レビュープロンプトが「実行できなかった確認は未実行と書き、こちらで実行できる形で渡す」と求めているのはこのため。また、対話型の Codex に「終わったら `hc send` で報告して」と頼む方法は、読み取り専用のままでは使えない。

## `codex review` を使わない理由

Codex には組み込みの `codex review --uncommitted | --base <branch> | --commit <sha>` があるが、対象フラグと追加の指示文を同時に渡せない（CLI 0.130 以降は引数エラー）。このスキルは「変更の目的」を必ず渡して、目的に反する動作だけを指摘させるので、差分を git で集めて `codex exec` に渡す。

## モデルと推論量

```bash
dev-relay review code --model <モデル名> --effort xhigh ...
```

- 省略すると、モデルは Codex の既定（`~/.codex/config.toml` の `model`）、推論量は役割のファイルにある候補の値（`high`）が使われる。`--model` と `--effort` は、この実行だけ値を置き換える。選ばれたレビュアーが Codex のときだけ使える。置き換えても送り先は OpenAI のままなので、送り先の許可の判定は変わらない。
- 使えるモデル名は、Codex を対話で起動して `/model` で確かめるのが確実。
- 推論量の値は、そのまま Codex に渡す。使える値は Codex のモデルによる。誤った値は、Codex が使える値の一覧を付けたエラーにする（`dev-relay` では値を検査しない）。レビューは `high` が既定。時間と使用量を抑えたいときは `medium`、セキュリティや大きな設計判断では `xhigh`。
- `-c` の値は TOML として解釈されるので、手で呼ぶときは `'model_reasoning_effort="high"'` のように文字列を二重引用符で囲む。

## 続きを聞きたいとき

```bash
codex exec resume --last "追加の質問"
```

直前のセッションの文脈を引き継ぐ。`--last` は直近のセッションを指すので、間に別の Codex を動かしていると、意図したのと違うセッションにつながることがある。このスキルの手順では使っていない。再レビューは、修正後の差分で `dev-relay review` をもう一度実行する。
