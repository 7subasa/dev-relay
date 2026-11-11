#!/usr/bin/env bash
# 前回確認したときの状態（記録）と、見直しの日付。common.sh と resolve.sh を読み込んだあとに
# source する。単体では実行しない。
# 記録は設定フォルダの state/snapshot に、key=value を1行ずつ書く。

# 記録に書くキーの順番
SNAP_KEYS="saved tool.codex.version tool.cursor.version codex.default-model codex.models cursor.models"

state_dir() { printf '%s\n' "$(config_dir)/state"; }

snapshot_file() { printf '%s\n' "$(state_dir)/snapshot"; }

# 今日の日付。DEV_RELAY_TODAY はテスト用で、YYYY-MM-DD でなければ die する
today() {
  if [ -n "${DEV_RELAY_TODAY:-}" ]; then
    days_from_date "$DEV_RELAY_TODAY" >/dev/null || die "DEV_RELAY_TODAY は YYYY-MM-DD の形です: $DEV_RELAY_TODAY"
    printf '%s\n' "$DEV_RELAY_TODAY"
  else
    date +%Y-%m-%d
  fi
}

# YYYY-MM-DD を、1970-01-01 からの日数にして出す。形が違えば 1 を返す
days_from_date() {
  local y m d
  case "$1" in [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]) ;; *) return 1 ;; esac
  y="${1%%-*}"; m="${1#*-}"; m="${m%%-*}"; d="${1##*-}"
  y=$((10#$y)); m=$((10#$m)); d=$((10#$d))
  if [ "$m" -le 2 ]; then y=$((y - 1)); m=$((m + 12)); fi
  echo $(( 365 * y + y / 4 - y / 100 + y / 400 + (153 * (m - 3) + 2) / 5 + d - 719469 ))
}

# 記録から <キー> の値を出す。無ければ何も出さず 1 を返す
# 引数: ファイル キー
snapshot_get() {
  local line
  [ -f "$1" ] || return 1
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      "$2="*) printf '%s\n' "${line#*=}"; return 0 ;;
    esac
  done < "$1"
  return 1
}

# 今の状態を集めて、記録の形（saved を含む）で出力ファイルに書く。
# 取得に失敗したキー（道具は PATH にあるのに値が取れなかったもの）を、空白区切りで SNAP_FAILED に入れる。
# 道具が PATH に無いキーは書かず、失敗にも数えない。
# quick は CLI の版だけ（ネットワークを使わない）。full はモデルの一覧も集める。
# $(...) の中で呼ばない。引数: quick か full、出力ファイル
collect_snapshot() {
  local mode="$1" out="$2"
  local codex_ver="" cursor_ver="" codex_models="" codex_default="" cursor_models=""
  local home cache toml raw now tmpm

  SNAP_FAILED=""
  # $(...) の中の die は呼び出し元を止めないので、先に日付を確かめる
  now="$(today)" || return 1

  if command -v codex >/dev/null 2>&1; then
    codex_ver="$(tool_version codex)" || true
    [ -n "$codex_ver" ] || SNAP_FAILED="${SNAP_FAILED:+$SNAP_FAILED }tool.codex.version"
  fi
  if command -v cursor-agent >/dev/null 2>&1; then
    cursor_ver="$(tool_version cursor)" || true
    [ -n "$cursor_ver" ] || SNAP_FAILED="${SNAP_FAILED:+$SNAP_FAILED }tool.cursor.version"
  fi

  if [ "$mode" = "full" ]; then
    if command -v codex >/dev/null 2>&1; then
      home="${CODEX_HOME:-$HOME/.codex}"
      cache="$home/models_cache.json"
      toml="$home/config.toml"
      if command -v jq >/dev/null 2>&1 && [ -r "$cache" ]; then
        raw="$(jq -r '[.models[] | select(.visibility == "list")] | sort_by(.priority) | .[].slug' "$cache" 2>/dev/null)" || raw=""
        if [ -n "$raw" ]; then
          codex_models="$(printf '%s\n' "$raw" | paste -sd, -)"
        fi
      fi
      [ -n "$codex_models" ] || SNAP_FAILED="${SNAP_FAILED:+$SNAP_FAILED }codex.models"
      if [ -r "$toml" ]; then
        codex_default="$(awk '
          /^[[:space:]]*\[/ { exit }
          /^[[:space:]]*model[[:space:]]*=[[:space:]]*"[^"]*"/ {
            s = $0
            sub(/^[^"]*"/, "", s)
            sub(/".*$/, "", s)
            print s
            exit
          }' "$toml")"
      fi
      if [ -z "$codex_default" ]; then codex_default="${codex_models%%,*}"; fi
      [ -n "$codex_default" ] || SNAP_FAILED="${SNAP_FAILED:+$SNAP_FAILED }codex.default-model"
    fi
    if command -v cursor-agent >/dev/null 2>&1; then
      # 版と同じく、出力は一時ファイルで受ける（tool_version のコメントを参照）。
      # 期限を付ける道具が無ければ呼ばない
      if have_timeout_tool; then
        tmpm="$(mktemp)" || tmpm=""
        if [ -n "$tmpm" ]; then
          if run_with_timeout 20 cursor-agent models > "$tmpm" 2>/dev/null < /dev/null; then
            raw="$(grep -E '^[a-z0-9][a-z0-9._-]* - ' "$tmpm" | sed 's/ - .*//' || true)"
            if [ -n "$raw" ]; then
              cursor_models="$(printf '%s\n' "$raw" | paste -sd, -)"
            fi
          fi
          rm -f "$tmpm"
        fi
      fi
      [ -n "$cursor_models" ] || SNAP_FAILED="${SNAP_FAILED:+$SNAP_FAILED }cursor.models"
    fi
  fi

  {
    echo "saved=$now"
    if [ -n "$codex_ver" ]; then echo "tool.codex.version=$codex_ver"; fi
    if [ -n "$cursor_ver" ]; then echo "tool.cursor.version=$cursor_ver"; fi
    if [ -n "$codex_default" ]; then echo "codex.default-model=$codex_default"; fi
    if [ -n "$codex_models" ]; then echo "codex.models=$codex_models"; fi
    if [ -n "$cursor_models" ]; then echo "cursor.models=$cursor_models"; fi
  } > "$out"
}

# 記録の一時ファイルを、記録と同じフォルダに作ってパスを出す（mv や ln を同じ場所で行うため）
snapshot_tmp() {
  local dir
  dir="$(state_dir)"
  mkdir -p "$dir" || return 1
  mktemp "$dir/.tmp.XXXXXX"
}

# 一時ファイルで記録を置き換える（mv）。引数: 一時ファイル
snapshot_replace() {
  mv -f "$1" "$(snapshot_file)"
}

# 記録が無いときだけ作る。すでにあれば何もせず 1 を返す（ln は宛先があると失敗する）。
# 一時ファイルは、成否にかかわらず消す。引数: 一時ファイル
snapshot_create() {
  local st=0
  ln "$1" "$(snapshot_file)" 2>/dev/null || st=$?
  rm -f "$1"
  return "$st"
}

# 見直しの日付（config/review-dates.conf）のうち、saved < 日付 <= 今日 の行を、そのまま1行ずつ出す。
# 形（YYYY-MM-DD の後ろに空白と文）が違う行と、# で始まる行は無視する。
# 引数: saved 今日
due_dates() {
  local saved="$1" now="$2" file line d rest
  file="$DEV_RELAY_ROOT/config/review-dates.conf"
  [ -f "$file" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in ''|'#'*) continue ;; esac
    d="${line%%[[:space:]]*}"
    days_from_date "$d" >/dev/null || continue
    rest="${line#"$d"}"
    rest="${rest#"${rest%%[![:space:]]*}"}"
    [ -n "$rest" ] || continue
    if [[ "$d" > "$saved" ]] && ! [[ "$d" > "$now" ]]; then
      printf '%s\n' "$line"
    fi
  done < "$file"
}
