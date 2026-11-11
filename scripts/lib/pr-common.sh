#!/usr/bin/env bash
# pr.sh と pr-respond.sh が共有する関数。common.sh と gh.sh のあとに source する。単体では実行しない。
# gh_line は、呼ぶ側が作った TMPD（一時フォルダ）を使う。

add_blocker() { P_BLOCKERS="${P_BLOCKERS:+$P_BLOCKERS;}$1"; }

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
