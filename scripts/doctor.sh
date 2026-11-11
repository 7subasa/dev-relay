#!/usr/bin/env bash
# 道具の状態、設定、役割ごとに選ばれるレビュアーを key=value で1行ずつ出す。
# 使い方: dev-relay doctor
# 終了コードは常に 0（役割のファイルが壊れているなどの内部エラーを除く）。

set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
source "$(dirname "${BASH_SOURCE[0]}")/lib/resolve.sh"
source "$(dirname "${BASH_SOURCE[0]}")/lib/gh.sh"

case "${1:-}" in
  "") ;;
  -h|--help) sed -n '2,4p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
  *) die "doctor は引数を取りません: $1" ;;
esac

probe_tools
probe_gh
load_vendors

echo "tool.codex=${TOOL_CODEX}"
if [ "$TOOL_CODEX" != "not-installed" ]; then
  echo "tool.codex.version=$(tool_version codex || true)"
fi
echo "tool.cursor=${TOOL_CURSOR}"
if [ "$TOOL_CURSOR" != "not-installed" ]; then
  echo "tool.cursor.version=$(tool_version cursor || true)"
fi
echo "tool.gh=${TOOL_GH}"
if [ "$TOOL_GH" != "not-installed" ]; then
  echo "tool.gh.version=$(gh_version || true)"
fi
echo "tool.jq=${TOOL_JQ}"
echo "tool.herdr=${TOOL_HERDR}"
if [ -n "${HC_TERMINAL_ID:-}" ] && [ "$TOOL_HERDR" = "ok" ]; then
  echo "tool.herdr.inside=yes"
else
  echo "tool.herdr.inside=no"
fi

if in_git_repo; then
  echo "git.repo=yes"
  echo "git.dirty=$(git status --porcelain | wc -l | tr -d ' ')"
  echo "repo.pr=$(pr_allowed_get)"
else
  echo "git.repo=no"
fi

echo "config.dir=$(config_dir)"
echo "config.metered=$(config_get metered off)"
echo "config.notice=$(config_get notice on)"
echo "config.vendors=${VENDORS_USER}"
echo "repo.vendors=${VENDORS_ALLOWED:-none}"
echo "repo.vendors.source=${VENDORS_SOURCE}"

report_role() {
  local role="$1" only="${2:-}" exclude="${3:-}"
  if resolve_role "$role" "$only" "$exclude"; then
    echo "role.${role}=${R_ID}"
    echo "role.${role}.backend=${R_BACKEND}"
  else
    echo "role.${role}=none"
    echo "role.${role}.backend=none"
  fi
  echo "role.${role}.source=$(role_source "$role")"
  if [ "$(role_source "$role")" = "override" ]; then
    echo "role.${role}.override=$(role_override_state "$role")"
  fi
  echo "role.${role}.skipped=${R_SKIPPED}"
}

report_role design-review
report_role code-review
# 追加のレビュアーは、通常のコードレビューで選ばれる id を除外して決める
PRIMARY=""
if resolve_role code-review; then PRIMARY="$R_ID"; fi
report_role code-review-extra "" "$PRIMARY"
