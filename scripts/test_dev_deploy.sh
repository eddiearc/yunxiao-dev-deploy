#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/common.sh"

assert_eq() {
  local expected="$1"
  local actual="$2"
  local message="$3"
  if [[ "$expected" != "$actual" ]]; then
    echo "assertion failed: ${message}" >&2
    echo "expected: ${expected}" >&2
    echo "actual:   ${actual}" >&2
    exit 1
  fi
}

test_default_payload_appends_without_dropping() {
  local latest_summary_json
  local payload_json
  local branches

  latest_summary_json='{"branches":["feature-a","feature-b"]}'
  payload_json="$(build_branch_mode_payload "$latest_summary_json" "feature-c" "test-comment")"
  branches="$(printf '%s' "$payload_json" | jq -c '.branchModeBranchs')"
  assert_eq '["feature-a","feature-b","feature-c"]' "$branches" "default payload should append current branch"
}

test_deleted_remote_branches_are_pruned_before_building_payload() {
  local original_remote_branch_exists
  local prune_json
  local sanitized_latest_summary_json
  local payload_json
  local kept
  local removed
  local branches

  original_remote_branch_exists="$(declare -f remote_branch_exists)"
  remote_branch_exists() {
    [[ "$1" != "feature-deleted" ]]
  }

  prune_json="$(prune_deleted_remote_branches '["feature-a","feature-deleted","feature-b"]')"
  kept="$(printf '%s' "$prune_json" | jq -c '.kept')"
  removed="$(printf '%s' "$prune_json" | jq -c '.removed')"
  assert_eq '["feature-a","feature-b"]' "$kept" "existing branches should be kept"
  assert_eq '["feature-deleted"]' "$removed" "deleted branches should be removed"

  sanitized_latest_summary_json="$(sanitize_latest_summary_branches '{"branches":["feature-a","feature-deleted","feature-b"]}' "$prune_json")"
  payload_json="$(build_branch_mode_payload "$sanitized_latest_summary_json" "feature-c" "test-comment")"
  branches="$(printf '%s' "$payload_json" | jq -c '.branchModeBranchs')"
  assert_eq '["feature-a","feature-b","feature-c"]' "$branches" "deleted branches should not be carried into the next deploy payload"

  eval "$original_remote_branch_exists"
}

test_shrink_requires_explicit_override() {
  local latest_summary_json
  local payload_json

  latest_summary_json='{"branches":["feature-a","feature-b"]}'
  payload_json="$(build_exact_branch_mode_payload '["feature-a"]' "test-comment")"

  if (
    ensure_branch_set_not_shrunk "$latest_summary_json" "$payload_json" "false"
  ) >/tmp/test_dev_deploy.out 2>/tmp/test_dev_deploy.err; then
    echo "expected shrink protection to fail without allow-shrink" >&2
    exit 1
  fi

  if ! grep -q "默认禁止静默 shrink" /tmp/test_dev_deploy.err; then
    echo "expected shrink protection error message" >&2
    cat /tmp/test_dev_deploy.err >&2
    exit 1
  fi

  ensure_branch_set_not_shrunk "$latest_summary_json" "$payload_json" "true"
}

test_parse_branch_list_csv_dedupes_and_trims() {
  local result

  result="$(parse_branch_list_csv ' feature-a,feature-b , feature-a ,,feature-c ')"
  assert_eq '["feature-a","feature-b","feature-c"]' "$result" "csv parsing should trim and dedupe"
}

test_extract_triggered_run_id_supports_multiple_shapes() {
  assert_eq '1031' "$(extract_triggered_run_id '1031')" "numeric response should be supported"
  assert_eq '1032' "$(extract_triggered_run_id '"1032"')" "string response should be supported"
  assert_eq '1033' "$(extract_triggered_run_id '{"pipelineRunId":1033}')" "object pipelineRunId should be supported"
  assert_eq '1034' "$(extract_triggered_run_id '{"data":{"runId":1034}}')" "nested object runId should be supported"
}

test_detect_pipeline_trigger_mode() {
  local branch_mode_detail
  local running_branch_detail

  branch_mode_detail='{"pipelineConfig":{"sources":[{"data":{"repo":"https://github.com/acme/api.git","isBranchMode":true}}]}}'
  running_branch_detail='{"pipelineConfig":{"sources":[{"data":{"repo":"https://github.com/acme/api.git","isBranchMode":null}}]}}'

  assert_eq 'branch_mode' "$(detect_pipeline_trigger_mode "$branch_mode_detail")" "branch mode source should be detected"
  assert_eq 'running_branch' "$(detect_pipeline_trigger_mode "$running_branch_detail")" "regular source should use runningBranchs"
  assert_eq 'unknown' "$(detect_pipeline_trigger_mode '{"pipelineConfig":{"sources":[]}}')" "missing source should be unknown"
}

test_running_branch_payload_uses_repo_url_key() {
  local payload_json

  payload_json="$(build_running_branch_payload "https://github.com/acme/api.git" "feature-a" "test-comment")"
  assert_eq 'feature-a' "$(printf '%s' "$payload_json" | jq -r '.runningBranchs["https://github.com/acme/api.git"]')" "runningBranchs should map repo URL to branch"
  assert_eq 'test-comment' "$(printf '%s' "$payload_json" | jq -r '.comment')" "runningBranch payload should include comment"
}

test_validate_run_source_branch_fails_when_ignored() {
  local run_detail_json

  run_detail_json='{"status":"RUNNING","sources":[{"sign":"api","type":"githubOAuth","data":{"repo":"https://github.com/acme/api.git","branch":"main"}}]}'
  if (
    validate_run_source_branch "$run_detail_json" "feature-a"
  ) >/tmp/test_dev_deploy.out 2>/tmp/test_dev_deploy.err; then
    echo "expected source branch validation to fail when branch is ignored" >&2
    exit 1
  fi
  if ! grep -q "流水线触发参数未生效" /tmp/test_dev_deploy.err; then
    echo "expected source branch validation error message" >&2
    cat /tmp/test_dev_deploy.err >&2
    exit 1
  fi
  validate_run_source_branch '{"sources":[{"data":{"branch":"feature-a"}}]}' "feature-a"
}

test_validate_run_source_branch_accepts_branch_mode_integration_set() {
  # branch-mode：顶层 source 只显示 base 分支 main，目标分支在「分支集成」
  # 阶段的 CI_SOURCE_BRANCHES 集成集里，校验必须通过（不能误报参数未生效）。
  local params run_detail_json
  params='{"CI_SOURCE_BRANCHES":[{"CI_COMMIT_REF_NAME":"feature-a"},{"CI_COMMIT_REF_NAME":"feature-b"}]}'
  run_detail_json="$(jq -cn --arg params "$params" '{
    status: "RUNNING",
    sources: [{"sign":"api","type":"githubOAuth","data":{"repo":"https://github.com/acme/api.git","branch":"main"}}],
    stages: [{"name":"分支集成","stageInfo":{"jobs":[{"params":$params}]}}]
  }')"
  # 目标分支在集成集中 -> 通过
  validate_run_source_branch "$run_detail_json" "feature-b"
  # 前缀分支不在集成集中 -> 仍应失败（精确匹配，避免误判）
  if (
    validate_run_source_branch "$run_detail_json" "feature"
  ) >/tmp/test_dev_deploy.out 2>/tmp/test_dev_deploy.err; then
    echo "expected prefix branch not in integration set to fail" >&2
    exit 1
  fi
}

branch_mode_run_detail() {
  # 构造一次分支模式 run detail，params 是 JSON 字符串（fromjson）。
  local status="$1" build_message="$2" trigger_source="$3" remark="$4" branch="$5" commit="$6"
  local params
  params="$(jq -cn \
    --arg bm "$build_message" \
    --arg ts "$trigger_source" \
    --arg remark "$remark" \
    --arg branch "$branch" \
    --arg commit "$commit" '{
      BUILD_MESSAGE: $bm,
      FLOW_SYSTEM_IDENTIFICATION_PARAM_TRIGGER_SOURCE: $ts,
      FLOW_INST_RUNNING_COMMENT: $remark,
      CI_SOURCE_BRANCHES: [{CI_COMMIT_REF_NAME: $branch, CI_COMMIT_ID: $commit}]
    }')"
  jq -cn --arg status "$status" --arg params "$params" '{
    status: $status,
    stages: [{name: "分支集成", stageInfo: {jobs: [{params: $params}]}}]
  }'
}

test_run_matches_non_pop_page_trigger() {
  local run_json
  run_json="$(branch_mode_run_detail "RUNNING" "页面手动触发" "CONSOLE" "dev deploy: feature-a" "feature-a" "abcdef1234567890")"

  # 同分支同 commit 的非 POP 页面触发 -> 匹配
  if ! run_matches_branch_commit_and_non_pop_trigger "$run_json" "feature-a" "abcdef1234567890" "dev deploy: feature-a"; then
    echo "expected non-POP page trigger of feature-a@abcdef1234567890 to match" >&2
    exit 1
  fi

  # commit 前缀匹配（短 SHA） -> 仍匹配
  if ! run_matches_branch_commit_and_non_pop_trigger "$run_json" "feature-a" "abcdef1" "dev deploy: feature-a"; then
    echo "expected short-SHA prefix commit to match" >&2
    exit 1
  fi

  # 不同分支 -> 不匹配（精确 index，避免误判）
  if run_matches_branch_commit_and_non_pop_trigger "$run_json" "feature-b" "abcdef1234567890" "dev deploy: feature-b"; then
    echo "expected different branch not to match" >&2
    exit 1
  fi
}

test_run_matches_rejects_pop_api_trigger() {
  local run_json
  run_json="$(branch_mode_run_detail "RUNNING" "POP API 触发" "POP_API" "dev deploy: feature-a" "feature-a" "abcdef1234567890")"

  # POP API 触发的 run 不应被当作可复用的页面 run
  if run_matches_branch_commit_and_non_pop_trigger "$run_json" "feature-a" "abcdef1234567890" "dev deploy: feature-a"; then
    echo "expected POP_API triggered run to be rejected" >&2
    exit 1
  fi
}

test_find_active_pipeline_run_returns_first_active() {
  local runs_json result

  runs_json='[{"pipelineRunId":10,"status":"SUCCESS"},{"pipelineRunId":11,"status":"RUNNING"},{"pipelineRunId":12,"status":"WAITING"}]'
  result="$(find_active_pipeline_run "$runs_json")"
  assert_eq '11' "$result" "first WAITING/RUNNING run should be returned"

  runs_json='[{"pipelineRunId":10,"status":"SUCCESS"},{"pipelineRunId":11,"status":"FAIL"}]'
  result="$(find_active_pipeline_run "$runs_json")"
  assert_eq '' "$result" "no active run should yield empty result"
}

main() {
  test_default_payload_appends_without_dropping
  test_deleted_remote_branches_are_pruned_before_building_payload
  test_shrink_requires_explicit_override
  test_parse_branch_list_csv_dedupes_and_trims
  test_extract_triggered_run_id_supports_multiple_shapes
  test_detect_pipeline_trigger_mode
  test_running_branch_payload_uses_repo_url_key
  test_validate_run_source_branch_fails_when_ignored
  test_validate_run_source_branch_accepts_branch_mode_integration_set
  test_run_matches_non_pop_page_trigger
  test_run_matches_rejects_pop_api_trigger
  test_find_active_pipeline_run_returns_first_active
  rm -f /tmp/test_dev_deploy.out /tmp/test_dev_deploy.err
  echo "OK"
}

main "$@"
