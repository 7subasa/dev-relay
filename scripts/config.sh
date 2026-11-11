#!/usr/bin/env bash
# 利用者の設定を表示・変更する。
#
# 使い方:
#   dev-relay config metered [off|auto]
#   dev-relay config notice [on|off]                  セッション開始時の通知を出すか
#   dev-relay config vendors                          今のリポジトリで有効な一覧と出どころを表示
#   dev-relay config vendors --user <一覧|none|ask>    利用者の既定を書く
#   dev-relay config vendors --repo <一覧|none>        このリポジトリの設定を書く
#   dev-relay config vendors --repo --reset           このリポジトリの設定を消す
#   dev-relay config role <役割>                      役割の候補のファイルと、上書きの有無を表示
#   dev-relay config role <役割> --from <ファイル>     役割の候補を、このファイルで上書きする
#   dev-relay config role <役割> --keep               既定値が変わったあとも、上書きを続ける
#   dev-relay config role <役割> --reset              上書きをやめて、既定値に戻す
#
# 一覧は提供元の小文字の名前をカンマで区切ったもの（例: openai,cursor,google）。
# 設定は設定フォルダ（DEV_RELAY_CONFIG_DIR、既定は ~/.config/dev-relay）に、
# リポジトリごとの設定は git のローカル設定 dev-relay.vendors に書く。
# 役割の上書きは設定フォルダの roles/<役割>.conf（形式は config/roles/*.conf と同じ）。

set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
source "$(dirname "${BASH_SOURCE[0]}")/lib/resolve.sh"

usage() { sed -n '2,19p' "$0" | sed 's/^# \{0,1\}//'; }

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

config_notice() {
  if [ $# -eq 0 ]; then
    echo "notice=$(config_get notice on)"
    return 0
  fi
  [ $# -eq 1 ] || die "config notice の引数は on か off の1つです"
  case "$1" in
    on|off) config_set notice "$1"; echo "notice=$1" ;;
    *) die "notice は on か off です: $1" ;;
  esac
}

config_role() {
  local role="${1:-}" action="" from="" dir default now
  [ $# -gt 0 ] || die "役割を指定してください（${ROLES// /、}）"
  shift
  case " $ROLES " in *" $role "*) ;; *) die "知らない役割です（${ROLES// /、}）: $role" ;; esac
  while [ $# -gt 0 ]; do
    case "$1" in
      --from)
        [ -z "$action" ] || die "--from、--keep、--reset は同時に1つだけ指定できます"
        [ $# -ge 2 ] || die "--from にはファイルが必要です"
        action="from"; from="$2"; shift 2 ;;
      --keep|--reset)
        [ -z "$action" ] || die "--from、--keep、--reset は同時に1つだけ指定できます"
        action="${1#--}"; shift ;;
      -*) die "unknown option: $1" ;;
      *) die "余分な引数です: $1" ;;
    esac
  done

  dir="$(config_dir)/roles"
  default="$(role_default_file "$role")"
  now="$(cksum < "$default")"

  case "$action" in
    "")
      echo "role=${role}"
      echo "source=$(role_source "$role")"
      echo "file=$(abs_path "$(role_file "$role")")"
      echo "default=$(abs_path "$default")"
      if [ "$(role_source "$role")" = "override" ]; then
        echo "override=$(role_override_state "$role")"
      fi
      ;;
    from)
      local rows tmp fline
      rows="$(read_role_file "$from")" || exit 1
      [ -n "$rows" ] || die "候補が1つもありません: $from"
      # 同じ id は、どの役割でも同じ定義を指す（追加のレビュアーの除外などが id で決まるため）
      local other orows oline fid fdef oid odef
      for other in $ROLES; do
        [ "$other" != "$role" ] || continue
        orows="$(read_role_file "$(role_file "$other")")" || exit 1
        while IFS= read -r oline; do
          [ -n "$oline" ] || continue
          oid="${oline%% *}"; odef="${oline#* }"
          while IFS= read -r fline; do
            [ -n "$fline" ] || continue
            fid="${fline%% *}"; fdef="${fline#* }"
            if [ "$fid" = "$oid" ] && [ "$fdef" != "$odef" ]; then
              die "id ${fid} は役割 ${other} で別の定義に使われています。同じ id は同じ定義にするか、別の id を付けてください"
            fi
          done <<EOF2
$rows
EOF2
        done <<EOF
$orows
EOF
      done
      mkdir -p "$dir"
      # 上書きの前に .base を書く。.conf が先にあると、.base が無い間は stale に見える
      tmp="$(mktemp "$dir/.tmp.XXXXXX")"
      printf '%s\n' "$now" > "$tmp"
      mv -f "$tmp" "$dir/${role}.base"
      tmp="$(mktemp "$dir/.tmp.XXXXXX")"
      cat "$from" > "$tmp"
      mv -f "$tmp" "$dir/${role}.conf"
      echo "source=override"
      ;;
    keep)
      [ -f "$dir/${role}.conf" ] || die "役割 ${role} に上書きはありません"
      local tmpk
      tmpk="$(mktemp "$dir/.tmp.XXXXXX")"
      printf '%s\n' "$now" > "$tmpk"
      mv -f "$tmpk" "$dir/${role}.base"
      echo "override=current"
      ;;
    reset)
      rm -f "$dir/${role}.conf" "$dir/${role}.base"
      echo "source=default"
      ;;
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
  notice) shift; config_notice "$@" ;;
  role) shift; config_role "$@" ;;
  vendors) shift; config_vendors "$@" ;;
  -h|--help) usage ;;
  *) usage >&2; exit 1 ;;
esac
