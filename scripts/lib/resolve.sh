#!/usr/bin/env bash
# レビュアーの決め方。common.sh を読み込んだあとに source する。単体では実行しない。

# 道具の状態を調べ、TOOL_CODEX / TOOL_CURSOR / TOOL_JQ / TOOL_HERDR に
# ok / not-installed / not-logged-in を入れる。
# bash 3.2 では $(...) の中で代入した変数が呼び出し元に残らないので、
# $(...) の中で呼ばず、呼び出し元のシェルで最初に1回だけ呼ぶ。
probe_tools() {
  local out lc

  TOOL_CODEX="not-installed"
  if command -v codex >/dev/null 2>&1; then
    if run_with_timeout 10 codex login status >/dev/null 2>&1; then
      TOOL_CODEX="ok"
    else
      TOOL_CODEX="not-logged-in"
    fi
  fi

  # cursor-agent status は、未ログインでも終了コード 0 で "Not logged in" と出す。
  # 終了コードでは判定できないので、出力の文言も見る。
  TOOL_CURSOR="not-installed"
  if command -v cursor-agent >/dev/null 2>&1; then
    TOOL_CURSOR="not-logged-in"
    if out="$(run_with_timeout 10 cursor-agent status 2>&1)"; then
      lc="$(printf '%s' "$out" | tr '[:upper:]' '[:lower:]')"
      case "$lc" in
        *"not logged in"*) ;;
        *"logged in"*) TOOL_CURSOR="ok" ;;
      esac
    fi
  fi

  TOOL_JQ="not-installed"
  if command -v jq >/dev/null 2>&1; then TOOL_JQ="ok"; fi

  TOOL_HERDR="not-installed"
  if command -v hc >/dev/null 2>&1; then TOOL_HERDR="ok"; fi
}

# 候補が使えない理由を ; 区切りで標準出力に出す。無ければ空。
# 道具の状態は TOOL_* を読むだけで、調べ直さない。
# 引数: backend billing vendors
candidate_reasons() {
  local backend="$1" billing="$2" vendors="$3" r="" missing="" v
  case "$backend" in
    codex)
      case "$TOOL_CODEX" in
        not-installed)  r="${r:+$r;}codex-not-installed" ;;
        not-logged-in)  r="${r:+$r;}codex-not-logged-in" ;;
      esac
      ;;
    cursor)
      case "$TOOL_CURSOR" in
        not-installed)  r="${r:+$r;}cursor-not-installed" ;;
        not-logged-in)  r="${r:+$r;}cursor-not-logged-in" ;;
      esac
      if [ "$TOOL_JQ" != "ok" ]; then r="${r:+$r;}jq-not-installed"; fi
      if ! in_git_repo; then r="${r:+$r;}not-a-git-repo"; fi
      ;;
  esac
  if [ "$billing" = "metered" ] && [ "$(config_get metered off)" != "auto" ]; then
    r="${r:+$r;}metered-off"
  fi
  local IFS=','
  for v in $vendors; do
    case ",${VENDORS_ALLOWED},anthropic," in
      *",${v},"*) ;;
      *) missing="${missing:+$missing,}${v}" ;;
    esac
  done
  if [ -n "$missing" ]; then r="${r:+$r;}vendor-not-allowed:${missing}"; fi
  printf '%s' "$r"
}

# 役割のファイルから、使える最初の候補を選ぶ。
# 選んだ候補を R_ID R_BACKEND R_MODEL R_EFFORT R_BILLING R_VENDORS に、
# 飛ばした候補と理由を R_SKIPPED（空白区切り。例: carbon(metered-off;vendor-not-allowed:cursor,google)）に入れる。
# 選べたら 0、選べなければ 1。形式の壊れた行と、ファイルに無い指定の id は die する。
# 呼ぶ前に probe_tools と load_vendors を呼んでおく。$(...) の中で呼ばない。
# 引数: 役割 [指定の id] [除外する id]
resolve_role() {
  local role="$1" only="${2:-}" exclude="${3:-}"
  local file="$DEV_RELAY_ROOT/config/roles/${role}.conf"
  local line lineno=0 id backend model effort billing vendors extra reasons seen=" " found_only=0
  R_ID=""; R_BACKEND=""; R_MODEL=""; R_EFFORT=""; R_BILLING=""; R_VENDORS=""; R_SKIPPED=""
  [ -f "$file" ] || die "役割のファイルが見つかりません: $file"

  while IFS= read -r line || [ -n "$line" ]; do
    lineno=$((lineno + 1))
    case "$line" in
      ''|'#'*) continue ;;
    esac
    id=""; backend=""; model=""; effort=""; billing=""; vendors=""; extra=""
    read -r id backend model effort billing vendors extra <<EOF
$line
EOF
    case "$id" in ''|'#'*) continue ;; esac
    if [ -z "$vendors" ] || [ -n "$extra" ]; then
      die "$file:$lineno: 列は id backend model effort billing vendors の6つです: $line"
    fi
    printf '%s\n' "$id" | grep -Eq '^[a-z0-9-]+$' || die "$file:$lineno: id の形が不正です: $id"
    case "$seen" in *" $id "*) die "$file:$lineno: id が重複しています: $id" ;; esac
    seen="$seen$id "
    case "$backend" in codex|cursor|claude) ;; *) die "$file:$lineno: backend は codex / cursor / claude のどれかです: $backend" ;; esac
    case "$billing" in included|metered) ;; *) die "$file:$lineno: billing は included / metered のどちらかです: $billing" ;; esac
    valid_vendor_list "$vendors" || die "$file:$lineno: vendors の形が不正です: $vendors"

    # 候補を選んだあとも、ファイルの残りの行は形式の検査のために読む
    [ -z "$R_ID" ] || continue
    if [ -n "$only" ] && [ "$id" != "$only" ]; then continue; fi
    if [ -n "$only" ]; then found_only=1; fi

    reasons="$(candidate_reasons "$backend" "$billing" "$vendors")"
    if [ -n "$exclude" ] && [ "$id" = "$exclude" ]; then
      reasons="${reasons:+$reasons;}same-as-primary"
    fi
    if [ -z "$reasons" ]; then
      R_ID="$id"; R_BACKEND="$backend"; R_MODEL="$model"; R_EFFORT="$effort"
      R_BILLING="$billing"; R_VENDORS="$vendors"
    else
      R_SKIPPED="${R_SKIPPED:+$R_SKIPPED }${id}(${reasons})"
    fi
  done < "$file"

  if [ -n "$only" ] && [ "$found_only" -eq 0 ]; then
    die "役割 ${role} に id ${only} の候補はありません（${file}）"
  fi
  [ -n "$R_ID" ]
}
