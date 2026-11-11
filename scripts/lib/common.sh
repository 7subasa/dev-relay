#!/usr/bin/env bash
# review.sh / doctor.sh / config.sh が共有する関数群。単体では実行しない。

if [ -z "${DEV_RELAY_ROOT:-}" ]; then
  DEV_RELAY_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
fi
OUT_DIR=".dev-relay"
TIMEOUT_SEC="${DEV_RELAY_TIMEOUT:-900}"

die() { echo "error: $*" >&2; exit 1; }

repo_root() {
  git rev-parse --show-toplevel 2>/dev/null || pwd
}

in_git_repo() {
  git rev-parse --is-inside-work-tree >/dev/null 2>&1
}

# 既存ファイルの絶対パスを返す（cd する前の作業ディレクトリ基準で解決するために使う）
abs_path() {
  printf '%s/%s\n' "$(cd "$(dirname "$1")" && pwd)" "$(basename "$1")"
}

# シンボリックリンクに書くと、リンク先（作業ファイルなど）を上書きしてしまう。引数: パス（複数可）
refuse_symlink() {
  local f
  for f in "$@"; do
    [ ! -L "$f" ] || die "シンボリックリンクには書き込めません: $f"
  done
}

# 結果ファイルを置くフォルダを作る。
# そのフォルダから上へたどって、名前が .dev-relay の最初のフォルダに .gitignore が無ければ、
# 結果を誤ってコミットしないよう中身が * の .gitignore を作る（.gitignore 自身も無視され、git status に現れない）
ensure_out_dir() {
  local dir="$1" d
  mkdir -p "$dir"
  d="$(cd "$dir" && pwd)"
  while [ "$d" != "/" ]; do
    if [ "$(basename "$d")" = ".dev-relay" ]; then
      if [ ! -f "$d/.gitignore" ]; then printf '*\n' > "$d/.gitignore"; fi
      return 0
    fi
    d="$(dirname "$d")"
  done
}

# PR のフォルダ（<root>/.dev-relay/pr/<ブランチ名を直した名前>）を検査して作り、パスを PR_DIR に入れる。
# 呼ぶ前に P_BRANCH を設定しておく（取れなければ detached）。
# 引数: 作業ツリーの最上位 [PR のフォルダの下の書く先...]
# .dev-relay、pr、PR のフォルダ、書く先のどれかがシンボリックリンクなら、何も作らずに止める。
ensure_pr_dir() {
  local root="$1" name t
  shift
  name="$(printf '%s' "${P_BRANCH:-detached}" | LC_ALL=C sed 's/[^A-Za-z0-9._-]/-/g')"
  PR_DIR="$root/$OUT_DIR/pr/$name"
  refuse_symlink "$root/$OUT_DIR" "$root/$OUT_DIR/pr" "$PR_DIR"
  for t in "$@"; do refuse_symlink "$PR_DIR/$t"; done
  ensure_out_dir "$PR_DIR"
}

timestamp() { date +%Y%m%d-%H%M%S; }

# テンプレート中のプレースホルダーを安全に置換して標準出力に出す。
# awk の gsub は置換文字列の & や \ を特別扱いし、-v はバックスラッシュをエスケープとして
# 解釈するため、値は環境変数で渡し、index/substr で素朴に置き換える。
# 引数: template_file placeholder replacement
render_template() {
  local template="$1"
  RT_PAT="$2" RT_REP="$3" awk '
    BEGIN { pat = ENVIRON["RT_PAT"]; rep = ENVIRON["RT_REP"] }
    function repl(s,    i, out) {
      out = ""
      while ((i = index(s, pat)) > 0) {
        out = out substr(s, 1, i - 1) rep
        s = substr(s, i + length(pat))
      }
      return out s
    }
    { print repl($0) }
  ' "$template"
}

# ---- 期限 -------------------------------------------------------------------

have_timeout_tool() {
  command -v timeout >/dev/null 2>&1 || command -v gtimeout >/dev/null 2>&1 || command -v perl >/dev/null 2>&1
}

# 期限を付けてコマンドを実行する。timeout、gtimeout、perl の順に、あるものを使う。
# 期限が来たら TERM を送り、1秒たっても終わらなければ KILL する（TERM を無視する子も止める）。
# 期限で終わったときの終了コードは 124 にそろえる（KILL で終わった 137 も 124 にする）。
# 3つとも無いときは期限なしで実行する（review.sh は CLI を呼ぶ前に have_timeout_tool で止める）。
# 引数: 秒 コマンド...
run_with_timeout() {
  local sec="$1" st=0
  shift
  if command -v timeout >/dev/null 2>&1; then
    timeout -k 1 "$sec" "$@" || st=$?
    if [ "$st" -eq 137 ]; then st=124; fi
  elif command -v gtimeout >/dev/null 2>&1; then
    gtimeout -k 1 "$sec" "$@" || st=$?
    if [ "$st" -eq 137 ]; then st=124; fi
  elif command -v perl >/dev/null 2>&1; then
    perl -e '
      use POSIX ":sys_wait_h";
      my $sec = shift;
      my $pid = fork;
      exit 127 unless defined $pid;
      if ($pid == 0) { setpgrp(0, 0); exec @ARGV; exit 127; }
      my $stop = sub {
        kill "TERM", -$pid;
        for (1 .. 10) { last if waitpid($pid, WNOHANG) > 0; select(undef, undef, undef, 0.1); }
        kill "KILL", -$pid;
        waitpid($pid, 0);
      };
      $SIG{ALRM} = sub { $stop->(); exit 124; };
      $SIG{INT} = $SIG{TERM} = $SIG{HUP} = sub { $stop->(); exit 143; };
      alarm $sec;
      waitpid($pid, 0);
      exit(($? & 127) ? 128 + ($? & 127) : $? >> 8);
    ' "$sec" "$@" || st=$?
  else
    "$@" || st=$?
  fi
  return "$st"
}

# レビュアーの CLI の終了コードを人が読めるメッセージにする
# 引数: 終了コード レビュアーの id
explain_exit() {
  local status="$1" what="$2"
  case "$status" in
    0) ;;
    124) echo "レビュアー ${what} が ${TIMEOUT_SEC} 秒でタイムアウトしました。DEV_RELAY_TIMEOUT を延ばすか、対象を小さくしてください。" >&2 ;;
    *)  echo "レビュアー ${what} が異常終了しました (exit $status)。ログイン状態や対象の指定を確認してください。" >&2 ;;
  esac
}

# 機密情報らしきファイルが対象に含まれていたら警告する（止めはしない）。
# 外部の提供元に送られる前に、人が気づけるようにするのが目的。
# 引数: ファイル一覧 vendors
warn_sensitive_files() {
  local files="$1" vendors="$2" hit
  hit="$(printf '%s\n' "$files" | grep -Ei '(^|/)\.env(\.|$)|\.(pem|key|p12|pfx)$|credentials|secrets?\.(json|ya?ml|toml)$|id_(rsa|ed25519)' || true)"
  if [ -n "$hit" ]; then
    echo "warning: 機密情報を含む可能性のあるファイルがレビュー対象に含まれています。${vendors} に送られる内容を確認してください:" >&2
    printf '%s\n' "$hit" | sed 's/^/  - /' >&2
  fi
}

# 結果ファイルの冒頭にメタ情報を書く。レビュアーの情報は R_* から取る
# 引数: ファイル kind(code|design) target
write_header() {
  local file="$1" kind="$2" target="$3"
  mkdir -p "$(dirname "$file")"
  {
    echo "# dev-relay ${kind} review"
    echo
    echo "- date: $(date '+%Y-%m-%d %H:%M:%S')"
    echo "- reviewer: ${R_ID}"
    echo "- backend: ${R_BACKEND}"
    echo "- model: ${R_MODEL:--}"
    echo "- effort: ${R_EFFORT:--}"
    echo "- billing: ${R_BILLING}"
    echo "- vendors: ${R_VENDORS}"
    echo "- target: ${target}"
    echo "- repo: $(repo_root)"
    echo
    echo "---"
    echo
  } > "$file"
}

# レビュアーの最終メッセージを結果ファイルに追記し、パスを標準出力の最後の行に出す
finish_result() {
  local result="$1" out="$2"
  if [ -s "$result" ]; then
    cat "$result" >> "$out"
  else
    echo "_(レビュアーからの出力が空でした。タイムアウトまたはエラーの可能性があります)_" >> "$out"
  fi
}

# ---- 利用者の設定（プラグインの外） ------------------------------------------

config_dir() {
  printf '%s\n' "${DEV_RELAY_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/dev-relay}"
}

# 設定フォルダの <名前> の1行目を返す。ファイルが無い、または空なら <無いときの値>
config_get() {
  local name="$1" default="$2" file value=""
  file="$(config_dir)/$name"
  if [ -f "$file" ]; then
    IFS= read -r value < "$file" || true
  fi
  if [ -n "$value" ]; then
    printf '%s\n' "$value"
  else
    printf '%s\n' "$default"
  fi
}

# 設定フォルダを作り、同じフォルダの一時ファイルに書いてから mv で置き換える。
# 設定ごとにファイルを分けているので、別の設定の書き込みと競合しない。
config_set() {
  local name="$1" value="$2" dir tmp
  dir="$(config_dir)"
  mkdir -p "$dir"
  tmp="$(mktemp "$dir/.tmp.XXXXXX")"
  printf '%s\n' "$value" > "$tmp"
  mv -f "$tmp" "$dir/$name"
}

# 提供元の一覧の形（^[a-z0-9-]+(,[a-z0-9-]+)*$）か。none と ask は名前に使えない
valid_vendor_list() {
  local v="$1" item
  printf '%s\n' "$v" | grep -Eq '^[a-z0-9-]+(,[a-z0-9-]+)*$' || return 1
  local IFS=','
  for item in $v; do
    case "$item" in none|ask) return 1 ;; esac
  done
  return 0
}

# コードを送ってよい提供元を決める。結果は次の変数に入る（$(...) の中で呼ばない）:
#   VENDORS_ALLOWED  有効な一覧（空もある）
#   VENDORS_SOURCE   repo / user / ask / unset
#   VENDORS_USER     利用者の既定（一覧 / none / ask / unset）
load_vendors() {
  local repo_val="" user_val
  user_val="$(config_get vendors unset)"
  case "$user_val" in
    none|ask|unset) ;;
    *)
      if ! valid_vendor_list "$user_val"; then
        echo "warning: 設定 vendors の値が不正なので unset として扱います: $user_val" >&2
        user_val="unset"
      fi
      ;;
  esac
  VENDORS_USER="$user_val"

  if in_git_repo; then
    repo_val="$(git config --local --get dev-relay.vendors 2>/dev/null || true)"
  fi
  VENDORS_ALLOWED=""
  if [ -n "$repo_val" ]; then
    VENDORS_SOURCE="repo"
    if [ "$repo_val" = "none" ]; then
      :
    elif valid_vendor_list "$repo_val"; then
      VENDORS_ALLOWED="$repo_val"
    else
      echo "warning: git 設定 dev-relay.vendors の値が不正なので none として扱います: $repo_val" >&2
    fi
    return 0
  fi
  case "$user_val" in
    unset) VENDORS_SOURCE="unset" ;;
    ask)   VENDORS_SOURCE="ask" ;;
    none)  VENDORS_SOURCE="user" ;;
    *)     VENDORS_SOURCE="user"; VENDORS_ALLOWED="$user_val" ;;
  esac
}
