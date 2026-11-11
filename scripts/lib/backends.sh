#!/usr/bin/env bash
# レビュアーの実行方法（backend）。common.sh と resolve.sh を読み込んだあとに source する。
# 単体では実行しない。選ばれた候補は R_* に入っている。

# Codex を読み取り専用で1回実行する。CLI の終了コードを返す。
# -c model_provider="openai" を必ず付ける。付けないと、利用者の Codex 設定しだいで
# 候補の vendors に書いた先と別の接続先に送られうる。
# 引数: 依頼文のファイル 本文の出力先
run_codex() {
  local prompt="$1" body="$2"
  local -a args=()
  # 共有デーモン経由で動くと、Herdr (hc) などの端末ランタイムの外でコマンドが実行される。
  # このフラグを持つ CLI では常に切る。古い CLI には無いので、あるときだけ付ける。
  if codex --help 2>/dev/null | grep -q -- '--no-daemon'; then
    args+=(--no-daemon)
  fi
  args+=(--sandbox read-only -c 'model_provider="openai"')
  if [ "$R_EFFORT" != "-" ]; then
    args+=(-c "model_reasoning_effort=\"${R_EFFORT}\"")
  fi
  if [ "$R_MODEL" != "-" ]; then
    args+=(--model "$R_MODEL")
  fi
  run_with_timeout "$TIMEOUT_SEC" codex "${args[@]}" exec --skip-git-repo-check -o "$body" - < "$prompt"
}

# Cursor CLI を ask モードで1回実行し、JSON から本文と末尾の2行を取り出す。
# 失敗（終了コードが 0 以外、JSON でない、is_error が false でない、result が空）は 0 以外を返す。
# 引数: 依頼文のファイル 本文の出力先 末尾に足す行の出力先
run_cursor() {
  local prompt="$1" body="$2" trailer="$3"
  local json err st=0
  local -a args=(-p --mode ask --trust)
  json="$(mktemp)"
  err="$(mktemp)"
  if [ "$R_MODEL" != "-" ]; then
    args+=(--model "$R_MODEL")
  fi
  args+=(--output-format json --workspace "$(repo_root)")

  run_with_timeout "$TIMEOUT_SEC" cursor-agent "${args[@]}" < "$prompt" > "$json" 2> "$err" || st=$?
  if [ "$st" -eq 0 ]; then
    if jq -e 'type == "object" and .is_error == false and ((.result // "") | type == "string" and length > 0)' "$json" >/dev/null 2>&1; then
      jq -r '.result' "$json" > "$body"
      {
        printf '\n---\n\n'
        jq -r '"- duration_ms: \(.duration_ms // 0)", "- tokens: input=\(.usage.inputTokens // 0) output=\(.usage.outputTokens // 0) cache_read=\(.usage.cacheReadTokens // 0) cache_write=\(.usage.cacheWriteTokens // 0)"' "$json"
      } > "$trailer"
    else
      echo "cursor-agent の出力が不正です（JSON でない、is_error が false でない、または result が空）。" >&2
      st=1
    fi
  fi
  if [ "$st" -ne 0 ]; then
    tail -n 20 "$err" >&2
  fi
  rm -f "$json" "$err"
  return "$st"
}

# 作業ツリーの一覧を標準出力に出す。実行の前後で比べて、レビュアーが書き込んだかを検出する。
# git status と index に加え、追跡ファイル全体の実行権限とシンボリックリンクかどうか、
# 変更のあるファイルと未追跡のファイルの実際の中身（改行の変換などをかけないハッシュ）を並べる。
# core.filemode=false でも実行権限の変更を見つけるため、権限は追跡ファイル全体で取る
# （ファイルごとに外部コマンドを起動しない）。リポジトリのルートで呼ぶ。
worktree_manifest() {
  local f h x
  git status --porcelain=v1 --untracked-files=all
  git ls-files --stage
  git ls-files -z | while IFS= read -r -d '' f; do
    x="-"
    if [ -L "$f" ]; then x="l"; elif [ -x "$f" ]; then x="x"; fi
    printf 'M %s %s\n' "$x" "$f"
  done
  git ls-files -z --modified --others --exclude-standard | while IFS= read -r -d '' f; do
    x="-"
    if [ -L "$f" ]; then
      h="link:$(readlink "$f" | git hash-object --stdin)"
    elif [ -f "$f" ]; then
      h="$(git hash-object --no-filters -- "$f")"
      if [ -x "$f" ]; then x="x"; fi
    elif [ -d "$f" ]; then
      h="dir"
    else
      h="missing"
    fi
    printf 'W %s %s %s\n' "$h" "$x" "$f"
  done
}
