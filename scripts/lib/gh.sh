#!/usr/bin/env bash
# GitHub CLI（gh）まわりの関数。common.sh を読み込んだあとに source する。単体では実行しない。
# gh は github.com だけを対象にする。呼び方は次の形に限る（引数の順も同じ）。
# リポジトリは、ホストを付けた形（github.com/OWNER/REPO）で渡す。GH_HOST があっても宛先が変わらない:
#   gh --version
#   gh auth token --hostname github.com --no-refresh
#   gh auth token --hostname github.com
#   gh api --hostname github.com user -q .login
#   gh repo view github.com/<OWNER/REPO> --json defaultBranchRef,isFork -q '...'
#   gh pr list -R github.com/<OWNER/REPO> --head <ブランチ> --state open --limit 100 --json url,isCrossRepository -q '...'
#   gh pr list -R github.com/<OWNER/REPO> --state all --limit 5 --json title -q '.[].title'
#   gh pr create -R github.com/<OWNER/REPO> --base <ベース> --head <ブランチ> --title <題> --body-file <ファイル> [--draft]
#   gh api --hostname github.com graphql -f query=<pr-feedback.graphql の問い合わせ> -f owner=<OWNER> -f name=<REPO> -f head=<ブランチ> -q <pr-feedback.jq の式>
#   gh api --hostname github.com graphql -f query=<pr-reply.graphql の ReplyThread> -f id=<スレッドの id> -F body=@<ファイル> -q .data.addPullRequestReviewThreadReply.comment.url
#   gh api --hostname github.com graphql -f query=<pr-comment.graphql の AddComment> -f id=<PR の id> -F body=@<ファイル> -q .data.addComment.commentEdge.node.url
#   gh api --hostname github.com graphql -f query=<pr-inbox.graphql の問い合わせ> -f reqq=<検索の式> -f mineq=<検索の式> -q <pr-inbox.jq の式>
#   gh api --hostname github.com graphql -f query=<pr-review.graphql の問い合わせ> -f owner=<OWNER> -f name=<REPO> -F number=<番号> -f me=<アカウント> -q <pr-review.jq の式>
#   gh api --hostname github.com graphql -f query=<AddReview の変更（pr-review.sh が組み立てる）> -f id=<PR の id> -f oid=<先頭の SHA> -F body=@<ファイル> [-f p<i>=<パス> -F l<i>=<行> -F b<i>=@<ファイル>]... -q .data.addPullRequestReview.pullRequestReview.url
#   gh run view <run-id> -R github.com/<OWNER/REPO> --log-failed
#   gh run view <run-id> -R github.com/<OWNER/REPO> --json attempt -q .attempt
#   gh run rerun <run-id> -R github.com/<OWNER/REPO> --failed

# gh の状態を調べ、TOOL_GH に ok / not-installed / not-logged-in を入れる。
# 有無だけを見るので、トークンの更新（通信）はさせない。$(...) の中で呼ばない。
probe_gh() {
  TOOL_GH="not-installed"
  if command -v gh >/dev/null 2>&1; then
    TOOL_GH="not-logged-in"
    if run_with_timeout 10 gh auth token --hostname github.com --no-refresh >/dev/null 2>&1 < /dev/null; then
      TOOL_GH="ok"
    fi
  fi
}

# push 先か fetch 元の URL から OWNER/REPO を出す。github.com だけが対象。
# 取り出せなければ、何も出さず 1 を返す。
# 対応する形: SCP 形式（git ユーザーの github.com:o/r）、https://github.com/o/r、ssh://（git ユーザー）github.com/o/r。
# どれも末尾の .git は付いていてもよい
gh_repo_from_url() {
  local url="$1" path
  case "$url" in
    git[@]github.com:*)     path="${url#git[@]github.com:}" ;;
    https://github.com/*)   path="${url#https://github.com/}" ;;
    ssh://git[@]github.com/*) path="${url#ssh://git[@]github.com/}" ;;
    *) return 1 ;;
  esac
  path="${path%.git}"
  printf '%s\n' "$path" | grep -Eq '^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$' || return 1
  printf '%s\n' "$path"
}

# 有効なアカウントのトークンを1度だけ取り、GH_TOKEN に入れて export する。以降の gh は、すべてこのトークンを使う
# （途中で別のセッションが有効なアカウントを切り替えても、調べたアカウントの名義になる）。
# トークンは一時ファイルを経由するだけで、出力にも記録にも残さない。取れなければ 1。$(...) の中で呼ばない。
gh_token() {
  local tmp tok=""
  tmp="$(mktemp)" || return 1
  if gh_capture 10 "$tmp" auth token --hostname github.com; then
    IFS= read -r tok < "$tmp" || true
  fi
  rm -f "$tmp" "$tmp.err"
  [ -n "$tok" ] || return 1
  GH_TOKEN="$tok"
  export GH_TOKEN
}

# gh を期限付きで実行し、標準出力を出力ファイルに、標準エラーを <出力ファイル>.err に書く。
# gh の終了コードを返す（期限で止めたときは 124）。標準入力は /dev/null。
# 出力は $(...) やパイプで受けない。期限で止めたあとも孫プロセスが出力を握っていると、
# 受ける側が終わるまで待たされる（resolve.sh の tool_version と同じ理由）。
# 引数: 秒 出力ファイル gh の引数...
gh_capture() {
  local sec="$1" out="$2"
  shift 2
  run_with_timeout "$sec" gh "$@" > "$out" 2> "$out.err" < /dev/null
}

# gh の版を1行で出す。PATH に無ければ何も出さず 0。あるのに取れなければ何も出さず 1。
gh_version() {
  local tmp first=""
  command -v gh >/dev/null 2>&1 || return 0
  have_timeout_tool || return 1
  tmp="$(mktemp)" || return 1
  if ! gh_capture 3 "$tmp" --version; then
    rm -f "$tmp" "$tmp.err"
    return 1
  fi
  IFS= read -r first < "$tmp" || true
  rm -f "$tmp" "$tmp.err"
  [ -n "$first" ] || return 1
  printf '%s\n' "$first"
}

# このリポジトリで PR 機能を使ってよいか。on / off / unset を出す（git 設定 dev-relay.pr）。
# 許可は、値がちょうど1つの on のときだけ。それ以外の値や複数の値は off として扱い、警告を出す。
# git リポジトリの外や、値が無いときは unset。
pr_allowed_get() {
  local vals="" n=0
  if in_git_repo; then
    vals="$(git config --local --get-all dev-relay.pr 2>/dev/null || true)"
    # 空の値も1つと数える（$(...) は末尾の改行を落とすので、数えるのは別に行う）
    n="$(git config --local --get-all dev-relay.pr 2>/dev/null | wc -l | tr -d ' ')"
  fi
  if [ "$n" -eq 0 ]; then
    echo unset
  elif [ "$n" -eq 1 ] && [ "$vals" = "on" ]; then
    echo on
  else
    if [ "$vals" != "off" ]; then
      echo "warning: git 設定 dev-relay.pr の値が on か off の1つではないので off として扱います" >&2
    fi
    echo off
  fi
}
