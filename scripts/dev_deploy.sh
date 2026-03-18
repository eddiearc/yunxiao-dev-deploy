#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/common.sh"

usage() {
  cat <<'EOF'
Usage:
  dev_deploy.sh latest [--pipeline-link URL]
  dev_deploy.sh run [--pipeline-link URL] [--comment TEXT] [--dry-run] [--wait]

Examples:
  dev_deploy.sh latest
  dev_deploy.sh run
  dev_deploy.sh run --dry-run
  dev_deploy.sh run --pipeline-link "https://flow.aliyun.com/pipelines/123456/current"
  dev_deploy.sh run --comment "dev deploy from codex"
EOF
}

command="run"
pipeline_link=""
comment=""
dry_run="false"
wait_after_run="false"

if [[ $# -gt 0 ]]; then
  case "$1" in
    latest|run)
      command="$1"
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
  esac
fi

while [[ $# -gt 0 ]]; do
  case "$1" in
    --pipeline-link)
      pipeline_link="${2:-}"
      shift 2
      ;;
    --comment)
      comment="${2:-}"
      shift 2
      ;;
    --dry-run)
      dry_run="true"
      shift
      ;;
    --wait)
      wait_after_run="true"
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      die "未知参数: $1"
      ;;
  esac
done

load_project_env
ensure_yunxiao_token

organization_id="$(resolve_organization_id)"
pipeline_id="$(resolve_pipeline_id "$pipeline_link")"
fetch_pipeline_detail "$organization_id" "$pipeline_id"

pipeline_name="$(printf '%s' "$API_BODY" | jq -r '.name // ""')"
block_if_prod_pipeline "$pipeline_name"

latest_summary_json="$(fetch_latest_successful_run_summary "$organization_id" "$pipeline_id")"
latest_run_id="$(printf '%s' "$latest_summary_json" | jq -r '.pipelineRunId // empty')"
latest_release_branch="$(printf '%s' "$latest_summary_json" | jq -r '.releaseBranch // ""')"
latest_branches="$(printf '%s' "$latest_summary_json" | jq -r '(.branches // []) | join(", ")')"
running_run_id="$(fetch_latest_running_run_id "$organization_id" "$pipeline_id")"

if [[ "$command" == "latest" ]]; then
  printf 'pipeline=%s\n' "$pipeline_name"
  printf 'pipeline_id=%s\n' "$pipeline_id"
  printf 'latest_success_run_id=%s\n' "${latest_run_id:-none}"
  printf 'latest_release_branch=%s\n' "${latest_release_branch:-none}"
  printf 'latest_integrated_branches=%s\n' "${latest_branches:-none}"

  # Get current branch for deployment status check
  current_branch_for_check="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || true)"
  if [[ -n "$current_branch_for_check" && "$current_branch_for_check" != "HEAD" ]]; then
    latest_deploy_time="$(printf '%s' "$latest_summary_json" | jq -r '.createTime // empty')"
    if [[ -n "$latest_deploy_time" ]]; then
      printf 'latest_deploy_time=%s\n' "$latest_deploy_time"
    fi

    last_commit_time="$(git log -1 --format=%ci HEAD 2>/dev/null || true)"
    if [[ -n "$last_commit_time" ]]; then
      printf 'last_commit_time=%s\n' "$last_commit_time"
    fi

    if check_if_latest_commit_deployed "$latest_summary_json" "$current_branch_for_check"; then
      printf 'latest_commit_deployed=true\n'
    else
      printf 'latest_commit_deployed=false\n'
    fi
  fi

  if [[ -n "$running_run_id" ]]; then
    running_run_detail="$(fetch_pipeline_run_detail "$organization_id" "$pipeline_id" "$running_run_id")"
    blocking_json="$(extract_blocking_actions "$running_run_detail")"
    blocking_count="$(printf '%s' "$blocking_json" | jq 'length')"
    printf 'running_run_id=%s\n' "$running_run_id"
    if [[ "$blocking_count" -gt 0 ]]; then
      printf 'running_run_blocked=true\n'
      printf 'running_run_blocking_summary=%s\n' "$(format_blocking_summary "$blocking_json" | paste -sd ';' -)"
      printf 'running_run_action=请到云效页面处理阻塞后再继续: https://flow.aliyun.com/pipelines/%s/current\n' "$pipeline_id"
    else
      printf 'running_run_blocked=false\n'
    fi
  fi
  exit 0
fi

current_branch="$(ensure_branch_ready_for_dev_deploy)"
run_comment="$comment"
if [[ -z "$run_comment" ]]; then
  run_comment="dev deploy from codex: ${current_branch}"
fi

params_json="$(build_branch_mode_payload "$latest_summary_json" "$current_branch" "$run_comment")"
merged_branches="$(printf '%s' "$params_json" | jq -r '.branchModeBranchs | join(", ")')"

printf 'pipeline=%s\n' "$pipeline_name"
printf 'pipeline_id=%s\n' "$pipeline_id"
printf 'current_branch=%s\n' "$current_branch"
printf 'latest_success_run_id=%s\n' "${latest_run_id:-none}"
printf 'latest_release_branch=%s\n' "${latest_release_branch:-none}"
printf 'latest_integrated_branches=%s\n' "${latest_branches:-none}"
printf 'next_integrated_branches=%s\n' "$merged_branches"
printf 'params=%s\n' "$params_json"

if [[ "$dry_run" == "true" ]]; then
  exit 0
fi

run_response="$(trigger_pipeline_run "$organization_id" "$pipeline_id" "$params_json")"
run_id="$(printf '%s' "$run_response" | jq -r '.pipelineRunId // .id // .runId // empty')"

printf 'triggered_pipeline_run_id=%s\n' "${run_id:-unknown}"
printf 'trigger_response=%s\n' "$run_response"

if [[ -n "$run_id" ]]; then
  run_detail="$(fetch_pipeline_run_detail "$organization_id" "$pipeline_id" "$run_id")"
  blocking_json="$(extract_blocking_actions "$run_detail")"
  blocking_count="$(printf '%s' "$blocking_json" | jq 'length')"
  if [[ "$blocking_count" -gt 0 ]]; then
    printf 'triggered_run_blocked=true\n'
    printf 'triggered_run_blocking_summary=%s\n' "$(format_blocking_summary "$blocking_json" | paste -sd ';' -)"
    printf 'triggered_run_action=请到云效页面处理阻塞后再继续: https://flow.aliyun.com/pipelines/%s/current\n' "$pipeline_id"
  fi
fi

if [[ "$wait_after_run" == "true" && -n "$run_id" ]]; then
  bash "${SCRIPT_DIR}/wait_pipeline_run.sh" "$run_id"
fi
