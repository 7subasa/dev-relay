#!/usr/bin/env bash
# 本物のレビュアーを、作り物の差分に対して動かし、指定の出力形式で指摘が返るかを確かめる。
#
# 使い方:
#   dev-relay smoke [--reviewer ID]... [--vendors <一覧|none>]
#   dev-relay smoke check <結果ファイル>
#
#   smoke        3つの役割（設計レビュー、コードレビュー、追加のコードレビュー）の候補を、
#                同じ id は1回だけ、同時に動かす。題材は tests/smoke/ の小さいリポジトリ。
#                結果は <設定フォルダ>/state/smoke/<実行の id>/ に残す（7日より古い実行のフォルダは消す）。
#   --reviewer   この id の候補だけを動かす（何度でも指定できる）。
#   --vendors    差分を送ってよい提供元を、この実行に限って置き換える。
#                省略時は、実行したフォルダで有効な許可をそのまま使う。metered は設定のまま。
#   smoke check  結果ファイルが出力形式どおりかを調べる。ネットワークは使わない。
#
# 状態は pass / fail / skipped / pending。pending は backend が claude の候補で、
# 依頼文を書いて止まる（Agent ツールで動かし、返った本文を .out に書いてから smoke check で調べる）。
# 終了コード: 0 fail が無い（smoke check は合格）/ 1 引数や前提の誤り / 2 fail がある（smoke check は不合格）
# 環境変数: DEV_RELAY_TIMEOUT（候補1件の期限。秒。既定 300）

set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
source "$(dirname "${BASH_SOURCE[0]}")/lib/resolve.sh"
source "$(dirname "${BASH_SOURCE[0]}")/lib/backends.sh"
source "$(dirname "${BASH_SOURCE[0]}")/lib/state.sh"

usage() { sed -n '2,19p' "$0" | sed 's/^# \{0,1\}//'; }

# ---- 結果ファイルの調べ方（smoke と smoke check で共通） -----------------------

# 結果ファイルを調べ、次の変数に入れる（$(...) の中で呼ばない）:
#   CHK_FINDINGS  指摘の数
#   CHK_SEEDED    仕込んだ不具合に触れた数（<n>/2）
#   CHK_REASONS   不合格の理由を ; でつないだもの（合格なら空）
# awk は、全角文字を [...] の中に書かない（バイト単位で扱う awk があり、ほかの文字を壊す）。
check_result() {
  local file="$1" out line key val findings=0 missing="" verdict=0 seeded=0
  out="$(awk '
    BEGIN {
      items[1] = "重要度"; items[2] = "場所"; items[3] = "再現"; items[4] = "確認状況"
      v1 = "要修正あり"; v2 = "ブロッカーなし"
    }
    # フェンスの行。フェンスの中の行は、見出し・項目・判定として数えない
    /^[[:space:]]*```/ {
      infence = !infence
      if (inblk) text[n] = text[n] "\n" $0
      next
    }
    infence { if (inblk) text[n] = text[n] "\n" $0; next }
    # 指摘のブロックの始まり
    /^###[[:space:]]+[0-9]/ {
      n++; inblk = 1; text[n] = $0; verdict = 0
      for (k = 1; k <= 4; k++) have[n, k] = 0
      next
    }
    {
      if ($0 ~ /^#[#]?[#]?[#]?[#]?[#]?[[:space:]]/ || $0 ~ /^---[[:space:]]*$/) {
        inblk = 0
      } else if (inblk) {
        text[n] = text[n] "\n" $0
        if (match($0, /^[[:space:]]*[-*][[:space:]]*\**/)) {
          rest = substr($0, RLENGTH + 1)
          for (k = 1; k <= 4; k++) if (index(rest, items[k]) == 1) have[n, k] = 1
        }
      }
      # 判定の行: 最後のブロックの見出しより後ろで、前後の空白と飾りを除くと、2つの語のどちらかにちょうど一致する行
      if (n > 0) {
        t = $0
        sub(/^([[:space:]]|[*_`]|「|」|。)+/, "", t)
        sub(/([[:space:]]|[*_`]|「|」|。)+$/, "", t)
        if (t == v1 || t == v2) verdict++
      }
    }
    END {
      print "findings=" (n + 0)
      miss = ""
      for (b = 1; b <= n && miss == ""; b++)
        for (k = 1; k <= 4; k++)
          if (!have[b, k]) miss = miss (miss == "" ? "" : ",") items[k]
      print "missing=" miss
      print "verdict=" verdict
      s1 = 0; s2 = 0
      for (b = 1; b <= n; b++) {
        t = tolower(text[b])
        if (index(t, "偶数") > 0 || t ~ /(^|[^a-z])even([^a-z]|$)/) s1 = 1
        if (index(t, "空のリスト") > 0 || index(t, "空リスト") > 0 || index(t, "空の入力") > 0 \
            || index(t, "empty") > 0 || index(t, "indexerror") > 0) s2 = 1
      }
      print "seeded=" (s1 + s2)
    }
  ' "$file")"
  while IFS= read -r line; do
    key="${line%%=*}"; val="${line#*=}"
    case "$key" in
      findings) findings="$val" ;;
      missing)  missing="$val" ;;
      verdict)  verdict="$val" ;;
      seeded)   seeded="$val" ;;
    esac
  done <<EOF
$out
EOF
  CHK_FINDINGS="$findings"
  CHK_SEEDED="${seeded}/2"
  CHK_REASONS=""
  if [ "$findings" -eq 0 ]; then
    CHK_REASONS="no-findings"
    return 0
  fi
  if [ -n "$missing" ]; then CHK_REASONS="fields-missing:${missing}"; fi
  if [ "$verdict" -lt 1 ]; then CHK_REASONS="${CHK_REASONS:+$CHK_REASONS;}no-verdict"; fi
  if [ "$seeded" -lt 1 ]; then CHK_REASONS="${CHK_REASONS:+$CHK_REASONS;}seeded-0"; fi
  return 0
}

smoke_check() {
  [ $# -eq 1 ] || die "smoke check の引数は結果ファイル1つです"
  [ -f "$1" ] || die "結果ファイルが見つかりません: $1"
  check_result "$1"
  if [ -z "$CHK_REASONS" ]; then
    echo "check=pass"
  else
    echo "check=fail"
    echo "check.reason=${CHK_REASONS}"
  fi
  echo "check.findings=${CHK_FINDINGS}"
  echo "check.seeded=${CHK_SEEDED}"
  [ -z "$CHK_REASONS" ] || exit 2
}

# ---- smoke ------------------------------------------------------------------

# 題材のリポジトリを作る。引数: ディレクトリ 許可
# メールアドレスの形は公開前の確認に掛かるので、2つの文字列をつないで作る
make_subject() {
  local dir="$1" vendors="$2" email
  email="smoke@""users.noreply.github.com"
  mkdir -p "$dir"
  (
    cd "$dir"
    git init -q
    git config user.name dev-relay-smoke
    git config user.email "$email"
    git config commit.gpgsign false
    git config dev-relay.vendors "$vendors"
    cp -R "$DEV_RELAY_ROOT/tests/smoke/base/." .
    git add -A
    git -c core.hooksPath=/dev/null commit -qm base
    cp -R "$DEV_RELAY_ROOT/tests/smoke/change/." .
  )
}

# 候補1件を動かす。バックグラウンドのサブシェルで呼ぶ。引数: ディレクトリ id
run_candidate() {
  local dir="$1" id="$2" st=0
  cd "$dir/repo"
  worktree_manifest > ../before
  DEV_RELAY_CONFIG_DIR="$dir/cfg" DEV_RELAY_TIMEOUT="${DEV_RELAY_TIMEOUT:-300}" \
    bash "$DEV_RELAY_ROOT/scripts/review.sh" code \
    --intent "$(cat "$DEV_RELAY_ROOT/tests/smoke/intent.txt")" \
    --reviewer "$id" --out "$dir/result.md" > ../stdout 2> ../stderr || st=$?
  echo "$st" > ../exit
  worktree_manifest > ../after
}

smoke_run() {
  local only=" " vendors_opt="" have_vendors_opt=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --reviewer)
        [ $# -ge 2 ] || die "--reviewer には id が必要です"
        case "$2" in ''|*[!a-z0-9-]*) die "--reviewer の id の形が不正です（小文字の英数字とハイフン）: $2" ;; esac
        only="${only}$2 "; shift 2 ;;
      --vendors)  [ $# -ge 2 ] || die "--vendors には一覧か none が必要です"; vendors_opt="$2"; have_vendors_opt=1; shift 2 ;;
      -h|--help)  usage; exit 0 ;;
      *) die "unknown argument: $1" ;;
    esac
  done

  # 1. 引数と前提の検査
  if [ "$have_vendors_opt" -eq 1 ] && [ "$vendors_opt" != "none" ]; then
    valid_vendor_list "$vendors_opt" || die "--vendors は none か、提供元の小文字の名前をカンマで区切った一覧です（ask は使えません）: $vendors_opt"
  fi
  case "${DEV_RELAY_TIMEOUT:-300}" in
    ''|0*|*[!0-9]*) die "DEV_RELAY_TIMEOUT は正の整数（秒）で指定してください: ${DEV_RELAY_TIMEOUT:-300}" ;;
  esac
  have_timeout_tool || die "timeout も gtimeout も perl も見つかりません。レビューに期限を付けられないので実行しません。"
  command -v git >/dev/null 2>&1 || die "git が見つかりません"

  # 2. 差分を送ってよい提供元
  local vendors
  if [ "$have_vendors_opt" -eq 1 ]; then
    vendors="$vendors_opt"
  else
    load_vendors
    vendors="${VENDORS_ALLOWED:-none}"
  fi

  # これ以降は題材のリポジトリだけを操作する。実行元のリポジトリを指す環境変数（GIT_DIR など）を外す
  # （残っていると、git init や git commit が題材ではなく、そのリポジトリに対して動く）
  # shellcheck disable=SC2046
  unset $(git rev-parse --local-env-vars)

  # 3. 作業フォルダ。ほかの実行のフォルダは消さない（同時に動いている実行や、確認待ちの依頼文を残すため）。
  # 7日より古いものだけ、パスを確かめてから消す
  local base run_dir d
  base="$(state_dir)/smoke"
  case "$base" in
    */state/smoke) ;;
    *) die "作業フォルダのパスが想定と違うので、古いフォルダを消しません: $base" ;;
  esac
  if [ -d "$base" ]; then
    find "$base" -mindepth 1 -maxdepth 1 -type d -mtime +7 -print0 | while IFS= read -r -d '' d; do
      rm -rf -- "$d"
    done
  fi
  run_dir="$base/$(timestamp)-$$"
  mkdir -p "$run_dir"
  run_dir="$(cd "$run_dir" && pwd)"

  # 4. 候補を集める。id がすでに出た候補は飛ばす。ただし定義（5列）が先に出たものと違えば die
  local role rows row id backend model effort billing vendors_col extra def j
  local n=0 i
  local -a C_ID C_ROLE C_BACKEND C_MODEL C_EFFORT C_BILLING C_VENDORS C_DEF C_REASONS
  for role in $ROLES; do
    rows="$(read_role_file "$(role_file "$role")")" || exit 1
    while IFS= read -r row; do
      [ -n "$row" ] || continue
      read -r id backend model effort billing vendors_col extra <<EOF
$row
EOF
      def="${backend} ${model} ${effort} ${billing} ${vendors_col}"
      for ((j = 0; j < n; j++)); do
        [ "${C_ID[$j]}" = "$id" ] || continue
        [ "${C_DEF[$j]}" = "$def" ] \
          || die "id ${id} は役割 ${C_ROLE[$j]} で別の定義に使われています。同じ id は同じ定義にするか、別の id を付けてください"
        continue 2
      done
      C_ID[$n]="$id"; C_ROLE[$n]="$role"; C_BACKEND[$n]="$backend"; C_MODEL[$n]="$model"
      C_EFFORT[$n]="$effort"; C_BILLING[$n]="$billing"; C_VENDORS[$n]="$vendors_col"; C_DEF[$n]="$def"
      n=$((n + 1))
    done <<EOF
$rows
EOF
  done

  # --reviewer は id で絞る。どの役割にも無い id は die
  if [ "$only" != " " ]; then
    local keep=0 found
    for id in $only; do
      found=0
      for ((i = 0; i < n; i++)); do
        if [ "${C_ID[$i]}" = "$id" ]; then found=1; fi
      done
      [ "$found" -eq 1 ] || die "どの役割にも id ${id} の候補はありません"
    done
    for ((i = 0; i < n; i++)); do
      case "$only" in
        *" ${C_ID[$i]} "*)
          C_ID[$keep]="${C_ID[$i]}"; C_ROLE[$keep]="${C_ROLE[$i]}"; C_BACKEND[$keep]="${C_BACKEND[$i]}"
          C_MODEL[$keep]="${C_MODEL[$i]}"; C_EFFORT[$keep]="${C_EFFORT[$i]}"; C_BILLING[$keep]="${C_BILLING[$i]}"
          C_VENDORS[$keep]="${C_VENDORS[$i]}"
          keep=$((keep + 1)) ;;
      esac
    done
    n="$keep"
  fi

  # 5. 道具の状態。許可は手順2の値にそろえる
  probe_tools
  if [ "$vendors" = "none" ]; then VENDORS_ALLOWED=""; else VENDORS_ALLOWED="$vendors"; fi

  # 6. 候補ごとに、題材と、その候補だけを code-review の候補にした設定フォルダを作る。
  # 使えない理由があれば skipped
  local dir metered
  metered="$(config_get metered off)"
  for ((i = 0; i < n; i++)); do
    dir="$run_dir/${C_ID[$i]}"
    make_subject "$dir/repo" "$vendors"
    mkdir -p "$dir/cfg/roles"
    printf '%s %s %s %s %s %s\n' "${C_ID[$i]}" "${C_BACKEND[$i]}" "${C_MODEL[$i]}" "${C_EFFORT[$i]}" \
      "${C_BILLING[$i]}" "${C_VENDORS[$i]}" > "$dir/cfg/roles/code-review.conf"
    printf '%s\n' "$metered" > "$dir/cfg/metered"
    C_REASONS[$i]="$(cd "$dir/repo" && DEV_RELAY_CONFIG_DIR="$dir/cfg" candidate_reasons "${C_BACKEND[$i]}" "${C_BILLING[$i]}" "${C_VENDORS[$i]}")"
  done

  # 7. 使える候補を同時に動かし、全部を待つ
  local started=0
  for ((i = 0; i < n; i++)); do
    [ -z "${C_REASONS[$i]}" ] || continue
    ( run_candidate "$run_dir/${C_ID[$i]}" "${C_ID[$i]}" ) &
    started=$((started + 1))
  done
  if [ "$started" -gt 0 ]; then
    echo "${started} 件のレビュアーを同時に動かしています（期限 ${DEV_RELAY_TIMEOUT:-300} 秒）..." >&2
  fi
  wait

  # 8. 候補の順に結果を決めて出す
  local failed=0 st state reasons name
  echo "smoke.dir=${run_dir}"
  echo "smoke.vendors=${vendors}"
  for ((i = 0; i < n; i++)); do
    name="${C_ID[$i]}"
    dir="$run_dir/$name"
    if [ -n "${C_REASONS[$i]}" ]; then
      echo "smoke.${name}=skipped"
      echo "smoke.${name}.role=${C_ROLE[$i]}"
      echo "smoke.${name}.reason=${C_REASONS[$i]}"
      continue
    fi
    st=1
    if [ -f "$dir/exit" ]; then IFS= read -r st < "$dir/exit" || st=1; fi
    if [ "$st" = "3" ]; then
      echo "smoke.${name}=pending"
      echo "smoke.${name}.role=${C_ROLE[$i]}"
      echo "smoke.${name}.prompt=${dir}/result.prompt.md"
      echo "smoke.${name}.out=${dir}/result.md"
      continue
    fi
    reasons=""
    if [ "$st" != "0" ]; then
      reasons="exit:${st}"
    else
      if [ -f "$dir/result.md" ]; then
        check_result "$dir/result.md"
        reasons="$CHK_REASONS"
      else
        reasons="no-findings"
      fi
      if ! cmp -s "$dir/before" "$dir/after"; then reasons="${reasons:+$reasons;}worktree-changed"; fi
    fi
    if [ -z "$reasons" ]; then state="pass"; else state="fail"; failed=1; fi
    echo "smoke.${name}=${state}"
    echo "smoke.${name}.role=${C_ROLE[$i]}"
    if [ "$state" = "fail" ]; then echo "smoke.${name}.reason=${reasons}"; fi
    if [ "$st" = "0" ] && [ -f "$dir/result.md" ]; then
      echo "smoke.${name}.findings=${CHK_FINDINGS}"
      echo "smoke.${name}.seeded=${CHK_SEEDED}"
    fi
    if [ -f "$dir/result.md" ]; then echo "smoke.${name}.result=${dir}/result.md"; fi
  done

  # 9. 終了コード
  if [ "$failed" -eq 1 ]; then exit 2; fi
  exit 0
}

case "${1:-}" in
  check) shift; smoke_check "$@" ;;
  *) smoke_run "$@" ;;
esac
