#!/usr/bin/env bash
# dev-relay のテスト。本物のモデルは呼ばない（tests/stubs/ の偽の CLI だけを使う）。
# 使い方: bash tests/run.sh    （macOS 標準の bash 3.2 でも /bin/bash tests/run.sh で動く）
# 1件ごとに "ok <番号> - <名前>" か "not ok <番号> - <名前>" を出す。1件でも落ちたら終了コード 1。

set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
DR="$ROOT/bin/dev-relay"
ORIG_PATH="$PATH"
SAFE_PATH="/usr/bin:/bin:/usr/sbin:/sbin"
# このファイル自体が公開チェックの対象なので、メールアドレスの形を1つの文字列として書かない
NOREPLY="test@""users.noreply.github.com"

WORK="$(cd "$(mktemp -d)" && pwd -P)"
trap 'rm -rf "${WORK:?}"' EXIT

N=0
PASSED=0
FAILED=0

# ---- テストの道具 -----------------------------------------------------------

fail() { FAIL=1; echo "# FAIL: $*" >&2; }

skip() { printf '%s\n' "$*" > "$WORK/skip"; }

assert_rc() {
  if [ "$RC" -ne "$1" ]; then
    fail "終了コード: 期待 ${1}、実際 ${RC}"
    sed 's/^/#   stderr: /' "$T/err" 2>/dev/null | head -n 8 >&2
  fi
}
assert_eq() { [ "$1" = "$2" ] || fail "${3:-値}: 期待 '$2'、実際 '$1'"; }
assert_contains() { case "$1" in *"$2"*) ;; *) fail "${3:-文字列}に '$2' が無い: $1" ;; esac; }
assert_has() { grep -qF -- "$2" "$1" 2>/dev/null || fail "$1 に '$2' が無い"; }
assert_lacks() { if grep -qF -- "$2" "$1" 2>/dev/null; then fail "$1 に '$2' がある"; fi; }
assert_file() { [ -f "$1" ] || fail "ファイルが無い: $1"; }

# 標準出力の key=value から値を取る
kv() { awk -F= -v k="$1" '$1 == k { sub(/^[^=]*=/, ""); print; exit }' "$T/out"; }
last_line() { tail -n 1 "$T/out"; }
codex_runs() { grep -c '^codex .* exec ' "$STUB_LOG" || true; }
cursor_runs() { grep -c '^cursor-agent -p ' "$STUB_LOG" || true; }

link_tool() {
  local p
  if ! PATH="$SAFE_PATH" command -v "$1" >/dev/null 2>&1; then
    p="$(PATH="$ORIG_PATH" command -v "$1" || true)"
    if [ -n "$p" ]; then ln -s "$p" "$T/tools/$1"; fi
  fi
}

have_jq() { PATH="$ORIG_PATH:$SAFE_PATH" command -v jq >/dev/null 2>&1; }
need_jq() { have_jq || { skip "jq が見つからない"; return 1; }; }

# 本物の道具と利用者の設定から切り離した環境と、対象のリポジトリを作る。
# 呼ぶのはテスト関数の中（サブシェル）なので、export は他のテストに残らない。
new_env() {
  T="$(mktemp -d "$WORK/t.XXXXXX")"
  mkdir -p "$T/bin" "$T/tools" "$T/cfg" "$T/home"
  link_tool git
  link_tool jq
  export PATH="$T/bin:$T/tools:$SAFE_PATH"
  export DEV_RELAY_CONFIG_DIR="$T/cfg" HOME="$T/home"
  export STUB_LOG="$T/stub.log" STUB_STDIN="$T/stdin"
  export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL="$T/gitconfig"
  unset XDG_CONFIG_HOME HC_TERMINAL_ID DEV_RELAY_TIMEOUT DEV_RELAY_ROOT
  unset STUB_CODEX_LOGIN STUB_CODEX_SLEEP STUB_CODEX_BODY STUB_CODEX_EXIT
  unset STUB_CURSOR_LOGIN STUB_CURSOR_ACTION STUB_CURSOR_IS_ERROR STUB_CURSOR_EXIT
  unset STUB_CODEX_VERSION STUB_CURSOR_VERSION STUB_VERSION_SLEEP STUB_VERSION_ORPHAN STUB_VERSION_IGNORE
  unset STUB_CURSOR_BODY STUB_CURSOR_MODELS STUB_CURSOR_MODELS_EXIT
  unset DEV_RELAY_TODAY CODEX_HOME
  : > "$STUB_LOG"
  REPO="$T/repo"
  git init -q "$REPO"
  (
    cd "$REPO" || exit 1
    git config user.name tester
    git config user.email "$NOREPLY"
    git config commit.gpgsign false
    printf 'line1\nline2\nline3\n' > app.txt
    git add app.txt
    git commit -qm init
    printf 'line1\nline2 changed\nline3\n' > app.txt
  )
}

# timeout と gtimeout だけが無い PATH を作る（perl の経路を通すため）。
# 標準の場所にある実行ファイルを、その2つを除いてシンボリックリンクで並べる。
without_timeout_tools() {
  local d f name
  mkdir -p "$T/farm"
  for d in /usr/bin /bin /usr/sbin /sbin; do
    for f in "$d"/*; do
      name="$(basename "$f")"
      case "$name" in timeout|gtimeout) continue ;; esac
      if [ -f "$f" ] && [ -x "$f" ] && [ ! -e "$T/farm/$name" ]; then ln -s "$f" "$T/farm/$name"; fi
    done
  done
  export PATH="$T/bin:$T/farm"
  if command -v timeout >/dev/null 2>&1 || command -v gtimeout >/dev/null 2>&1; then
    fail "timeout か gtimeout が PATH に残っている"
  fi
}

with_codex()  { ln -s "$ROOT/tests/stubs/codex" "$T/bin/codex"; }
with_cursor() { ln -s "$ROOT/tests/stubs/cursor-agent" "$T/bin/cursor-agent"; }

# dev-relay を対象のリポジトリで実行し、標準出力を $T/out、標準エラーを $T/err、終了コードを RC に入れる
dr() {
  RC=0
  ( cd "$REPO" && "$DR" "$@" ) > "$T/out" 2> "$T/err" || RC=$?
}
dr_in() {
  local dir="$1"
  shift
  RC=0
  ( cd "$dir" && "$DR" "$@" ) > "$T/out" 2> "$T/err" || RC=$?
}

set_user_vendors() { dr config vendors --user "$1"; [ "$RC" -eq 0 ] || fail "config vendors --user $1 が失敗した"; }
set_metered()      { dr config metered "$1"; [ "$RC" -eq 0 ] || fail "config metered $1 が失敗した"; }

# 追加のレビュアーに Cursor（carbon）が選ばれる環境
cursor_extra_env() {
  new_env
  with_codex
  with_cursor
  set_user_vendors openai,cursor,google
  set_metered auto
}

# プラグインを写したフォルダ（$T/plugin）を作る。drp はその bin/dev-relay を実行する。
# 既定値のファイル（config/）や見直しの日付を書き換えるテストに使う
plugin_copy() {
  mkdir -p "$T/plugin/skills/dev" "$T/plugin/tests"
  cp -R "$ROOT/bin" "$ROOT/scripts" "$ROOT/config" "$ROOT/hooks" "$T/plugin/"
  cp -R "$ROOT/skills/dev/references" "$T/plugin/skills/dev/"
  cp -R "$ROOT/tests/smoke" "$T/plugin/tests/"
}
drp() {
  RC=0
  ( cd "$REPO" && "$T/plugin/bin/dev-relay" "$@" ) > "$T/out" 2> "$T/err" || RC=$?
}

# 記録（state/snapshot）を直接書く。引数は key=value の行
write_snapshot() {
  mkdir -p "$T/cfg/state"
  printf '%s\n' "$@" > "$T/cfg/state/snapshot"
}
SNAP="state/snapshot"
# 偽の CLI の既定の版と同じ記録（保存日は 2026-10-01）
snapshot_same_versions() {
  write_snapshot "saved=2026-10-01" "tool.codex.version=codex-cli 0.0.0-stub" "tool.cursor.version=2026.11.10-stub"
}

# 版の記録と通知の確認で使う環境（偽の codex と cursor-agent）
refresh_env() {
  new_env; with_codex; with_cursor
}

# 出力の行の数
out_lines() { wc -l < "$T/out" | tr -d ' '; }

# 形式どおりのレビュー本文（指摘2件、4つの項目、判定の行、仕込んだ不具合への言及）を標準出力に出す。
# 引数で、1つだけ欠いた本文にできる:
#   no-findings          指摘の見出しが無い
#   no-field:<項目>      全部の指摘から、その項目の行を除く
#   no-verdict           判定の行が無い
#   no-seeded            仕込んだ不具合に触れない
review_item() { [ "$REVIEW_OMIT" = "no-field:$1" ] || printf -- '- %s: %s\n' "$1" "$2"; }
review_body() {
  local n title repro
  REVIEW_OMIT="${1:-}"
  if [ "$REVIEW_OMIT" = no-findings ]; then
    printf '%s\n\n%s\n' '偶数個の入力と空のリストに問題がありますが、指摘の見出しを付けずに書きました。' '要修正あり'
    return 0
  fi
  for n in 1 2; do
    if [ "$REVIEW_OMIT" = no-seeded ]; then
      title="docstring の表記"; repro="目視で確認できる"
    elif [ "$n" = 1 ]; then
      title="偶数個のときに中央2つの平均を返さない"; repro="median([1, 2, 3, 4]) が 3 を返す"
    else
      title="空のリストで ValueError にならない"; repro="median([]) が IndexError になる"
    fi
    printf '### %s %s\n' "$n" "$title"
    review_item 重要度 高
    review_item 場所 "stats.py:$((n + 3))"
    review_item 再現 "$repro"
    review_item 実際の結果 "実行した結果"
    review_item 目的が要求する結果 "正しい値"
    review_item 確認状況 実行済み
    review_item 修正案 "直す"
    printf '\n'
  done
  if [ "$REVIEW_OMIT" != no-verdict ]; then printf '要修正あり\n'; fi
}

# スモークテストの環境。Codex と Cursor が形式どおりの本文を返す。引数: 許可する提供元（省略時は全部）
smoke_env() {
  local good
  new_env; with_codex; with_cursor
  set_user_vendors "${1:-openai,cursor,xai,google}"
  good="$(review_body)"
  export STUB_CODEX_BODY="$good" STUB_CURSOR_BODY="$good"
}

# ---- テスト -----------------------------------------------------------------

t_entry() {
  [ -x "$DR" ] || fail "bin/dev-relay に実行権限が無い"
  RC=0; "$DR" --help >/dev/null 2>&1 || RC=$?; assert_eq "$RC" 0 "--help の終了コード"
  RC=0; "$DR" no-such-command >/dev/null 2>&1 || RC=$?; assert_eq "$RC" 1 "知らないサブコマンドの終了コード"
}

t_doctor_unset() {
  new_env; with_codex; with_cursor
  dr doctor
  assert_rc 0
  assert_eq "$(kv repo.vendors.source)" unset "source"
  assert_eq "$(kv role.code-review)" claude "role.code-review"
  assert_contains "$(kv role.code-review.skipped)" "codex(vendor-not-allowed:openai)" "skipped"
}

t_doctor_user_openai() {
  new_env; with_codex; with_cursor
  set_user_vendors openai
  dr doctor
  assert_eq "$(kv repo.vendors.source)" user "source"
  assert_eq "$(kv role.code-review)" codex "role.code-review"
  assert_eq "$(kv role.code-review-extra)" claude "role.code-review-extra"
  skipped="$(kv role.code-review-extra.skipped)"
  assert_contains "$skipped" "carbon(" "extra の skipped"
  assert_contains "$skipped" "metered-off" "extra の skipped"
  assert_contains "$skipped" "vendor-not-allowed:cursor,google" "extra の skipped"
}

t_doctor_ask() {
  new_env; with_codex
  set_user_vendors ask
  dr doctor
  assert_eq "$(kv repo.vendors.source)" ask "source"
  assert_eq "$(kv role.code-review)" claude "role.code-review"
}

t_doctor_ask_repo() {
  new_env; with_codex
  set_user_vendors ask
  dr config vendors --repo openai
  dr doctor
  assert_eq "$(kv repo.vendors.source)" repo "source"
  assert_eq "$(kv role.code-review)" codex "role.code-review"
}

t_doctor_repo_none() {
  new_env; with_codex
  set_user_vendors openai
  dr config vendors --repo none
  dr doctor
  assert_eq "$(kv repo.vendors)" none "repo.vendors"
  assert_eq "$(kv repo.vendors.source)" repo "source"
  assert_eq "$(kv role.code-review)" claude "リポジトリの設定が優先されること"
}

t_doctor_no_tools() {
  new_env
  dr doctor
  assert_eq "$(kv tool.codex)" not-installed "tool.codex"
  assert_eq "$(kv role.design-review)" claude "design-review"
  assert_eq "$(kv role.code-review)" claude "code-review"
  assert_eq "$(kv role.code-review-extra)" none "code-review-extra"
}

t_doctor_cursor_only() {
  need_jq || return 0
  new_env; with_cursor
  dr config vendors --repo openai,cursor,xai
  dr doctor
  assert_eq "$(kv role.code-review)" grok "role.code-review"
}

t_doctor_codex_logged_out() {
  new_env; with_codex
  set_user_vendors openai
  export STUB_CODEX_LOGIN=1
  dr doctor
  assert_eq "$(kv tool.codex)" not-logged-in "tool.codex"
  [ "$(kv role.code-review)" != codex ] || fail "未ログインの codex が選ばれた"
}

t_doctor_cursor_logged_out() {
  new_env; with_cursor
  export STUB_CURSOR_LOGIN=1
  dr doctor
  assert_eq "$(kv tool.cursor)" not-logged-in "tool.cursor（終了コード 0 の Not logged in）"
}

t_review_no_intent() {
  new_env
  dr review code
  assert_rc 1
}

t_review_no_changes() {
  new_env
  (cd "$REPO" && git commit -qam change)
  dr review code --intent "目的"
  assert_rc 1
}

t_dry_run() {
  new_env; with_codex; with_cursor
  set_user_vendors openai
  dr review code --intent "目的ABC" --dry-run
  assert_rc 0
  assert_has "$T/out" "目的ABC"
  assert_has "$T/out" "line2 changed"
  [ ! -s "$STUB_LOG" ] || fail "--dry-run で CLI が呼ばれた: $(cat "$STUB_LOG")"
}

t_review_codex() {
  new_env; with_codex
  set_user_vendors openai
  dr review code --intent "目的ABC"
  assert_rc 0
  res="$(last_line)"
  assert_file "$res"
  assert_has "$res" "reviewer: codex"
  assert_has "$res" "stub codex review body"
  assert_has "$STUB_LOG" "--sandbox read-only"
  assert_has "$STUB_STDIN" "目的ABC"
}

t_effort_max() {
  new_env; with_codex
  set_user_vendors openai
  dr review code --intent "目的" --effort max
  assert_rc 0
  assert_has "$STUB_LOG" 'model_reasoning_effort="max"'
}

t_extra_metered_off() {
  new_env; with_codex; with_cursor
  set_user_vendors openai,cursor,google
  dr review code --intent "目的ABC" --extra
  assert_rc 3
  prompt="$(last_line)"
  assert_file "$prompt"
  case "$prompt" in *.prompt.md) ;; *) fail "依頼文のファイル名が .prompt.md でない: $prompt" ;; esac
  assert_has "$prompt" "目的ABC"
}

t_extra_cursor() {
  need_jq || return 0
  cursor_extra_env
  dr review code --intent "目的ABC" --extra
  assert_rc 0
  res="$(last_line)"
  assert_file "$res"
  assert_has "$STUB_LOG" "--mode ask"
  assert_has "$STUB_LOG" "--model gemini-4-carbon-medium"
  assert_has "$res" "reviewer: carbon"
  assert_has "$res" "billing: metered"
  assert_has "$res" "stub cursor review body"
  assert_has "$res" "tokens:"
  assert_has "$STUB_STDIN" "目的ABC"
}

t_extra_reviewer_not_allowed() {
  new_env; with_codex; with_cursor
  set_user_vendors openai
  set_metered auto
  dr review code --intent "目的" --extra --reviewer carbon
  assert_rc 1
  assert_has "$T/err" "vendor-not-allowed"
  assert_eq "$(cursor_runs)" 0 "Cursor の実行回数"
}

t_unset_does_not_send() {
  new_env; with_codex
  dr review code --intent "目的"
  assert_rc 3
  assert_eq "$(codex_runs)" 0 "Codex の実行回数"
}

# Cursor が作業ツリーを変えたとき、終了コード 5 で、変わったパスが結果ファイルに残る
cursor_changes() {
  need_jq || return 0
  cursor_extra_env
  if [ -n "${2:-}" ]; then (cd "$REPO" && eval "$2"); fi
  export STUB_CURSOR_ACTION="$1"
  dr review code --intent "目的" --extra
  assert_rc 5
  res="$(last_line)"
  assert_file "$res"
  assert_has "$res" "作業ツリーの変化"
  assert_has "$res" "${1#*:}"
}

t_cursor_create()  { cursor_changes "create:newfile.txt"; }
t_cursor_append()  { cursor_changes "append:app.txt"; }
t_cursor_restage() { cursor_changes "restage:staged.txt" "echo new > staged.txt; git add staged.txt"; }
t_cursor_crlf() {
  need_jq || return 0
  cursor_extra_env
  (cd "$REPO" && git config core.autocrlf input)
  export STUB_CURSOR_ACTION="crlf:app.txt"
  dr review code --intent "目的" --extra
  assert_rc 5
  assert_has "$(last_line)" "app.txt"
}
t_cursor_chmod() { cursor_changes "chmod:app.txt"; }

t_cursor_change_beats_failure() {
  need_jq || return 0
  cursor_extra_env
  export STUB_CURSOR_ACTION="create:newfile.txt" STUB_CURSOR_EXIT=2
  dr review code --intent "目的" --extra
  assert_rc 5
  res="$(last_line)"
  assert_has "$res" "CLI の終了状態: 2"
  assert_has "$res" "作業ツリーの変化"
}

t_cursor_is_error() {
  need_jq || return 0
  cursor_extra_env
  export STUB_CURSOR_IS_ERROR=1
  dr review code --intent "目的" --extra
  assert_rc 10
}

t_extra_model_rejected() {
  need_jq || return 0
  cursor_extra_env
  dr review code --intent "目的" --extra --model x
  assert_rc 1
  assert_eq "$(cursor_runs)" 0 "Cursor の実行回数"
}

t_codex_fails() {
  new_env; with_codex
  set_user_vendors openai
  export STUB_CODEX_EXIT=2
  dr review code --intent "目的"
  assert_rc 10
  assert_has "$(last_line)" "CLI の終了状態: 2"
}

t_timeout() {
  new_env; with_codex
  set_user_vendors openai
  export STUB_CODEX_SLEEP=5 DEV_RELAY_TIMEOUT=1
  start=$SECONDS
  dr review code --intent "目的"
  elapsed=$((SECONDS - start))
  assert_rc 124
  [ "$elapsed" -le 3 ] || fail "3秒以内に戻らなかった: ${elapsed} 秒"
}

t_out_symlink() {
  new_env; with_codex
  set_user_vendors openai
  mkdir -p "$REPO/.dev-relay"
  ln -s ../app.txt "$REPO/.dev-relay/result.md"
  before="$(cat "$REPO/app.txt")"
  dr review code --intent "目的" --out "$REPO/.dev-relay/result.md"
  assert_rc 1
  assert_eq "$(cat "$REPO/app.txt")" "$before" "ソースの内容"
  assert_eq "$(codex_runs)" 0 "Codex の実行回数"
}

t_prompt_symlink() {
  new_env
  mkdir -p "$REPO/.dev-relay"
  ln -s ../app.txt "$REPO/.dev-relay/result.prompt.md"
  before="$(cat "$REPO/app.txt")"
  dr review code --intent "目的" --out "$REPO/.dev-relay/result.md"
  assert_rc 1
  assert_eq "$(cat "$REPO/app.txt")" "$before" "ソースの内容"
}

t_cursor_clean_crlf() {
  need_jq || return 0
  cursor_extra_env
  (
    cd "$REPO" || exit 1
    git checkout -- app.txt
    git config core.autocrlf input
    printf 'review target\n' > other.txt
  )
  export STUB_CURSOR_ACTION=crlf:app.txt
  dr review code --intent "目的" --extra
  assert_rc 5
  assert_has "$(last_line)" "app.txt"
}

t_cursor_clean_chmod() {
  need_jq || return 0
  cursor_extra_env
  (
    cd "$REPO" || exit 1
    git checkout -- app.txt
    git config core.filemode false
    printf 'review target\n' > other.txt
  )
  export STUB_CURSOR_ACTION=chmod:app.txt
  dr review code --intent "目的" --extra
  assert_rc 5
  assert_has "$(last_line)" "app.txt"
}

t_out_is_directory() {
  new_env; with_codex
  set_user_vendors openai
  mkdir -p "$REPO/.dev-relay"
  dr review code --intent "目的" --out "$REPO/.dev-relay"
  assert_rc 1
  assert_has "$T/err" "ディレクトリ"
  assert_eq "$(codex_runs)" 0 "Codex の実行回数"
  [ -z "$(ls -A "$REPO/.dev-relay")" ] || fail "フォルダの中に何かが書かれた"
  [ ! -e "$REPO/.dev-relay.prompt.md" ] || fail "フォルダの隣に依頼文が書かれた"
}

t_out_not_ignored_leaves_no_dir() {
  new_env; with_codex
  set_user_vendors openai
  dr review code --intent "目的" --out "$REPO/unignored-dir/sub/out.md"
  assert_rc 1
  [ ! -e "$REPO/unignored-dir" ] || fail "エラー終了したのに作業ツリーにフォルダが残った"
}

t_out_not_ignored_keeps_existing_dir() {
  new_env; with_codex
  set_user_vendors openai
  mkdir -p "$REPO/existing-dir"
  printf 'keep\n' > "$REPO/existing-dir/keep.txt"
  dr review code --intent "目的" --out "$REPO/existing-dir/sub/out.md"
  assert_rc 1
  assert_file "$REPO/existing-dir/keep.txt"
  [ ! -e "$REPO/existing-dir/sub" ] || fail "この実行が作ったフォルダが残った"
}

t_out_fresh_dev_relay() {
  new_env; with_codex
  set_user_vendors openai
  [ ! -e "$REPO/.dev-relay" ] || fail "前提: .dev-relay/ がまだ無いこと"
  dr review code --intent "目的" --out "$REPO/.dev-relay/x.md"
  assert_rc 0
  assert_file "$REPO/.dev-relay/x.md"
}

t_untracked_japanese() {
  new_env
  git -C "$REPO" config core.quotePath true
  printf 'UNTRACKED_MARKER\n' > "$REPO/新規.txt"
  dr review code --intent "目的" --dry-run
  assert_rc 0
  assert_has "$T/out" "UNTRACKED_MARKER"
}

t_timeout_perl() {
  new_env; with_codex
  set_user_vendors openai
  without_timeout_tools
  export STUB_CODEX_SLEEP=5 DEV_RELAY_TIMEOUT=1
  start=$SECONDS
  dr review code --intent "目的"
  elapsed=$((SECONDS - start))
  assert_rc 124
  [ "$elapsed" -le 3 ] || fail "3秒以内に戻らなかった: ${elapsed} 秒"
}

# 空白や日本語を含む名前の機密らしいファイルでも、警告にそのファイル名が出る
sensitive_files() {
  printf 'secret\n' > "$REPO/my key.pem"
  printf 'secret\n' > "$REPO/日本語.pem"
}
assert_sensitive_warning() {
  assert_rc 0
  assert_has "$T/err" "機密情報を含む可能性"
  assert_has "$T/err" "my key.pem"
  assert_has "$T/err" "日本語.pem"
}

t_sensitive_uncommitted() {
  new_env; with_codex
  set_user_vendors openai
  sensitive_files
  dr review code --intent "目的"
  assert_sensitive_warning
}

t_sensitive_commit() {
  new_env; with_codex
  set_user_vendors openai
  sensitive_files
  (cd "$REPO" && git add -A && git commit -qm secrets)
  dr review code --intent "目的" --commit HEAD
  assert_sensitive_warning
}

t_sensitive_base() {
  new_env; with_codex
  set_user_vendors openai
  sensitive_files
  (cd "$REPO" && git add -A && git commit -qm secrets)
  dr review code --intent "目的" --base HEAD~1
  assert_sensitive_warning
}

t_probe_once() {
  new_env; with_codex
  set_user_vendors openai
  dr review code --intent "目的"
  assert_rc 0
  assert_eq "$(grep -c '^codex login status' "$STUB_LOG" || true)" 1 "login status の呼び出し回数"
}

t_claude_fallback() {
  new_env
  dr review code --intent "目的ABC"
  assert_rc 3
  prompt="$(last_line)"
  assert_file "$prompt"
  assert_has "$prompt" "目的ABC"
  assert_has "$T/err" "dev-relay:reviewer"
}

t_extra_none() {
  new_env
  dr review code --intent "目的" --extra
  assert_rc 4
}

t_extra_exclude() {
  new_env; with_codex; with_cursor
  set_user_vendors openai,cursor,google
  dr review code --intent "目的" --extra --exclude claude
  assert_rc 4
}

t_out_not_ignored() {
  new_env; with_codex
  set_user_vendors openai
  dr review code --intent "目的" --out "$REPO/out.md"
  assert_rc 1
  assert_has "$T/err" "無視"
  assert_eq "$(codex_runs)" 0 "Codex の実行回数"
}

t_unique_out() {
  new_env; with_codex
  set_user_vendors openai
  dr review code --intent "目的"; a="$(last_line)"
  dr review code --intent "目的"; b="$(last_line)"
  [ -n "$a" ] && [ "$a" != "$b" ] || fail "結果ファイルのパスが同じ: $a / $b"
}

t_prompt_not_ignored() {
  new_env
  echo "res.md" >> "$REPO/.git/info/exclude"
  dr review code --intent "目的" --out "$REPO/res.md"
  assert_rc 1
  [ ! -e "$REPO/res.prompt.md" ] || fail "依頼文のファイルが作られた"
}

t_design() {
  new_env; with_codex
  set_user_vendors openai
  printf '# 設計書\nDESIGNBODY\n' > "$T/design.md"
  dr review design "$T/design.md"
  assert_rc 0
  assert_has "$STUB_STDIN" "DESIGNBODY"
  assert_has "$(last_line)" "# dev-relay design review"
}

t_reviewer_unknown() {
  new_env
  dr review code --intent "目的" --reviewer nosuch
  assert_rc 1
}

t_effort_cursor() {
  need_jq || return 0
  new_env; with_cursor
  set_user_vendors openai,cursor,xai
  dr review code --intent "目的" --effort high
  assert_rc 1
  assert_eq "$(cursor_runs)" 0 "Cursor の実行回数"
}

t_worktree_untouched() {
  new_env; with_codex; with_cursor
  set_user_vendors openai,cursor,google
  set_metered auto
  before="$(cd "$REPO" && git status --porcelain)"
  dr review code --intent "目的"
  assert_rc 0
  assert_eq "$(cd "$REPO" && git status --porcelain)" "$before" "Codex のレビュー後の git status"
  if have_jq; then
    dr review code --intent "目的" --extra
    assert_rc 0
    assert_eq "$(cd "$REPO" && git status --porcelain)" "$before" "Cursor のレビュー後の git status"
  fi
}

t_config_metered() {
  new_env
  dr config metered; assert_eq "$(cat "$T/out")" "metered=off" "既定"
  dr config metered auto; assert_rc 0
  dr config metered; assert_eq "$(cat "$T/out")" "metered=auto" "auto を書いたあと"
  dr config metered bogus; assert_rc 1
  dr config metered; assert_eq "$(cat "$T/out")" "metered=auto" "不正な値のあと"
}

t_config_concurrent() {
  new_env
  i=0
  while [ "$i" -lt 5 ]; do
    i=$((i + 1))
    rm -f "$T/cfg/metered" "$T/cfg/vendors"
    ( cd "$REPO" && "$DR" config metered auto >/dev/null 2>&1 ) &
    ( cd "$REPO" && "$DR" config vendors --user none >/dev/null 2>&1 ) &
    wait
    assert_eq "$(head -n 1 "$T/cfg/metered" 2>/dev/null)" auto "metered（$i 回目）"
    assert_eq "$(head -n 1 "$T/cfg/vendors" 2>/dev/null)" none "vendors（$i 回目）"
  done
}

t_bad_timeouts() {
  new_env; with_codex
  set_user_vendors openai
  for v in 0 -1 0.2 abc; do
    export DEV_RELAY_TIMEOUT="$v"
    dr review code --intent "目的"
    assert_rc 1
    assert_eq "$(codex_runs)" 0 "DEV_RELAY_TIMEOUT=$v での Codex の実行回数"
  done
}

t_provider_pinned() {
  new_env; with_codex
  set_user_vendors openai
  dr review code --intent "目的"
  assert_rc 0
  assert_has "$STUB_LOG" 'model_provider="openai"'
}

t_config_vendors() {
  new_env
  cv() { dr config vendors "$@"; }
  cv;                        assert_eq "$(tr '\n' ' ' < "$T/out")" "vendors=none source=unset " "何も無いとき"
  cv --user openai;          assert_rc 0
  cv;                        assert_eq "$(tr '\n' ' ' < "$T/out")" "vendors=openai source=user " "--user openai"
  cv --user ask;             assert_rc 0
  cv;                        assert_eq "$(tr '\n' ' ' < "$T/out")" "vendors=none source=ask " "--user ask"
  cv --user none;            assert_rc 0
  cv;                        assert_eq "$(tr '\n' ' ' < "$T/out")" "vendors=none source=user " "--user none"
  cv --user openai;          assert_rc 0
  cv --repo openai,cursor;   assert_rc 0
  cv;                        assert_eq "$(tr '\n' ' ' < "$T/out")" "vendors=openai,cursor source=repo " "--repo"
  assert_eq "$(cd "$REPO" && git config --local --get dev-relay.vendors)" "openai,cursor" "git の設定"
  cv --repo --reset;         assert_rc 0
  cv;                        assert_eq "$(tr '\n' ' ' < "$T/out")" "vendors=openai source=user " "--repo --reset のあと"
  cv --repo ask;             assert_rc 1
  cv --repo "Bad Value";     assert_rc 1
  cv --user openai,none;     assert_rc 1
  cv --user "";              assert_rc 1
  cv openai;                 assert_rc 1
  cv --user a --repo b;      assert_rc 1
  nogit="$T/nogit"; mkdir -p "$nogit"
  dr_in "$nogit" config vendors --repo openai; assert_rc 1
  dr_in "$nogit" config vendors --repo --reset; assert_rc 1
}

t_broken_role_file() {
  new_env
  mkdir -p "$T/plugin"
  cp -R "$ROOT/bin" "$ROOT/scripts" "$ROOT/config" "$ROOT/skills" "$T/plugin/"
  conf="$T/plugin/config/roles/code-review.conf"
  printf 'broken line here\n' >> "$conf"
  n="$(wc -l < "$conf" | tr -d ' ')"
  RC=0
  ( cd "$REPO" && "$T/plugin/bin/dev-relay" doctor ) > "$T/out" 2> "$T/err" || RC=$?
  [ "$RC" -ne 0 ] || fail "壊れた行があるのに成功した"
  assert_has "$T/err" "code-review.conf:$n"
}

t_agent_bodies() {
  body() { awk 'c >= 2 { print } /^---$/ { c++ }' "$1"; }
  body "$ROOT/agents/implementer.md" > "$WORK/impl-body"
  body "$ROOT/agents/implementer-hard.md" > "$WORK/impl-hard-body"
  [ -s "$WORK/impl-body" ] || fail "implementer.md の本文が空"
  cmp -s "$WORK/impl-body" "$WORK/impl-hard-body" || fail "implementer.md と implementer-hard.md の本文が違う"
}

t_plugin_validate() {
  command -v claude >/dev/null 2>&1 || { skip "claude コマンドが無い"; return 0; }
  RC=0
  ( cd "$ROOT" && claude plugin validate . ) > "$WORK/validate.out" 2>&1 || RC=$?
  [ "$RC" -eq 0 ] || { fail "claude plugin validate が失敗した"; sed 's/^/#   /' "$WORK/validate.out" >&2; }
}

# 公開チェックのテスト用に、コミット済みの小さいリポジトリを作る
public_repo() {
  P="$T/pub"
  git init -q "$P"
  (
    cd "$P" || exit 1
    git config user.name tester
    git config user.email "$NOREPLY"
    git config commit.gpgsign false
    printf 'harmless text\n' > note.txt
    git add note.txt
    git commit -qm init
  )
}

t_public_clean() {
  new_env; public_repo
  RC=0; "$ROOT/tests/check-public.sh" "$P" > "$T/out" 2> "$T/err" || RC=$?
  assert_rc 0
}

t_public_detects() {
  new_env; public_repo
  # 検出されるべき文字列は、このファイルに1つの文字列として書かないよう、実行時に組み立てる
  printf 'see %s%s\n' "/Us" "ers/somebody/project" > "$P/bad.txt"
  RC=0; "$ROOT/tests/check-public.sh" "$P" > "$T/out" 2> "$T/err" || RC=$?
  assert_rc 1
  assert_contains "$(cat "$T/out" "$T/err")" "bad.txt:1" "出力"
  rm -f "$P/bad.txt"

  printf 'dir %s%s\n' "/ho" "me/somebody/project" > "$P/bad.txt"
  RC=0; "$ROOT/tests/check-public.sh" "$P" > "$T/out" 2> "$T/err" || RC=$?
  assert_rc 1
  rm -f "$P/bad.txt"

  printf 'dir %s%s\n' 'C:\Us' 'ers\somebody' > "$P/bad.txt"
  RC=0; "$ROOT/tests/check-public.sh" "$P" > "$T/out" 2> "$T/err" || RC=$?
  assert_rc 1
  rm -f "$P/bad.txt"

  printf 'mail %s%s\n' "somebody@" "example.com" > "$P/bad.txt"
  RC=0; "$ROOT/tests/check-public.sh" "$P" > "$T/out" 2> "$T/err" || RC=$?
  assert_rc 1
  rm -f "$P/bad.txt"

  printf 'key %s%s\n' "sk-" "abcdefghijklmnopqrstuvwx" > "$P/bad.txt"
  RC=0; "$ROOT/tests/check-public.sh" "$P" > "$T/out" 2> "$T/err" || RC=$?
  assert_rc 1
  rm -f "$P/bad.txt"

  printf 'Mentions AcmeCorp here\n' > "$P/bad.txt"
  printf '\nacmecorp\n' > "$T/cfg/private-words.txt"
  RC=0; "$ROOT/tests/check-public.sh" "$P" > "$T/out" 2> "$T/err" || RC=$?
  assert_rc 1
  rm -f "$P/bad.txt" "$T/cfg/private-words.txt"

  printf 'memo\n' > "$P/HANDOFF.md"
  RC=0; "$ROOT/tests/check-public.sh" "$P" > "$T/out" 2> "$T/err" || RC=$?
  assert_rc 1
  rm -f "$P/HANDOFF.md"

  (cd "$P" && git config user.email "somebody@""example.com" && git commit -q --allow-empty -m other)
  RC=0; "$ROOT/tests/check-public.sh" "$P" > "$T/out" 2> "$T/err" || RC=$?
  assert_rc 1
}

t_public_subdir_and_empty_email() {
  new_env; public_repo
  mkdir -p "$P/sub/.dev-relay" "$P/sub/.codex-review"
  printf 'x\n' > "$P/sub/.dev-relay/out.md"
  printf 'x\n' > "$P/sub/.codex-review/a.md"
  printf 'x\n' > "$P/sub/HANDOFF.md"
  RC=0; "$ROOT/tests/check-public.sh" "$P" > "$T/out" 2> "$T/err" || RC=$?
  assert_rc 1
  assert_has "$T/out" "sub/.dev-relay/out.md"
  assert_has "$T/out" "sub/.codex-review/a.md"
  assert_has "$T/out" "sub/HANDOFF.md"
}

t_public_empty_local_part() {
  new_env; public_repo
  git -C "$P" config user.email "@users.noreply.github.com"
  RC=0; "$ROOT/tests/check-public.sh" "$P" > "$T/out" 2> "$T/err" || RC=$?
  assert_rc 1
  assert_has "$T/out" "noreply"
}

t_public_japanese() {
  new_env; public_repo
  git -C "$P" config core.quotePath true
  printf 'see %s%s\n' '/Us' 'ers/somebody/project' > "$P/機密.md"
  RC=0; "$ROOT/tests/check-public.sh" "$P" > "$T/out" 2> "$T/err" || RC=$?
  assert_rc 1
  assert_contains "$(cat "$T/out")" "機密.md:1" "出力"
}

# ---- P1: 記録と通知 ----------------------------------------------------------

t_notice_first_run_records() {
  refresh_env
  dr refresh notice
  assert_rc 0
  assert_eq "$(cat "$T/out")" "" "記録が無いときの標準出力"
  assert_file "$T/cfg/$SNAP"
  assert_has "$T/cfg/$SNAP" "saved="
  assert_has "$T/cfg/$SNAP" "tool.codex.version=codex-cli 0.0.0-stub"
  assert_has "$T/cfg/$SNAP" "tool.cursor.version=2026.11.10-stub"
}

t_notice_quiet_when_same() {
  refresh_env
  export DEV_RELAY_TODAY=2026-10-01
  dr refresh save; assert_rc 0
  dr refresh notice
  assert_rc 0
  assert_eq "$(cat "$T/out")" "" "版が同じで30日未満のときの標準出力"
}

t_notice_codex_version() {
  refresh_env
  export DEV_RELAY_TODAY=2026-10-02 STUB_CODEX_VERSION="codex-cli 0.1.0-new"
  snapshot_same_versions
  dr refresh notice
  assert_rc 0
  assert_eq "$(out_lines)" 1 "出力の行数"
  assert_eq "$(cat "$T/out")" "dev-relay: Codex CLI の版が変わりました（codex-cli 0.0.0-stub → codex-cli 0.1.0-new）。/dev-relay:refresh で確認できます。" "通知の文"
}

t_notice_hook_json() {
  need_jq || return 0
  refresh_env
  export DEV_RELAY_TODAY=2026-10-02 STUB_CODEX_VERSION="codex-cli 0.1.0-new"
  snapshot_same_versions
  dr refresh notice; assert_rc 0
  plain="$(cat "$T/out")"
  dr refresh notice --hook
  assert_rc 0
  assert_eq "$(out_lines)" 1 "--hook の出力の行数"
  jq -e . "$T/out" >/dev/null 2>&1 || fail "--hook の出力が JSON でない: $(cat "$T/out")"
  assert_eq "$(jq -r .systemMessage "$T/out")" "$plain" "systemMessage と --hook なしの出力"
}

t_notice_hook_escapes() {
  need_jq || return 0
  refresh_env
  export DEV_RELAY_TODAY=2026-10-02 STUB_CODEX_VERSION='codex-cli 1"0\x'
  snapshot_same_versions
  dr refresh notice --hook
  assert_rc 0
  assert_eq "$(out_lines)" 1 "--hook の出力の行数"
  jq -e . "$T/out" >/dev/null 2>&1 || fail "版に \" と \\ があると --hook の出力が JSON でなくなる: $(cat "$T/out")"
  assert_contains "$(jq -r .systemMessage "$T/out" 2>/dev/null)" 'codex-cli 1"0\x' "systemMessage"
}

t_notice_30_days() {
  refresh_env
  snapshot_same_versions
  export DEV_RELAY_TODAY=2026-10-31
  dr refresh notice
  assert_rc 0
  assert_contains "$(cat "$T/out")" "前回の確認から30日たちました" "30日後の通知"
  export DEV_RELAY_TODAY=2026-10-30
  dr refresh notice
  assert_rc 0
  assert_eq "$(cat "$T/out")" "" "29日後の標準出力"
}

t_notice_one_line_in_order() {
  refresh_env
  snapshot_same_versions
  export DEV_RELAY_TODAY=2026-10-31 STUB_CODEX_VERSION="codex-cli 0.2.0" STUB_CURSOR_VERSION="2026.12.0"
  dr refresh notice
  assert_rc 0
  assert_eq "$(out_lines)" 1 "出力の行数"
  assert_eq "$(cat "$T/out")" "dev-relay: Codex CLI の版が変わりました（codex-cli 0.0.0-stub → codex-cli 0.2.0）、Cursor CLI の版が変わりました（2026.11.10-stub → 2026.12.0）、前回の確認から30日たちました。/dev-relay:refresh で確認できます。" "通知の文"
}

t_notice_cli_missing() {
  new_env; with_cursor
  export DEV_RELAY_TODAY=2026-10-02
  snapshot_same_versions
  dr refresh notice
  assert_rc 0
  assert_eq "$(cat "$T/out")" "" "Codex が PATH に無いときの標準出力"
  rm -f "$T/bin/cursor-agent"
  dr refresh notice
  assert_rc 0
  assert_eq "$(cat "$T/out")" "" "どちらも PATH に無いときの標準出力"
}

t_notice_off() {
  refresh_env
  export DEV_RELAY_TODAY=2026-10-31 STUB_CODEX_VERSION="codex-cli 0.2.0"
  dr config notice off; assert_rc 0
  dr refresh notice
  assert_rc 0
  assert_eq "$(cat "$T/out")" "" "notice off のときの標準出力"
  [ ! -e "$T/cfg/$SNAP" ] || fail "notice off なのに記録が書かれた"
  snapshot_same_versions
  dr refresh notice
  assert_eq "$(cat "$T/out")" "" "記録があっても notice off なら出さない"
  dr config notice on; assert_rc 0
  dr refresh notice
  assert_contains "$(cat "$T/out")" "Codex CLI の版が変わりました" "notice on に戻したあと"
}

t_notice_review_date() {
  refresh_env; plugin_copy
  printf '# 形式: 日付 文\n2026-10-15 テスト用の見直し\n' > "$T/plugin/config/review-dates.conf"
  snapshot_same_versions
  export DEV_RELAY_TODAY=2026-10-20
  drp refresh notice
  assert_rc 0
  assert_contains "$(cat "$T/out")" "見直す予定の日を過ぎました（2026-10-15 テスト用の見直し）" "期限が来たときの通知"
  drp refresh save; assert_rc 0
  assert_has "$T/cfg/$SNAP" "saved=2026-10-20"
  drp refresh notice
  assert_rc 0
  assert_eq "$(cat "$T/out")" "" "日付のあとに save したあとの標準出力"
}

t_notice_unwritable() {
  refresh_env
  printf 'x' > "$T/blocked"
  export DEV_RELAY_CONFIG_DIR="$T/blocked/cfg"
  dr refresh notice
  assert_rc 0
  dr refresh notice --hook
  assert_rc 0
  [ ! -s "$T/err" ] || fail "--hook が標準エラーに出した: $(cat "$T/err")"
}

t_refresh_save_check_clean() {
  refresh_env
  export DEV_RELAY_TODAY=2026-10-01
  dr refresh save
  assert_rc 0
  assert_eq "$(kv saved)" 2026-10-01 "save の saved"
  assert_eq "$(kv snapshot)" "$T/cfg/$SNAP" "save の snapshot"
  assert_file "$T/cfg/$SNAP"
  dr refresh check
  assert_rc 0
  assert_eq "$(kv snapshot)" present "snapshot"
  assert_eq "$(kv days-since)" 0 "days-since"
  n="$(grep -Ec '^(changed|added|removed|unavailable|override|due)[.=]' "$T/out" || true)"
  assert_eq "$n" 0 "変化の行の数"
}

t_check_cursor_models() {
  refresh_env
  export DEV_RELAY_TODAY=2026-10-01
  dr refresh save; assert_rc 0
  export STUB_CURSOR_MODELS=$'auto - Auto (default)\ngrok-4.7-high - Grok 4.7 High\nnew-model-x - New Model X'
  dr refresh check
  assert_rc 0
  assert_eq "$(kv added.cursor.models)" new-model-x "added.cursor.models"
  assert_eq "$(kv removed.cursor.models)" gemini-4-carbon-medium "removed.cursor.models"
}

write_codex_models() {
  mkdir -p "$HOME/.codex"
  printf '%s\n' "$1" > "$HOME/.codex/models_cache.json"
}
t_check_codex_models() {
  need_jq || return 0
  refresh_env
  export DEV_RELAY_TODAY=2026-10-01
  write_codex_models '{"models":[{"slug":"gpt-6.1-terra","visibility":"list","priority":2},{"slug":"gpt-6-astra","visibility":"list","priority":3},{"slug":"hidden-one","visibility":"hide","priority":0},{"slug":"gpt-6.1-sol","visibility":"list","priority":1}]}'
  dr refresh save; assert_rc 0
  assert_has "$T/cfg/$SNAP" "codex.models=gpt-6.1-sol,gpt-6.1-terra,gpt-6-astra"
  assert_has "$T/cfg/$SNAP" "codex.default-model=gpt-6.1-sol"
  write_codex_models '{"models":[{"slug":"gpt-6.1-terra","visibility":"list","priority":2},{"slug":"gpt-6-astra","visibility":"list","priority":3},{"slug":"gpt-6.2-sol","visibility":"list","priority":1}]}'
  dr refresh check
  assert_rc 0
  assert_eq "$(kv added.codex.models)" gpt-6.2-sol "added.codex.models"
  assert_eq "$(kv removed.codex.models)" gpt-6.1-sol "removed.codex.models"
  assert_eq "$(kv changed.codex.default-model)" "gpt-6.1-sol -> gpt-6.2-sol" "changed.codex.default-model（一覧の先頭）"
  # config.toml の model（最初の [ より前）が、一覧の先頭より優先される
  printf 'model = "gpt-6.1-terra"\n\n[profiles.x]\nmodel = "ignored"\n' > "$HOME/.codex/config.toml"
  dr refresh check
  assert_eq "$(kv changed.codex.default-model)" "gpt-6.1-sol -> gpt-6.1-terra" "changed.codex.default-model（config.toml）"
  # 最初の [ より後ろの model は使わない
  printf '[profiles.x]\nmodel = "ignored"\n' > "$HOME/.codex/config.toml"
  dr refresh check
  assert_eq "$(kv changed.codex.default-model)" "gpt-6.1-sol -> gpt-6.2-sol" "changed.codex.default-model（[ より後ろの model は無視）"
}

t_check_no_snapshot() {
  refresh_env
  dr refresh check
  assert_rc 0
  assert_eq "$(kv snapshot)" absent "snapshot"
  assert_eq "$(kv saved)" "" "saved"
  assert_eq "$(kv days-since)" "" "days-since"
  [ ! -e "$T/cfg/$SNAP" ] || fail "check が記録を書いた"
}

t_check_unavailable() {
  refresh_env
  export STUB_CURSOR_MODELS="auto - Auto (default)"
  dr refresh check
  assert_rc 0
  assert_eq "$(kv unavailable.design-review)" "grok(grok-4.7-high)" "unavailable.design-review"
  assert_eq "$(kv unavailable.code-review)" "grok(grok-4.7-high)" "unavailable.code-review"
  assert_eq "$(kv unavailable.code-review-extra)" "carbon(gemini-4-carbon-medium)" "unavailable.code-review-extra"
  assert_eq "$(grep '^unavailable\.' "$T/out" | cut -d= -f1 | tr '\n' ' ')" "unavailable.design-review unavailable.code-review unavailable.code-review-extra " "役割の順"
}

t_check_unavailable_codex_hidden() {
  need_jq || return 0
  refresh_env
  write_codex_models '{"models":[{"slug":"gpt-6.1-sol","visibility":"list","priority":1},{"slug":"gpt-hidden","visibility":"hide","priority":0}]}'
  printf 'hid  codex  gpt-hidden   -  included  openai\ngone codex  gpt-missing  -  included  openai\nclaude claude - - included anthropic\n' > "$T/codex.conf"
  dr config role design-review --from "$T/codex.conf"; assert_rc 0
  dr refresh check
  assert_rc 0
  assert_eq "$(kv unavailable.design-review)" "gone(gpt-missing)" "非表示のモデルは出さず、一覧に無いモデルだけ出す"
}

t_refresh_bad_args() {
  refresh_env
  dr refresh bogus; assert_rc 1
  dr refresh notice --bogus; assert_rc 1
  dr refresh --help; assert_rc 0
}

# ---- P1: 役割の上書き --------------------------------------------------------

t_role_override_doctor() {
  new_env; with_codex; with_cursor
  set_user_vendors openai
  printf '# 手元の候補\nmine  codex   -  low  included  openai\nclaude claude  -  -    included  anthropic\n' > "$T/mine.conf"
  dr config role code-review --from "$T/mine.conf"
  assert_rc 0
  assert_eq "$(kv source)" override "config role --from の source"
  dr config role code-review
  assert_rc 0
  assert_eq "$(kv role)" code-review "role"
  assert_eq "$(kv source)" override "source"
  assert_eq "$(kv file)" "$T/cfg/roles/code-review.conf" "file"
  assert_eq "$(kv default)" "$ROOT/config/roles/code-review.conf" "default"
  assert_eq "$(kv override)" current "override"
  dr doctor
  assert_rc 0
  assert_eq "$(kv role.code-review)" mine "role.code-review"
  assert_eq "$(kv role.code-review.source)" override "role.code-review.source"
  assert_eq "$(kv role.code-review.override)" current "role.code-review.override"
  assert_eq "$(kv role.design-review.source)" default "role.design-review.source"
}

t_role_from_rejects() {
  new_env
  printf 'broken line here\n' > "$T/broken.conf"
  dr config role code-review --from "$T/broken.conf"
  assert_rc 1
  assert_has "$T/err" "broken.conf:1"
  printf '# 候補が1つも無い\n\n' > "$T/empty.conf"
  dr config role code-review --from "$T/empty.conf"
  assert_rc 1
  # backend と vendors の食い違い（3行目）
  printf '# 食い違う候補\nok  claude  -  -  included  anthropic\n' > "$T/head.conf"
  for bad in \
    "x codex - - included anthropic" \
    "x cursor grok-4.7-high - included xai" \
    "x cursor gemini-4-carbon-medium - included cursor" \
    "x claude - - included openai" \
    "x claude gpt-x - included anthropic"; do
    { cat "$T/head.conf"; printf '%s\n' "$bad"; } > "$T/mismatch.conf"
    dr config role code-review --from "$T/mismatch.conf"
    assert_rc 1
    assert_has "$T/err" "mismatch.conf:3"
  done
  [ ! -e "$T/cfg/roles/code-review.conf" ] || fail "拒んだのに上書きが作られた"
  # ほかの役割（design-review の既定値）で別の定義に使われている id
  printf '%s\n' 'grok  cursor  gemini-4-carbon-medium  -  included  cursor,google' > "$T/sameid.conf"
  dr config role code-review --from "$T/sameid.conf"
  assert_rc 1
  assert_has "$T/err" "別の定義に使われています"
  [ ! -e "$T/cfg/roles/code-review.conf" ] || fail "別の定義の id を含むファイルで上書きが作られた"
  # 同じ定義なら通る
  printf '%s\n' 'codex  codex  -  high  included  openai' > "$T/samedef.conf"
  dr config role code-review --from "$T/samedef.conf"
  assert_rc 0
}

t_role_stale_and_keep() {
  refresh_env; plugin_copy
  set_user_vendors openai
  export DEV_RELAY_TODAY=2026-10-02
  snapshot_same_versions
  printf 'mine  codex   -  low  included  openai\n' > "$T/mine.conf"
  drp config role code-review --from "$T/mine.conf"; assert_rc 0
  drp doctor
  assert_eq "$(kv role.code-review.override)" current "既定値を変える前"
  printf '# 既定値が変わった\n' >> "$T/plugin/config/roles/code-review.conf"
  drp doctor
  assert_eq "$(kv role.code-review.override)" stale "既定値を変えたあとの doctor"
  drp refresh check
  assert_eq "$(kv override.code-review)" stale "refresh check の override.code-review"
  drp refresh notice
  assert_contains "$(cat "$T/out")" "上書きの元になった既定のレビュアー候補が変わりました（code-review）" "通知"
  drp config role code-review --keep
  assert_rc 0
  assert_eq "$(kv override)" current "--keep の出力"
  drp doctor
  assert_eq "$(kv role.code-review.override)" current "--keep のあとの doctor"
  drp refresh notice
  assert_eq "$(cat "$T/out")" "" "--keep のあとの通知"
}

t_role_reset_and_errors() {
  new_env
  printf 'mine  codex   -  low  included  openai\n' > "$T/mine.conf"
  dr config role code-review --from "$T/mine.conf"; assert_rc 0
  dr config role code-review --reset
  assert_rc 0
  assert_eq "$(kv source)" default "--reset の出力"
  [ ! -e "$T/cfg/roles/code-review.conf" ] || fail "--reset のあとに .conf が残った"
  [ ! -e "$T/cfg/roles/code-review.base" ] || fail "--reset のあとに .base が残った"
  dr config role code-review
  assert_eq "$(kv source)" default "--reset のあとの source"
  assert_eq "$(kv file)" "$ROOT/config/roles/code-review.conf" "--reset のあとの file"
  dr config role code-review --reset; assert_rc 0
  dr config role nosuch-role; assert_rc 1
  dr config role code-review --keep; assert_rc 1
  dr config role code-review --from "$T/mine.conf" --reset; assert_rc 1
}

t_role_override_metered_vendors() {
  new_env; with_codex; with_cursor
  set_user_vendors openai
  printf 'c1  cursor  gemini-4-carbon-medium  -  metered   cursor,google\na1  cursor  grok-4.7-high  -  included  cursor,xai\nb1  codex  -  high  included  openai\nclaude  claude  -  -  included  anthropic\n' > "$T/ovr.conf"
  dr config role code-review --from "$T/ovr.conf"; assert_rc 0
  dr doctor
  assert_eq "$(kv role.code-review)" b1 "許可が無い候補を飛ばして選ぶ"
  assert_contains "$(kv role.code-review.skipped)" "a1(vendor-not-allowed:cursor,xai)" "a1 の理由"
  assert_contains "$(kv role.code-review.skipped)" "metered-off" "c1 の理由"
  if have_jq; then
    set_user_vendors openai,cursor,xai,google
    dr doctor
    assert_eq "$(kv role.code-review)" a1 "metered off のとき c1 を飛ばす"
    assert_contains "$(kv role.code-review.skipped)" "c1(metered-off)" "c1 の理由"
    set_metered auto
    dr doctor
    assert_eq "$(kv role.code-review)" c1 "metered auto なら c1 が選ばれる"
  fi
  # 設定フォルダに直接置いた、backend と vendors の食い違う上書き。送り先が none のときも CLI は呼ばれない
  set_user_vendors none
  mkdir -p "$T/cfg/roles"
  printf 'bad  codex  -  -  included  anthropic\n' > "$T/cfg/roles/code-review.conf"
  dr review code --intent "目的"
  assert_rc 1
  assert_eq "$(codex_runs)" 0 "Codex の実行回数"
}

t_config_notice() {
  new_env
  dr config notice; assert_eq "$(cat "$T/out")" "notice=on" "既定"
  dr config notice off; assert_rc 0
  assert_eq "$(cat "$T/out")" "notice=off" "off を書いたときの出力"
  dr config notice; assert_eq "$(cat "$T/out")" "notice=off" "off を書いたあと"
  dr config notice on; assert_rc 0
  dr config notice; assert_eq "$(cat "$T/out")" "notice=on" "on を書いたあと"
  dr config notice bogus; assert_rc 1
  dr config notice; assert_eq "$(cat "$T/out")" "notice=on" "不正な値のあと"
}

# ---- P1: スモークテスト（偽の CLI が形式どおりの本文を返す） ----------------------

t_smoke_codex_pass() {
  smoke_env
  dr smoke
  assert_rc 0
  assert_eq "$(kv smoke.codex)" pass "smoke.codex"
  assert_eq "$(kv smoke.codex.role)" design-review "smoke.codex.role"
  assert_eq "$(kv smoke.codex.findings)" 2 "smoke.codex.findings"
  assert_eq "$(kv smoke.codex.seeded)" 2/2 "smoke.codex.seeded"
  assert_file "$(kv smoke.codex.result)"
  assert_file "$(kv smoke.dir)/codex/result.md"
}

# Codex の本文を変えて smoke --reviewer codex を実行し、結果の状態と理由を確かめる
smoke_codex_with() {
  export STUB_CODEX_BODY="$(review_body "$1")"
  dr smoke --reviewer codex
  assert_rc 2
  assert_eq "$(kv smoke.codex)" fail "smoke.codex（$1）"
  assert_contains "$(kv smoke.codex.reason)" "$2" "smoke.codex.reason（$1）"
}
t_smoke_codex_fail_reasons() {
  smoke_env
  smoke_codex_with no-findings "no-findings"
  assert_eq "$(kv smoke.codex.reason)" "no-findings" "指摘が無いときは no-findings だけ"
  smoke_codex_with "no-field:再現" "fields-missing:再現"
  smoke_codex_with no-verdict "no-verdict"
  smoke_codex_with no-seeded "seeded-0"
}

t_smoke_codex_exit() {
  smoke_env
  export STUB_CODEX_EXIT=2
  dr smoke --reviewer codex
  assert_rc 2
  assert_eq "$(kv smoke.codex)" fail "smoke.codex"
  assert_eq "$(kv smoke.codex.reason)" "exit:10" "smoke.codex.reason"
}

t_smoke_vendors() {
  smoke_env openai
  dr smoke
  assert_rc 0
  assert_eq "$(kv smoke.vendors)" openai "smoke.vendors（設定のまま）"
  assert_eq "$(kv smoke.grok)" skipped "smoke.grok"
  assert_contains "$(kv smoke.grok.reason)" "vendor-not-allowed:cursor,xai" "smoke.grok.reason"
  assert_eq "$(cursor_runs)" 0 "Cursor の実行回数"
  dr smoke --vendors openai,cursor,xai
  assert_rc 0
  assert_eq "$(kv smoke.vendors)" openai,cursor,xai "smoke.vendors（--vendors）"
  if have_jq; then
    assert_eq "$(kv smoke.grok)" pass "--vendors で許可した grok"
    assert_eq "$(cursor_runs)" 1 "Cursor の実行回数"
  fi
}

t_smoke_metered() {
  need_jq || return 0
  smoke_env
  dr smoke --reviewer carbon
  assert_rc 0
  assert_eq "$(kv smoke.carbon)" skipped "metered off の carbon"
  assert_contains "$(kv smoke.carbon.reason)" "metered-off" "smoke.carbon.reason"
  assert_eq "$(cursor_runs)" 0 "Cursor の実行回数"
  set_metered auto
  dr smoke --reviewer carbon
  assert_rc 0
  assert_eq "$(kv smoke.carbon)" pass "metered auto の carbon"
  assert_has "$STUB_LOG" "--model gemini-4-carbon-medium"
}

t_smoke_cursor_changes_worktree() {
  need_jq || return 0
  smoke_env
  export STUB_CURSOR_ACTION="create:newfile.txt"
  dr smoke --reviewer grok
  assert_rc 2
  assert_eq "$(kv smoke.grok)" fail "smoke.grok"
  assert_eq "$(kv smoke.grok.reason)" "exit:5" "smoke.grok.reason"
}

# 題材で無視されるファイル（Python のキャッシュ）を Cursor が作っても、作業ツリーの変化に数えない
t_smoke_cursor_ignored_file() {
  need_jq || return 0
  smoke_env
  export STUB_CURSOR_ACTION="create:__pycache__/stats.cpython-314.pyc"
  dr smoke --reviewer grok
  assert_rc 0
  assert_eq "$(kv smoke.grok)" pass "smoke.grok"
}

t_smoke_claude_pending() {
  smoke_env
  dr smoke --reviewer claude
  assert_rc 0
  assert_eq "$(kv smoke.claude)" pending "smoke.claude"
  prompt="$(kv smoke.claude.prompt)"
  assert_file "$prompt"
  assert_has "$prompt" "median"
  case "$(kv smoke.claude.out)" in */result.md) ;; *) fail "smoke.claude.out が result.md でない: $(kv smoke.claude.out)" ;; esac
}

t_smoke_reviewer_filter() {
  smoke_env
  dr smoke --reviewer codex
  assert_rc 0
  assert_eq "$(kv smoke.codex)" pass "smoke.codex"
  assert_eq "$(kv smoke.grok)" "" "smoke.grok"
  assert_eq "$(kv smoke.claude)" "" "smoke.claude"
  assert_eq "$(kv smoke.carbon)" "" "smoke.carbon"
  dr smoke --reviewer codex --reviewer claude
  assert_rc 0
  assert_eq "$(kv smoke.codex)" pass "smoke.codex（2つ指定）"
  assert_eq "$(kv smoke.claude)" pending "smoke.claude（2つ指定）"
  dr smoke --reviewer nosuch
  assert_rc 1
}

t_smoke_outside_git() {
  smoke_env
  nogit="$T/nogit"; mkdir -p "$nogit"
  dr_in "$nogit" smoke --reviewer codex --reviewer grok
  assert_rc 0
  assert_eq "$(kv smoke.codex)" pass "git リポジトリの外の smoke.codex"
  if have_jq; then assert_eq "$(kv smoke.grok)" pass "git リポジトリの外の smoke.grok"; fi
  [ -z "$(ls -A "$nogit")" ] || fail "実行したフォルダに何かが書かれた: $(ls -A "$nogit")"
  before="$(cd "$REPO" && git status --porcelain)"
  dr smoke --reviewer codex
  assert_rc 0
  assert_eq "$(cd "$REPO" && git status --porcelain)" "$before" "smoke のあとの git status"
}

t_smoke_codex_once() {
  smoke_env
  dr smoke
  assert_rc 0
  assert_eq "$(codex_runs)" 1 "Codex の実行回数"
  assert_eq "$(grep -c '^smoke\.codex=' "$T/out" || true)" 1 "smoke.codex の行の数"
}

t_smoke_design_only_and_same_id() {
  smoke_env
  # design-review にだけある候補（dsg）
  printf 'codex  codex   -  high  included  openai\ndsg    codex   -  low   included  openai\nclaude claude  -  -    included  anthropic\n' > "$T/design.conf"
  dr config role design-review --from "$T/design.conf"; assert_rc 0
  dr smoke
  assert_rc 0
  assert_eq "$(kv smoke.dsg.role)" design-review "smoke.dsg.role"
  assert_eq "$(kv smoke.dsg)" pass "smoke.dsg"
  assert_eq "$(codex_runs)" 2 "Codex の実行回数（codex と dsg）"
  # 同じ id が役割によって違う定義（設定フォルダに直接置く）。CLI は呼ばれない
  : > "$STUB_LOG"
  printf 'codex  codex   -  high  included  openai\ngrok   cursor  gemini-4-carbon-medium  -  included  cursor,google\nclaude claude  -  -    included  anthropic\n' > "$T/cfg/roles/design-review.conf"
  dr smoke
  assert_rc 1
  assert_eq "$(codex_runs)" 0 "Codex の実行回数"
  assert_eq "$(cursor_runs)" 0 "Cursor の実行回数"
}

t_smoke_runs_are_separate() {
  smoke_env
  dr smoke --reviewer claude
  assert_rc 0
  d1="$(kv smoke.dir)"
  p1="$(kv smoke.claude.prompt)"
  assert_file "$p1"
  old="$(date -v-8d +%Y%m%d%H%M 2>/dev/null || date -d '8 days ago' +%Y%m%d%H%M)"
  mkdir -p "$T/cfg/state/smoke/old-run" "$T/cfg/state/smoke/new-run"
  touch -t "$old" "$T/cfg/state/smoke/old-run"
  dr smoke --reviewer codex
  assert_rc 0
  d2="$(kv smoke.dir)"
  [ -n "$d1" ] && [ "$d1" != "$d2" ] || fail "smoke.dir が同じ: $d1 / $d2"
  assert_file "$p1"
  [ ! -e "$T/cfg/state/smoke/old-run" ] || fail "8日前のフォルダが消えていない"
  [ -d "$T/cfg/state/smoke/new-run" ] || fail "新しいフォルダが消えた"
  [ -d "$d2" ] || fail "今回のフォルダが無い"
}

t_smoke_check_exit_codes() {
  new_env
  review_body > "$T/good.md"
  dr smoke check "$T/good.md"
  assert_rc 0
  assert_eq "$(kv check)" pass "check"
  assert_eq "$(kv check.findings)" 2 "check.findings"
  assert_eq "$(kv check.seeded)" 2/2 "check.seeded"
  review_body no-verdict > "$T/bad.md"
  dr smoke check "$T/bad.md"
  assert_rc 2
  assert_eq "$(kv check)" fail "check（判定なし）"
  assert_eq "$(kv check.reason)" no-verdict "check.reason"
  dr smoke check "$T/nosuch.md"
  assert_rc 1
}

t_smoke_check_prompt_echo() {
  new_env
  dr review code --intent "目的" --dry-run
  assert_rc 0
  cp "$T/out" "$T/echo.md"
  dr smoke check "$T/echo.md"
  assert_rc 2
  assert_eq "$(kv check)" fail "check"
  assert_eq "$(kv check.reason)" no-findings "check.reason"
}

t_smoke_check_shapes() {
  new_env
  # 4つの項目が2つの指摘に分かれている
  cat > "$T/split.md" <<'MD'
### 1 偶数個の件
- 重要度: 高
- 場所: stats.py:4

### 2 空のリストの件
- 再現: median([]) が IndexError になる
- 確認状況: 実行済み

要修正あり
MD
  dr smoke check "$T/split.md"
  assert_rc 2
  assert_eq "$(kv check.reason)" "fields-missing:再現,確認状況" "項目が分かれているとき"
  # 形式がフェンスの中にしか無い
  cat > "$T/fenced.md" <<'MD'
次の形式で書きます。

```
### 1 偶数個の件
- 重要度: 高
- 場所: stats.py:4
- 再現: median([1, 2, 3, 4]) が 3 を返す
- 確認状況: 実行済み
```

要修正あり
MD
  dr smoke check "$T/fenced.md"
  assert_rc 2
  assert_eq "$(kv check.reason)" no-findings "フェンスの中だけのとき"
  # 判定の語を2つとも含む行しか無い
  { review_body no-verdict; printf '%s\n' '最後に1行で「ブロッカーなし」または「要修正あり」と書いてください。'; } > "$T/both.md"
  dr smoke check "$T/both.md"
  assert_rc 2
  assert_eq "$(kv check.reason)" no-verdict "判定の語を2つとも含む行しか無いとき"
  # 判定の語を文の中に含む行しか無い
  { review_body no-verdict; printf '%s\n' '最終判定は要修正ありです。'; } > "$T/sentence.md"
  dr smoke check "$T/sentence.md"
  assert_rc 2
  assert_eq "$(kv check.reason)" no-verdict "判定の語を文の中に含む行しか無いとき"
  # 項目の行の中にだけ判定の語がある
  review_body no-verdict | sed 's/^- 再現: median(\[\]).*$/- 再現: echo 要修正あり/' > "$T/item.md"
  assert_has "$T/item.md" "- 再現: echo 要修正あり"
  dr smoke check "$T/item.md"
  assert_rc 2
  assert_eq "$(kv check.reason)" no-verdict "項目の行の中にだけ判定の語があるとき"
  # 飾りを付けた判定の行は判定として数える
  { review_body no-verdict; printf '%s\n' '**要修正あり**'; } > "$T/bold.md"
  dr smoke check "$T/bold.md"
  assert_rc 0
  assert_eq "$(kv check)" pass "太字の判定の行"
}

t_smoke_fixture() {
  command -v python3 >/dev/null 2>&1 || { skip "python3 が無い"; return 0; }
  new_env
  mkdir -p "$T/base" "$T/changed"
  cp -R "$ROOT/tests/smoke/base/." "$T/base/"
  cp -R "$ROOT/tests/smoke/base/." "$T/changed/"
  cp -R "$ROOT/tests/smoke/change/." "$T/changed/"
  RC=0; ( cd "$T/base" && python3 -B -m unittest ) > "$T/out" 2> "$T/err" || RC=$?
  assert_rc 0
  RC=0; ( cd "$T/changed" && python3 -B -m unittest ) > "$T/out" 2> "$T/err" || RC=$?
  assert_rc 0
  ( cd "$T/changed" && python3 -B - <<'PY'
import stats
print("even=%s" % stats.median([1, 2, 3, 4]))
try:
    stats.median([])
    print("empty=none")
except Exception as e:
    print("empty=%s" % type(e).__name__)
PY
  ) > "$T/out" 2> "$T/err" || true
  [ "$(kv even)" != "2.5" ] || fail "median([1, 2, 3, 4]) が 2.5 になる（不具合が仕込まれていない）"
  [ "$(kv empty)" != "ValueError" ] || fail "median([]) が ValueError になる（不具合が仕込まれていない）"
}

# ---- P1: そのほか ------------------------------------------------------------

t_hooks_json() {
  need_jq || return 0
  jq -e . "$ROOT/hooks/hooks.json" >/dev/null 2>&1 || fail "hooks/hooks.json が正しい JSON でない"
  jq -e '[.hooks.SessionStart[].hooks[].command] | any(contains("refresh notice --hook"))' "$ROOT/hooks/hooks.json" >/dev/null 2>&1 \
    || fail "SessionStart のコマンドに refresh notice --hook が無い"
}

t_days_from_date() {
  new_env
  diff_days() { echo $(( $(days_from_date "$1") - $(days_from_date "$2") )); }
  # shellcheck disable=SC1091
  . "$ROOT/scripts/lib/common.sh"
  # shellcheck disable=SC1091
  . "$ROOT/scripts/lib/state.sh"
  assert_eq "$(diff_days 2026-03-01 2026-02-28)" 1 "2026-03-01 と 2026-02-28"
  assert_eq "$(diff_days 2024-03-01 2024-02-28)" 2 "2024-03-01 と 2024-02-28"
  assert_eq "$(diff_days 2027-01-01 2026-12-31)" 1 "2027-01-01 と 2026-12-31"
  RC=0; days_from_date 2026-3-1 >/dev/null 2>&1 || RC=$?
  assert_eq "$RC" 1 "形が違う日付の戻り値"
}

t_save_keeps_on_failure() {
  refresh_env
  export DEV_RELAY_TODAY=2026-10-01
  dr refresh save; assert_rc 0
  warn1="$(grep -c '^warning:' "$T/err" || true)"
  before="$(grep '^cursor.models=' "$T/cfg/$SNAP")"
  [ -n "$before" ] || fail "最初の save に cursor.models が無い"
  export STUB_CURSOR_MODELS_EXIT=1 STUB_CURSOR_MODELS="bogus-one - Bogus One"
  dr refresh save
  assert_rc 0
  warn2="$(grep -c '^warning:' "$T/err" || true)"
  [ "$warn2" -gt "$warn1" ] || fail "取得に失敗したのに警告が増えない（${warn1} → ${warn2}）"
  assert_eq "$(grep '^cursor.models=' "$T/cfg/$SNAP")" "$before" "引き継いだ cursor.models"
  assert_lacks "$T/cfg/$SNAP" "bogus-one"
  unset STUB_CURSOR_MODELS_EXIT
  export STUB_CURSOR_MODELS=$'auto - Auto (default)\ngrok-4.7-high - Grok 4.7 High\nnew-model-x - New Model X'
  dr refresh check
  assert_rc 0
  assert_eq "$(kv added.cursor.models)" new-model-x "引き継いだ一覧との違い（added）"
  assert_eq "$(kv removed.cursor.models)" gemini-4-carbon-medium "引き継いだ一覧との違い（removed）"
}

# --version が止まる場合（sleep で待つ、標準出力を持った子が残る）。9秒以内に、何も出さず 0 で戻る
hook_hang_case() {
  start=$SECONDS
  dr refresh notice --hook
  elapsed=$((SECONDS - start))
  assert_rc 0
  assert_eq "$(cat "$T/out")" "" "標準出力（$1）"
  [ ! -s "$T/err" ] || fail "標準エラーに出た（$1）: $(cat "$T/err")"
  [ "$elapsed" -le 9 ] || fail "9秒以内に戻らなかった（$1）: ${elapsed} 秒"
}
t_hook_returns_when_version_hangs() {
  refresh_env
  export DEV_RELAY_TODAY=2026-10-01
  dr refresh save; assert_rc 0
  export STUB_VERSION_SLEEP=30
  hook_hang_case "sleep"
  unset STUB_VERSION_SLEEP
  export STUB_VERSION_ORPHAN=30
  hook_hang_case "子が残る"
  unset STUB_VERSION_ORPHAN
  without_timeout_tools
  export STUB_VERSION_SLEEP=30
  hook_hang_case "perl の経路・sleep"
  unset STUB_VERSION_SLEEP
  export STUB_VERSION_ORPHAN=30
  hook_hang_case "perl の経路・子が残る"
}

# TERM を無視する --version でも、期限のあと KILL で止めて戻る
t_hook_returns_when_version_ignores_term() {
  refresh_env
  export DEV_RELAY_TODAY=2026-10-01
  dr refresh save; assert_rc 0
  export STUB_VERSION_IGNORE=30
  hook_hang_case "TERM を無視する"
  without_timeout_tools
  hook_hang_case "perl の経路・TERM を無視する"
}

t_notice_does_not_clobber_save() {
  refresh_env
  export DEV_RELAY_TODAY=2026-10-01
  ( export STUB_VERSION_SLEEP=2; cd "$REPO" && "$DR" refresh notice ) > "$T/notice.out" 2> "$T/notice.err" &
  pid=$!
  sleep 1
  dr refresh save; assert_rc 0
  wait "$pid"
  assert_has "$T/cfg/$SNAP" "cursor.models="
}

t_notice_corrupt_snapshot() {
  refresh_env
  export DEV_RELAY_TODAY=2026-10-01
  write_snapshot "tool.codex.version=codex-cli 0.0.0-stub"
  cp "$T/cfg/$SNAP" "$T/snapshot.orig"
  dr refresh notice
  assert_rc 0
  assert_eq "$(out_lines)" 1 "出力の行数"
  assert_contains "$(cat "$T/out")" "前回の確認の記録を読めません" "通知"
  cmp -s "$T/snapshot.orig" "$T/cfg/$SNAP" || fail "壊れた記録が書き換えられた"
  dr refresh save; assert_rc 0
  dr refresh notice
  assert_eq "$(cat "$T/out")" "" "save のあとの通知"
}

t_save_prints_changes() {
  refresh_env
  export DEV_RELAY_TODAY=2026-10-01
  dr refresh save; assert_rc 0
  export STUB_CURSOR_MODELS=$'auto - Auto (default)\ngrok-4.7-high - Grok 4.7 High\ngemini-4-carbon-medium - Gemini 4 Carbon Medium\nnew-model-x - New Model X'
  dr refresh save
  assert_rc 0
  assert_eq "$(kv added.cursor.models)" new-model-x "added.cursor.models"
  assert_eq "$(kv saved)" 2026-10-01 "saved"
  a="$(grep -n '^added\.cursor\.models=' "$T/out" | cut -d: -f1)"
  b="$(grep -n '^saved=' "$T/out" | cut -d: -f1)"
  [ -n "$a" ] && [ -n "$b" ] && [ "$a" -lt "$b" ] || fail "added の行が saved より前に出ていない（${a:-無し} / ${b:-無し}）"
  dr refresh check
  assert_eq "$(kv added.cursor.models)" "" "save のあとの check"
}

t_smoke_ignores_git_env() {
  smoke_env
  other="$T/other"
  git init -q "$other"
  (
    cd "$other" || exit 1
    git config user.name tester
    git config user.email "$NOREPLY"
    git config commit.gpgsign false
    printf 'a\n' > f.txt
    git add f.txt
    git commit -qm init
    printf 'b\n' > f.txt
  )
  other_state() {
    env -u GIT_DIR -u GIT_WORK_TREE git -C "$other" rev-parse HEAD
    env -u GIT_DIR -u GIT_WORK_TREE git -C "$other" status --porcelain
    env -u GIT_DIR -u GIT_WORK_TREE git -C "$other" config --local --list
  }
  before="$(other_state)"
  export GIT_DIR="$other/.git" GIT_WORK_TREE="$other"
  dr smoke --reviewer claude --vendors none
  unset GIT_DIR GIT_WORK_TREE
  assert_rc 0
  assert_eq "$(kv smoke.claude)" pending "smoke.claude"
  assert_eq "$(other_state)" "$before" "実行元のリポジトリの HEAD、作業ツリー、ローカル設定"
}

t_smoke_relative_config_dir() {
  need_jq || return 0
  smoke_env
  export DEV_RELAY_CONFIG_DIR=relcfg
  dr_in "$T" config metered auto; assert_rc 0
  dr_in "$T" smoke --reviewer carbon --vendors cursor,google
  assert_rc 0
  assert_eq "$(kv smoke.carbon)" pass "相対パスの設定フォルダで metered auto の carbon"
}

t_smoke_bad_reviewer_value() {
  smoke_env
  dr smoke --reviewer "" --vendors none; assert_rc 1
  dr smoke --reviewer " " --vendors none; assert_rc 1
  dr_in "$ROOT/tests/stubs" smoke --reviewer "code*" --vendors none; assert_rc 1
}

t_smoke_bad_timeout() {
  smoke_env
  export DEV_RELAY_TIMEOUT=0
  dr smoke --reviewer claude --vendors none
  assert_rc 1
}

t_notice_two_review_dates() {
  refresh_env; plugin_copy
  printf '2026-10-15 一件目\n2026-10-18 二件目\n' > "$T/plugin/config/review-dates.conf"
  snapshot_same_versions
  export DEV_RELAY_TODAY=2026-10-20
  drp refresh notice
  assert_rc 0
  assert_eq "$(cat "$T/out")" "dev-relay: 見直す予定の日を過ぎました（2026-10-15 一件目 ほか1件）。/dev-relay:refresh で確認できます。" "通知の文"
}

# ---- 実行 -------------------------------------------------------------------

run_test() {
  local name="$1" fn="$2" rc
  N=$((N + 1))
  rm -f "$WORK/skip"
  ( FAIL=0; "$fn"; [ "$FAIL" -eq 0 ] )
  rc=$?
  if [ "$rc" -eq 0 ]; then
    PASSED=$((PASSED + 1))
    if [ -f "$WORK/skip" ]; then
      echo "ok $N - $name # SKIP $(cat "$WORK/skip")"
    else
      echo "ok $N - $name"
    fi
  else
    FAILED=$((FAILED + 1))
    echo "not ok $N - $name"
  fi
}

run_test "1 bin/dev-relay: 実行権限、--help、知らないサブコマンド" t_entry
run_test "2 doctor: 設定が何も無ければ Claude になり、codex は vendor-not-allowed" t_doctor_unset
run_test "2a doctor: 許可 openai なら codex、追加は claude、carbon の理由が出る" t_doctor_user_openai
run_test "2b doctor: 利用者の既定 ask は source=ask で claude" t_doctor_ask
run_test "2c doctor: リポジトリの設定 openai が ask より優先される" t_doctor_ask_repo
run_test "2d doctor: リポジトリの設定 none が利用者の既定より優先される" t_doctor_repo_none
run_test "3 doctor: どちらもなし" t_doctor_no_tools
run_test "4 doctor: Codex なし・Cursor ありで grok" t_doctor_cursor_only
run_test "5 doctor: Codex が未ログイン" t_doctor_codex_logged_out
run_test "15a doctor: Cursor が未ログイン（終了コード 0 の Not logged in）" t_doctor_cursor_logged_out
run_test "6 review code: 目的なしは 1" t_review_no_intent
run_test "7 review code: 変更なしは 1" t_review_no_changes
run_test "8 review code --dry-run: 依頼文を出し、CLI を呼ばない" t_dry_run
run_test "9 review code: Codex で結果ファイルが返る" t_review_codex
run_test "10 review code --effort max: Codex に渡る" t_effort_max
run_test "11 review code --extra: metered=off なら 3 と依頼文" t_extra_metered_off
run_test "12 review code --extra: metered=auto なら Cursor（carbon）" t_extra_cursor
run_test "13 review code --extra --reviewer carbon: 許可が無ければ 1" t_extra_reviewer_not_allowed
run_test "13a review code: 設定が無ければ Codex があっても外部へ送らない" t_unset_does_not_send
run_test "14 Cursor がファイルを作ると 5" t_cursor_create
run_test "14a Cursor が変更済みのファイルに追記すると 5" t_cursor_append
run_test "14b Cursor がステージ済みの新規ファイルを書き換えて add し直すと 5" t_cursor_restage
run_test "14c Cursor が失敗しても、作業ツリーの変化があれば 5" t_cursor_change_beats_failure
run_test "15 Cursor の is_error が true なら 10" t_cursor_is_error
run_test "15b review code --extra --model x: Cursor では 1" t_extra_model_rejected
run_test "16 Codex の CLI が終了コード 2 なら 10" t_codex_fails
run_test "16a タイムアウトは 124 で、期限内に戻る" t_timeout
run_test "29 結果ファイルが symlink なら、ソースを上書きせず 1" t_out_symlink
run_test "29a 依頼文のファイルが symlink なら、ソースを上書きせず 1" t_prompt_symlink
run_test "30 Cursor が未変更ファイルの改行を変えても 5（autocrlf=input）" t_cursor_clean_crlf
run_test "30a Cursor が未変更ファイルに実行権限を付けても 5（core.filemode=false）" t_cursor_clean_chmod
run_test "18d review code --out: フォルダを渡すと何も書かず 1" t_out_is_directory
run_test "18e review code --out: 置き場所の検査で 1 のとき、この実行が作ったフォルダを残さない" t_out_not_ignored_leaves_no_dir
run_test "18f review code --out: 前からあったフォルダは消さない" t_out_not_ignored_keeps_existing_dir
run_test "18g review code --out: .dev-relay/ がまだ無くても標準の使い方は通る" t_out_fresh_dev_relay
run_test "31 日本語名の未追跡ファイルが依頼文に入る" t_untracked_japanese
run_test "32 timeout と gtimeout が無くても、タイムアウトは 124（perl の経路）" t_timeout_perl
run_test "33 機密らしい名前（空白・日本語を含む）の未追跡ファイルで警告が出る" t_sensitive_uncommitted
run_test "33a 同じ警告が --commit でも出る" t_sensitive_commit
run_test "33b 同じ警告が --base でも出る" t_sensitive_base
run_test "16b login status は1回の実行で1回だけ" t_probe_once
run_test "17 review code: どちらもなしなら 3 と依頼文" t_claude_fallback
run_test "18 review code --extra: どちらもなしなら 4" t_extra_none
run_test "18a review code --extra --exclude claude: 4" t_extra_exclude
run_test "18b review code --out: 無視されない場所は 1" t_out_not_ignored
run_test "18c review code: 同じ秒に2回起動しても結果ファイルが重ならない" t_unique_out
run_test "19 review design: 設計書が標準入力に渡る" t_design
run_test "20 review code --reviewer nosuch: 1" t_reviewer_unknown
run_test "21 review code --effort: Cursor では 1" t_effort_cursor
run_test "22 レビューの前後で git status が変わらない" t_worktree_untouched
run_test "23 config metered" t_config_metered
run_test "23a config の同時書き込みで、どちらの値も残る" t_config_concurrent
run_test "23b DEV_RELAY_TIMEOUT が 0、-1、0.2、abc なら 1" t_bad_timeouts
run_test "23c Codex に model_provider=openai が渡る" t_provider_pinned
run_test "23d Cursor が変更済みのファイルを CRLF に変えると 5" t_cursor_crlf
run_test "23e Cursor が変更済みのファイルに実行権限を付けると 5" t_cursor_chmod
run_test "23f 依頼文のファイルが無視されなければ 1" t_prompt_not_ignored
run_test "24 config vendors" t_config_vendors
run_test "25 役割のファイルの壊れた行は、ファイル名と行番号付きのエラー" t_broken_role_file
run_test "26 implementer.md と implementer-hard.md の本文が一致する" t_agent_bodies
run_test "27 claude plugin validate" t_plugin_validate
run_test "28 check-public: 問題のないリポジトリは 0" t_public_clean
run_test "28a check-public: 問題のあるリポジトリは 1" t_public_detects

run_test "28b check-public: サブフォルダの下の HANDOFF.md、.codex-review/、.dev-relay/ も 1" t_public_subdir_and_empty_email
run_test "28c check-public: @ の前が空の noreply アドレスは 1" t_public_empty_local_part
run_test "31a check-public: 日本語名のファイルも検査する" t_public_japanese

run_test "34 refresh notice: 記録が無ければ何も出さず、state/snapshot に saved と版の行を書く" t_notice_first_run_records
run_test "35 refresh notice: 版が同じで30日未満なら何も出さない" t_notice_quiet_when_same
run_test "36 refresh notice: Codex の版が変わると、前と今の版を含む1行が出る" t_notice_codex_version
run_test "37 refresh notice --hook: 1行の JSON で、systemMessage が --hook なしの出力と同じ" t_notice_hook_json
run_test "38 refresh notice --hook: 版にダブルクォートとバックスラッシュが入っていても正しい JSON" t_notice_hook_escapes
run_test "39 refresh notice: saved の30日後は知らせ、29日後は出さない" t_notice_30_days
run_test "40 refresh notice: 版の変化と30日が重なっても1行で、理由が決められた順に並ぶ" t_notice_one_line_in_order
run_test "41 refresh notice: CLI が PATH から無くなっても、版の変化としては知らせない" t_notice_cli_missing
run_test "42 refresh notice: config notice off なら何も出さず、記録も書かない" t_notice_off
run_test "43 refresh notice: 見直しの日付を過ぎると知らせ、その日以降の refresh save で出なくなる" t_notice_review_date
run_test "44 refresh notice: 設定フォルダに書けなくても終了コード 0（--hook は標準エラーも空）" t_notice_unwritable
run_test "45 refresh save のあとの refresh check: 変化が無ければ present、days-since=0、変化の行なし" t_refresh_save_check_clean
run_test "46 refresh check: Cursor のモデルの増減が added / removed に出る" t_check_cursor_models
run_test "47 refresh check: Codex のモデル一覧と既定のモデルの変化が出る（config.toml の model を優先）" t_check_codex_models
run_test "48 refresh check: 記録が無ければ snapshot=absent で、記録を書かない" t_check_no_snapshot
run_test "49 refresh check: 候補のモデルが今の一覧に無いと unavailable.<役割> に出る" t_check_unavailable
run_test "49a refresh check: Codex の候補のモデルが非表示（hide）でも一覧のファイルにあれば出ない" t_check_unavailable_codex_hidden
run_test "50 refresh: 知らない引数は 1、--help は 0" t_refresh_bad_args
run_test "51 config role --from: doctor で上書きの先頭の候補が選ばれ、source=override、override=current" t_role_override_doctor
run_test "52 config role --from: 壊れたファイル、候補が無いファイル、backend と vendors の食い違いは 1 で、上書きを作らない" t_role_from_rejects
run_test "53 上書きの元の既定値が変わると stale になり、通知に出る。--keep で current に戻る" t_role_stale_and_keep
run_test "54 config role --reset: 既定に戻る。知らない役割、上書きの無い --keep、--from と --reset の同時指定は 1" t_role_reset_and_errors
run_test "55 上書きした候補にも metered と送り先の許可が効き、食い違う上書きは送り先 none でも 1 で CLI を呼ばない" t_role_override_metered_vendors
run_test "56 config notice: 既定は on、off と on を書ける、ほかは 1" t_config_notice
run_test "57 smoke: Codex が形式どおりの本文を返すと pass で、findings と seeded が出る" t_smoke_codex_pass
run_test "58 smoke: 指摘なし、項目の欠け、判定なし、仕込んだ不具合に触れないは fail で終了コード 2" t_smoke_codex_fail_reasons
run_test "59 smoke: Codex が失敗すると fail と exit:10" t_smoke_codex_exit
run_test "60 smoke: 許可の無い候補は skipped で CLI を呼ばず、--vendors で許可すると動く" t_smoke_vendors
run_test "61 smoke: metered が off なら carbon は skipped、auto なら動く" t_smoke_metered
run_test "62 smoke: Cursor が題材にファイルを作ると fail（exit:5）" t_smoke_cursor_changes_worktree
run_test "63 smoke: claude は pending で、題材の差分を含む依頼文が残る" t_smoke_claude_pending
run_test "64 smoke --reviewer: 指定した候補だけが出る。知らない id は 1" t_smoke_reviewer_filter
run_test "65 smoke: git リポジトリの外でも動き、実行したフォルダを変えない" t_smoke_outside_git
run_test "66 smoke: 既定値で全部を許可しても、Codex の実行は1回だけ" t_smoke_codex_once
run_test "67 smoke: design-review にだけある候補も試され、同じ id が役割ごとに違う定義なら 1 で CLI を呼ばない" t_smoke_design_only_and_same_id
run_test "68 smoke: 実行ごとに別のフォルダで、前の実行を消さず、8日前のフォルダだけ消す" t_smoke_runs_are_separate
run_test "69 smoke check: 合格は 0、不合格は 2 と理由、無いファイルは 1" t_smoke_check_exit_codes
run_test "70 smoke check: 依頼文をそのまま写した結果は no-findings で不合格" t_smoke_check_prompt_echo
run_test "71 smoke check: 項目が分かれた結果、フェンスの中だけの結果、判定の語が文や項目の中にしか無い結果は不合格。飾りを付けた判定の行は合格" t_smoke_check_shapes
run_test "72 題材: base のテストが通り、change を重ねると中央値の不具合が出る" t_smoke_fixture
run_test "73 hooks/hooks.json: 正しい JSON で、SessionStart が refresh notice --hook を呼ぶ" t_hooks_json
run_test "74 days_from_date: うるう年をまたぐ日数の差、形が違えば 1" t_days_from_date
run_test "75 refresh save: 取得に失敗したキーは警告を出し、前回の値を引き継ぐ" t_save_keeps_on_failure
run_test "76 refresh notice --hook: --version が止まっても、子が残っても、perl の経路でも9秒以内に、何も出さず 0 で戻る" t_hook_returns_when_version_hangs
run_test "77 refresh notice: 記録を作っている間に refresh save が終わっても、save の記録が残る" t_notice_does_not_clobber_save
run_test "78 refresh notice: 記録が壊れていると、書き換えずに読めない旨を知らせ、save のあとは出ない" t_notice_corrupt_snapshot
run_test "79 refresh save: 前回の記録からの変化を saved より前に出す" t_save_prints_changes
run_test "80 smoke: GIT_DIR と GIT_WORK_TREE が別のリポジトリを指していても、そのリポジトリを変えない" t_smoke_ignores_git_env
run_test "81 smoke: 設定フォルダが相対パスでも、metered auto の carbon が動く" t_smoke_relative_config_dir
run_test "82 smoke --reviewer: 空、空白、グロブは 1" t_smoke_bad_reviewer_value
run_test "83 smoke: DEV_RELAY_TIMEOUT が不正なら 1" t_smoke_bad_timeout
run_test "84 refresh notice --hook: --version が TERM を無視しても、perl の経路でも9秒以内に、何も出さず 0 で戻る" t_hook_returns_when_version_ignores_term
run_test "85 refresh notice: 見直しの日付が2件過ぎていると、括弧の中に ほか1件 を付ける" t_notice_two_review_dates
run_test "86 smoke: Cursor が題材の無視されるファイル（__pycache__）を作っても pass" t_smoke_cursor_ignored_file

echo "# ${PASSED} passed, ${FAILED} failed"
[ "$FAILED" -eq 0 ]
