#!/usr/bin/env bash
# 前回の確認からの変化を調べ、記録し、セッションの開始時に知らせる。
#
# 使い方:
#   dev-relay refresh check             前回の記録と今を比べ、変化を key=value で表示（記録は書かない）
#   dev-relay refresh save              今の状態を記録し、確認した日を今日にする
#   dev-relay refresh notice [--hook]   知らせることがあれば1行表示する（ネットワークは使わない）
#
# notice は SessionStart のフックから呼ばれる。--hook を付けると {"systemMessage":"..."} の
# 1行で出し、標準エラーには何も出さない。どの場合も終了コードは 0。
# 記録は設定フォルダ（DEV_RELAY_CONFIG_DIR、既定は ~/.config/dev-relay）の state/snapshot。
# 通知を止めるには dev-relay config notice off。

set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
source "$(dirname "${BASH_SOURCE[0]}")/lib/resolve.sh"
source "$(dirname "${BASH_SOURCE[0]}")/lib/state.sh"

usage() { sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'; }

# a にあって b に無い要素を、a の順にカンマでつなぐ。引数: カンマ区切りの一覧 a, b
list_minus() {
  local a="$1" b="$2" out="" item
  local IFS=','
  for item in $a; do
    case ",${b}," in
      *",${item},"*) ;;
      *) out="${out:+$out,}${item}" ;;
    esac
  done
  printf '%s' "$out"
}

# 文を、JSON の文字列の中身にする。制御文字を除き、\ と " を \ で始まる形にする
json_escape() {
  printf '%s' "$1" | LC_ALL=C tr -d '\000-\037\177' | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'
}

# 前回の記録と今の記録を比べ、changed.*、added.*、removed.* の行を出す（両方に値があるキーだけ）。
# 引数: 前回の記録 今の記録
print_changes() {
  local prior="$1" cur="$2" key pv cv un
  for key in tool.codex.version tool.cursor.version codex.default-model; do
    pv="$(snapshot_get "$prior" "$key")" || continue
    cv="$(snapshot_get "$cur" "$key")" || continue
    if [ "$pv" != "$cv" ]; then echo "changed.${key}=${pv} -> ${cv}"; fi
  done
  for key in codex.models cursor.models; do
    pv="$(snapshot_get "$prior" "$key")" || continue
    cv="$(snapshot_get "$cur" "$key")" || continue
    un="$(list_minus "$cv" "$pv")"
    if [ -n "$un" ]; then echo "added.${key}=${un}"; fi
    un="$(list_minus "$pv" "$cv")"
    if [ -n "$un" ]; then echo "removed.${key}=${un}"; fi
  done
}

refresh_check() {
  local snap now saved days key pv cv role rows line id backend model un list codex_all="" cache
  snap="$(snapshot_file)"
  now="$(today)"
  cur="$(mktemp)"
  trap 'rm -f "$cur"' EXIT
  collect_snapshot full "$cur"
  for key in $SNAP_FAILED; do
    echo "warning: ${key} を取得できませんでした。前回の値とは比べません" >&2
  done

  if [ -f "$snap" ]; then
    echo "snapshot=present"
    saved="$(snapshot_get "$snap" saved)" || saved=""
    if days_from_date "$saved" >/dev/null 2>&1; then
      echo "saved=${saved}"
      days=$(( $(days_from_date "$now") - $(days_from_date "$saved") ))
      echo "days-since=${days}"
    else
      saved=""
    fi
    print_changes "$snap" "$cur"
    if [ -n "$saved" ]; then
      due_dates "$saved" "$now" | while IFS= read -r line; do echo "due=${line}"; done
    fi
  else
    echo "snapshot=absent"
  fi

  for role in $ROLES; do
    pv="$(role_override_state "$role")"
    if [ "$pv" != "none" ]; then echo "override.${role}=${pv}"; fi
  done

  # Codex は、一覧で hide のモデルも --model で指定すれば動くので、全部の slug と比べる
  cache="${CODEX_HOME:-$HOME/.codex}/models_cache.json"
  if command -v codex >/dev/null 2>&1 && command -v jq >/dev/null 2>&1 && [ -r "$cache" ]; then
    codex_all="$(jq -r '.models[].slug' "$cache" 2>/dev/null | paste -sd, -)" || codex_all=""
  fi

  for role in $ROLES; do
    rows="$(read_role_file "$(role_file "$role")")" || exit 1
    un=""
    while IFS= read -r line; do
      [ -n "$line" ] || continue
      read -r id backend model _ <<EOF
$line
EOF
      [ "$model" != "-" ] || continue
      case "$backend" in
        cursor) list="$(snapshot_get "$cur" "cursor.models")" || continue ;;
        codex)  list="$codex_all" ;;
        *) continue ;;
      esac
      [ -n "$list" ] || continue
      case ",${list}," in
        *",${model},"*) ;;
        *) un="${un:+$un }${id}(${model})" ;;
      esac
    done <<EOF
$rows
EOF
    if [ -n "$un" ]; then echo "unavailable.${role}=${un}"; fi
  done
}

refresh_save() {
  local snap key v prior now
  snap="$(snapshot_file)"
  now="$(today)"
  cur="$(snapshot_tmp)" || die "記録を置くフォルダを作れません: $(state_dir)"
  out="$(snapshot_tmp)" || die "記録を置くフォルダを作れません: $(state_dir)"
  trap 'rm -f "$cur" "$out"' EXIT
  collect_snapshot full "$cur"

  # 取得に失敗したキーは、前回の値を引き継ぐ（一時的な失敗で、比べる相手を失わないため）
  : > "$out"
  for key in $SNAP_KEYS; do
    if v="$(snapshot_get "$cur" "$key")"; then
      echo "${key}=${v}" >> "$out"
      continue
    fi
    case " ${SNAP_FAILED} " in
      *" ${key} "*)
        if prior="$(snapshot_get "$snap" "$key")"; then
          echo "${key}=${prior}" >> "$out"
          echo "warning: ${key} を取得できなかったので、前回の値を引き継ぎました" >&2
        else
          echo "warning: ${key} を取得できなかったので、記録に書きません" >&2
        fi
        ;;
    esac
  done
  # check のあとに変わったもの（Codex は実行のたびにモデル一覧を更新する）を、
  # 黙って新しい基準にしないため、前回の記録との違いを出してから置き換える
  if [ -f "$snap" ]; then print_changes "$snap" "$out"; fi
  snapshot_replace "$out"
  echo "saved=${now}"
  echo "snapshot=${snap}"
}

# 知らせる文を標準出力に出す。何も無ければ何も出さない。
# $(...) の中で呼ぶので、エラーでは止まらず、失敗は何も出さずに戻る（set -e も効かない）
notice_body() {
  local snap tmp now saved days reasons="" r t name pv cv dues n line d rest stale role st
  set +e
  [ "$(config_get notice on)" != "off" ] || return 0
  now="$(today)" || return 0
  snap="$(snapshot_file)"

  saved=""
  if [ -f "$snap" ]; then
    saved="$(snapshot_get "$snap" saved)" || saved=""
    days_from_date "$saved" >/dev/null 2>&1 || saved=""
  fi

  # 壊れている（saved の行が無い・形が違う）ときは、書き換えずに知らせる。直すのは refresh save。
  # フックが置き換えると、同時に動いた refresh save の記録を消しうる
  if [ -f "$snap" ] && [ -z "$saved" ]; then
    printf 'dev-relay: 前回の確認の記録を読めません。/dev-relay:refresh で確認できます。\n'
    return 0
  fi

  # 記録が無い（入れた直後）ときは、版だけの記録を書いて、何も知らせない。
  # 同時に refresh save が書いた記録を残すため、すでにあれば置き換えない（ln）
  if [ -z "$saved" ]; then
    tmp="$(snapshot_tmp 2>/dev/null)" || return 0
    if ! collect_snapshot quick "$tmp" 2>/dev/null; then rm -f "$tmp"; return 0; fi
    snapshot_create "$tmp" || true
    return 0
  fi

  tmp="$(mktemp)" || return 0
  if ! collect_snapshot quick "$tmp"; then rm -f "$tmp"; return 0; fi

  for t in codex cursor; do
    case "$t" in codex) name="Codex" ;; cursor) name="Cursor" ;; esac
    pv="$(snapshot_get "$snap" "tool.${t}.version")" || continue
    cv="$(snapshot_get "$tmp" "tool.${t}.version")" || continue
    if [ "$pv" != "$cv" ]; then
      reasons="${reasons:+${reasons}、}${name} CLI の版が変わりました（${pv} → ${cv}）"
    fi
  done
  rm -f "$tmp"

  dues="$(due_dates "$saved" "$now")"
  if [ -n "$dues" ]; then
    n=0
    while IFS= read -r line; do n=$((n + 1)); done <<EOF
$dues
EOF
    line="${dues%%$'\n'*}"
    d="${line%%[[:space:]]*}"
    rest="${line#"$d"}"
    rest="${rest#"${rest%%[![:space:]]*}"}"
    r="${d} ${rest}"
    if [ "$n" -ge 2 ]; then r="${r} ほか$((n - 1))件"; fi
    reasons="${reasons:+${reasons}、}見直す予定の日を過ぎました（${r}）"
  fi

  stale=""
  for role in $ROLES; do
    st="$(role_override_state "$role")"
    if [ "$st" = "stale" ]; then stale="${stale:+$stale,}${role}"; fi
  done
  if [ -n "$stale" ]; then
    reasons="${reasons:+${reasons}、}上書きの元になった既定のレビュアー候補が変わりました（${stale}）"
  fi

  days=$(( $(days_from_date "$now") - $(days_from_date "$saved") ))
  if [ "$days" -ge 30 ]; then
    reasons="${reasons:+${reasons}、}前回の確認から${days}日たちました"
  fi

  if [ -n "$reasons" ]; then
    printf 'dev-relay: %s。/dev-relay:refresh で確認できます。\n' "$reasons"
  fi
}

refresh_notice() {
  local hook=0 arg msg=""
  for arg in "$@"; do
    case "$arg" in
      --hook) hook=1 ;;
      *) usage >&2; exit 1 ;;
    esac
  done
  # フックは標準入力に JSON を渡してくるが、読まない。子プロセスにも渡さない
  exec </dev/null
  if [ "$hook" -eq 1 ]; then
    msg="$(notice_body 2>/dev/null)" || msg=""
    if [ -n "$msg" ]; then
      printf '{"systemMessage":"%s"}\n' "$(json_escape "$msg")" 2>/dev/null || true
    fi
  else
    msg="$(notice_body)" || msg=""
    if [ -n "$msg" ]; then printf '%s\n' "$msg" || true; fi
  fi
  exit 0
}

SUB="${1:-}"
case "$SUB" in
  check|save)
    shift
    [ $# -eq 0 ] || { usage >&2; exit 1; }
    "refresh_${SUB}" ;;
  notice) shift; refresh_notice "$@" ;;
  -h|--help) usage ;;
  *) usage >&2; exit 1 ;;
esac
