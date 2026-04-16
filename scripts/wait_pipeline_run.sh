#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/common.sh"

if [[ $# -lt 1 || $# -gt 2 ]]; then
  cat >&2 <<'EOF'
Usage:
  wait_pipeline_run.sh PIPELINE_RUN_ID [POLL_SECONDS]
EOF
  exit 1
fi

run_id="$1"
poll_seconds="${2:-15}"

load_project_env
ensure_yunxiao_token

organization_id="$(resolve_organization_id)"
pipeline_id="$(resolve_pipeline_id)"

while true; do
  run_detail="$(fetch_pipeline_run_detail "$organization_id" "$pipeline_id" "$run_id")"
  status="$(printf '%s' "$run_detail" | jq -r '.status // "UNKNOWN"')"
  printf 'pipeline_run_id=%s status=%s\n' "$run_id" "$status"

  if [[ "$status" == "RUNNING" ]]; then
    blocking_json="$(extract_blocking_actions "$run_detail")"
    blocking_count="$(printf '%s' "$blocking_json" | jq 'length')"
    if [[ "$blocking_count" -gt 0 ]]; then
      printf 'blocked=true\n'
      printf 'blocking_summary=%s\n' "$(format_blocking_summary "$blocking_json" | paste -sd ';' -)"
      printf 'resolution_options=release_branch,original_branch_requires_confirmation\n'
      printf 'action=如果是 CONFLICT_MERGE，默认优先在 releaseBranch 解决并重跑；若需要改 original_branch/featureBranch，必须先得到用户明确答复。云效页面: https://flow.aliyun.com/pipelines/%s/current\n' "$pipeline_id"
      exit 2
    fi
  fi

  case "$status" in
    SUCCESS|FAIL|FAILED|CANCELED|ABORTED|TERMINATED)
      exit 0
      ;;
  esac

  sleep "$poll_seconds"
done
