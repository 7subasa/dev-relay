#!/usr/bin/env bash
# 公開してよい状態かを機械的に確かめる。問題があれば、ファイル名と行番号を出して終了コード 1。
# 使い方: tests/check-public.sh [<リポジトリ>]    （省略時は、このスクリプトがあるリポジトリ）
#
# 確かめること:
#   - ホームディレクトリを含む絶対パス、メールアドレス、よくある秘密の形が、管理対象のファイルに無い
#   - 設定フォルダの private-words.txt の各行（固定の文字列。大文字小文字を区別しない）が無い
#   - HANDOFF.md、.codex-review/、.dev-relay/ が管理対象に含まれない
#   - git の user.email と全コミットの作者・committer のメールアドレスが @users.noreply.github.com で終わる
#
# 検査用のパターンは、このスクリプト自身に一致しない書き方（文字クラス）にしている。

set -u

REPO="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
cd "$REPO" || { echo "error: リポジトリに移動できません: $REPO" >&2; exit 1; }

FAIL=0
problem() { echo "$*"; FAIL=1; }

# 管理対象と、無視されていない未追跡のファイル。日本語などの名前が引用符付きにならないよう、NUL 区切りで列挙する
list_files() { git ls-files -z -co --exclude-standard; }

# 内容の検査。引数: ラベル 拡張正規表現
scan_pattern() {
  local label="$1" pattern="$2" f
  list_files | while IFS= read -r -d '' f; do
    [ -f "$f" ] || continue
    grep -nEI -- "$pattern" "$f" 2>/dev/null | while IFS=: read -r no _rest; do
      echo "$f:$no: $label"
    done
  done
}

OUT="$(
  scan_pattern "ホームディレクトリを含むパス（macOS）" '/[U]sers/[A-Za-z0-9._-]+/'
  scan_pattern "ホームディレクトリを含むパス（Linux）" '/[h]ome/[a-z_][a-z0-9_-]*/'
  scan_pattern "ホームディレクトリを含むパス（Windows）" '[A-Za-z]:[\\/][U]sers[\\/]'
  scan_pattern "メールアドレスの形" '[A-Za-z0-9._%+-]+@[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)*\.[A-Za-z]{2,}'
  scan_pattern "API キーの形" '(sk|pk)-[A-Za-z0-9_-]{20,}|gh[pousr]_[A-Za-z0-9]{30,}|AKIA[0-9A-Z]{16}|xox[abprs]-[A-Za-z0-9-]{10,}|AIza[0-9A-Za-z_-]{35}'
  scan_pattern "秘密鍵の見出し" '-----BEGIN [A-Z ]*PRIVATE KEY-----'
)"
if [ -n "$OUT" ]; then problem "$OUT"; fi

# 禁止する語の一覧（手元だけに置く）
PRIVATE_WORDS="${DEV_RELAY_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/dev-relay}/private-words.txt"
if [ -f "$PRIVATE_WORDS" ]; then
  WORDS_FILE="$(mktemp)"
  grep -v '^[[:space:]]*$' "$PRIVATE_WORDS" > "$WORDS_FILE" || true
  if [ -s "$WORDS_FILE" ]; then
    list_files | while IFS= read -r -d '' f; do
      [ -f "$f" ] || continue
      grep -nFiI -f "$WORDS_FILE" -- "$f" 2>/dev/null | while IFS=: read -r no _rest; do
        echo "$f:$no: 禁止する語（private-words.txt）"
      done
    done > "$WORDS_FILE.found"
    if [ -s "$WORDS_FILE.found" ]; then problem "$(cat "$WORDS_FILE.found")"; fi
  fi
  rm -f "$WORDS_FILE" "$WORDS_FILE.found"
fi

# 管理対象に含まれてはいけないもの
HIT="$(list_files | tr '\0' '\n' | grep -E '(^|/)(HANDOFF\.md|\.codex-review/|\.dev-relay/)' || true)"
if [ -n "$HIT" ]; then
  problem "$(printf '%s\n' "$HIT" | sed 's/$/: 管理対象に含めてはいけないファイル/')"
fi

# コミットの作者
is_noreply() {
  case "$1" in
    ?*"@users.noreply.github.com") return 0 ;;
    *) return 1 ;;
  esac
}
if ! is_noreply "$(git config user.email || true)"; then
  problem "git config user.email が noreply アドレスでない（設定なしを含む）"
fi
if git rev-parse --verify --quiet HEAD >/dev/null; then
  BAD=""
  while read -r sha author committer; do
    if ! is_noreply "$author" || ! is_noreply "$committer"; then BAD="$BAD $sha"; fi
  done <<EOF2
$(git log --format='%h %ae %ce')
EOF2
  if [ -n "$BAD" ]; then
    problem "作者か committer が noreply アドレスでないコミット:$BAD"
  fi
fi

if [ "$FAIL" -eq 0 ]; then
  echo "ok: 公開してよい状態です"
  exit 0
fi
exit 1
