#!/usr/bin/env bash
# 作業のフォルダ（.dev-relay/<topic>/）を作る。終わった作業を .dev-relay/done/ に移す。
#
# 使い方:
#   dev-relay work dir <topic>      .dev-relay/<topic>/ と、その下の review/ impl/ logs/ を作り、パスを key=value で表示する
#   dev-relay work done <名前>      終わった作業を .dev-relay/done/ に移す。名前は <topic> か pr/<n>
#
# <topic> は ^[A-Za-z0-9][A-Za-z0-9._-]*$ で 64 文字以内。done、pr、review は予約で使えない。
# 移す先がすでにあれば、<名前>-2、-3 … と空いている最初の名前にする。
# シンボリックリンクを経由するときは、何も作らず何も移さずに止める。
# 終了コード: 0 完了 / 1 引数や前提の誤り

set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

usage() { sed -n '2,10p' "$0" | sed 's/^# \{0,1\}//'; }

# <topic> の形か。引数: 名前
valid_topic() {
  local LC_ALL=C t="$1"
  case "$t" in
    ''|*[!A-Za-z0-9._-]*|[!A-Za-z0-9]*) return 1 ;;
    done|pr|review) return 1 ;;
  esac
  [ "${#t}" -le 64 ]
}

# 作業ツリーの最上位を ROOT に入れる。git リポジトリの外では止める
need_root() {
  in_git_repo || die "git リポジトリの外では作業のフォルダを決められません"
  ROOT="$(git rev-parse --show-toplevel)"
}

work_dir() {
  local topic dir
  [ $# -eq 1 ] || die "使い方: dev-relay work dir <topic>"
  topic="$1"
  valid_topic "$topic" || die "topic の形が合いません（英数字で始まり、英数字と . _ - だけ、64 文字以内。done pr review は使えません）: $topic"
  need_root
  dir="$ROOT/$OUT_DIR/$topic"
  refuse_symlink "$ROOT/$OUT_DIR" "$dir" "$dir/review" "$dir/impl" "$dir/logs"
  mkdir -p "$dir/review" "$dir/impl" "$dir/logs"
  ensure_out_dir "$dir"
  echo "work.dir=${dir}"
  echo "work.review=${dir}/review"
  echo "work.impl=${dir}/impl"
  echo "work.logs=${dir}/logs"
}

work_done() {
  local name n src done_dir dest i
  [ $# -eq 1 ] || die "使い方: dev-relay work done <topic | pr/<n>>"
  name="$1"
  case "$name" in
    pr/*)
      n="${name#pr/}"
      case "$n" in ''|.|..|*[!A-Za-z0-9._-]*) die "pr/<n> の形が合いません: $name" ;; esac
      ;;
    *) valid_topic "$name" || die "名前の形が合いません（<topic> か pr/<n>）: $name" ;;
  esac
  need_root
  src="$ROOT/$OUT_DIR/$name"
  done_dir="$ROOT/$OUT_DIR/done"
  case "$name" in
    pr/*) refuse_symlink "$ROOT/$OUT_DIR" "$ROOT/$OUT_DIR/pr" "$src" "$done_dir" "$done_dir/pr" ;;
    *)    refuse_symlink "$ROOT/$OUT_DIR" "$src" "$done_dir" ;;
  esac
  [ -d "$src" ] || die "移す作業のフォルダがありません: $src"
  dest="$done_dir/$name"
  mkdir -p "$(dirname "$dest")"
  i=2
  while [ -e "$dest" ] || [ -L "$dest" ]; do
    dest="$done_dir/$name-$i"
    i=$((i + 1))
  done
  mv "$src" "$dest"
  echo "work.done=${dest}"
}

case "${1:-}" in
  ""|-h|--help) usage; exit 0 ;;
  dir) shift; work_dir "$@" ;;
  done) shift; work_done "$@" ;;
  *) echo "error: 知らないサブコマンドです: $1" >&2; usage >&2; exit 1 ;;
esac
