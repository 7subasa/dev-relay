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

echo "# ${PASSED} passed, ${FAILED} failed"
[ "$FAILED" -eq 0 ]
