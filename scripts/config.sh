#!/usr/bin/env bash
# 利用者の設定を表示・変更する。
#
# 使い方:
#   dev-relay config metered [off|auto]
#   dev-relay config vendors                          今のリポジトリで有効な一覧と出どころを表示
#   dev-relay config vendors --user <一覧|none|ask>    利用者の既定を書く
#   dev-relay config vendors --repo <一覧|none>        このリポジトリの設定を書く
#   dev-relay config vendors --repo --reset           このリポジトリの設定を消す
#
# 一覧は提供元の小文字の名前をカンマで区切ったもの（例: openai,cursor,google）。
# 設定は設定フォルダ（DEV_RELAY_CONFIG_DIR、既定は ~/.config/dev-relay）に、
# リポジトリごとの設定は git のローカル設定 dev-relay.vendors に書く。

set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

usage() { sed -n '2,13p' "$0" | sed 's/^# \{0,1\}//'; }

config_metered() {
  if [ $# -eq 0 ]; then
    echo "metered=$(config_get metered off)"
    return 0
  fi
  [ $# -eq 1 ] || die "config metered の引数は off か auto の1つです"
  case "$1" in
    off|auto) config_set metered "$1"; echo "metered=$1" ;;
    *) die "metered は off か auto です: $1" ;;
  esac
}

config_vendors() {
  local scope="" value="" have_value=0 reset=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --user|--repo)
        [ -z "$scope" ] || die "--user と --repo は同時に指定できません"
        scope="${1#--}"; shift ;;
      --reset) reset=1; shift ;;
      -*) die "unknown option: $1" ;;
      *)
        [ "$have_value" -eq 0 ] || die "値は1つだけ指定してください"
        value="$1"; have_value=1; shift ;;
    esac
  done

  if [ -z "$scope" ]; then
    [ "$have_value" -eq 0 ] && [ "$reset" -eq 0 ] || die "書き込みには --user か --repo が必要です"
    load_vendors
    echo "vendors=${VENDORS_ALLOWED:-none}"
    echo "source=${VENDORS_SOURCE}"
    return 0
  fi

  if [ "$reset" -eq 1 ]; then
    [ "$scope" = "repo" ] && [ "$have_value" -eq 0 ] || die "--reset は --repo だけと一緒に使います"
    in_git_repo || die "git リポジトリの外ではリポジトリごとの設定を消せません"
    git config --local --unset dev-relay.vendors 2>/dev/null || true
    echo "このリポジトリの設定を消しました"
    return 0
  fi

  [ "$have_value" -eq 1 ] || die "値が必要です（一覧、none、--user のときは ask も）"
  case "$value" in
    none) ;;
    ask)  [ "$scope" = "user" ] || die "ask は --user でだけ使えます" ;;
    *)    valid_vendor_list "$value" || die "一覧の形が不正です（小文字の英数字とハイフンをカンマで区切る。none と ask は名前に使えません）: $value" ;;
  esac
  if [ "$scope" = "user" ]; then
    config_set vendors "$value"
  else
    in_git_repo || die "git リポジトリの外ではリポジトリごとの設定を書けません"
    git config --local dev-relay.vendors "$value"
  fi
  echo "${scope}.vendors=${value}"
}

SUB="${1:-}"
case "$SUB" in
  metered) shift; config_metered "$@" ;;
  vendors) shift; config_vendors "$@" ;;
  -h|--help) usage ;;
  *) usage >&2; exit 1 ;;
esac
