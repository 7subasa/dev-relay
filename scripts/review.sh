#!/usr/bin/env bash
# 設計書または実装差分を、選ばれたレビュアー（読み取り専用）にレビューさせ、結果を .dev-relay/ に保存する。
#
# 使い方:
#   dev-relay review design <設計書> [--focus S] [--repo DIR] [--reviewer ID]
#                                    [--model M] [--effort E] [--out FILE] [--dry-run]
#   dev-relay review code [--uncommitted | --base BRANCH | --commit SHA]
#                         [--intent S] [--design FILE] [--focus S] [--repo DIR]
#                         [--extra [--exclude ID]] [--reviewer ID] [--model M] [--effort E]
#                         [--out FILE] [--dry-run]
#
#   code の対象を省略すると --uncommitted（ステージ済み・未ステージ・未追跡をすべて含む）。
#   --intent と --design のどちらかは必須。レビュアーは「目的に反する動作」を探すので、
#   目的が無いと指摘の基準が決まらない。--design には設計書か、bugfix の原因メモを渡す。
#   --repo      レビュー対象のリポジトリ（worktree を含む）。省略時は現在のディレクトリ。
#   --extra     追加のレビュアー（役割 code-review-extra）から選ぶ。
#   --exclude   --extra と一緒にだけ使う。通常のレビューで実際に使った id を渡す。
#   --reviewer  その役割の候補のうち、この id だけを見る。metered や送り先の許可は越えられない。
#   --model, --effort  Codex のときだけ、この実行に限って置き換える。
#   --out       結果ファイル。省略時は .dev-relay/review/<code|design>-<日時>-<id>-<PID>.md。絶対パス推奨。
#               git の作業ツリーの中なら、git に無視される場所でなければならない。
#   --dry-run   レビュアーを決めず、どの CLI も呼ばずに、送る予定の依頼文を標準出力に出して終わる。
#
# 終了コード: 0 完了 / 1 引数や前提の誤り / 3 レビュアーが claude（依頼文を書いて戻る）/
#             4 使える追加のレビュアーが無い / 5 Cursor のレビュー中に作業ツリーが変わった /
#             10 レビュアーの CLI が失敗 / 124 タイムアウト
# 環境変数: DEV_RELAY_TIMEOUT（秒。正の整数。既定 900）

set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
source "$(dirname "${BASH_SOURCE[0]}")/lib/resolve.sh"
source "$(dirname "${BASH_SOURCE[0]}")/lib/backends.sh"

usage() { sed -n '2,27p' "$0" | sed 's/^# \{0,1\}//'; }

KIND="${1:-}"
case "$KIND" in
  code|design) shift ;;
  -h|--help) usage; exit 0 ;;
  *) usage >&2; exit 1 ;;
esac

TARGET=""        # uncommitted | base | commit
TARGET_ARG=""    # ブランチ名 / コミット SHA
INTENT=""
DESIGN=""
FOCUS=""
REPO=""
EXTRA=0
EXCLUDE=""
REVIEWER=""
MODEL=""
EFFORT=""
OUT=""
DRY_RUN=0

set_target() {
  [ -z "$TARGET" ] || die "レビュー対象（--uncommitted / --base / --commit）は1つだけ指定してください"
  TARGET="$1"; TARGET_ARG="${2:-}"
}
code_only() { [ "$KIND" = "code" ] || die "$1 は code でだけ使えます"; }

while [ $# -gt 0 ]; do
  case "$1" in
    --uncommitted) code_only "$1"; set_target uncommitted; shift ;;
    --base)        code_only "$1"; [ $# -ge 2 ] || die "--base にはブランチ名が必要です"; set_target base "$2"; shift 2 ;;
    --commit)      code_only "$1"; [ $# -ge 2 ] || die "--commit にはコミット SHA が必要です"; set_target commit "$2"; shift 2 ;;
    --intent)      code_only "$1"; [ $# -ge 2 ] || die "--intent には目的が必要です"; INTENT="$2"; shift 2 ;;
    --design)      code_only "$1"; [ $# -ge 2 ] || die "--design にはファイルが必要です"; DESIGN="$2"; shift 2 ;;
    --extra)       code_only "$1"; EXTRA=1; shift ;;
    --exclude)     code_only "$1"; [ $# -ge 2 ] || die "--exclude には id が必要です"; EXCLUDE="$2"; shift 2 ;;
    --focus)       [ $# -ge 2 ] || die "--focus には観点が必要です"; FOCUS="$2"; shift 2 ;;
    --repo)        [ $# -ge 2 ] || die "--repo にはディレクトリが必要です"; REPO="$2"; shift 2 ;;
    --reviewer)    [ $# -ge 2 ] || die "--reviewer には id が必要です"; REVIEWER="$2"; shift 2 ;;
    --model)       [ $# -ge 2 ] || die "--model にはモデル名が必要です"; MODEL="$2"; shift 2 ;;
    --effort)      [ $# -ge 2 ] || die "--effort には値が必要です"; EFFORT="$2"; shift 2 ;;
    --out)         [ $# -ge 2 ] || die "--out にはファイルが必要です"; OUT="$2"; shift 2 ;;
    --dry-run)     DRY_RUN=1; shift ;;
    -h|--help)     usage; exit 0 ;;
    -*) die "unknown option: $1" ;;
    *)
      [ "$KIND" = "design" ] || die "unknown argument: $1"
      [ -z "$DESIGN" ] || die "設計ファイルは1つだけ指定してください"
      DESIGN="$1"; shift ;;
  esac
done

# ---- 1. 引数の検査 ----------------------------------------------------------
printf '%s\n' "$TIMEOUT_SEC" | grep -Eq '^[1-9][0-9]*$' \
  || die "DEV_RELAY_TIMEOUT は正の整数（秒）で指定してください: $TIMEOUT_SEC"
[ -z "$EXCLUDE" ] || [ "$EXTRA" -eq 1 ] || die "--exclude は --extra と一緒にだけ使えます"
if [ "$KIND" = "code" ]; then
  [ -n "$TARGET" ] || TARGET="uncommitted"
  [ -n "$INTENT" ] || [ -n "$DESIGN" ] || die "変更の目的が必要です。--intent \"目的\" か --design <設計書> を指定してください。"
else
  [ -n "$DESIGN" ] || { usage >&2; exit 1; }
fi

# ---- 2. 設計書のパス、リポジトリへの移動 ------------------------------------
# 設計書のパスは cd する前の場所を基準に解決する
if [ -n "$DESIGN" ]; then
  [ -f "$DESIGN" ] || die "設計ファイルが見つかりません: $DESIGN"
  DESIGN="$(abs_path "$DESIGN")"
fi
if [ -n "$REPO" ]; then
  [ -d "$REPO" ] || die "--repo のディレクトリが見つかりません: $REPO"
  cd "$REPO"
fi
if [ "$KIND" = "code" ]; then
  in_git_repo || die "git リポジトリ内で実行してください（差分を対象にします）"
fi
cd "$(repo_root)"

# ---- 3. 依頼文の組み立て ----------------------------------------------------
PROMPT_FILE="$(mktemp)"
RESULT_FILE="$(mktemp)"
TRAILER_FILE="$(mktemp)"
STAGE_FILE="$(mktemp)"
MANIFEST_BEFORE="$(mktemp)"
MANIFEST_AFTER="$(mktemp)"
trap 'st=$?; rm -f "$PROMPT_FILE" "$RESULT_FILE" "$TRAILER_FILE" "$STAGE_FILE" "$MANIFEST_BEFORE" "$MANIFEST_AFTER"; exit $st' EXIT

FOCUS_TEXT="特になし（全般的に見てください）"
[ -z "$FOCUS" ] || FOCUS_TEXT="$FOCUS"
CHANGED_FILES=""

if [ "$KIND" = "code" ]; then
  case "$TARGET" in
    uncommitted)
      TARGET_DESC="uncommitted changes"
      [ -n "$(git status --porcelain)" ] || die "未コミットの変更がありません。--base <branch> か --commit <sha> を指定してください。"
      # 空白や日本語を含む名前が引用符付きにならないよう、-z で列挙して改行区切りに直す
      if git rev-parse --verify --quiet HEAD >/dev/null; then
        CHANGED_FILES="$({ git diff HEAD --name-only -z; git ls-files -z --others --exclude-standard; } | tr '\0' '\n')"
      else
        CHANGED_FILES="$({ git diff --cached --name-only -z; git ls-files -z --others --exclude-standard; } | tr '\0' '\n')"
      fi
      ;;
    base)
      TARGET_DESC="diff against $TARGET_ARG"
      git rev-parse --verify --quiet "$TARGET_ARG" >/dev/null || die "ブランチが見つかりません: ${TARGET_ARG}（git fetch が必要かもしれません）"
      CHANGED_FILES="$(git diff --name-only -z "$TARGET_ARG...HEAD" | tr '\0' '\n')"
      [ -n "$CHANGED_FILES" ] || die "$TARGET_ARG との差分がありません。"
      ;;
    commit)
      TARGET_DESC="commit $TARGET_ARG"
      git rev-parse --verify --quiet "$TARGET_ARG^{commit}" >/dev/null || die "コミットが見つかりません: $TARGET_ARG"
      CHANGED_FILES="$(git show --name-only -z --format= "$TARGET_ARG" | tr '\0' '\n')"
      ;;
  esac

  TEMPLATE="$DEV_RELAY_ROOT/skills/dev/references/code-review-prompt.md"
  [ -f "$TEMPLATE" ] || die "テンプレートが見つかりません: $TEMPLATE"
  INTENT_TEXT="$INTENT"
  [ -n "$INTENT_TEXT" ] || INTENT_TEXT="末尾の「設計ドキュメント」に書かれた目的に従ってください。"

  # 差分をホスト側で集め、指示文・設計書と一緒に標準入力で渡す。
  # レビュアーはリポジトリを読み取り専用で参照できるので、差分の外側の文脈も自分で確認できる。
  render_template "$TEMPLATE" '{{FOCUS}}' "$FOCUS_TEXT" > "$STAGE_FILE"
  {
    render_template "$STAGE_FILE" '{{INTENT}}' "$INTENT_TEXT"
    if [ -n "$DESIGN" ]; then
      echo
      echo "## 設計ドキュメント"
      echo "以下は事前に確定した設計書（不具合修正の場合は原因メモ）です。実装がここから逸脱している箇所、書かれているのに実装されていない箇所、書かれていない振る舞いを追加している箇所も、目的に反する動作として指摘してください。"
      echo
      echo '````markdown'
      cat "$DESIGN"
      echo '````'
    fi
    echo
    echo "## レビュー対象の差分（${TARGET_DESC}）"
    echo
    echo '````diff'
    case "$TARGET" in
      uncommitted)
        # コミットが1つも無いリポジトリでは HEAD が無いので、ステージ済みの内容を出す
        if git rev-parse --verify --quiet HEAD >/dev/null; then
          git diff HEAD
        else
          git diff --cached
        fi
        # 未追跡ファイルは git diff に現れないので、空ファイルとの比較で全文を差分にする
        git ls-files -z --others --exclude-standard | while IFS= read -r -d '' f; do
          [ -f "$f" ] && git diff --no-index -- /dev/null "$f" || true
        done
        ;;
      base)   git diff "$TARGET_ARG...HEAD" ;;
      commit) git show --format='commit %H%n%s%n' "$TARGET_ARG" ;;
    esac
    echo '````'
  } > "$PROMPT_FILE"
else
  TARGET_DESC="$DESIGN"
  TEMPLATE="$DEV_RELAY_ROOT/skills/dev/references/design-review-prompt.md"
  [ -f "$TEMPLATE" ] || die "テンプレートが見つかりません: $TEMPLATE"

  # {{DESIGN_DOC}} の行を境に前後へ分け、間に設計書本文を挟む。
  # 設計書本文は置換にかけず、そのまま連結する（本文中の記号で壊れないようにするため）。
  RENDERED="$(render_template "$TEMPLATE" '{{FOCUS}}' "$FOCUS_TEXT")"
  {
    printf '%s\n' "$RENDERED" | awk '/\{\{DESIGN_DOC\}\}/ { exit } { print }'
    echo
    echo '````markdown'
    cat "$DESIGN"
    echo '````'
    echo
    printf '%s\n' "$RENDERED" | awk 'found { print } /\{\{DESIGN_DOC\}\}/ { found=1 }'
  } > "$PROMPT_FILE"
fi

# ---- 4. --dry-run -----------------------------------------------------------
if [ "$DRY_RUN" -eq 1 ]; then
  cat "$PROMPT_FILE"
  exit 0
fi

# ---- 5. レビュアーを決める --------------------------------------------------
if [ "$KIND" = "design" ]; then
  ROLE="design-review"
elif [ "$EXTRA" -eq 1 ]; then
  ROLE="code-review-extra"
else
  ROLE="code-review"
fi

probe_tools
load_vendors

if [ "$EXTRA" -eq 1 ] && [ -z "$EXCLUDE" ]; then
  # 通常のレビューで実際に使う id を除外し、同じレビュアーを2回動かさない
  if resolve_role code-review; then EXCLUDE="$R_ID"; fi
fi
if resolve_role "$ROLE" "$REVIEWER" "$EXCLUDE"; then :; else
  echo "使えるレビュアーがありません（役割 ${ROLE}）。飛ばした候補: ${R_SKIPPED:-なし}" >&2
  if [ -n "$REVIEWER" ]; then
    exit 1
  elif [ "$EXTRA" -eq 1 ]; then
    echo "追加のレビュアーなしで進めてください。理由は dev-relay doctor で確かめられます。" >&2
    exit 4
  fi
  die "役割 ${ROLE} のレビュアーを決められませんでした"
fi

# ---- 6. --model と --effort -------------------------------------------------
if [ -n "$MODEL" ] || [ -n "$EFFORT" ]; then
  [ "$R_BACKEND" = "codex" ] \
    || die "--model と --effort は backend が codex のレビュアーでだけ使えます（選ばれたレビュアー: ${R_ID}、backend: ${R_BACKEND}）。別のモデルを使うときは config/roles/ に候補を足して --reviewer で選んでください。"
  [ -z "$MODEL" ] || R_MODEL="$MODEL"
  [ -z "$EFFORT" ] || R_EFFORT="$EFFORT"
fi

# ---- 7. 結果ファイルのパス --------------------------------------------------
if [ -z "$OUT" ]; then
  # 既定の置き場所の各段がリンクなら、リンク先に書いてしまうので止める
  refuse_symlink "$OUT_DIR" "$OUT_DIR/review"
  OUT="$OUT_DIR/review/${KIND}-$(timestamp)-${R_ID}-$$.md"
fi
case "$OUT" in /*) ;; *) OUT="$(pwd)/$OUT" ;; esac
PROMPT_OUT="${OUT%.md}.prompt.md"
[ ! -d "$OUT" ] || die "--out にディレクトリは指定できません。ファイルのパスを渡してください: $OUT"

# 作業ツリーの中に置くファイルは、git に無視される場所でなければならない。
# 同時に動く Cursor のレビューの検査に、別のレビューの結果ファイルが混ざらないようにするため。
require_ignored_or_outside() {
  local f="$1" dir top canon
  # シンボリックリンクに書くと、リンク先（作業ファイルなど）を上書きしてしまう
  [ ! -L "$f" ] || die "シンボリックリンクには書き込めません: $f"
  in_git_repo || return 0
  dir="$(cd "$(dirname "$f")" && pwd -P)"
  canon="$dir/$(basename "$f")"
  top="$(git rev-parse --show-toplevel)"
  case "$canon" in
    "$top"/*) ;;
    *) return 0 ;;
  esac
  git check-ignore -q -- "$canon" \
    || die "ファイルは git に無視される場所か、作業ツリーの外に置いてください（.dev-relay/ が確実です）: $f"
}
# 置き場所の検査に落ちたとき、この実行が作ったフォルダだけを消す（前からあったフォルダは残す）
NEW_TOP=""
d="$(dirname "$OUT")"
while [ ! -e "$d" ]; do NEW_TOP="$d"; d="$(dirname "$d")"; done
ensure_out_dir "$(dirname "$OUT")"
(
  require_ignored_or_outside "$OUT"
  if [ "$R_BACKEND" = "claude" ]; then
    require_ignored_or_outside "$PROMPT_OUT"
  fi
) || {
  if [ -n "$NEW_TOP" ]; then rm -rf -- "$NEW_TOP"; fi
  exit 1
}

# ---- 8. claude: 依頼文を書いて戻る ------------------------------------------
if [ "$R_BACKEND" = "claude" ]; then
  cp "$PROMPT_FILE" "$PROMPT_OUT"
  echo "このレビュアー（${R_ID}）は Agent ツールで起動する。subagent_type は dev-relay:reviewer。" >&2
  echo "依頼文: $PROMPT_OUT" >&2
  echo "結果を書く先: $OUT" >&2
  echo "$PROMPT_OUT"
  exit 3
fi

have_timeout_tool || die "timeout も gtimeout も perl も見つかりません。レビューに期限を付けられないので実行しません。"

# ---- 9. 機密情報らしいファイル名の警告 --------------------------------------
if [ "$KIND" = "code" ]; then
  warn_sensitive_files "$CHANGED_FILES" "$R_VENDORS"
fi

# ---- 10. 実行 ---------------------------------------------------------------
write_header "$OUT" "$KIND" "$TARGET_DESC"
echo "レビュアー ${R_ID}（backend: ${R_BACKEND}, model: ${R_MODEL:--}, effort: ${R_EFFORT:--}）に${KIND}レビューを依頼しています（対象: ${TARGET_DESC}）..." >&2

STATUS=0
CHANGED=0
if [ "$R_BACKEND" = "cursor" ]; then
  worktree_manifest > "$MANIFEST_BEFORE"
  run_cursor "$PROMPT_FILE" "$RESULT_FILE" "$TRAILER_FILE" || STATUS=$?
  worktree_manifest > "$MANIFEST_AFTER"
  cmp -s "$MANIFEST_BEFORE" "$MANIFEST_AFTER" || CHANGED=1
else
  run_codex "$PROMPT_FILE" "$RESULT_FILE" || STATUS=$?
fi
explain_exit "$STATUS" "$R_ID"

finish_result "$RESULT_FILE" "$OUT"
if [ "$STATUS" -ne 0 ]; then
  { echo; echo "- CLI の終了状態: ${STATUS}"; } >> "$OUT"
fi
if [ "$CHANGED" -eq 1 ]; then
  {
    echo
    echo "## 作業ツリーの変化を検出"
    echo
    echo "レビューの前後で作業ツリーが変わった。レビュアーが書き込んだか、同時に動いていた別の作業（テストの実行など）が作ったかを確かめること。スクリプトは元に戻さない。"
    echo
    echo '```'
    diff "$MANIFEST_BEFORE" "$MANIFEST_AFTER" | grep -E '^[<>]' || true
    echo '```'
  } >> "$OUT"
  echo "error: レビューの前後で作業ツリーが変わりました。結果ファイルの一覧を確かめてください。" >&2
fi
if [ -s "$TRAILER_FILE" ]; then
  cat "$TRAILER_FILE" >> "$OUT"
fi

echo >&2
echo "結果を保存しました: $OUT" >&2
echo "$OUT"

# ---- 11. 終了コード ---------------------------------------------------------
if [ "$CHANGED" -eq 1 ]; then exit 5; fi
if [ "$STATUS" -eq 124 ]; then exit 124; fi
if [ "$STATUS" -ne 0 ]; then exit 10; fi
exit 0
