#!/usr/bin/env bash
# レビュアーの決め方。common.sh を読み込んだあとに source する。単体では実行しない。

# 役割の一覧。doctor や refresh は、この順に役割を扱う
ROLES="design-review code-review code-review-extra"

# CLI の版を1行で出す。引数: codex か cursor
# PATH に無ければ、何も出さず 0 を返す。PATH にあるのに取れなければ
# （失敗、期限、空の出力）、何も出さず 1 を返す。ネットワークは使わない。
tool_version() {
  local cmd tmp first=""
  case "$1" in
    codex)  cmd="codex" ;;
    cursor) cmd="cursor-agent" ;;
    *) return 1 ;;
  esac
  command -v "$cmd" >/dev/null 2>&1 || return 0
  # 期限を付ける道具が無いと、フックの待ち時間を保証できないので呼ばない
  have_timeout_tool || return 1
  # 出力は $(...) やパイプで受けない。期限で止めたあとも孫プロセスが出力を握っていると、
  # 受ける側が終わるまで待たされる。一時ファイルに書かせれば、待たずに読める
  tmp="$(mktemp)" || return 1
  if ! run_with_timeout 2 "$cmd" --version > "$tmp" 2>/dev/null < /dev/null; then
    rm -f "$tmp"
    return 1
  fi
  IFS= read -r first < "$tmp" || true
  rm -f "$tmp"
  [ -n "$first" ] || return 1
  printf '%s\n' "$first"
}

# 役割の既定値のファイル（プラグインの中）
role_default_file() { printf '%s\n' "$DEV_RELAY_ROOT/config/roles/${1}.conf"; }

# 役割の候補のファイル。利用者の上書きがあればそれ、無ければ既定値
role_file() {
  if [ -f "$(config_dir)/roles/${1}.conf" ]; then
    printf '%s\n' "$(config_dir)/roles/${1}.conf"
  else
    role_default_file "$1"
  fi
}

# override か default
role_source() {
  if [ -f "$(config_dir)/roles/${1}.conf" ]; then echo override; else echo default; fi
}

# 上書きが無ければ none。あれば、上書きを作ったときの既定値のチェックサムが
# 今の既定値と同じなら current、違う（.base が無いのも含む）なら stale
role_override_state() {
  local base now="" saved=""
  [ -f "$(config_dir)/roles/${1}.conf" ] || { echo none; return 0; }
  base="$(config_dir)/roles/${1}.base"
  now="$(cksum < "$(role_default_file "$1")")"
  if [ -f "$base" ]; then IFS= read -r saved < "$base" || true; fi
  if [ -n "$saved" ] && [ "$saved" = "$now" ]; then echo current; else echo stale; fi
}

# 役割のファイルを読んで検査し、候補を1行ずつ
# "id backend model effort billing vendors"（空白1つ区切り）で標準出力に出す。
# 形式の壊れた行、backend と vendors の食い違う行、ファイルが無いときは die する。
# $(...) の中で呼ぶ（die はその中だけで終わるので、呼び出し側は失敗を見て終わる）。
# 引数: ファイル
read_role_file() {
  local file="$1"
  local line lineno=0 id backend model effort billing vendors extra seen=" " need="" missing="" v
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

    # claude の候補は決まったエージェントで動き、model を渡す経路が無い。指定を受け付けると、
    # 試したつもりのモデルと実際に動くモデルが食い違う
    if [ "$backend" = "claude" ] && { [ "$model" != "-" ] || [ "$effort" != "-" ]; }; then
      die "$file:$lineno: backend が claude の候補は model と effort を - にします: $line"
    fi

    # backend と model から分かる送り先が vendors に書かれているか。
    # 許可は vendors の列を信じて決めるので、食い違いは送り先の取り違えになる
    case "$backend" in
      codex)  need="openai" ;;
      claude) need="anthropic" ;;
      cursor)
        need="cursor"
        case "$model" in
          gemini*)               need="$need,google" ;;
          grok*|cursor-grok*)    need="$need,xai" ;;
          gpt*)                  need="$need,openai" ;;
          claude*)               need="$need,anthropic" ;;
          deepseek*)             need="$need,deepseek" ;;
        esac
        ;;
    esac
    missing=""
    local IFS=','
    for v in $need; do
      case ",${vendors}," in
        *",${v},"*) ;;
        *) missing="${missing:+$missing,}${v}" ;;
      esac
    done
    unset IFS
    if [ -n "$missing" ]; then
      die "$file:$lineno: backend が ${backend} で model が ${model} の候補は、vendors に ${missing} が要ります: $line"
    fi

    printf '%s %s %s %s %s %s\n' "$id" "$backend" "$model" "$effort" "$billing" "$vendors"
  done < "$file"
}


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
# 利用者の上書きがあれば、既定値ではなく上書きのファイルを読む。
# 呼ぶ前に probe_tools と load_vendors を呼んでおく。$(...) の中で呼ばない。
# 引数: 役割 [指定の id] [除外する id]
resolve_role() {
  local role="$1" only="${2:-}" exclude="${3:-}"
  local file rows line id backend model effort billing vendors reasons found_only=0
  R_ID=""; R_BACKEND=""; R_MODEL=""; R_EFFORT=""; R_BILLING=""; R_VENDORS=""; R_SKIPPED=""
  file="$(role_file "$role")"
  # 候補を選んだあとも、ファイルの残りの行は形式の検査のために読む（read_role_file が全行を検査する）
  rows="$(read_role_file "$file")" || exit 1

  while IFS= read -r line; do
    [ -n "$line" ] || continue
    read -r id backend model effort billing vendors <<EOF
$line
EOF
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
  done <<EOF
$rows
EOF

  if [ -n "$only" ] && [ "$found_only" -eq 0 ]; then
    die "役割 ${role} に id ${only} の候補はありません（${file}）"
  fi
  [ -n "$R_ID" ]
}
