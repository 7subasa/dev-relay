#!/usr/bin/env bash
# pr.sh と pr-respond.sh と pr-review.sh が共有する関数。common.sh と gh.sh のあとに source する。単体では実行しない。
# gh_line は、呼ぶ側が作った TMPD（一時フォルダ）を使う。lock_acquire は、呼ぶ側の LOCK_DIR を設定する。

RE_ID='^[A-Za-z0-9_=-]+$'
RE_VER='^[A-Za-z0-9_=@:.,+/-]+$'
RE_NUM='^[0-9]+$'
RE_URL='^https://[^[:space:]]+$'
RE_SHA='^[0-9a-f]{40}$'
RE_B64='^[A-Za-z0-9+/=]+$'
RE_FILE='^[A-Za-z0-9._-]+$'

# 値の形を調べる。引数: 正規表現 値
is_re() { printf '%s\n' "$2" | LC_ALL=C grep -Eq -- "$1"; }

add_blocker() { P_BLOCKERS="${P_BLOCKERS:+$P_BLOCKERS;}$1"; }
add_reason() { R_REASONS="${R_REASONS:+$R_REASONS;}$1"; }

# gh を実行し、標準出力の1行目を GH_LINE に入れる（空もある）。gh が失敗したら 1。
# 引数: 秒 gh の引数...
gh_line() {
  local sec="$1"
  shift
  GH_LINE=""
  gh_capture "$sec" "$TMPD/gh.out" "$@" || return 1
  IFS= read -r GH_LINE < "$TMPD/gh.out" || true
  GH_LINE="${GH_LINE%$'\r'}"
}

# 今のブランチ名を P_BRANCH に入れる（取れなければ空）
pr_branch() {
  P_BRANCH="$(git symbolic-ref -q --short HEAD 2>/dev/null || true)"
}

# 宛先を決める。P_REMOTE と P_REPO を設定し、決められない理由を P_BLOCKERS に足す。
# 呼ぶ前に P_BRANCH を設定しておく。
pr_dest() {
  local up="" remotes urls n repo fetch_url fetch_repo
  P_REMOTE=""; P_REPO=""
  if [ -n "$P_BRANCH" ]; then
    up="$(git config --get "branch.${P_BRANCH}.remote" 2>/dev/null || true)"
  fi
  remotes="$(git remote 2>/dev/null || true)"
  if [ -n "$up" ] && [ "$up" != "." ] && printf '%s\n' "$remotes" | grep -Fxq -- "$up"; then
    P_REMOTE="$up"
  elif printf '%s\n' "$remotes" | grep -Fxq origin; then
    P_REMOTE="origin"
  elif [ "$(printf '%s' "$remotes" | grep -c . || true)" -eq 1 ]; then
    P_REMOTE="$remotes"
  fi
  if [ -z "$P_REMOTE" ]; then
    add_blocker no-remote
    return 0
  fi

  # push 先は、pushurl と insteadOf を当てはめたあとの URL。ちょうど1つでなければ決められない
  urls="$(git remote get-url --push --all "$P_REMOTE" 2>/dev/null || true)"
  n="$(printf '%s' "$urls" | grep -c . || true)"
  if [ "$n" -ne 1 ]; then
    add_blocker push-url-mismatch
    return 0
  fi
  if ! repo="$(gh_repo_from_url "$urls")"; then
    add_blocker not-github
    return 0
  fi
  # ベースとの差は fetch 元から数えるので、fetch 元も同じリポジトリでなければならない
  fetch_url="$(git remote get-url "$P_REMOTE" 2>/dev/null || true)"
  fetch_repo="$(gh_repo_from_url "$fetch_url" || true)"
  if [ "$fetch_repo" != "$repo" ]; then
    add_blocker push-url-mismatch
    return 0
  fi
  P_REPO="$repo"
  P_PUSH_URL="$urls"
}

# 漏れの形に合う行を、行番号付き（行番号:行）で出す。引数: 種類 ファイル
# 検査用の文字列は、公開前の確認（tests/check-public.sh）に掛からないよう文字クラスで書く
leak_grep() {
  case "$1" in
    home-path)
      LC_ALL=C grep -anE -e '/[U]sers/[A-Za-z0-9._-]+/' -e '/[h]ome/[a-z_][a-z0-9_-]*/' -e '[A-Za-z]:[\\/][U]sers[\\/]' "$2" ;;
    api-key)
      LC_ALL=C grep -anE -e '(sk|pk)-[A-Za-z0-9_-]{20,}' -e 'gh[pousr]_[A-Za-z0-9]{30,}' -e 'AKIA[0-9A-Z]{16}' \
        -e 'xox[abprs]-[A-Za-z0-9-]{10,}' -e 'AIza[0-9A-Za-z_-]{35}' "$2" ;;
    private-key)
      LC_ALL=C grep -anE -e '-----BEGIN [A-Z ]*PRIVATE KEY-----' "$2" ;;
  esac
}

# 本文の末尾の空白だけの行を落として出す。引数: ファイル
strip_trailing_blank() {
  LC_ALL=C awk '{ if ($0 ~ /^[[:space:]]*$/) { blanks = blanks $0 "\n" } else { printf "%s", blanks; blanks = ""; print } }' "$1"
}

# 投稿する形を作る: 末尾の空白行を落とし、{{commit}} を置き換え、空行1つを挟んで印を最後の行に付ける。
# 引数: 元のファイル 出力ファイル SHA（置き換えない場合は空） 印
build_post() {
  local src="$1" dest="$2" sha="$3" marker="$4"
  strip_trailing_blank "$src" > "$dest.1"
  if [ -n "$sha" ]; then
    render_template "$dest.1" '{{commit}}' "$sha" > "$dest.2"
  else
    cp "$dest.1" "$dest.2"
  fi
  { cat "$dest.2"; printf '\n%s\n' "$marker"; } > "$dest"
  rm -f "$dest.1" "$dest.2"
}

# 排他を取る。取れなければ <結果の key>=locked で 1。LOCK_DIR を設定する（消すのは呼ぶ側の cleanup）。
# 引数: 排他のフォルダの名前（git の共通フォルダの下） 結果の key コマンドの呼び名
lock_acquire() {
  local name="$1" key="$2" what="$3" common pidfile pid=""
  common="$(cd "$(git rev-parse --git-common-dir)" && pwd -P)"
  LOCK_DIR=""
  if ! mkdir "$common/$name" 2>/dev/null; then
    pidfile="$common/$name/pid"
    if [ -r "$pidfile" ]; then IFS= read -r pid < "$pidfile" || true; fi
    echo "${key}=locked"
    echo "error: 別の ${what} が実行中か、前の実行の排他が残っています: ${common}/${name}${pid:+（pid ${pid}）}" >&2
    echo "実行中でないことを確かめてから、そのフォルダを消してください（自動では消しません）。" >&2
    exit 1
  fi
  LOCK_DIR="$common/$name"
  printf '%s\n' "$$" > "$LOCK_DIR/pid"
}

# ブランチを要らない前提を集める（pr inbox と pr review が使う）。pr_collect と fb_collect の前半と同じ順。
# 結果は次の変数に入る（$(...) の中で呼ばない）:
#   TOOL_GH P_GIT P_ALLOWED P_ACCOUNT P_REMOTE P_REPO P_PUSH_URL P_BRANCH P_BLOCKERS（; 区切り）
pr_base_collect() {
  local gh_ok=0 in_repo=1
  P_BLOCKERS=""; P_GIT="no"; P_ALLOWED="unset"; P_ACCOUNT=""; P_REMOTE=""; P_REPO=""; P_PUSH_URL=""; P_BRANCH=""

  probe_gh
  if ! in_git_repo; then in_repo=0; add_blocker not-a-git-repo; fi
  case "$TOOL_GH" in
    not-installed) add_blocker gh-not-installed ;;
    not-logged-in) add_blocker gh-not-logged-in ;;
  esac
  if [ "$in_repo" -eq 0 ]; then return 0; fi
  P_GIT="yes"

  P_ALLOWED="$(pr_allowed_get)"
  case "$P_ALLOWED" in
    unset) add_blocker permission-unset ;;
    off)   add_blocker not-allowed ;;
  esac

  # ブランチが無くても（detached HEAD）よい。宛先は、あれば追跡先、無ければ origin から決める
  pr_branch
  pr_dest
  # GitHub への照会は、このリポジトリで許可されているときだけ行う
  if [ "$TOOL_GH" = "ok" ] && [ -n "$P_REPO" ] && [ "$P_ALLOWED" = "on" ]; then gh_ok=1; fi
  if [ "$gh_ok" -eq 0 ]; then return 0; fi

  # トークンを1度だけ取り、以降の gh はすべてそれを使う。取れなければ、アカウントを確かめられない
  if gh_token && gh_line 10 api --hostname github.com user -q .login && [ -n "$GH_LINE" ]; then
    P_ACCOUNT="$GH_LINE"
  else
    add_blocker account-unknown
  fi
  if [ -n "$P_ACCOUNT" ] && ! is_re '^[A-Za-z0-9-]+$' "$P_ACCOUNT"; then
    P_ACCOUNT=""
    add_blocker account-unknown
  fi
}
