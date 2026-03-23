#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/common.sh"

if [[ $# -lt 1 ]]; then
  cat >&2 <<'EOF'
Usage:
  cancel_pipeline_run.sh PIPELINE_RUN_ID [--reason TEXT]
EOF
  exit 1
fi

run_id="$1"
shift || true

reason=""
if [[ $# -gt 0 ]]; then
  case "$1" in
    --reason)
      reason="${2:-}"
      ;;
    *)
      die "未知参数: $1"
      ;;
  esac
fi

load_project_env
ensure_yunxiao_token

organization_id="$(resolve_organization_id)"
pipeline_id="$(resolve_pipeline_id)"
run_detail="$(fetch_pipeline_run_detail "$organization_id" "$pipeline_id" "$run_id")"
status_before="$(printf '%s' "$run_detail" | jq -r '.status // ""')"

printf 'pipeline_id=%s\n' "$pipeline_id"
printf 'pipeline_run_id=%s\n' "$run_id"
printf 'status_before=%s\n' "${status_before:-unknown}"

case "$status_before" in
  SUCCESS|FAILED|CANCELED|ABORTED|TERMINATED)
    printf 'skip_reason=already_finished\n'
    exit 0
    ;;
esac

blocking_json="$(extract_blocking_actions "$run_detail")"
blocking_count="$(printf '%s' "$blocking_json" | jq 'length')"
if [[ "$blocking_count" -gt 0 ]]; then
  printf 'blocking_summary=%s\n' "$(format_blocking_summary "$blocking_json" | paste -sd ';' -)"
fi

if [[ -n "$reason" ]]; then
  printf 'reason=%s\n' "$reason"
fi

terminate_response="$(terminate_pipeline_run "$organization_id" "$pipeline_id" "$run_id")"
printf 'terminate_response=%s\n' "$terminate_response"

updated_detail="$(fetch_pipeline_run_detail "$organization_id" "$pipeline_id" "$run_id")"
printf 'status_after=%s\n' "$(printf '%s' "$updated_detail" | jq -r '.status // ""')"
