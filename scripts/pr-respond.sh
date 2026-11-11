#!/usr/bin/env bash
# 自分の PR に付いたレビューと CI の読み取り、対応の実行（push・返信・まとめのコメント・CI の再実行）。
#
# 使い方:
#   dev-relay pr feedback                         自分の PR のレビューと CI を一覧のファイルにし、対応の前提を key=value で表示
#   dev-relay pr ci-log <run の id>               CI の失敗したステップのログを保存する
#   dev-relay pr respond --plan <ファイル> (--dry-run | --confirm <確認の値>)
#                                                 --dry-run が確認の値（respond.confirm）を出し、--confirm がその値を受けて実行する
#
# PR 機能は、git 設定 dev-relay.pr が on のリポジトリでだけ動く（dev-relay config pr）。
# 宛先は、git が実際に push する URL から決める（github.com だけ）。force-push、マージ、スレッドの解決はしない。
# 終了コード: 0 完了 / 1 引数や前提の誤り / 10 push か gh の失敗（一部だけ行われたことがある）

set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
source "$(dirname "${BASH_SOURCE[0]}")/lib/gh.sh"
source "$(dirname "${BASH_SOURCE[0]}")/lib/pr-common.sh"

FB_LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")/lib" && pwd)"

usage() { sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'; }

# 認証の入力待ちで止まらないようにする
export GIT_TERMINAL_PROMPT=0

TMPD="$(mktemp -d)"
HEAD_REF=""
BASE_REF=""
LOCK_DIR=""
# 一時フォルダ、PR の先頭とベースを取り込んだこの実行だけの参照、この実行が作った排他を、終了時に消す
cleanup() {
  rm -rf "$TMPD"
  if [ -n "$HEAD_REF" ]; then git update-ref -d "$HEAD_REF" >/dev/null 2>&1 || true; fi
  if [ -n "$BASE_REF" ]; then git update-ref -d "$BASE_REF" >/dev/null 2>&1 || true; fi
  if [ -n "$LOCK_DIR" ]; then rm -rf "$LOCK_DIR"; fi
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

RE_ID='^[A-Za-z0-9_=-]+$'
RE_VER='^[A-Za-z0-9_=@:.,+/-]+$'
RE_NUM='^[0-9]+$'
RE_URL='^https://[^[:space:]]+$'
RE_SHA='^[0-9a-f]{40}$'
RE_B64='^[A-Za-z0-9+/=]+$'
RE_FILE='^[A-Za-z0-9._-]+$'

# 値の形を調べる。引数: 正規表現 値
is_re() { printf '%s\n' "$2" | LC_ALL=C grep -Eq -- "$1"; }

# ---- 収集（feedback / ci-log / respond が同じものを使う） ----------------------

# jq のプログラムが出した機械の行を読み、FB_* と、$TMPD の fb.threads / fb.items / fb.ci に入れる。
# 形が合わない値、知らない key、1つのはずの key の重複があれば 1。引数: jq の出力のファイル
fb_parse() {
  local f="$1" line rest key a b c d ex
  FB_PRS=""; FB_TRUNC=""; FB_PR_ID=""; FB_PR_NUMBER=""; FB_PR_URL=""; FB_PR_AUTHOR=""
  FB_PR_HEAD=""; FB_PR_BASE=""; FB_MERGEABLE=""
  : > "$TMPD/fb.threads"; : > "$TMPD/fb.items"; : > "$TMPD/fb.ci"
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      "@@dr "*) ;;
      *) continue ;;
    esac
    rest="${line#@@dr }"
    key=""; a=""; b=""; c=""; d=""; ex=""
    IFS=' ' read -r key a b c d ex <<< "$rest" || true
    case "$key" in
      prs)
        [ -z "$FB_PRS" ] && is_re "$RE_NUM" "$a" && [ -z "$b" ] || return 1
        FB_PRS="$a" ;;
      truncated)
        [ -z "$FB_TRUNC" ] && { [ "$a" = yes ] || [ "$a" = no ]; } && [ -z "$b" ] || return 1
        FB_TRUNC="$a" ;;
      pr-id)
        [ -z "$FB_PR_ID" ] && is_re "$RE_ID" "$a" && [ -z "$b" ] || return 1
        FB_PR_ID="$a" ;;
      pr-number)
        [ -z "$FB_PR_NUMBER" ] && is_re "$RE_NUM" "$a" && [ -z "$b" ] || return 1
        FB_PR_NUMBER="$a" ;;
      pr-url)
        [ -z "$FB_PR_URL" ] && is_re "$RE_URL" "$a" && [ -z "$b" ] || return 1
        FB_PR_URL="$a" ;;
      pr-author)
        [ -z "$FB_PR_AUTHOR" ] && [ -n "$a" ] && [ -z "$b" ] || return 1
        FB_PR_AUTHOR="$a" ;;
      pr-head)
        [ -z "$FB_PR_HEAD" ] && is_re "$RE_SHA" "$a" && [ -z "$b" ] || return 1
        FB_PR_HEAD="$a" ;;
      pr-base)
        [ -z "$FB_PR_BASE" ] && [ -n "$a" ] && [ -z "$b" ] || return 1
        FB_PR_BASE="$a" ;;
      pr-mergeable)
        [ -z "$FB_MERGEABLE" ] && { [ "$a" = mergeable ] || [ "$a" = conflicting ] || [ "$a" = unknown ]; } && [ -z "$b" ] || return 1
        FB_MERGEABLE="$a" ;;
      thread)
        is_re "$RE_ID" "$a" && { [ "$b" = todo ] || [ "$b" = waiting ]; } && is_re "$RE_VER" "$c" && [ -z "$d" ] || return 1
        printf '%s %s %s\n' "$a" "$b" "$c" >> "$TMPD/fb.threads" ;;
      item)
        { [ "$a" = review ] || [ "$a" = comment ]; } && is_re "$RE_ID" "$b" && is_re "$RE_VER" "$c" \
          && is_re "$RE_B64" "$d" && [ -z "$ex" ] || return 1
        printf '%s %s %s %s\n' "$a" "$b" "$c" "$d" >> "$TMPD/fb.items" ;;
      ci)
        { [ "$a" = pass ] || [ "$a" = pending ] || [ "$a" = fail ]; } && is_re '^([0-9]+|-)$' "$b" && [ -z "$c" ] || return 1
        printf '%s %s\n' "$a" "$b" >> "$TMPD/fb.ci" ;;
      *) return 1 ;;
    esac
  done < "$f"
  [ -n "$FB_PRS" ] && [ -n "$FB_TRUNC" ] || return 1
  if [ "$FB_PRS" = "1" ]; then
    [ -n "$FB_PR_ID" ] && [ -n "$FB_PR_NUMBER" ] && [ -n "$FB_PR_URL" ] && [ -n "$FB_PR_AUTHOR" ] \
      && [ -n "$FB_PR_HEAD" ] && [ -n "$FB_PR_BASE" ] && [ -n "$FB_MERGEABLE" ] || return 1
  fi
  return 0
}

# 同じ問い合わせを GitHub に出し、FB_* に入れる。P_REPO と P_BRANCH と P_ACCOUNT を使う。
# 結果の止める理由は P_BLOCKERS に足す。$(...) の中で呼ばない
fb_query() {
  local owner name query prog
  owner="${P_REPO%%/*}"
  name="${P_REPO#*/}"
  query="$(cat "$FB_LIB/pr-feedback.graphql")"
  # アカウントは ^[A-Za-z0-9-]+$ に合うことを確かめたものだけが来る
  prog="def me: \"${P_ACCOUNT}\";"$'\n'"$(cat "$FB_LIB/pr-feedback.jq")"
  if ! gh_capture 30 "$TMPD/fb.out" api --hostname github.com graphql \
      -f query="$query" -f owner="$owner" -f name="$name" -f head="$P_BRANCH" -q "$prog"; then
    add_blocker feedback-unknown
    return 0
  fi
  if ! fb_parse "$TMPD/fb.out"; then
    add_blocker feedback-unknown
    return 0
  fi
  # 切り詰めがあれば、選ぶ前に止める（11件目以降に対象があるかもしれない）
  if [ "$FB_TRUNC" = "yes" ]; then add_blocker feedback-truncated; fi
  if [ "$FB_PRS" = "0" ]; then
    if [ "$FB_TRUNC" != "yes" ]; then add_blocker no-pr; fi
    return 0
  elif [ "$FB_PRS" != "1" ]; then
    if [ "$FB_TRUNC" != "yes" ]; then add_blocker multiple-prs; fi
    return 0
  fi
  FB_FOUND=1
  if [ "$FB_PR_AUTHOR" != "$P_ACCOUNT" ]; then add_blocker not-own-pr; fi
  P_BASE="$FB_PR_BASE"
  FB_CI_FAIL="$(grep -c '^fail ' "$TMPD/fb.ci" || true)"
  FB_CI_PENDING="$(grep -c '^pending ' "$TMPD/fb.ci" || true)"
  FB_CI_PASS="$(grep -c '^pass ' "$TMPD/fb.ci" || true)"
  FB_THREADS_TODO="$(awk '$2 == "todo"' "$TMPD/fb.threads" | wc -l | tr -d ' ')"
  FB_THREADS_WAITING="$(awk '$2 == "waiting"' "$TMPD/fb.threads" | wc -l | tr -d ' ')"
  FB_COMMENTS_TODO="$(wc -l < "$TMPD/fb.items" | tr -d ' ')"
}

# PR の先頭とベースを、この実行だけの参照に fetch し、手元の HEAD と比べる。
# P_REMOTE_HEAD P_HEAD_STATE P_AHEAD P_BASE_SHA に入れ、止める理由を P_BLOCKERS に足す。
fb_compare() {
  local sha
  HEAD_REF="refs/dev-relay/pr-head-$$"
  if run_with_timeout 30 git fetch -q "$P_REMOTE" "+refs/heads/${P_BRANCH}:${HEAD_REF}" >/dev/null 2>&1 < /dev/null; then
    sha="$(git rev-parse --verify -q "${HEAD_REF}^{commit}" 2>/dev/null || true)"
  else
    sha=""
  fi
  if [ -z "$sha" ] || [ "$sha" != "$FB_PR_HEAD" ] || [ -z "$P_HEAD" ]; then
    add_blocker head-unknown
  else
    P_REMOTE_HEAD="$sha"
    if [ "$P_HEAD" = "$sha" ]; then
      P_HEAD_STATE="same"
    elif git merge-base --is-ancestor "$sha" "$P_HEAD" 2>/dev/null; then
      P_HEAD_STATE="ahead"
      P_AHEAD="$(git rev-list --count "${sha}..${P_HEAD}" 2>/dev/null || true)"
      case "$P_AHEAD" in ''|*[!0-9]*) P_AHEAD="" ;; esac
    elif git merge-base --is-ancestor "$P_HEAD" "$sha" 2>/dev/null; then
      P_HEAD_STATE="behind"
      add_blocker head-behind
    else
      P_HEAD_STATE="diverged"
      add_blocker head-diverged
    fi
  fi
  git update-ref -d "$HEAD_REF" >/dev/null 2>&1 || true
  HEAD_REF=""

  # ベースは、スキルが競合の解消や古いベースの取り込みで使う。取れなくても止めない
  if git check-ref-format "refs/heads/${P_BASE}" 2>/dev/null; then
    BASE_REF="refs/dev-relay/pr-base-$$"
    if run_with_timeout 30 git fetch -q "$P_REMOTE" "+refs/heads/${P_BASE}:${BASE_REF}" >/dev/null 2>&1 < /dev/null; then
      P_BASE_SHA="$(git rev-parse --verify -q "${BASE_REF}^{commit}" 2>/dev/null || true)"
    fi
    git update-ref -d "$BASE_REF" >/dev/null 2>&1 || true
    BASE_REF=""
  fi
}

# 前提と、PR のレビューと CI を集める。結果は次の変数に入る（$(...) の中で呼ばない）:
#   P_GIT P_ALLOWED P_ACCOUNT P_REMOTE P_REPO P_PUSH_URL P_BRANCH P_HEAD P_DIRTY P_STAGED
#   P_BASE P_BASE_SHA P_REMOTE_HEAD P_HEAD_STATE P_AHEAD P_BLOCKERS（; 区切り）
#   FB_FOUND（PR が見つかって、出力を読めたとき 1）
#   FB_PR_ID FB_PR_NUMBER FB_PR_URL FB_PR_AUTHOR FB_PR_HEAD FB_MERGEABLE
#   FB_CI_FAIL FB_CI_PENDING FB_CI_PASS FB_THREADS_TODO FB_THREADS_WAITING FB_COMMENTS_TODO
#   $TMPD/fb.threads（<id> <todo|waiting> <版>）、$TMPD/fb.items（<review|comment> <id> <版> <base64>）、
#   $TMPD/fb.ci（<pass|pending|fail> <run の id か ->）、$TMPD/fb.jq.out（jq の出力）
fb_collect() {
  local gh_ok=0 in_repo=1
  P_BLOCKERS=""; P_GIT="no"; P_ALLOWED="unset"; P_ACCOUNT=""; P_REMOTE=""; P_REPO=""; P_PUSH_URL=""
  P_BRANCH=""; P_HEAD=""; P_DIRTY=""; P_STAGED=""; P_BASE=""; P_BASE_SHA=""; P_REMOTE_HEAD=""
  P_HEAD_STATE=""; P_AHEAD=""
  FB_FOUND=0; FB_PRS=""; FB_PR_ID=""; FB_PR_NUMBER=""; FB_PR_URL=""; FB_PR_AUTHOR=""; FB_PR_HEAD=""
  FB_PR_BASE=""; FB_MERGEABLE=""
  FB_CI_FAIL=0; FB_CI_PENDING=0; FB_CI_PASS=0; FB_THREADS_TODO=0; FB_THREADS_WAITING=0; FB_COMMENTS_TODO=0
  : > "$TMPD/fb.threads"; : > "$TMPD/fb.items"; : > "$TMPD/fb.ci"

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

  pr_branch
  if [ -z "$P_BRANCH" ]; then add_blocker detached-head; fi
  P_HEAD="$(git rev-parse --verify -q "HEAD^{commit}" 2>/dev/null || true)"
  P_DIRTY="$(git status --porcelain | wc -l | tr -d ' ')"
  P_STAGED="$(git diff --cached --no-relative --name-only | wc -l | tr -d ' ')"

  pr_dest
  # GitHub への照会と fetch は、このリポジトリで許可されているときだけ行う
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
  if [ -z "$P_ACCOUNT" ] || [ -z "$P_BRANCH" ]; then return 0; fi

  fb_query
  if [ "$FB_FOUND" -eq 1 ]; then
    grep -v '^@@dr ' "$TMPD/fb.out" > "$TMPD/fb.jq.out" || true
    fb_compare
  fi
}

# ブランチ名を、ファイル名に使える形に直す（pr draft-path と同じ）
fb_branch_name() {
  printf '%s' "${P_BRANCH:-detached}" | LC_ALL=C sed 's/[^A-Za-z0-9._-]/-/g'
}

# ---- feedback ---------------------------------------------------------------

# シンボリックリンクに書くと、リンク先（作業ファイルなど）を上書きしてしまう。引数: パス（複数可）
refuse_symlink() {
  local f
  for f in "$@"; do
    [ ! -L "$f" ] || die "シンボリックリンクには書き込めません: $f"
  done
}

pr_feedback() {
  local root name items drafts
  [ $# -eq 0 ] || die "feedback は引数を取りません: $1"
  fb_collect

  if [ "$FB_FOUND" -eq 1 ]; then
    root="$(git rev-parse --show-toplevel)"
    name="$(fb_branch_name)"
    items="$root/.dev-relay/pr-${name}-feedback.md"
    drafts="$root/.dev-relay/respond-${name}"
    refuse_symlink "$root/.dev-relay" "$items" "$drafts"
    ensure_out_dir "$root/.dev-relay"
    # 機械の行を除いた残りが、一覧のファイル
    cp "$TMPD/fb.jq.out" "$items"
    mkdir -p "$drafts"
  fi

  echo "tool.gh=${TOOL_GH}"
  echo "git.repo=${P_GIT}"
  if [ "$P_GIT" = "yes" ]; then
    echo "pr.allowed=${P_ALLOWED}"
    if [ -n "$P_ACCOUNT" ]; then echo "pr.account=${P_ACCOUNT}"; fi
    if [ -n "$P_REMOTE" ]; then echo "pr.remote=${P_REMOTE}"; fi
    if [ -n "$P_REPO" ]; then echo "pr.repo=${P_REPO}"; fi
    if [ -n "$P_BRANCH" ]; then echo "pr.branch=${P_BRANCH}"; fi
    if [ -n "$P_HEAD" ]; then echo "pr.head=${P_HEAD}"; fi
    echo "pr.dirty=${P_DIRTY}"
    echo "pr.staged=${P_STAGED}"
  fi
  if [ "$FB_FOUND" -eq 1 ]; then
    echo "pr.number=${FB_PR_NUMBER}"
    echo "pr.url=${FB_PR_URL}"
    echo "pr.base=${P_BASE}"
    if [ -n "$P_BASE_SHA" ]; then echo "pr.base-sha=${P_BASE_SHA}"; fi
    if [ -n "$P_REMOTE_HEAD" ]; then echo "pr.remote-head=${P_REMOTE_HEAD}"; fi
    if [ -n "$P_HEAD_STATE" ]; then echo "pr.head-state=${P_HEAD_STATE}"; fi
    if [ "$P_HEAD_STATE" = "ahead" ] && [ -n "$P_AHEAD" ]; then echo "pr.ahead=${P_AHEAD}"; fi
    echo "pr.mergeable=${FB_MERGEABLE}"
    echo "ci.fail=${FB_CI_FAIL}"
    echo "ci.pending=${FB_CI_PENDING}"
    echo "ci.pass=${FB_CI_PASS}"
    echo "fb.threads.todo=${FB_THREADS_TODO}"
    echo "fb.threads.waiting=${FB_THREADS_WAITING}"
    echo "fb.comments.todo=${FB_COMMENTS_TODO}"
    echo "fb.items=${items}"
    echo "fb.drafts=${drafts}"
  fi
  if [ -z "$P_BLOCKERS" ]; then echo "pr.ready=yes"; else echo "pr.ready=no"; fi
  echo "pr.blockers=${P_BLOCKERS}"
}

# ---- ci-log -----------------------------------------------------------------

pr_ci_log() {
  local run="" root name out kept="" b rest lines
  [ $# -eq 1 ] || die "使い方: dev-relay pr ci-log <run の id>"
  run="$1"
  is_re "$RE_NUM" "$run" || die "run の id は数字だけです: $run"
  have_timeout_tool || die "timeout も gtimeout も perl も見つかりません。gh に期限を付けられないので実行しません。"
  fb_collect

  # 読むだけなので、先頭の食い違い、他人の PR、切り詰めでは止めない
  rest="$P_BLOCKERS"
  while [ -n "$rest" ]; do
    b="${rest%%;*}"
    if [ "$b" = "$rest" ]; then rest=""; else rest="${rest#*;}"; fi
    case "$b" in
      head-*|not-own-pr) ;;
      feedback-truncated) if [ "$FB_FOUND" -ne 1 ]; then kept="${kept:+$kept;}$b"; fi ;;
      *) kept="${kept:+$kept;}$b" ;;
    esac
  done
  if [ -n "$kept" ]; then
    echo "pr.blockers=${kept}"
    echo "error: CI のログを取れません。止める理由: ${kept}（dev-relay pr feedback で確かめる）" >&2
    exit 1
  fi
  if [ "$FB_FOUND" -ne 1 ]; then
    echo "error: PR を読めませんでした（dev-relay pr feedback で確かめる）" >&2
    exit 1
  fi
  if ! awk -v r="$run" '$2 == r { f = 1 } END { exit f ? 0 : 1 }' "$TMPD/fb.ci"; then
    echo "error: この PR の CI に無い run です: ${run}" >&2
    exit 1
  fi

  root="$(git rev-parse --show-toplevel)"
  name="$(fb_branch_name)"
  out="$root/.dev-relay/pr-${name}-ci-${run}.log"
  refuse_symlink "$root/.dev-relay" "$out"
  ensure_out_dir "$root/.dev-relay"
  if ! gh_capture 60 "$TMPD/ci.log" run view "$run" -R "github.com/${P_REPO}" --log-failed; then
    echo "error: gh run view が失敗した:" >&2
    tail -n 5 "$TMPD/ci.log.err" >&2 || true
    exit 10
  fi
  cp "$TMPD/ci.log" "$out"
  lines="$(wc -l < "$out" | tr -d ' ')"
  echo "ci.log=${out}"
  echo "ci.log.lines=${lines}"
}

# ---- respond ----------------------------------------------------------------

add_reason() { R_REASONS="${R_REASONS:+$R_REASONS;}$1"; }

# 計画のファイルの写し（$TMPD/plan.txt）を読む。結果は次の変数に入る（$(...) の中で呼ばない）:
#   PL_COMMIT（メッセージのファイル名）PL_COMMIT_REF PL_REPLIES（行: <id> <ファイル名>）
#   PL_COMMENT_FILE PL_COMMENT_IDS（空白区切り）PL_RERUNS（行: <run の id>）
#   PL_ACTIONS（動作の行。空白を1つにそろえたもの）PL_FILES（参照するファイル名の一覧。行ごと。重複なし）
# 誤りは R_REASONS に足す（bad-line / duplicate）。この関数は位置引数を使い回すので、引数を取らない
plan_parse() {
  local line n=0 norm act id ok
  PL_COMMIT=""; PL_COMMIT_REF=""; PL_REPLIES=""; PL_COMMENT_FILE=""; PL_COMMENT_IDS=""; PL_RERUNS=""
  PL_ACTIONS=""; PL_FILES=""
  while IFS= read -r line || [ -n "$line" ]; do
    n=$((n + 1))
    line="${line%$'\r'}"
    set -f
    # shellcheck disable=SC2086
    set -- $line
    set +f
    [ $# -gt 0 ] || continue
    case "$1" in '#'*) continue ;; esac
    norm="$*"
    act="$1"
    ok=1
    case "$act" in
      commit)
        if [ $# -eq 2 ] && is_re "$RE_FILE" "$2"; then
          if [ -n "$PL_COMMIT" ] || [ -n "$PL_COMMIT_REF" ]; then add_reason "duplicate:${n}"; ok=0
          else PL_COMMIT="$2"; plan_add_file "$2"; fi
        else add_reason "bad-line:${n}"; ok=0; fi ;;
      commit-ref)
        if [ $# -eq 2 ] && is_re "$RE_SHA" "$2"; then
          if [ -n "$PL_COMMIT" ] || [ -n "$PL_COMMIT_REF" ]; then add_reason "duplicate:${n}"; ok=0
          else PL_COMMIT_REF="$2"; fi
        else add_reason "bad-line:${n}"; ok=0; fi ;;
      reply)
        if [ $# -eq 3 ] && is_re "$RE_ID" "$2" && is_re "$RE_FILE" "$3"; then
          if printf '%s\n' "$PL_REPLIES" | awk -v t="$2" '$1 == t { f = 1 } END { exit f ? 0 : 1 }'; then
            add_reason "duplicate:${n}"; ok=0
          else
            PL_REPLIES="${PL_REPLIES:+$PL_REPLIES
}$2 $3"
            plan_add_file "$3"
          fi
        else add_reason "bad-line:${n}"; ok=0; fi ;;
      comment)
        if [ $# -ge 3 ] && is_re "$RE_FILE" "$2"; then
          for id in "${@:3}"; do is_re "$RE_ID" "$id" || ok=0; done
          if [ "$ok" -eq 0 ]; then add_reason "bad-line:${n}"
          elif [ -n "$PL_COMMENT_FILE" ]; then add_reason "duplicate:${n}"; ok=0
          else
            PL_COMMENT_FILE="$2"
            shift 2
            PL_COMMENT_IDS="$*"
            plan_add_file "$PL_COMMENT_FILE"
          fi
        else add_reason "bad-line:${n}"; ok=0; fi ;;
      rerun)
        if [ $# -eq 2 ] && is_re "$RE_NUM" "$2"; then
          if printf '%s\n' "$PL_RERUNS" | grep -Fxq -- "$2"; then add_reason "duplicate:${n}"; ok=0
          else PL_RERUNS="${PL_RERUNS:+$PL_RERUNS
}$2"; fi
        else add_reason "bad-line:${n}"; ok=0; fi ;;
      *) add_reason "bad-line:${n}"; ok=0 ;;
    esac
    if [ "$ok" -eq 1 ]; then
      PL_ACTIONS="${PL_ACTIONS:+$PL_ACTIONS
}$norm"
    fi
  done < "$TMPD/plan.txt"
}

# 参照するファイル名を、重複なしで PL_FILES に足す
plan_add_file() {
  if ! printf '%s\n' "$PL_FILES" | grep -Fxq -- "$1"; then
    PL_FILES="${PL_FILES:+$PL_FILES
}$1"
  fi
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

# 版の一覧（空白区切りの id）から、まとめのコメントの印を作る
handled_marker() {
  local id ver list=""
  for id in $PL_COMMENT_IDS; do
    ver="$(awk -v id="$id" '$2 == id { print $3; exit }' "$TMPD/fb.items")"
    [ -n "$ver" ] || ver="$id"
    case " $list " in *" $ver "*) continue ;; esac
    list="${list:+$list }$ver"
  done
  printf '<!-- dev-relay:handled %s -->' "$list"
}

# 計画の中身を調べ、誤りを R_REASONS に足す。ステージの木を INDEX_TREE に入れる。$(...) の中で呼ばない
plan_check() {
  local f n kind id file head_tree has_push=0 zero is_body
  zero="0000000000000000000000000000000000000000"
  INDEX_TREE=""

  # 参照するファイルの写し
  mkdir -p "$TMPD/files" "$TMPD/post"
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    if [ -f "$PLAN_DIR/$f" ] && [ ! -L "$PLAN_DIR/$f" ] && [ -r "$PLAN_DIR/$f" ] && cp "$PLAN_DIR/$f" "$TMPD/files/$f" 2>/dev/null; then
      :
    else
      add_reason "missing-file:${f}"
    fi
  done <<EOF
$PL_FILES
EOF

  # コミット
  if [ -n "$PL_COMMIT" ]; then
    # マージ・cherry-pick・revert の途中だと、コミットが2つ目の親を持つなど、確認した形にならない
    if git rev-parse -q --verify MERGE_HEAD > /dev/null 2>&1 \
      || git rev-parse -q --verify CHERRY_PICK_HEAD > /dev/null 2>&1 \
      || git rev-parse -q --verify REVERT_HEAD > /dev/null 2>&1; then
      add_reason operation-in-progress
    fi
    if INDEX_TREE="$(git write-tree 2>/dev/null)"; then
      head_tree="$(git rev-parse "HEAD^{tree}" 2>/dev/null || true)"
      if [ "$INDEX_TREE" = "$head_tree" ]; then add_reason nothing-staged; fi
    else
      INDEX_TREE=""
      add_reason index-unmerged
    fi
  elif [ "${P_STAGED:-0}" -gt 0 ]; then
    add_reason staged-without-commit
  fi
  if [ -n "$PL_COMMIT_REF" ]; then
    if ! git merge-base --is-ancestor "$PL_COMMIT_REF" HEAD 2>/dev/null; then
      add_reason "commit-ref-not-in-head:${PL_COMMIT_REF}"
    fi
  fi
  if [ -n "$PL_COMMIT" ] || [ "$P_HEAD_STATE" = "ahead" ]; then has_push=1; fi
  PUSH="no"
  if [ "$has_push" -eq 1 ]; then PUSH="yes"; fi

  # reply と comment
  while IFS=' ' read -r id file; do
    [ -n "$id" ] || continue
    if ! awk -v t="$id" '$1 == t && $2 == "todo" { f = 1 } END { exit f ? 0 : 1 }' "$TMPD/fb.threads"; then
      add_reason "not-todo:${id}"
    fi
  done <<EOF
$PL_REPLIES
EOF
  for id in $PL_COMMENT_IDS; do
    if ! awk -v t="$id" '$2 == t { f = 1 } END { exit f ? 0 : 1 }' "$TMPD/fb.items"; then
      add_reason "not-todo:${id}"
    fi
  done
  while IFS= read -r id; do
    [ -n "$id" ] || continue
    if ! awk -v r="$id" '$1 == "fail" && $2 == r { f = 1 } END { exit f ? 0 : 1 }' "$TMPD/fb.ci"; then
      add_reason "not-failed:${id}"
    fi
    if [ "$has_push" -eq 1 ]; then add_reason "rerun-with-push:${id}"; fi
  done <<EOF
$PL_RERUNS
EOF

  # ファイルの中身。投稿する本文（reply と comment）とコミットのメッセージで、調べることが違う
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    [ -f "$TMPD/files/$f" ] || continue
    is_body=0
    if [ "$f" = "$PL_COMMENT_FILE" ] || printf '%s\n' "$PL_REPLIES" | awk -v t="$f" '$2 == t { r = 1 } END { exit r ? 0 : 1 }'; then
      is_body=1
    fi
    if ! LC_ALL=C grep -q '[^[:space:]]' "$TMPD/files/$f"; then add_reason "empty-body:${f}"; fi
    if [ "$is_body" -eq 1 ]; then
      if grep -qF '<!-- dev-relay:' "$TMPD/files/$f"; then add_reason "reserved-marker:${f}"; fi
      if grep -qF '{{commit}}' "$TMPD/files/$f" && [ -z "$PL_COMMIT" ] && [ -z "$PL_COMMIT_REF" ]; then
        add_reason "commit-placeholder:${f}"
      fi
      # 投稿する形の長さ（{{commit}} を40文字に置き換え、印を足したあと）
      if [ "$f" = "$PL_COMMENT_FILE" ]; then
        build_post "$TMPD/files/$f" "$TMPD/post/len.txt" "$zero" "$(handled_marker)"
      else
        build_post "$TMPD/files/$f" "$TMPD/post/len.txt" "$zero" "<!-- dev-relay:reply -->"
      fi
      if [ "$(wc -c < "$TMPD/post/len.txt" | tr -d ' ')" -gt 60000 ]; then add_reason "too-long:${f}"; fi
    fi
    if [ "$f" = "$PL_COMMIT" ] && [ "$(wc -c < "$TMPD/files/$f" | tr -d ' ')" -gt 60000 ]; then
      add_reason "too-long:${f}"
    fi
    for kind in home-path api-key private-key; do
      n="$(leak_grep "$kind" "$TMPD/files/$f" | head -n 1 | cut -d: -f1 || true)"
      if [ -n "$n" ]; then add_reason "leak:${kind}@${f}:${n}"; fi
    done
  done <<EOF
$PL_FILES
EOF

  # 動作が無いことだけが誤りのときに出す（ほかの誤りがあれば、そちらを直すのが先）
  if [ -z "$R_REASONS" ] && [ -z "$PL_COMMIT" ] && [ -z "$PL_REPLIES" ] && [ -z "$PL_COMMENT_FILE" ] && [ -z "$PL_RERUNS" ] && [ "$PUSH" = "no" ]; then
    add_reason nothing-to-do
  fi
}

# 確認の値を作り、WANT に入れる。$(...) の中で呼ばない
plan_hash() {
  local id file ver b64
  {
    printf '%s\n' "$P_ACCOUNT" "$P_REPO" "$FB_PR_NUMBER" "$FB_PR_ID" "$P_BRANCH" "$P_PUSH_URL" "$P_HEAD" "$P_REMOTE_HEAD"
    printf '%s\n' "$PUSH"
    if [ -n "$PL_COMMIT" ]; then
      printf '%s\n' "$INDEX_TREE" "$(git hash-object --no-filters "$TMPD/files/$PL_COMMIT")"
    fi
    if [ -n "$PL_ACTIONS" ]; then printf '%s\n' "$PL_ACTIONS"; fi
    while IFS=' ' read -r id file; do
      [ -n "$id" ] || continue
      printf '%s\n' "$(git hash-object --no-filters "$TMPD/files/$file")"
      printf '%s\n' "$(awk -v t="$id" '$1 == t { print $3; exit }' "$TMPD/fb.threads")"
    done <<EOF
$PL_REPLIES
EOF
    if [ -n "$PL_COMMENT_FILE" ]; then
      printf '%s\n' "$(git hash-object --no-filters "$TMPD/files/$PL_COMMENT_FILE")"
      for id in $PL_COMMENT_IDS; do
        ver="$(awk -v t="$id" '$2 == t { print $3; exit }' "$TMPD/fb.items")"
        b64="$(awk -v t="$id" '$2 == t { print $4; exit }' "$TMPD/fb.items")"
        printf '%s\n' "${ver}:${b64}"
      done
    fi
  } > "$TMPD/confirm.in"
  WANT="$(git hash-object --stdin < "$TMPD/confirm.in")"
}

# 排他を取る。取れなければ respond.result=locked で 1
lock_acquire() {
  local common pidfile pid=""
  common="$(cd "$(git rev-parse --git-common-dir)" && pwd -P)"
  LOCK_DIR=""
  if ! mkdir "$common/dev-relay-respond.lock" 2>/dev/null; then
    pidfile="$common/dev-relay-respond.lock/pid"
    if [ -r "$pidfile" ]; then IFS= read -r pid < "$pidfile" || true; fi
    echo "respond.result=locked"
    echo "error: 別の pr respond が実行中か、前の実行の排他が残っています: ${common}/dev-relay-respond.lock${pid:+（pid ${pid}）}" >&2
    echo "実行中でないことを確かめてから、そのフォルダを消してください（自動では消しません）。" >&2
    exit 1
  fi
  LOCK_DIR="$common/dev-relay-respond.lock"
  printf '%s\n' "$$" > "$LOCK_DIR/pid"
}

# 返信か、まとめのコメントを GraphQL で投稿する。URL を GH_LINE に入れる。
# 引数: 問い合わせのファイル id 本文のファイル 取り出す式
gh_post() {
  local qfile="$1" id="$2" body="$3" expr="$4" query
  query="$(cat "$qfile")"
  gh_line 60 api --hostname github.com graphql -f query="$query" -f id="$id" -F "body=@${body}" -q "$expr" || return 1
  is_re "$RE_URL" "$GH_LINE"
}

pr_respond() {
  local plan="" mode="" confirm="" id file sha head_now msg_copy n i attempt unknown=0 list
  local new_head new_parent new_tree want_msg got_msg dirty_after
  while [ $# -gt 0 ]; do
    case "$1" in
      --plan) [ $# -ge 2 ] || die "--plan には計画のファイルが必要です"; plan="$2"; shift 2 ;;
      --dry-run)
        [ -z "$mode" ] || die "--dry-run と --confirm は、どちらか一方をちょうど1つ指定してください"
        mode="dry"; shift ;;
      --confirm)
        [ -z "$mode" ] || die "--dry-run と --confirm は、どちらか一方をちょうど1つ指定してください"
        [ $# -ge 2 ] || die "--confirm には確認の値が必要です"
        mode="confirm"; confirm="$2"; shift 2 ;;
      *) die "unknown argument: $1" ;;
    esac
  done
  [ -n "$plan" ] || die "--plan が必要です"
  [ -n "$mode" ] || die "--dry-run か --confirm <確認の値> のどちらかを指定してください"
  [ -f "$plan" ] && [ -r "$plan" ] || die "計画のファイルを読めません: $plan"
  have_timeout_tool || die "timeout も gtimeout も perl も見つかりません。push と gh に期限を付けられないので実行しません。"
  in_git_repo || die "git リポジトリの外では実行できません"

  # 2. 排他（--confirm のとき）
  if [ "$mode" = "confirm" ]; then lock_acquire; fi

  # 3. 計画の写し。以降の検査、確認の値、投稿、コミットには、この写しだけを使う
  PLAN_DIR="$(cd "$(dirname "$plan")" && pwd)"
  cp "$plan" "$TMPD/plan.txt"
  R_REASONS=""
  plan_parse

  # 4. 前提
  fb_collect
  if [ -z "$P_BLOCKERS" ] && [ "$FB_FOUND" -ne 1 ]; then add_blocker feedback-unknown; fi
  if [ -n "$P_BLOCKERS" ]; then
    echo "pr.blockers=${P_BLOCKERS}"
    echo "error: 対応できません。止める理由: ${P_BLOCKERS}（dev-relay pr feedback で確かめる）" >&2
    exit 1
  fi

  # 5. 計画
  plan_check
  if [ -n "$R_REASONS" ]; then
    echo "respond.reason=${R_REASONS}"
    echo "error: 計画に誤りがあります: ${R_REASONS}" >&2
    exit 1
  fi

  # 6. 確認の値
  plan_hash

  # 7. --dry-run
  if [ "$mode" = "dry" ]; then
    echo "pr.account=${P_ACCOUNT}"
    echo "pr.repo=${P_REPO}"
    echo "pr.number=${FB_PR_NUMBER}"
    echo "pr.branch=${P_BRANCH}"
    echo "pr.head=${P_HEAD}"
    echo "pr.remote-head=${P_REMOTE_HEAD}"
    echo "respond.push=${PUSH}"
    if [ "$P_HEAD_STATE" = "ahead" ]; then
      git log --no-show-signature --reverse --format='%H %s' "${P_REMOTE_HEAD}..${P_HEAD}" > "$TMPD/ahead.log" 2>/dev/null || : > "$TMPD/ahead.log"
      head -n 20 "$TMPD/ahead.log" > "$TMPD/ahead.20"
      while IFS= read -r list; do
        printf 'respond.commit=%s\n' "$list"
      done < "$TMPD/ahead.20"
      n="$(wc -l < "$TMPD/ahead.log" | tr -d ' ')"
      if [ "$n" -gt 20 ]; then echo "respond.commits-more=$((n - 20))"; fi
    fi
    if [ -n "$PL_COMMIT" ]; then
      echo "respond.new-commit=yes"
      git diff --cached --no-relative --name-only > "$TMPD/staged.list"
      while IFS= read -r list; do
        printf 'respond.staged=%s\n' "$list"
      done < "$TMPD/staged.list"
    else
      echo "respond.new-commit=no"
    fi
    n="$(git status --porcelain | awk 'substr($0, 2, 1) != " " { c++ } END { print c + 0 }')"
    echo "respond.unstaged=${n}"
    n=0
    if [ -n "$PL_REPLIES" ]; then n="$(printf '%s\n' "$PL_REPLIES" | wc -l | tr -d ' ')"; fi
    echo "respond.replies=${n}"
    if [ -n "$PL_COMMENT_FILE" ]; then
      echo "respond.comment=yes"
      n="$(printf '%s\n' $PL_COMMENT_IDS | sort -u | wc -l | tr -d ' ')"
      echo "respond.handled=${n}"
    else
      echo "respond.comment=no"
      echo "respond.handled=0"
    fi
    n=0
    if [ -n "$PL_RERUNS" ]; then n="$(printf '%s\n' "$PL_RERUNS" | wc -l | tr -d ' ')"; fi
    echo "respond.reruns=${n}"
    echo "respond.confirm=${WANT}"
    return 0
  fi

  # 8. --confirm
  if [ "$confirm" != "$WANT" ]; then
    echo "respond.changed=yes"
    echo "error: 計画を確かめたあとで、宛先か内容が変わった。--dry-run からやり直す" >&2
    exit 1
  fi

  head_now="$P_HEAD"
  sha="$PL_COMMIT_REF"

  # 8.1 コミット（commit があるとき）。メッセージの写しで作り、確認した親と木とメッセージのとおりかを確かめる
  if [ -n "$PL_COMMIT" ]; then
    msg_copy="$TMPD/files/$PL_COMMIT"
    if ! git commit -q --cleanup=whitespace -F "$msg_copy" > "$TMPD/commit.out" 2>&1 < /dev/null; then
      echo "respond.result=commit-failed"
      echo "error: コミットに失敗した（push も投稿もしていない）:" >&2
      tail -n 10 "$TMPD/commit.out" >&2
      exit 1
    fi
    new_head="$(git rev-parse --verify -q "HEAD^{commit}" 2>/dev/null || true)"
    new_parent="$(git log --no-show-signature -1 --format=%P HEAD 2>/dev/null || true)"
    new_tree="$(git rev-parse "HEAD^{tree}" 2>/dev/null || true)"
    want_msg="$(git stripspace < "$msg_copy" | git hash-object --stdin)"
    got_msg="$(git log --no-show-signature -1 --format=%B HEAD | git stripspace | git hash-object --stdin)"
    echo "respond.commit-sha=${new_head}"
    if [ "$new_parent" != "$P_HEAD" ] || [ "$new_tree" != "$INDEX_TREE" ] || [ "$want_msg" != "$got_msg" ]; then
      echo "respond.result=commit-changed"
      echo "error: 作られたコミットが、確認した内容（親・木・メッセージ）と違う。フックが変えた可能性がある（push も投稿もしていない）" >&2
      exit 1
    fi
    head_now="$new_head"
    sha="$new_head"
  fi

  # 8.2 未コミットの変更は push に入らない
  dirty_after="$(git status --porcelain | wc -l | tr -d ' ')"
  if [ "$dirty_after" -gt 0 ]; then
    echo "warning: 未コミットの変更が ${dirty_after} 件ある。push には入らない" >&2
  fi

  # 8.3 push。確認したコミットを SHA で指定して送る。force の類は付けない
  if [ "$PUSH" = "yes" ]; then
    is_re "$RE_SHA" "$head_now" || die "push するコミットが40文字の SHA ではないので push しません: $head_now"
    if ! run_with_timeout 120 git push "$P_PUSH_URL" "${head_now}:refs/heads/${P_BRANCH}" > "$TMPD/push.out" 2>&1 < /dev/null; then
      echo "error: ${P_REMOTE} へのブランチ ${P_BRANCH} の push に失敗した（force-push はしない）:" >&2
      tail -n 5 "$TMPD/push.out" >&2
      echo "respond.result=push-failed"
      exit 10
    fi
  fi

  # 8.4 返信。計画の順に投稿する。投稿されたか分からないものは unknown とし、次へ進む
  i=0
  while IFS=' ' read -r id file; do
    [ -n "$id" ] || continue
    i=$((i + 1))
    build_post "$TMPD/files/$file" "$TMPD/post/reply-$i.md" "$sha" "<!-- dev-relay:reply -->"
    if gh_post "$FB_LIB/pr-reply.graphql" "$id" "$TMPD/post/reply-$i.md" .data.addPullRequestReviewThreadReply.comment.url; then
      echo "reply.${id}=${GH_LINE}"
    else
      echo "reply.${id}=unknown"
      unknown=1
    fi
  done <<EOF
$PL_REPLIES
EOF

  # 8.5 まとめのコメント
  if [ -n "$PL_COMMENT_FILE" ]; then
    build_post "$TMPD/files/$PL_COMMENT_FILE" "$TMPD/post/comment.md" "$sha" "$(handled_marker)"
    if gh_post "$FB_LIB/pr-comment.graphql" "$FB_PR_ID" "$TMPD/post/comment.md" .data.addComment.commentEdge.node.url; then
      echo "comment=${GH_LINE}"
    else
      echo "comment=unknown"
      unknown=1
    fi
  fi

  # 8.6 CI の再実行。1つの run につき1回だけ
  while IFS= read -r id; do
    [ -n "$id" ] || continue
    attempt=""
    if gh_line 20 run view "$id" -R "github.com/${P_REPO}" --json attempt -q .attempt && is_re "$RE_NUM" "$GH_LINE"; then
      attempt="$GH_LINE"
    fi
    if [ -z "$attempt" ]; then
      echo "rerun.${id}=skipped:attempt-unknown"
    elif [ "$attempt" -ge 2 ]; then
      echo "rerun.${id}=skipped:already-rerun"
    elif gh_capture 60 "$TMPD/rerun.out" run rerun "$id" -R "github.com/${P_REPO}" --failed; then
      echo "rerun.${id}=ok"
    else
      echo "rerun.${id}=unknown"
      unknown=1
    fi
  done <<EOF
$PL_RERUNS
EOF

  # 8.7
  if [ "$unknown" -eq 1 ]; then
    echo "respond.result=partial"
    exit 10
  fi
  echo "respond.result=ok"
}

SUB="${1:-}"
case "${2:-}" in
  -h|--help) case "$SUB" in feedback|ci-log|respond) usage; exit 0 ;; esac ;;
esac
case "$SUB" in
  feedback) shift; pr_feedback "$@" ;;
  ci-log) shift; pr_ci_log "$@" ;;
  respond) shift; pr_respond "$@" ;;
  -h|--help) usage ;;
  "") usage >&2; exit 1 ;;
  *) echo "error: 知らないサブコマンドです: $SUB" >&2; usage >&2; exit 1 ;;
esac
