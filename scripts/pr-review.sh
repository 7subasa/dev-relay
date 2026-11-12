#!/usr/bin/env bash
# 届いた PR のレビュー。対応待ちの一覧、PR の取り出し、レビュー（コメント）の投稿、片付け。
#
# 使い方:
#   dev-relay pr inbox                            自分にレビュー依頼が来ている PR と、自分の PR の状態を一覧のファイルにする
#   dev-relay pr review fetch <番号>              PR の情報を取り出し、先頭を別の worktree に取り出す
#   dev-relay pr review post <番号> --plan <ファイル> (--dry-run | --confirm <確認の値>)
#                                                 --dry-run が確認の値（review.confirm）を出し、--confirm がその値を受けて投稿する
#   dev-relay pr review clean <番号>              取り出した worktree と参照を消す
#
# PR 機能は、git 設定 dev-relay.pr が on のリポジトリでだけ動く（dev-relay config pr）。
# 今のブランチと作業ツリーは変えない。GitHub に書くのは pr review post --confirm の1回だけ（event は COMMENT）。
# 承認、変更の要求、マージ、push、スレッドの解決はしない。フォークからの PR は取り出さない。
# 終了コード: 0 完了 / 1 引数や前提や計画の誤り / 10 投稿の失敗（投稿されたか分からないことがある）

set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
source "$(dirname "${BASH_SOURCE[0]}")/lib/gh.sh"
source "$(dirname "${BASH_SOURCE[0]}")/lib/pr-common.sh"

RV_LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")/lib" && pwd)"

usage() { sed -n '2,14p' "$0" | sed 's/^# \{0,1\}//'; }

# 認証の入力待ちで止まらないようにする
export GIT_TERMINAL_PROMPT=0

TMPD="$(mktemp -d)"
LOCK_DIR=""
# 一時フォルダと、この実行が作った排他を、終了時に消す（取り出した参照と worktree は clean まで残す）
cleanup() {
  rm -rf "$TMPD"
  if [ -n "$LOCK_DIR" ]; then rm -rf "$LOCK_DIR"; fi
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

MARKER='<!-- dev-relay:review -->'

# ---- 共通 -------------------------------------------------------------------

# レビューの置き場所（<最上位>/.dev-relay/pr-review）を RV_ROOT に入れ、リンクを検査する（何も作らない）。
# 引数: 作業ツリーの最上位 [書く先（RV_ROOT の下）...]
review_check() {
  local root="$1" t
  shift
  RV_ROOT="$root/$OUT_DIR/pr-review"
  refuse_symlink "$root/$OUT_DIR" "$RV_ROOT"
  for t in "$@"; do refuse_symlink "$RV_ROOT/$t"; done
}

# review_check のあと、置き場所を作る（.dev-relay/.gitignore もできる）。引数は review_check と同じ
review_dir() {
  review_check "$@"
  ensure_out_dir "$RV_ROOT"
}

# 番号の形（^[1-9][0-9]{0,8}$）。引数: 値
valid_number() { is_re '^[1-9][0-9]{0,8}$' "$1"; }

# 制御文字を ? に直して出す（1行にする）。引数: 文字列
printable() { printf '%s' "$1" | LC_ALL=C tr '\000-\037\177' '?'; echo; }

# 値があるときだけ key=値 を出す。引数: key 値
kv() { if [ -n "$2" ]; then echo "$1=$2"; fi; }

# <review.worktree> の worktree を消す（4.7 の手順6）。消したら WT_REMOVED=1。
# 登録があるときだけ git で消す。登録の無いフォルダは消さずに 1 を返す。引数: worktree のパス
wt_remove() {
  local wt="$1" parent real line found=0
  WT_REMOVED=0
  parent="$(dirname "$wt")"
  if [ -d "$parent" ]; then real="$(cd "$parent" && pwd -P)/$(basename "$wt")"; else real="$wt"; fi
  git worktree list --porcelain > "$TMPD/wt.list" 2>/dev/null || : > "$TMPD/wt.list"
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      "worktree ${real}") found=1 ;;
    esac
  done < "$TMPD/wt.list"
  if [ "$found" -eq 1 ]; then
    if [ -d "$real" ]; then
      if ! git -c core.hooksPath=/dev/null worktree remove --force "$real" > "$TMPD/wt.out" 2>&1 < /dev/null; then
        echo "error: worktree を消せませんでした: ${real}" >&2
        tail -n 5 "$TMPD/wt.out" >&2
        return 1
      fi
    else
      git -c core.hooksPath=/dev/null worktree prune > /dev/null 2>&1 < /dev/null || true
    fi
    WT_REMOVED=1
  elif [ -e "$real" ] || [ -L "$real" ]; then
    echo "error: worktree として登録されていないフォルダがあります。中を確かめて、手で消してください: ${real}" >&2
    return 1
  fi
  return 0
}

# 取り出したレビュー用の worktree（.dev-relay/pr-review/<番号>/wt）の中からは実行しない。
# 作業ツリーの最上位がそこになるので、元の場所とは別の場所を見て、参照だけを消したり、worktree の中にもう1つ作ったりする。
# git リポジトリの外では何もしない。4つのサブコマンドが、GitHub にも参照にもフォルダにも触れる前に呼ぶ
refuse_in_review_worktree() {
  local top num
  in_git_repo || return 0
  top="$(git rev-parse --show-toplevel 2>/dev/null)" || return 0
  case "$top" in
    */"$OUT_DIR"/pr-review/*/wt) ;;
    *) return 0 ;;
  esac
  num="${top%/wt}"
  num="${num##*/}"
  is_re '^[0-9]+$' "$num" || return 0
  die "取り出したレビュー用の worktree の中では実行できません。元の作業ツリーで実行してください（元の場所は git worktree list の1行目）: $top"
}

# 取り込んだ参照の名前。引数: 番号。RV_HEAD_REF と RV_BASE_REF に入れる
review_refs() {
  RV_HEAD_REF="refs/dev-relay/review/${1}/head"
  RV_BASE_REF="refs/dev-relay/review/${1}/base"
}

# ---- 一覧（inbox） -------------------------------------------------------------

# jq のプログラムが出した機械の行を読み、IB_* と、$TMPD の ib.req / ib.mine に入れる。
# 形が合わない値、知らない key、1つのはずの key の重複があれば 1。引数: jq の出力のファイル
ib_parse() {
  local f="$1" line rest key a b c d e ex
  IB_REQ_TOTAL=""; IB_MINE_TOTAL=""
  : > "$TMPD/ib.req"; : > "$TMPD/ib.mine"
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      "@@dr "*) ;;
      *) continue ;;
    esac
    rest="${line#@@dr }"
    key=""; a=""; b=""; c=""; d=""; e=""; ex=""
    IFS=' ' read -r key a b c d e ex <<< "$rest" || true
    case "$key" in
      requested-total)
        [ -z "$IB_REQ_TOTAL" ] && is_re '^[0-9]{1,9}$' "$a" && [ -z "$b" ] || return 1
        IB_REQ_TOTAL="$a" ;;
      mine-total)
        [ -z "$IB_MINE_TOTAL" ] && is_re '^[0-9]{1,9}$' "$a" && [ -z "$b" ] || return 1
        IB_MINE_TOTAL="$a" ;;
      requested)
        is_re "$RE_NUM" "$a" && { [ "$b" = same ] || [ "$b" = fork ]; } \
          && { [ "$c" = ready ] || [ "$c" = draft ]; } && [ -z "$d" ] || return 1
        printf '%s %s %s\n' "$a" "$b" "$c" >> "$TMPD/ib.req" ;;
      mine)
        is_re "$RE_NUM" "$a" && { [ "$b" = ready ] || [ "$b" = draft ]; } \
          && { [ "$c" = approved ] || [ "$c" = changes-requested ] || [ "$c" = review-required ] || [ "$c" = none ]; } \
          && { [ "$d" = pass ] || [ "$d" = fail ] || [ "$d" = pending ] || [ "$d" = none ]; } \
          && is_re '^[0-9]+[+]?$' "$e" && [ -z "$ex" ] || return 1
        printf '%s %s %s %s %s\n' "$a" "$b" "$c" "$d" "$e" >> "$TMPD/ib.mine" ;;
      *) return 1 ;;
    esac
  done < "$f"
  [ -n "$IB_REQ_TOTAL" ] && [ -n "$IB_MINE_TOTAL" ] || return 1
  return 0
}

pr_inbox() {
  local root query prog reqq mineq nreq nmine trunc=no n a b c d
  [ $# -eq 0 ] || die "inbox は引数を取りません: $1"
  refuse_in_review_worktree
  pr_base_collect

  if [ -z "$P_BLOCKERS" ]; then
    root="$(git rev-parse --show-toplevel)"
    review_check "$root" inbox.md
    query="$(cat "$RV_LIB/pr-inbox.graphql")"
    prog="$(cat "$RV_LIB/pr-inbox.jq")"
    reqq="repo:${P_REPO} is:pr is:open review-requested:${P_ACCOUNT}"
    mineq="repo:${P_REPO} is:pr is:open author:${P_ACCOUNT}"
    if ! gh_capture 30 "$TMPD/ib.out" api --hostname github.com graphql \
        -f query="$query" -f reqq="$reqq" -f mineq="$mineq" -q "$prog"; then
      add_blocker inbox-unknown
    elif ! ib_parse "$TMPD/ib.out"; then
      add_blocker inbox-unknown
    fi
  fi

  echo "tool.gh=${TOOL_GH}"
  echo "git.repo=${P_GIT}"
  if [ "$P_GIT" = "yes" ]; then
    echo "pr.allowed=${P_ALLOWED}"
    kv pr.account "$P_ACCOUNT"
    kv pr.repo "$P_REPO"
  fi
  if [ -z "$P_BLOCKERS" ]; then
    nreq="$(wc -l < "$TMPD/ib.req" | tr -d ' ')"
    nmine="$(wc -l < "$TMPD/ib.mine" | tr -d ' ')"
    if [ "$IB_REQ_TOTAL" -gt "$nreq" ] || [ "$IB_MINE_TOTAL" -gt "$nmine" ]; then trunc=yes; fi
    review_dir "$root" inbox.md
    LC_ALL=C grep -av '^@@dr ' "$TMPD/ib.out" > "$TMPD/ib.md" || true
    cp "$TMPD/ib.md" "$RV_ROOT/inbox.md"
    echo "inbox.requested=${nreq}"
    echo "inbox.mine=${nmine}"
    echo "inbox.truncated=${trunc}"
    echo "inbox.file=${RV_ROOT}/inbox.md"
    while read -r n a b; do
      [ -n "$n" ] || continue
      echo "requested.${n}=${a} ${b}"
    done < "$TMPD/ib.req"
    while read -r n a b c d; do
      [ -n "$n" ] || continue
      echo "mine.${n}=${a} ${b} ${c} ${d}"
    done < "$TMPD/ib.mine"
  fi
  if [ -z "$P_BLOCKERS" ]; then echo "inbox.ready=yes"; else echo "inbox.ready=no"; fi
  echo "inbox.blockers=${P_BLOCKERS}"
}

# ---- PR の問い合わせ（fetch と post が使う） --------------------------------------

# jq のプログラムが出した機械の行を読み、PV_* に入れる。13行がそろっていなければ 1。
# 形が合わない値、知らない key、重複があれば 1。引数: jq の出力のファイル
rv_parse() {
  local f="$1" line rest key a b
  PV_ID=""; PV_NUMBER=""; PV_URL=""; PV_STATE=""; PV_DRAFT=""; PV_FORK=""; PV_AUTHOR=""
  PV_HEAD=""; PV_BASE=""; PV_FILES=""; PV_REVIEWED=""; PV_PENDING=""; PV_TRUNC=""
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      "@@dr "*) ;;
      *) continue ;;
    esac
    rest="${line#@@dr }"
    key=""; a=""; b=""
    IFS=' ' read -r key a b <<< "$rest" || true
    case "$key" in
      pr-id)
        [ -z "$PV_ID" ] && is_re "$RE_ID" "$a" && [ -z "$b" ] || return 1
        PV_ID="$a" ;;
      pr-number)
        [ -z "$PV_NUMBER" ] && is_re "$RE_NUM" "$a" && [ -z "$b" ] || return 1
        PV_NUMBER="$a" ;;
      pr-url)
        [ -z "$PV_URL" ] && is_re "$RE_URL" "$a" && [ -z "$b" ] || return 1
        PV_URL="$a" ;;
      pr-state)
        [ -z "$PV_STATE" ] && { [ "$a" = open ] || [ "$a" = closed ] || [ "$a" = merged ]; } && [ -z "$b" ] || return 1
        PV_STATE="$a" ;;
      pr-draft)
        [ -z "$PV_DRAFT" ] && { [ "$a" = yes ] || [ "$a" = no ]; } && [ -z "$b" ] || return 1
        PV_DRAFT="$a" ;;
      pr-fork)
        [ -z "$PV_FORK" ] && { [ "$a" = yes ] || [ "$a" = no ]; } && [ -z "$b" ] || return 1
        PV_FORK="$a" ;;
      pr-author)
        [ -z "$PV_AUTHOR" ] && is_re '^[A-Za-z0-9-]+$' "$a" && [ -z "$b" ] || return 1
        PV_AUTHOR="$a" ;;
      pr-head)
        [ -z "$PV_HEAD" ] && is_re "$RE_SHA" "$a" && [ -z "$b" ] || return 1
        PV_HEAD="$a" ;;
      pr-base)
        [ -z "$PV_BASE" ] && [ -n "$a" ] && [ -z "$b" ] || return 1
        PV_BASE="$a" ;;
      pr-files)
        [ -z "$PV_FILES" ] && is_re "$RE_NUM" "$a" && [ -z "$b" ] || return 1
        PV_FILES="$a" ;;
      pr-reviewed)
        [ -z "$PV_REVIEWED" ] && is_re "$RE_NUM" "$a" && [ -z "$b" ] || return 1
        PV_REVIEWED="$a" ;;
      pr-pending)
        [ -z "$PV_PENDING" ] && { [ "$a" = yes ] || [ "$a" = no ]; } && [ -z "$b" ] || return 1
        PV_PENDING="$a" ;;
      pr-reviews-truncated)
        [ -z "$PV_TRUNC" ] && { [ "$a" = yes ] || [ "$a" = no ]; } && [ -z "$b" ] || return 1
        PV_TRUNC="$a" ;;
      *) return 1 ;;
    esac
  done < "$f"
  [ -n "$PV_ID" ] && [ -n "$PV_NUMBER" ] && [ -n "$PV_URL" ] && [ -n "$PV_STATE" ] && [ -n "$PV_DRAFT" ] \
    && [ -n "$PV_FORK" ] && [ -n "$PV_AUTHOR" ] && [ -n "$PV_HEAD" ] && [ -n "$PV_BASE" ] && [ -n "$PV_FILES" ] \
    && [ -n "$PV_REVIEWED" ] && [ -n "$PV_PENDING" ] && [ -n "$PV_TRUNC" ] || return 1
  return 0
}

# 4.3 の問い合わせを出し、PV_* に入れる（出力は $TMPD/rv.out）。
# 照会できない、読めない、提出済みのレビューが多すぎて数え切れない、番号が違うときは 1。引数: 番号
# P_REPO と P_ACCOUNT を使う。$(...) の中で呼ばない
rv_query() {
  local num="$1" query prog owner name
  owner="${P_REPO%%/*}"
  name="${P_REPO#*/}"
  query="$(cat "$RV_LIB/pr-review.graphql")"
  prog="$(cat "$RV_LIB/pr-review.jq")"
  if ! gh_capture 30 "$TMPD/rv.out" api --hostname github.com graphql \
      -f query="$query" -f owner="$owner" -f name="$name" -F number="$num" -f me="$P_ACCOUNT" -q "$prog"; then
    return 1
  fi
  rv_parse "$TMPD/rv.out" || return 1
  [ "$PV_TRUNC" = "no" ] || return 1
  [ "$PV_NUMBER" = "$1" ] || return 1
  return 0
}

# rv_query が成功したあとの、止める理由（取り出しと投稿で同じ）を P_BLOCKERS に足す
rv_state_checks() {
  if [ "$PV_STATE" != "open" ]; then add_blocker pr-closed; fi
  if [ "$PV_FORK" = "yes" ]; then add_blocker fork-pr; fi
  case "$PV_BASE" in
    -*) add_blocker pr-unknown ;;
    *) if ! git check-ref-format "refs/heads/${PV_BASE}" 2>/dev/null; then add_blocker pr-unknown; fi ;;
  esac
}

# ---- fetch ------------------------------------------------------------------

# エージェント向けの指示ファイルか（4.4）。大文字と小文字は区別しない。引数: パス
is_agent_file() {
  local lp base
  lp="$(printf '%s' "$1" | LC_ALL=C tr 'A-Z' 'a-z')"
  case "/${lp}/" in
    */.claude/*|*/.cursor/*|*/.codex/*|*/.agents/*) return 0 ;;
  esac
  base="${lp##*/}"
  case "$base" in
    claude.md|claude.local.md|agents.md|agents.override.md|gemini.md|.cursorrules|.mcp.json) return 0 ;;
  esac
  return 1
}

# PR が変えた指示ファイルを、worktree で分岐元の版に戻す（追加は消す）。
# 数を FT_NEUTRALIZED に、情報のファイルに足す節を $TMPD/neutral.md に入れる。失敗したら 1。
# 引数: worktree merge-base PR の先頭
neutralize() {
  local wt="$1" mb="$2" head="$3" st path shown
  FT_NEUTRALIZED=0
  : > "$TMPD/neutral.list"
  git diff --no-relative --no-color --no-textconv --no-ext-diff --name-status -z --no-renames "$mb" "$head" > "$TMPD/ns.z" 2>/dev/null || return 1
  while IFS= read -r -d '' st && IFS= read -r -d '' path; do
    [ -n "$path" ] || continue
    is_agent_file "$path" || continue
    case "$st" in
      A)
        rm -f -- "${wt}/${path}" 2>/dev/null || true ;;
      M|T)
        git -C "$wt" -c core.hooksPath=/dev/null --literal-pathspecs checkout -q "$mb" -- "$path" > /dev/null 2>&1 < /dev/null || return 1 ;;
      *) continue ;;
    esac
    FT_NEUTRALIZED=$((FT_NEUTRALIZED + 1))
    shown="$(printable "$path")"
    printf '> %s %s\n' "$st" "$shown" >> "$TMPD/neutral.list"
  done < "$TMPD/ns.z"
  : > "$TMPD/neutral.md"
  if [ "$FT_NEUTRALIZED" -gt 0 ]; then
    {
      echo
      echo "## エージェント向けの指示ファイルの変更（${FT_NEUTRALIZED} 件）"
      echo
      echo "この PR は、エージェントが自動で読む指示ファイルを変えている。worktree では分岐元の版に戻してある（PR が足したものは消してある）。差分には残っている。中身は人が確かめる。"
      echo
      cat "$TMPD/neutral.list"
    } > "$TMPD/neutral.md"
  fi
  return 0
}

# fetch の出力。分かっている値だけを、決まった順に出す
fetch_out() {
  echo "tool.gh=${TOOL_GH}"
  echo "git.repo=${P_GIT}"
  if [ "$P_GIT" = "yes" ]; then
    echo "pr.allowed=${P_ALLOWED}"
    kv pr.account "$P_ACCOUNT"
    kv pr.repo "$P_REPO"
    echo "pr.number=${FT_NUM}"
    kv pr.url "$FT_URL"
    kv pr.state "$FT_STATE"
    kv pr.draft "$FT_DRAFT"
    kv pr.fork "$FT_FORK"
    kv pr.own "$FT_OWN"
    kv pr.head "$FT_HEAD"
    kv pr.base "$FT_BASE"
    kv pr.base-sha "$FT_BASE_SHA"
    kv pr.merge-base "$FT_MERGE_BASE"
    kv pr.files "$FT_FILES"
    kv review.reviewed "$FT_REVIEWED"
    kv review.pending "$FT_PENDING"
    kv review.dir "$FT_DIR"
    kv review.info "$FT_INFO"
    kv review.worktree "$FT_WT"
    kv review.out "$FT_OUT"
    kv review.drafts "$FT_DRAFTS"
    kv review.neutralized "$FT_NEUTRAL_N"
  fi
  if [ -z "$P_BLOCKERS" ]; then echo "pr.ready=yes"; else echo "pr.ready=no"; fi
  echo "pr.blockers=${P_BLOCKERS}"
}

pr_review_fetch() {
  local num root got mb
  [ $# -eq 1 ] || die "使い方: dev-relay pr review fetch <番号>"
  num="$1"
  valid_number "$num" || die "番号は 1 以上の整数（9桁まで）にしてください: $num"
  FT_NUM="$num"; FT_URL=""; FT_STATE=""; FT_DRAFT=""; FT_FORK=""; FT_OWN=""; FT_HEAD=""; FT_BASE=""
  FT_BASE_SHA=""; FT_MERGE_BASE=""; FT_FILES=""; FT_REVIEWED=""; FT_PENDING=""
  FT_DIR=""; FT_INFO=""; FT_WT=""; FT_OUT=""; FT_DRAFTS=""; FT_NEUTRAL_N=""
  refuse_in_review_worktree

  # 1. 前提。git のパスの指定は、作業ツリーの最上位からの相対で読ませる
  if in_git_repo; then cd "$(git rev-parse --show-toplevel)"; fi
  pr_base_collect
  if [ -n "$P_BLOCKERS" ]; then fetch_out; return 0; fi

  # 2. PR の問い合わせ。ここまでは fetch もフォルダの作成もしない
  if ! rv_query "$num"; then
    add_blocker pr-unknown
  else
    FT_URL="$PV_URL"; FT_STATE="$PV_STATE"; FT_DRAFT="$PV_DRAFT"; FT_FORK="$PV_FORK"
    rv_state_checks
  fi
  if [ -n "$P_BLOCKERS" ]; then fetch_out; return 0; fi
  FT_BASE="$PV_BASE"; FT_HEAD="$PV_HEAD"; FT_FILES="$PV_FILES"
  FT_REVIEWED="$PV_REVIEWED"; FT_PENDING="$PV_PENDING"

  # 3.
  if [ "$PV_AUTHOR" = "$P_ACCOUNT" ]; then FT_OWN=yes; else FT_OWN=no; fi

  # 4. フォルダ
  root="$(git rev-parse --show-toplevel)"
  review_dir "$root" "$num" "$num/info.md" "$num/wt" "$num/review" "$num/drafts"
  FT_DIR="$RV_ROOT/$num"
  FT_INFO="$FT_DIR/info.md"
  FT_WT="$FT_DIR/wt"
  FT_OUT="$FT_DIR/review"
  FT_DRAFTS="$FT_DIR/drafts"
  mkdir -p "$FT_OUT" "$FT_DRAFTS"

  # 5. 取り込み。この2つの参照は pr review clean まで残す
  review_refs "$num"
  got=""
  if run_with_timeout 60 git fetch -q --no-tags "$P_REMOTE" \
      "+refs/pull/${num}/head:${RV_HEAD_REF}" "+refs/heads/${PV_BASE}:${RV_BASE_REF}" > /dev/null 2>&1 < /dev/null; then
    got="$(git rev-parse --verify -q "${RV_HEAD_REF}^{commit}" 2>/dev/null || true)"
  fi
  mb=""
  if [ -z "$got" ] || [ "$got" != "$PV_HEAD" ]; then
    add_blocker head-unknown
  else
    FT_BASE_SHA="$(git rev-parse --verify -q "${RV_BASE_REF}^{commit}" 2>/dev/null || true)"
    mb="$(git merge-base "$RV_BASE_REF" "$RV_HEAD_REF" 2>/dev/null || true)"
    if [ -z "$FT_BASE_SHA" ] || ! is_re "$RE_SHA" "$mb"; then
      mb=""
      FT_BASE_SHA=""
      add_blocker compare-unknown
    fi
  fi
  if [ -n "$P_BLOCKERS" ]; then
    git update-ref -d "$RV_HEAD_REF" > /dev/null 2>&1 || true
    git update-ref -d "$RV_BASE_REF" > /dev/null 2>&1 || true
    wt_remove "$FT_WT" || exit 1
    fetch_out
    return 0
  fi
  FT_MERGE_BASE="$mb"

  # 6. worktree。前のものがあれば、登録を確かめて消してから作り直す
  wt_remove "$FT_WT" || exit 1
  if ! git -c core.hooksPath=/dev/null worktree add -q --detach "$FT_WT" "$PV_HEAD" > "$TMPD/wt.add" 2>&1 < /dev/null; then
    echo "error: worktree を作れませんでした: ${FT_WT}" >&2
    tail -n 5 "$TMPD/wt.add" >&2
    exit 1
  fi

  # 7. エージェント向けの指示ファイルを分岐元の版に戻す
  if ! neutralize "$FT_WT" "$mb" "$PV_HEAD"; then
    wt_remove "$FT_WT" || true
    die "エージェント向けの指示ファイルを分岐元の版に戻せませんでした（worktree は消しました）"
  fi
  FT_NEUTRAL_N="$FT_NEUTRALIZED"

  # 8. 情報のファイル
  { LC_ALL=C grep -av '^@@dr ' "$TMPD/rv.out" || true; cat "$TMPD/neutral.md"; } > "$FT_INFO"

  # 9.
  fetch_out
}

# ---- post -------------------------------------------------------------------

# 計画のファイルの写し（$TMPD/plan.txt）を読む（4.8）。結果は次の変数に入る（$(...) の中で呼ばない）:
#   PL_HEAD PL_BASE PL_BODY PL_NTHREADS と $TMPD/pl.threads（行: <ファイル名> <TAB> <行> <TAB> <計画の行番号> <TAB> <パス>）
#   PL_FILES（参照するファイル名の一覧。行ごと。重複なし）
# 誤りは R_REASONS に足す（bad-line / duplicate）
plan_parse() {
  local line n=0 act a b c
  PL_HEAD=""; PL_BASE=""; PL_BODY=""; PL_NTHREADS=0; PL_FILES=""
  : > "$TMPD/pl.threads"
  while IFS= read -r line || [ -n "$line" ]; do
    n=$((n + 1))
    line="${line%$'\r'}"
    act=""; a=""; b=""; c=""
    IFS=$' \t' read -r act a b c <<< "$line" || true
    [ -n "$act" ] || continue
    case "$act" in '#'*) continue ;; esac
    case "$act" in
      head)
        if [ -n "$a" ] && [ -z "$b" ] && [ -z "$c" ] && is_re "$RE_SHA" "$a"; then
          if [ -n "$PL_HEAD" ]; then add_reason "duplicate:${n}"; else PL_HEAD="$a"; fi
        else add_reason "bad-line:${n}"; fi ;;
      base)
        if [ -n "$a" ] && [ -z "$b" ] && [ -z "$c" ] && ! printf '%s' "$a" | LC_ALL=C grep -q '[[:cntrl:]]'; then
          if [ -n "$PL_BASE" ]; then add_reason "duplicate:${n}"; else PL_BASE="$a"; fi
        else add_reason "bad-line:${n}"; fi ;;
      body)
        if [ -n "$a" ] && [ -z "$b" ] && [ -z "$c" ] && is_re "$RE_FILE" "$a"; then
          if [ -n "$PL_BODY" ]; then add_reason "duplicate:${n}"; else PL_BODY="$a"; plan_add_file "$a"; fi
        else add_reason "bad-line:${n}"; fi ;;
      thread)
        if [ -n "$a" ] && [ -n "$b" ] && [ -n "$c" ] && is_re "$RE_FILE" "$a" && is_re '^[1-9][0-9]{0,8}$' "$b" \
            && ! printf '%s' "$c" | LC_ALL=C grep -q '[[:cntrl:]]'; then
          if plan_has_thread "$b" "$c"; then
            add_reason "duplicate:${n}"
          else
            printf '%s\t%s\t%s\t%s\n' "$a" "$b" "$n" "$c" >> "$TMPD/pl.threads"
            PL_NTHREADS=$((PL_NTHREADS + 1))
            plan_add_file "$a"
          fi
        else add_reason "bad-line:${n}"; fi ;;
      *) add_reason "bad-line:${n}" ;;
    esac
  done < "$TMPD/plan.txt"
}

# 同じ行・同じパスの thread が、もう計画にあるか（文字列として完全に一致するかで比べる）。引数: 行 パス
plan_has_thread() {
  local tf tl tn tp
  while IFS=$'\t' read -r tf tl tn tp; do
    if [ "$tl" = "$1" ] && [ "$tp" = "$2" ]; then return 0; fi
  done < "$TMPD/pl.threads"
  return 1
}

# 参照するファイル名を、重複なしで PL_FILES に足す
plan_add_file() {
  if ! printf '%s\n' "$PL_FILES" | grep -Fxq -- "$1"; then
    PL_FILES="${PL_FILES:+$PL_FILES
}$1"
  fi
}

# 変えたファイルの一覧（$TMPD/changed.z。NUL 区切り）にパスがあるか。引数: パス
in_changed() {
  local p
  while IFS= read -r -d '' p; do
    if [ "$p" = "$1" ]; then return 0; fi
  done < "$TMPD/changed.z"
  return 1
}

# その行が、PR の差分の新しい側にあるか（4.9 の5。手元での目安）。引数: パス 行 merge-base 先頭
line_in_diff() {
  local path="$1" line="$2" mb="$3" head="$4"
  in_changed "$path" || return 1
  git --literal-pathspecs diff --no-relative --no-color --no-textconv --no-ext-diff --no-renames -U3 "$mb" "$head" -- "$path" 2>/dev/null \
    | awk -v L="$line" '
        /^@@ / {
          for (i = 1; i <= NF; i++) {
            if (substr($i, 1, 1) == "+") {
              s = substr($i, 2); n = split(s, p, ","); c = p[1] + 0; d = (n > 1) ? p[2] + 0 : 1
              if (d > 0 && L + 0 >= c && L + 0 < c + d) ok = 1
              break
            }
          }
        }
        END { exit ok ? 0 : 1 }'
}

# 計画の中身を調べ、誤りを R_REASONS に足す。引数: merge-base
plan_check() {
  local mb="$1" f kind n path line pn size
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

  if [ -z "$PL_HEAD" ]; then add_reason no-head; fi
  if [ -z "$PL_BASE" ]; then add_reason no-base; fi
  if [ -n "$PL_HEAD" ] && [ -n "$PL_BASE" ] && { [ "$PL_HEAD" != "$PV_HEAD" ] || [ "$PL_BASE" != "$PV_BASE" ]; }; then
    add_reason stale-plan
  fi
  if [ -z "$PL_BODY" ]; then add_reason no-body; fi
  if [ "$PL_NTHREADS" -gt 50 ]; then add_reason too-many-threads; fi

  # ファイルの中身。まとめも行のコメントも、投稿する本文
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    [ -f "$TMPD/files/$f" ] || continue
    if ! LC_ALL=C grep -q '[^[:space:]]' "$TMPD/files/$f"; then add_reason "empty-body:${f}"; fi
    if grep -qF '<!-- dev-relay:' "$TMPD/files/$f"; then add_reason "reserved-marker:${f}"; fi
    # 投稿する形の長さ（まとめは印を足したあと）
    if [ "$f" = "$PL_BODY" ]; then
      build_post "$TMPD/files/$f" "$TMPD/post/len.txt" "" "$MARKER"
    else
      strip_trailing_blank "$TMPD/files/$f" > "$TMPD/post/len.txt"
    fi
    size="$(wc -c < "$TMPD/post/len.txt" | tr -d ' ')"
    if [ "$size" -gt 60000 ]; then add_reason "too-long:${f}"; fi
    for kind in home-path api-key private-key; do
      n="$(leak_grep "$kind" "$TMPD/files/$f" | head -n 1 | cut -d: -f1 || true)"
      if [ -n "$n" ]; then add_reason "leak:${kind}@${f}:${n}"; fi
    done
  done <<EOF
$PL_FILES
EOF

  # 行のコメントの場所
  if [ "$PL_NTHREADS" -gt 0 ] && [ "$PL_NTHREADS" -le 50 ]; then
    git diff --no-relative --no-color --no-textconv --no-ext-diff --name-only -z --no-renames "$mb" "$PV_HEAD" > "$TMPD/changed.z" 2>/dev/null || : > "$TMPD/changed.z"
    while IFS="$(printf '\t')" read -r f line pn path; do
      [ -n "$f" ] || continue
      if ! line_in_diff "$path" "$line" "$mb" "$PV_HEAD"; then add_reason "not-in-diff:${pn}"; fi
    done < "$TMPD/pl.threads"
  fi
}

pr_review_post() {
  local num="" plan="" mode="" confirm="" mb i f line pn path q sep want
  local pre_reviewed sent_head
  [ $# -ge 1 ] || die "使い方: dev-relay pr review post <番号> --plan <ファイル> (--dry-run | --confirm <確認の値>)"
  num="$1"
  shift
  valid_number "$num" || die "番号は 1 以上の整数（9桁まで）にしてください: $num"
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
  have_timeout_tool || die "timeout も gtimeout も perl も見つかりません。gh に期限を付けられないので実行しません。"
  in_git_repo || die "git リポジトリの外では実行できません"
  refuse_in_review_worktree

  # 2. 排他（--confirm のとき）。GitHub への照会より前に取る
  if [ "$mode" = "confirm" ]; then lock_acquire dev-relay-review.lock review.result "pr review post"; fi

  # 3. 計画の写し。以降の検査、確認の値、投稿には、この写しと、投稿する形だけを使う
  PLAN_DIR="$(cd "$(dirname "$plan")" && pwd)"
  cp "$plan" "$TMPD/plan.txt"
  cd "$(git rev-parse --show-toplevel)"
  R_REASONS=""
  plan_parse

  # 4. 前提と PR の問い合わせ
  pr_base_collect
  review_refs "$num"
  mb=""
  if [ -z "$P_BLOCKERS" ]; then
    if ! rv_query "$num"; then
      add_blocker pr-unknown
    else
      rv_state_checks
      if [ "$PV_PENDING" = "yes" ]; then add_blocker pending-review; fi
      if ! git rev-parse --verify -q "${RV_HEAD_REF}^{commit}" > /dev/null 2>&1 \
        || ! git rev-parse --verify -q "${RV_BASE_REF}^{commit}" > /dev/null 2>&1; then
        add_blocker not-fetched
      else
        if [ "$(git rev-parse --verify -q "${RV_HEAD_REF}^{commit}" 2>/dev/null || true)" != "$PV_HEAD" ]; then
          add_blocker head-moved
        fi
        mb="$(git merge-base "$RV_BASE_REF" "$RV_HEAD_REF" 2>/dev/null || true)"
        if ! is_re "$RE_SHA" "$mb"; then add_blocker not-fetched; fi
      fi
    fi
  fi
  if [ -n "$P_BLOCKERS" ]; then
    echo "pr.blockers=${P_BLOCKERS}"
    echo "error: レビューを投稿できません。止める理由: ${P_BLOCKERS}（dev-relay pr review fetch ${num} で確かめる）" >&2
    exit 1
  fi

  # 5. 計画
  plan_check "$mb"
  if [ -n "$R_REASONS" ]; then
    echo "review.reason=${R_REASONS}"
    echo "error: 計画に誤りがあります: ${R_REASONS}" >&2
    exit 1
  fi

  # 6. 投稿する形
  build_post "$TMPD/files/$PL_BODY" "$TMPD/post/body.md" "" "$MARKER"
  i=0
  while IFS="$(printf '\t')" read -r f line pn path; do
    [ -n "$f" ] || continue
    i=$((i + 1))
    strip_trailing_blank "$TMPD/files/$f" > "$TMPD/post/t${i}.md"
  done < "$TMPD/pl.threads"

  # 7. 確認の値
  {
    printf '%s\n' "$P_ACCOUNT" "$P_REPO" "$num" "$PV_ID" "$PV_HEAD" "$PV_BASE" COMMENT "$PV_REVIEWED"
    git hash-object --no-filters "$TMPD/post/body.md"
    i=0
    while IFS="$(printf '\t')" read -r f line pn path; do
      [ -n "$f" ] || continue
      i=$((i + 1))
      printf '%s\n' "$path" "$line"
      git hash-object --no-filters "$TMPD/post/t${i}.md"
    done < "$TMPD/pl.threads"
  } > "$TMPD/confirm.in"
  want="$(git hash-object --stdin < "$TMPD/confirm.in")"

  # 8. --dry-run
  if [ "$mode" = "dry" ]; then
    echo "pr.account=${P_ACCOUNT}"
    echo "pr.repo=${P_REPO}"
    echo "pr.number=${num}"
    echo "pr.url=${PV_URL}"
    echo "pr.head=${PV_HEAD}"
    echo "pr.base=${PV_BASE}"
    echo "review.event=COMMENT"
    echo "review.threads=${PL_NTHREADS}"
    echo "review.reviewed=${PV_REVIEWED}"
    echo "review.confirm=${want}"
    return 0
  fi

  # 9. --confirm
  if [ "$confirm" != "$want" ]; then
    echo "review.changed=yes"
    echo "error: 計画を確かめたあとで、宛先か内容が変わった。--dry-run からやり直す" >&2
    exit 1
  fi

  # 4.10 の変更。thread の数に合わせて作る（配列の変数は gh の -f / -F で確実に渡せない）
  q='mutation AddReview($id: ID!, $oid: GitObjectID!, $body: String!'
  i=1
  while [ "$i" -le "$PL_NTHREADS" ]; do
    q="${q}, \$p${i}: String!, \$l${i}: Int!, \$b${i}: String!"
    i=$((i + 1))
  done
  q="${q}) {
  addPullRequestReview(input: {pullRequestId: \$id, commitOID: \$oid, event: COMMENT, body: \$body, threads: ["
  sep=""
  i=1
  while [ "$i" -le "$PL_NTHREADS" ]; do
    q="${q}${sep}{path: \$p${i}, line: \$l${i}, side: RIGHT, body: \$b${i}}"
    sep=", "
    i=$((i + 1))
  done
  q="${q}]}) {
    pullRequestReview { url }
  }
}"

  set -- api --hostname github.com graphql -f query="$q" -f id="$PV_ID" -f oid="$PV_HEAD" -F "body=@${TMPD}/post/body.md"
  i=0
  while IFS="$(printf '\t')" read -r f line pn path; do
    [ -n "$f" ] || continue
    i=$((i + 1))
    set -- "$@" -f "p${i}=${path}" -F "l${i}=${line}" -F "b${i}=@${TMPD}/post/t${i}.md"
  done < "$TMPD/pl.threads"

  pre_reviewed="$PV_REVIEWED"
  sent_head="$PV_HEAD"
  if gh_line 60 "$@" -q .data.addPullRequestReview.pullRequestReview.url && is_re "$RE_URL" "$GH_LINE"; then
    echo "review.url=${GH_LINE}"
    echo "review.result=ok"
    return 0
  fi

  echo "error: レビューの投稿が失敗した（gh の出力）:" >&2
  tail -n 5 "$TMPD/gh.out.err" >&2 || true
  # 投稿されていないかを、もう一度照会して確かめる。先頭が変わっていたら、数からは判断できない
  if rv_query "$num" && [ "$PV_HEAD" = "$sent_head" ] && [ "$PV_REVIEWED" = "$pre_reviewed" ] && [ "$PV_PENDING" = "no" ]; then
    echo "review.result=failed"
    echo "error: 何も投稿されていません。直してから --dry-run からやり直す" >&2
  else
    echo "review.result=unknown"
    echo "error: 投稿されたか分かりません。${PV_URL:-GitHub} で確かめてください（自動ではやり直しません）" >&2
  fi
  exit 10
}

# ---- clean ------------------------------------------------------------------

pr_review_clean() {
  local num root cleaned=no ref
  [ $# -eq 1 ] || die "使い方: dev-relay pr review clean <番号>"
  num="$1"
  valid_number "$num" || die "番号は 1 以上の整数（9桁まで）にしてください: $num"
  in_git_repo || die "git リポジトリの外では実行できません"
  refuse_in_review_worktree
  root="$(git rev-parse --show-toplevel)"
  review_check "$root" "$num" "$num/info.md" "$num/wt" "$num/review" "$num/drafts"
  review_refs "$num"

  # 1. worktree（フォルダが無くても、git に残った登録は片付ける。フォルダは作らない）
  wt_remove "$RV_ROOT/$num/wt" || exit 1
  if [ "$WT_REMOVED" -eq 1 ]; then cleaned=yes; fi
  # 2. 参照
  for ref in "$RV_HEAD_REF" "$RV_BASE_REF"; do
    if git rev-parse --verify -q "$ref" > /dev/null 2>&1; then
      git update-ref -d "$ref" > /dev/null 2>&1 || true
      cleaned=yes
    fi
  done
  echo "review.cleaned=${cleaned}"
}

# ---- 入口 -------------------------------------------------------------------

SUB="${1:-}"
case "$SUB" in
  inbox)
    case "${2:-}" in -h|--help) usage; exit 0 ;; esac
    shift; pr_inbox "$@" ;;
  review)
    case "${2:-}" in
      fetch|post|clean)
        case "${3:-}" in -h|--help) usage; exit 0 ;; esac
        ACT="$2"
        shift 2
        "pr_review_${ACT}" "$@" ;;
      -h|--help) usage ;;
      "") usage >&2; exit 1 ;;
      *) echo "error: 知らないサブコマンドです: review $2" >&2; usage >&2; exit 1 ;;
    esac ;;
  -h|--help) usage ;;
  "") usage >&2; exit 1 ;;
  *) echo "error: 知らないサブコマンドです: $SUB" >&2; usage >&2; exit 1 ;;
esac
