#!/usr/bin/env bash
# 今のブランチの変更を PR にするための、前提の確認・本文の検査・push と作成。
#
# 使い方:
#   dev-relay pr status [--base <ブランチ>]       前提を key=value で表示（止める理由は pr.blockers）
#   dev-relay pr recent                           題と本文の言語を決める材料（直近の PR の題、無ければコミットの題）
#   dev-relay pr draft-path                       下書きの本文を置くパスを表示
#   dev-relay pr check <本文ファイル> [--no-sections] [--title <題>]
#                                                 本文の形と、手元のパスや秘密の混入を調べる（合格 0、不合格 2）
#   dev-relay pr create --title <題> --body-file <ファイル> [--base <ブランチ>] [--draft] [--no-sections]
#                       (--dry-run | --confirm <確認の値>)
#                                                 --dry-run が確認の値（pr.confirm）を出し、--confirm がその値を受けて push と作成をする
#
# PR 機能は、git 設定 dev-relay.pr が on のリポジトリでだけ動く（dev-relay config pr）。
# 宛先は、git が実際に push する URL から決める（github.com だけ）。force-push、マージ、リモートの作成はしない。
# 終了コード: 0 完了 / 1 引数や前提の誤り / 2 check の不合格 / 10 push か gh の失敗

set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
source "$(dirname "${BASH_SOURCE[0]}")/lib/gh.sh"
source "$(dirname "${BASH_SOURCE[0]}")/lib/pr-common.sh"

usage() { sed -n '2,16p' "$0" | sed 's/^# \{0,1\}//'; }

# 認証の入力待ちで止まらないようにする
export GIT_TERMINAL_PROMPT=0

TMPD="$(mktemp -d)"
BASE_REF=""
# 一時フォルダと、ベースを取り込んだこの実行だけの参照を、終了時に消す
cleanup() {
  rm -rf "$TMPD"
  if [ -n "$BASE_REF" ]; then git update-ref -d "$BASE_REF" >/dev/null 2>&1 || true; fi
}
trap cleanup EXIT

# ---- 前提の収集（status と create が同じものを使う） -------------------------

# --base の値の形を調べる。引数: 値
check_base_arg() {
  [ -n "$1" ] || die "--base にはブランチ名が必要です"
  case "$1" in -*) die "--base の形が不正です（- で始まる値は使えません）: $1" ;; esac
  git check-ref-format "refs/heads/$1" 2>/dev/null || die "--base の形が不正です: $1"
}

# このブランチの開いている PR（同じリポジトリの中のブランチ）を P_EXISTING に入れる（無ければ空）。
# 照会できなければ 1。出力は「<件数> <URL か空>」。件数が上限（100）に達していて URL が空なら、
# 上限より先にあるかもしれないので、照会できなかったものとして扱う。P_REPO と P_BRANCH を使う。
pr_query_existing() {
  local count url
  P_EXISTING=""
  gh_line 20 pr list -R "github.com/${P_REPO}" --head "$P_BRANCH" --state open --limit 100 --json url,isCrossRepository \
    -q '"\(length) \([.[] | select(.isCrossRepository == false)][0].url // "")"' || return 1
  count="${GH_LINE%% *}"
  url="${GH_LINE#* }"
  if [ "$url" = "$GH_LINE" ]; then url=""; fi
  case "$count" in ''|*[!0-9]*) return 1 ;; esac
  if [ -z "$url" ] && [ "$count" -ge 100 ]; then return 1; fi
  P_EXISTING="$url"
}

# status の項目を集める。結果は P_* に入る（$(...) の中で呼ばない）:
#   P_GIT P_ALLOWED P_ACCOUNT P_REMOTE P_REPO P_PUSH_URL P_BRANCH P_HEAD P_BASE P_BASE_SHA P_DIRTY P_AHEAD
#   P_EXISTING P_TEMPLATE P_BLOCKERS（; 区切り）
# 引数: --base の値（無ければ空）
pr_collect() {
  local base_opt="$1" gh_ok=0 fork="" root t in_repo=1
  P_BLOCKERS=""; P_GIT="no"; P_ALLOWED="unset"; P_ACCOUNT=""; P_REMOTE=""; P_REPO=""; P_PUSH_URL=""
  P_BRANCH=""; P_HEAD=""; P_BASE=""; P_BASE_SHA=""; P_DIRTY=""; P_AHEAD=""; P_EXISTING=""; P_TEMPLATE=""

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
  root="$(git rev-parse --show-toplevel)"
  for t in .github/pull_request_template.md .github/PULL_REQUEST_TEMPLATE.md docs/pull_request_template.md pull_request_template.md; do
    if [ -f "$root/$t" ]; then P_TEMPLATE="$t"; break; fi
  done

  pr_dest
  # GitHub への照会と fetch は、このリポジトリで許可されているときだけ行う
  if [ "$TOOL_GH" = "ok" ] && [ -n "$P_REPO" ] && [ "$P_ALLOWED" = "on" ]; then gh_ok=1; fi

  if [ "$gh_ok" -eq 1 ]; then
    # トークンを1度だけ取り、以降の gh はすべてそれを使う。取れなければ、アカウントを確かめられない
    if gh_token && gh_line 10 api --hostname github.com user -q .login && [ -n "$GH_LINE" ]; then
      P_ACCOUNT="$GH_LINE"
    else
      add_blocker account-unknown
    fi
    # 既定のブランチとフォークか。--base があっても、フォークかどうかのために照会する
    if gh_line 20 repo view "github.com/${P_REPO}" --json defaultBranchRef,isFork \
        -q '"\(.defaultBranchRef.name // "") \(.isFork)"' \
        && [ "$GH_LINE" != "${GH_LINE% *}" ] && [ -n "${GH_LINE% *}" ] \
        && { [ "${GH_LINE##* }" = "true" ] || [ "${GH_LINE##* }" = "false" ]; }; then
      P_BASE="${GH_LINE% *}"
      fork="${GH_LINE##* }"
    else
      add_blocker repo-unknown
    fi
    if [ "$fork" = "true" ]; then add_blocker fork; fi
  fi
  if [ -n "$base_opt" ]; then P_BASE="$base_opt"; fi

  if [ -n "$P_BASE" ] && [ -n "$P_BRANCH" ] && [ "$P_BRANCH" = "$P_BASE" ]; then add_blocker on-base; fi

  # ベースとの差は、この実行だけの参照に fetch して数える（追跡参照は、fetch の設定しだいで無いことがある。
  # FETCH_HEAD は、同時に動いた別の fetch に書き換えられうる）
  if [ "$gh_ok" -eq 1 ] && [ -n "$P_BASE" ]; then
    BASE_REF="refs/dev-relay/pr-base-$$"
    if run_with_timeout 30 git fetch -q "$P_REMOTE" "+refs/heads/${P_BASE}:${BASE_REF}" >/dev/null 2>&1 < /dev/null; then
      P_BASE_SHA="$(git rev-parse --verify -q "${BASE_REF}^{commit}" 2>/dev/null || true)"
    fi
    git update-ref -d "$BASE_REF" >/dev/null 2>&1 || true
    BASE_REF=""
    if [ -z "$P_BASE_SHA" ]; then
      add_blocker compare-unknown
    elif [ -n "$P_HEAD" ]; then
      P_AHEAD="$(git rev-list --count "${P_BASE_SHA}..HEAD" 2>/dev/null || true)"
      case "$P_AHEAD" in
        ''|*[!0-9]*) P_AHEAD=""; add_blocker compare-unknown ;;
      esac
    fi
  fi
  if [ -z "$P_HEAD" ] || [ "$P_AHEAD" = "0" ]; then add_blocker no-commits; fi

  if [ "$gh_ok" -eq 1 ] && [ -n "$P_BRANCH" ]; then
    if pr_query_existing; then
      if [ -n "$P_EXISTING" ]; then add_blocker existing-pr; fi
    else
      add_blocker existing-unknown
    fi
  fi
}

pr_status() {
  local base=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --base) [ $# -ge 2 ] || die "--base にはブランチ名が必要です"; base="$2"; shift 2 ;;
      -*) die "unknown option: $1" ;;
      *) die "余分な引数です: $1" ;;
    esac
  done
  if [ -n "$base" ]; then check_base_arg "$base"; fi
  pr_collect "$base"

  echo "tool.gh=${TOOL_GH}"
  echo "git.repo=${P_GIT}"
  if [ "$P_GIT" = "yes" ]; then
    echo "pr.allowed=${P_ALLOWED}"
    if [ -n "$P_ACCOUNT" ]; then echo "pr.account=${P_ACCOUNT}"; fi
    if [ -n "$P_REMOTE" ]; then echo "pr.remote=${P_REMOTE}"; fi
    if [ -n "$P_REPO" ]; then echo "pr.repo=${P_REPO}"; fi
    if [ -n "$P_BRANCH" ]; then echo "pr.branch=${P_BRANCH}"; fi
    if [ -n "$P_HEAD" ]; then echo "pr.head=${P_HEAD}"; fi
    if [ -n "$P_BASE" ]; then echo "pr.base=${P_BASE}"; fi
    if [ -n "$P_BASE_SHA" ]; then echo "pr.base-sha=${P_BASE_SHA}"; fi
    echo "pr.dirty=${P_DIRTY}"
    if [ -n "$P_AHEAD" ]; then echo "pr.ahead=${P_AHEAD}"; fi
    if [ -n "$P_EXISTING" ]; then echo "pr.existing=${P_EXISTING}"; fi
    if [ -n "$P_TEMPLATE" ]; then echo "pr.template=${P_TEMPLATE}"; fi
  fi
  if [ -z "$P_BLOCKERS" ]; then echo "pr.ready=yes"; else echo "pr.ready=no"; fi
  echo "pr.blockers=${P_BLOCKERS}"
}

# ---- recent / draft-path ----------------------------------------------------

pr_recent() {
  local n=0 line
  [ $# -eq 0 ] || die "recent は引数を取りません: $1"
  probe_gh
  if [ "$TOOL_GH" = "ok" ] && in_git_repo && [ "$(pr_allowed_get)" = "on" ]; then
    P_BLOCKERS=""
    pr_branch
    pr_dest
    if [ -n "$P_REPO" ] \
        && gh_capture 20 "$TMPD/titles" pr list -R "github.com/${P_REPO}" --state all --limit 5 --json title -q '.[].title'; then
      head -n 5 "$TMPD/titles" > "$TMPD/titles.5"
      while IFS= read -r line; do
        line="${line%$'\r'}"
        [ -n "$line" ] || continue
        printf 'pr: %s\n' "$line"
        n=$((n + 1))
      done < "$TMPD/titles.5"
    fi
  fi
  if [ "$n" -eq 0 ] && in_git_repo; then
    git log --no-show-signature -5 --format=%s 2>/dev/null | head -n 5 > "$TMPD/commits" || true
    while IFS= read -r line; do
      line="${line%$'\r'}"
      [ -n "$line" ] || continue
      printf 'commit: %s\n' "$line"
    done < "$TMPD/commits"
  fi
  return 0
}

pr_draft_path() {
  local root branch name
  [ $# -eq 0 ] || die "draft-path は引数を取りません: $1"
  in_git_repo || die "git リポジトリの外では下書きのパスを決められません"
  root="$(git rev-parse --show-toplevel)"
  pr_branch
  branch="${P_BRANCH:-detached}"
  name="$(printf '%s' "$branch" | LC_ALL=C sed 's/[^A-Za-z0-9._-]/-/g')"
  ensure_out_dir "$root/.dev-relay"
  echo "$root/.dev-relay/pr-${name}.md"
}

# ---- 本文の検査（check と create が同じものを使う） ---------------------------

# 本文と題を調べる。結果は次の変数に入る（$(...) の中で呼ばない）:
#   CK_REASONS  不合格の理由（; 区切り。合格なら空）
#   CK_LINES    空でない行の数（フェンスの中とフェンスの行を除く）
# 引数: 本文ファイル 題（無ければ空） --no-sections か（yes / no）
pr_check_body() {
  local file="$1" title="$2" nosec="$3" out line key val kind n
  local lines=0 total=0 missing="" order=0 emptysec="" nocmd=0 unclosed=0
  CK_REASONS=""; CK_LINES=0

  out="$(LC_ALL=C awk '
    BEGIN {
      n = split("Why|What changed|Scope|Tradeoffs|Blast Radius|Verification", names, "|")
      for (i = 1; i <= n; i++) key["## " names[i]] = i
    }
    {
      nb = ($0 ~ /[^[:space:]]/)
      if (nb) total++
      # フェンスの行は、節の行に数えない。中の行は、見出しとして数えず、check.lines にも入れない。
      # 閉じたフェンスの中の空でない行だけを、その節の行に数える（閉じていないフェンスの中は数えない）
      if ($0 ~ /^[[:space:]]*```/) {
        if (!infence) {
          infence = 1; fcur = cur; fcnt = 0
        } else {
          infence = 0
          if (fcur > 0) {
            cnt[fcur] += fcnt
            if (fcnt > 0) goodfence[fcur] = 1
          }
        }
        next
      }
      if (infence) {
        if (nb) fcnt++
        next
      }
      if (nb) lines++
      if ($0 ~ /^##([[:space:]]|$)/) {
        line = $0
        sub(/[[:space:]]+$/, "", line)
        cur = 0
        if (line in key) {
          cur = key[line]
          if (!(cur in first)) first[cur] = NR
        }
        next
      }
      if (cur > 0 && nb) cnt[cur]++
    }
    END {
      print "lines=" (lines + 0)
      print "total=" (total + 0)
      miss = ""; emp = ""
      for (i = 1; i <= n; i++) {
        if (!(i in first)) miss = miss (miss == "" ? "" : ",") names[i]
        else if (cnt[i] + 0 == 0) emp = emp (emp == "" ? "" : ",") names[i]
      }
      print "missing=" miss
      ord = 0
      if (miss == "") for (i = 2; i <= n; i++) if (first[i] < first[i - 1]) ord = 1
      print "order=" ord
      print "emptysec=" emp
      nc = 0
      if ((6 in first) && !(goodfence[6])) nc = 1
      print "nocmd=" nc
      print "unclosed=" (infence ? 1 : 0)
    }
  ' "$file")"
  while IFS= read -r line; do
    key="${line%%=*}"; val="${line#*=}"
    case "$key" in
      lines)    lines="$val" ;;
      total)    total="$val" ;;
      missing)  missing="$val" ;;
      order)    order="$val" ;;
      emptysec) emptysec="$val" ;;
      nocmd)    nocmd="$val" ;;
      unclosed) unclosed="$val" ;;
    esac
  done <<EOF
$out
EOF
  CK_LINES="$lines"

  if [ "$total" -eq 0 ]; then
    CK_REASONS="empty"
  elif [ "$nosec" != "yes" ]; then
    if [ -n "$missing" ]; then CK_REASONS="${CK_REASONS:+$CK_REASONS;}missing-section:${missing}"; fi
    if [ "$order" -eq 1 ]; then CK_REASONS="${CK_REASONS:+$CK_REASONS;}order"; fi
    if [ -n "$emptysec" ]; then CK_REASONS="${CK_REASONS:+$CK_REASONS;}empty-section:${emptysec}"; fi
    if [ "$nocmd" -eq 1 ]; then CK_REASONS="${CK_REASONS:+$CK_REASONS;}no-commands"; fi
  fi
  # 閉じていないフェンスは、節の検査ではなく本文の形の検査なので、--no-sections でも調べる
  if [ "$total" -ne 0 ] && [ "$unclosed" -eq 1 ]; then CK_REASONS="${CK_REASONS:+$CK_REASONS;}unclosed-fence"; fi

  for kind in home-path api-key private-key; do
    n="$(leak_grep "$kind" "$file" | head -n 1 | cut -d: -f1 || true)"
    if [ -n "$n" ]; then CK_REASONS="${CK_REASONS:+$CK_REASONS;}leak:${kind}@${n}"; fi
  done
  if [ -n "$title" ]; then
    printf '%s\n' "$title" > "$TMPD/title.txt"
    for kind in home-path api-key private-key; do
      n="$(leak_grep "$kind" "$TMPD/title.txt" | head -n 1 || true)"
      if [ -n "$n" ]; then CK_REASONS="${CK_REASONS:+$CK_REASONS;}leak:${kind}@title"; fi
    done
  fi
  return 0
}

pr_check() {
  local file="" title="" nosec="no"
  while [ $# -gt 0 ]; do
    case "$1" in
      --no-sections) nosec="yes"; shift ;;
      --title) [ $# -ge 2 ] || die "--title には題が必要です"; title="$2"; shift 2 ;;
      -*) die "unknown option: $1" ;;
      *) [ -z "$file" ] || die "余分な引数です: $1"; file="$1"; shift ;;
    esac
  done
  [ -n "$file" ] || die "本文のファイルを指定してください"
  [ -f "$file" ] && [ -r "$file" ] || die "本文のファイルを読めません: $file"
  pr_check_body "$file" "$title" "$nosec"
  if [ -z "$CK_REASONS" ]; then echo "check=pass"; else echo "check=fail"; echo "check.reason=${CK_REASONS}"; fi
  echo "check.lines=${CK_LINES}"
  if [ "$CK_LINES" -gt 60 ]; then echo "check.long=yes"; fi
  if [ -n "$CK_REASONS" ]; then exit 2; fi
}

# ---- create -----------------------------------------------------------------

pr_create() {
  local title="" body="" base="" draft="no" nosec="no" mode="" confirm="" len
  local body_hash commits_hash want draft_flag url
  while [ $# -gt 0 ]; do
    case "$1" in
      --title) [ $# -ge 2 ] || die "--title には題が必要です"; title="$2"; shift 2 ;;
      --body-file) [ $# -ge 2 ] || die "--body-file にはファイルが必要です"; body="$2"; shift 2 ;;
      --base) [ $# -ge 2 ] || die "--base にはブランチ名が必要です"; base="$2"; shift 2 ;;
      --draft) draft="yes"; shift ;;
      --no-sections) nosec="yes"; shift ;;
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
  [ -n "$mode" ] || die "--dry-run か --confirm <確認の値> のどちらかを指定してください"

  # 1. 引数の検査
  case "$title" in
    *$'\n'*|*$'\r'*) die "--title は1行にしてください" ;;
  esac
  printf '%s' "$title" | grep -q '[^[:space:]]' || die "--title は空にできません"
  # 文字数は、ロケールによらず UTF-8 の先頭バイトだけを数える
  len="$(printf '%s' "$title" | LC_ALL=C tr -d '\200-\277' | wc -c | tr -d ' ')"
  [ "$len" -le 100 ] || die "--title は100文字以下にしてください（今は ${len} 文字）"
  [ -n "$body" ] || die "--body-file が必要です"
  [ -f "$body" ] && [ -r "$body" ] || die "--body-file を読めません: $body"
  if [ -n "$base" ]; then check_base_arg "$base"; fi
  have_timeout_tool || die "timeout も gtimeout も perl も見つかりません。push と PR の作成に期限を付けられないので実行しません。"

  # 2. 本文の写し。以降の検査と作成には、この写しを使う
  cp "$body" "$TMPD/body.md"

  # 3. 前提
  pr_collect "$base"
  if [ -n "$P_BLOCKERS" ]; then
    echo "pr.blockers=${P_BLOCKERS}"
    echo "error: PR を作れません。止める理由: ${P_BLOCKERS}（dev-relay pr status で確かめる）" >&2
    exit 1
  fi

  # 4. 題と本文の検査
  pr_check_body "$TMPD/body.md" "$title" "$nosec"
  if [ -n "$CK_REASONS" ]; then
    echo "check.reason=${CK_REASONS}"
    echo "error: 題か本文が検査に通りません: ${CK_REASONS}（dev-relay pr check で確かめる）" >&2
    exit 1
  fi

  # 5. 確認の値
  body_hash="$(git hash-object --no-filters "$TMPD/body.md")"
  # PR に入るコミットの一覧。ベースが進んだだけでは変わらず、ベースに自分のコミットが入れば変わる
  commits_hash="$(git rev-list "${P_BASE_SHA}..HEAD" | git hash-object --stdin)"
  want="$(printf '%s\n' "$P_ACCOUNT" "$P_REPO" "$P_BASE" "$P_BRANCH" "$P_HEAD" "$commits_hash" "$draft" "$nosec" "$title" "$body_hash" \
    | git hash-object --stdin)"

  # 6. --dry-run
  if [ "$mode" = "dry" ]; then
    echo "pr.account=${P_ACCOUNT}"
    echo "pr.repo=${P_REPO}"
    echo "pr.base=${P_BASE}"
    echo "pr.base-sha=${P_BASE_SHA}"
    echo "pr.branch=${P_BRANCH}"
    echo "pr.head=${P_HEAD}"
    echo "pr.ahead=${P_AHEAD}"
    echo "pr.dirty=${P_DIRTY}"
    echo "pr.draft=${draft}"
    printf 'pr.title=%s\n' "$title"
    echo "check.lines=${CK_LINES}"
    if [ "$CK_LINES" -gt 60 ]; then echo "check.long=yes"; fi
    echo "pr.confirm=${want}"
    return 0
  fi

  # 7. --confirm
  if [ "$confirm" != "$want" ]; then
    echo "pr.changed=yes"
    echo "error: 下書きを確かめたあとで、宛先か内容が変わった。--dry-run からやり直す" >&2
    exit 1
  fi

  # 8. 未コミットの変更は PR に入らない
  if [ "$P_DIRTY" -gt 0 ]; then
    echo "warning: 未コミットの変更が ${P_DIRTY} 件ある。PR には入らない" >&2
  fi

  # 9. push。確認したコミットを SHA で指定して送る。force の類は付けない。
  # SHA が空だと、ブランチを消す指定になるので、40文字の SHA でなければ送らない
  case "$P_HEAD" in
    *[!0-9a-f]*) die "pr.head が SHA ではないので push しません: $P_HEAD" ;;
  esac
  [ "${#P_HEAD}" -eq 40 ] || die "pr.head が40文字の SHA ではないので push しません: $P_HEAD"
  # 送り先は、リモート名ではなく、確かめた URL（P_PUSH_URL）。確認のあとで pushurl が変わっても、別の宛先へは送らない
  if ! run_with_timeout 120 git push "$P_PUSH_URL" "${P_HEAD}:refs/heads/${P_BRANCH}" > "$TMPD/push.out" 2>&1 < /dev/null; then
    echo "error: ${P_REMOTE} へのブランチ ${P_BRANCH} の push に失敗した（force-push はしない）:" >&2
    tail -n 5 "$TMPD/push.out" >&2
    exit 10
  fi
  # URL に push すると追跡参照は更新されないので、--set-upstream-to ではなく設定を直接書く
  git config "branch.${P_BRANCH}.remote" "$P_REMOTE" >/dev/null 2>&1 || true
  git config "branch.${P_BRANCH}.merge" "refs/heads/${P_BRANCH}" >/dev/null 2>&1 || true

  # 10. 作る
  if [ "$draft" = "yes" ]; then draft_flag="--draft"; else draft_flag=""; fi
  if gh_capture 60 "$TMPD/create.out" pr create -R "github.com/${P_REPO}" --base "$P_BASE" --head "$P_BRANCH" \
      --title "$title" --body-file "$TMPD/body.md" ${draft_flag:+"$draft_flag"}; then
    # 11. gh の出力のうち https:// で始まる最後の行が URL
    url="$(tr -d '\r' < "$TMPD/create.out" | grep '^https://' | tail -n 1 || true)"
    if [ -n "$url" ]; then
      echo "pr.url=${url}"
      echo "pr.draft=${draft}"
      return 0
    fi
  fi

  # 12. 作られたかどうかが分からない（応答だけが失われることも、あとから作られることもある）。
  # 成功としては終わらない。既存の PR をもう一度照会し、見つかれば URL も添える
  echo "gh pr create の応答が失敗したか、URL を取れなかった:" >&2
  tail -n 5 "$TMPD/create.out.err" >&2 || true
  echo "pr.result=unknown"
  if pr_query_existing && [ -n "$P_EXISTING" ]; then
    echo "pr.existing=${P_EXISTING}"
  fi
  echo "PR が作られたか確かめられない。ブランチは push 済み。リポジトリの PR の一覧を確かめる" >&2
  exit 10
}

SUB="${1:-}"
case "$SUB" in
  status) shift; pr_status "$@" ;;
  recent) shift; pr_recent "$@" ;;
  draft-path) shift; pr_draft_path "$@" ;;
  check) shift; pr_check "$@" ;;
  create) shift; pr_create "$@" ;;
  -h|--help) usage ;;
  "") usage >&2; exit 1 ;;
  *) echo "error: 知らないサブコマンドです: $SUB" >&2; usage >&2; exit 1 ;;
esac
