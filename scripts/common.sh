#!/usr/bin/env bash
set -euo pipefail

API_STATUS=""
API_BODY=""

die() {
  echo "$*" >&2
  exit 1
}

print_permission_hint() {
  local scope="$1"

  case "$scope" in
    organization-read)
      cat >&2 <<'EOF'
当前操作需要以下 Personal Access Token 权限：
- 组织管理 / 所有权限点只读
EOF
      ;;
    pipeline-read)
      cat >&2 <<'EOF'
当前操作需要以下 Personal Access Token 权限：
- 流水线 / 只读
EOF
      ;;
    pipeline-run-read)
      cat >&2 <<'EOF'
当前操作需要以下 Personal Access Token 权限：
- 流水线运行实例 / 只读
EOF
      ;;
    pipeline-run-write)
      cat >&2 <<'EOF'
当前操作需要以下 Personal Access Token 权限：
- 流水线 / 只读
- 流水线运行实例 / 读写

如果你后续还要查看任务日志，可再补：
- 流水线运行任务 / 只读
EOF
      ;;
  esac
}

die_permission_denied() {
  local operation="$1"
  local scope="$2"

  {
    echo "${operation}失败。HTTP 403: 当前 token 没有访问这个 API 的权限。"
    print_permission_hint "$scope"
    echo "请到以下地址更新 Personal Access Token 后重试："
    echo "https://account-devops.aliyun.com/settings/personalAccessToken"
  } >&2

  exit 1
}

repo_root() {
  git rev-parse --show-toplevel 2>/dev/null
}

global_config_file() {
  echo "${HOME}/.yunxiao/config.sh"
}

project_env_file() {
  echo "$(repo_root)/.yunxiao/project.env"
}

load_env_file_if_unset() {
  local env_file="$1"
  local line
  local key
  local value

  if [[ -f "$env_file" ]]; then
    while IFS= read -r line || [[ -n "$line" ]]; do
      line="${line#"${line%%[![:space:]]*}"}"
      [[ -z "$line" ]] && continue
      [[ "$line" =~ ^# ]] && continue

      if [[ "$line" == export[[:space:]]* ]]; then
        line="${line#export}"
        line="${line#"${line%%[![:space:]]*}"}"
      fi

      [[ "$line" != *=* ]] && continue

      key="${line%%=*}"
      key="${key%"${key##*[![:space:]]}"}"
      value="${line#*=}"
      value="${value#"${value%%[![:space:]]*}"}"
      value="${value#\"}"
      value="${value%\"}"
      value="${value#\'}"
      value="${value%\'}"

      if [[ -z "${!key+x}" ]]; then
        printf -v "$key" '%s' "$value"
        export "$key"
      fi
    done <"$env_file"
  fi
}

load_global_env() {
  load_env_file_if_unset "$(global_config_file)"
}

load_project_env() {
  load_env_file_if_unset "$(project_env_file)"
}

save_project_env_var() {
  local key="$1"
  local value="$2"
  local env_file
  local tmp_file
  local found="false"

  env_file="$(project_env_file)"
  mkdir -p "$(dirname "$env_file")"
  tmp_file="$(mktemp)"

  if [[ -f "$env_file" ]]; then
    while IFS= read -r line || [[ -n "$line" ]]; do
      if [[ "$line" == "${key}="* ]]; then
        printf '%s="%s"\n' "$key" "$value" >>"$tmp_file"
        found="true"
      else
        printf '%s\n' "$line" >>"$tmp_file"
      fi
    done <"$env_file"
  fi

  if [[ "$found" != "true" ]]; then
    printf '%s="%s"\n' "$key" "$value" >>"$tmp_file"
  fi

  mv "$tmp_file" "$env_file"
}

ensure_yunxiao_token() {
  load_global_env

  if [[ -n "${YUNXIAO_ACCESS_TOKEN:-}" ]]; then
    return 0
  fi

  cat >&2 <<EOF
缺少 YUNXIAO_ACCESS_TOKEN。

请先去这里生成个人 AccessToken：
https://account-devops.aliyun.com/settings/personalAccessToken

权限至少需要：
- 组织管理：所有权限点只读
- 流水线：所有权限点只读

如果你希望后续自动复用 token，可以先运行：
bash scripts/setup.sh

它会把 token 保存到：
$(global_config_file)
EOF
  exit 1
}

api_request() {
  local method="$1"
  local path="$2"
  local body="${3:-}"
  local body_file

  body_file="$(mktemp)"

  if [[ -n "$body" ]]; then
    API_STATUS="$(
      curl -sS -o "$body_file" -w '%{http_code}' \
        -X "$method" \
        "https://${YUNXIAO_DOMAIN:-openapi-rdc.aliyuncs.com}${path}" \
        -H "x-yunxiao-token: ${YUNXIAO_ACCESS_TOKEN}" \
        -H "Content-Type: application/json" \
        --data "$body"
    )"
  else
    API_STATUS="$(
      curl -sS -o "$body_file" -w '%{http_code}' \
        -X "$method" \
        "https://${YUNXIAO_DOMAIN:-openapi-rdc.aliyuncs.com}${path}" \
        -H "x-yunxiao-token: ${YUNXIAO_ACCESS_TOKEN}" \
        -H "Content-Type: application/json"
    )"
  fi

  API_BODY="$(cat "$body_file")"
  rm -f "$body_file"

  [[ "$API_STATUS" =~ ^2 ]]
}

resolve_organization_id() {
  if [[ -n "${YUNXIAO_ORGANIZATION_ID:-}" ]]; then
    printf '%s\n' "$YUNXIAO_ORGANIZATION_ID"
    return 0
  fi

  if ! api_request GET "/oapi/v1/platform/organizations"; then
    if [[ "$API_STATUS" == "403" ]]; then
      die_permission_denied "获取 organizationId" "organization-read"
    fi
    die "获取 organizationId 失败。HTTP ${API_STATUS}: ${API_BODY}"
  fi

  local org_count
  org_count="$(printf '%s' "$API_BODY" | jq 'length')"
  if [[ "$org_count" == "0" ]]; then
    die "当前 token 没有关联任何组织，无法继续。"
  fi
  if [[ "$org_count" != "1" ]]; then
    die "当前 token 可访问多个组织，请先在 .yunxiao/project.env 配置 YUNXIAO_ORGANIZATION_ID。"
  fi

  YUNXIAO_ORGANIZATION_ID="$(printf '%s' "$API_BODY" | jq -r '.[0].id')"
  save_project_env_var "YUNXIAO_ORGANIZATION_ID" "$YUNXIAO_ORGANIZATION_ID"
  printf '%s\n' "$YUNXIAO_ORGANIZATION_ID"
}

parse_pipeline_id_from_link() {
  local pipeline_link="$1"
  if [[ "$pipeline_link" =~ /pipelines/([0-9]+)(/|$) ]]; then
    printf '%s\n' "${BASH_REMATCH[1]}"
    return 0
  fi
  return 1
}

resolve_pipeline_id() {
  local pipeline_link="${1:-}"
  local current_config_pipeline_id="${YUNXIAO_DEV_PIPELINE_ID:-}"

  if [[ -n "$pipeline_link" ]]; then
    if ! YUNXIAO_DEV_PIPELINE_ID="$(parse_pipeline_id_from_link "$pipeline_link")"; then
      die "无法从流水线链接解析 pipelineId: $pipeline_link"
    fi
    if [[ -z "$current_config_pipeline_id" ]]; then
      save_project_env_var "YUNXIAO_DEV_PIPELINE_ID" "$YUNXIAO_DEV_PIPELINE_ID"
    fi
    printf '%s\n' "$YUNXIAO_DEV_PIPELINE_ID"
    return 0
  fi

  if [[ -n "${YUNXIAO_DEV_PIPELINE_ID:-}" ]]; then
    printf '%s\n' "$YUNXIAO_DEV_PIPELINE_ID"
    return 0
  fi

  die "缺少 YUNXIAO_DEV_PIPELINE_ID。请提供流水线链接，例如 https://flow.aliyun.com/pipelines/123456/current"
}

ensure_branch_ready_for_dev_deploy() {
  local branch upstream local_head upstream_head

  branch="$(git rev-parse --abbrev-ref HEAD)"
  if [[ "$branch" == "HEAD" ]]; then
    die "当前处于 detached HEAD，不能触发 dev 部署。"
  fi

  case "$branch" in
    main|master)
      die "当前分支是 ${branch}，禁止直接用于 dev 部署。请切到非主分支后重试。"
      ;;
  esac

  upstream="$(git rev-parse --abbrev-ref --symbolic-full-name '@{u}' 2>/dev/null || true)"
  if [[ -z "$upstream" ]]; then
    die "当前分支还没有上游远程分支。请先 push 到远程再部署。"
  fi

  local_head="$(git rev-parse HEAD)"
  upstream_head="$(git rev-parse '@{u}')"
  if [[ "$local_head" != "$upstream_head" ]]; then
    die "当前分支存在未推送提交，或本地与远程不一致。请先 push 并确保 HEAD 与上游一致。"
  fi

  printf '%s\n' "$branch"
}

fetch_pipeline_detail() {
  local organization_id="$1"
  local pipeline_id="$2"

  if ! api_request GET "/oapi/v1/flow/organizations/${organization_id}/pipelines/${pipeline_id}"; then
    if [[ "$API_STATUS" == "403" ]]; then
      die_permission_denied "获取流水线详情" "pipeline-read"
    fi
    die "获取流水线详情失败。HTTP ${API_STATUS}: ${API_BODY}"
  fi
}

block_if_prod_pipeline() {
  local pipeline_name="$1"
  if [[ "${pipeline_name,,}" == *prod* ]]; then
    die "检测到流水线名称包含 prod：${pipeline_name}。为避免风险，已严格阻止执行。"
  fi
}

fetch_latest_successful_run_summary() {
  local organization_id="$1"
  local pipeline_id="$2"
  local run_id

  if ! api_request GET "/oapi/v1/flow/organizations/${organization_id}/pipelines/${pipeline_id}/runs?perPage=20&page=1"; then
    if [[ "$API_STATUS" == "403" ]]; then
      die_permission_denied "获取流水线运行列表" "pipeline-run-read"
    fi
    die "获取流水线运行列表失败。HTTP ${API_STATUS}: ${API_BODY}"
  fi

  run_id="$(printf '%s' "$API_BODY" | jq -r 'map(select(.status == "SUCCESS")) | first.pipelineRunId // empty')"
  if [[ -z "$run_id" ]]; then
    printf '{"pipelineRunId":null,"releaseBranch":"","branches":[]}\n'
    return 0
  fi

  if ! api_request GET "/oapi/v1/flow/organizations/${organization_id}/pipelines/${pipeline_id}/runs/${run_id}"; then
    if [[ "$API_STATUS" == "403" ]]; then
      die_permission_denied "获取最近成功运行详情" "pipeline-run-read"
    fi
    die "获取最近成功运行详情失败。HTTP ${API_STATUS}: ${API_BODY}"
  fi

  printf '%s' "$API_BODY" | jq -c '
    {
      pipelineRunId: .pipelineRunId,
      createTime: .createTime,
      releaseBranch: (.sources[0].data.branch // ""),
      branches: (
        reduce (
          [
            .stages[]?
            | select(.name == "分支集成")
            | .stageInfo.jobs[]?.params
            | fromjson?
            | .CI_SOURCE_BRANCHES[]?.CI_COMMIT_REF_NAME
          ][]
        ) as $item
          ([]; if index($item) then . else . + [$item] end)
      )
    }
  '
}

fetch_latest_running_run_id() {
  local organization_id="$1"
  local pipeline_id="$2"

  if ! api_request GET "/oapi/v1/flow/organizations/${organization_id}/pipelines/${pipeline_id}/runs?perPage=20&page=1"; then
    if [[ "$API_STATUS" == "403" ]]; then
      die_permission_denied "获取流水线运行列表" "pipeline-run-read"
    fi
    die "获取流水线运行列表失败。HTTP ${API_STATUS}: ${API_BODY}"
  fi

  printf '%s' "$API_BODY" | jq -r 'map(select(.status == "RUNNING")) | first.pipelineRunId // empty'
}

fetch_pipeline_run_detail() {
  local organization_id="$1"
  local pipeline_id="$2"
  local run_id="$3"

  if ! api_request GET "/oapi/v1/flow/organizations/${organization_id}/pipelines/${pipeline_id}/runs/${run_id}"; then
    if [[ "$API_STATUS" == "403" ]]; then
      die_permission_denied "获取流水线运行详情" "pipeline-run-read"
    fi
    die "获取流水线运行详情失败。HTTP ${API_STATUS}: ${API_BODY}"
  fi

  printf '%s\n' "$API_BODY"
}

extract_blocking_actions() {
  local run_detail_json="$1"

  printf '%s' "$run_detail_json" | jq -c '
    [
      .stages[]? as $stage
      | $stage.stageInfo.jobs[]? as $job
      | $job.actions[]?
      | select(.type == "ExecutePipelineJobAction" and (.disable != true))
      | {
          stage: $stage.name,
          job: $job.name,
          jobStatus: $job.status,
          actionType: .type,
          displayType: .displayType,
          actionId: (.params.actionId // null),
          data: (
            if (.data | type) == "string" then
              (try (.data | fromjson) catch .data)
            else
              .data
            end
          )
        }
    ]
  '
}

format_blocking_summary() {
  local blocking_json="$1"

  printf '%s' "$blocking_json" | jq -r '
    map(
      "stage=" + .stage
      + " job=" + .job
      + " displayType=" + (.displayType // "")
      + (
          if (.data | type) == "object" then
            (
              if (.data.featureBranch // "") != "" then
                " featureBranch=" + .data.featureBranch
              else
                ""
              end
            )
            + (
              if (.data.releaseBranch // "") != "" then
                " releaseBranch=" + .data.releaseBranch
              else
                ""
              end
            )
          else
            ""
          end
        )
    ) | join("\n")
  '
}

build_branch_mode_payload() {
  local latest_summary_json="$1"
  local current_branch="$2"
  local comment="${3:-}"

  jq -cn \
    --argjson latest "$latest_summary_json" \
    --arg branch "$current_branch" \
    --arg comment "$comment" '
      ($latest.branches // []) as $existing
      | {
          branchModeBranchs: (
            reduce ($existing + [$branch])[] as $item
              ([]; if index($item) then . else . + [$item] end)
          )
        }
      | if $comment == "" then . else . + {comment: $comment} end
    '
}

parse_branch_list_csv() {
  local csv="$1"

  jq -cn \
    --arg csv "$csv" '
      ($csv | split(",") | map(gsub("^\\s+|\\s+$"; "")) | map(select(length > 0))) as $items
      | reduce $items[] as $item
          ([]; if index($item) then . else . + [$item] end)
    '
}

build_exact_branch_mode_payload() {
  local branches_json="$1"
  local comment="${2:-}"

  jq -cn \
    --argjson branches "$branches_json" \
    --arg comment "$comment" '
      {
        branchModeBranchs: $branches
      }
      | if $comment == "" then . else . + {comment: $comment} end
    '
}

extract_triggered_run_id() {
  local response_json="$1"

  printf '%s' "$response_json" | jq -r '
    if type == "number" then
      tostring
    elif type == "string" then
      .
    elif type == "object" then
      (.pipelineRunId // .id // .runId // .data.pipelineRunId // .data.id // .data.runId // empty) | tostring
    else
      empty
    end
  '
}

ensure_branch_set_not_shrunk() {
  local latest_summary_json="$1"
  local params_json="$2"
  local allow_shrink="${3:-false}"
  local removed

  removed="$(
    jq -rn \
      --argjson latest "$latest_summary_json" \
      --argjson params "$params_json" '
        ($latest.branches // []) as $existing
        | ($params.branchModeBranchs // []) as $target
        | [ $existing[] as $item | select(($target | index($item)) == null) | $item ]
        | join(",")
      '
  )"

  if [[ -n "$removed" && "$allow_shrink" != "true" ]]; then
    die "检测到本次部署会移除已部署分支: ${removed}。默认禁止静默 shrink。请改用追加模式，或显式传 --replace-branches 并加 --allow-shrink。"
  fi
}

trigger_pipeline_run() {
  local organization_id="$1"
  local pipeline_id="$2"
  local params_json="$3"
  local body

  body="$(jq -cn --arg params "$params_json" '{params: $params}')"

  if ! api_request POST "/oapi/v1/flow/organizations/${organization_id}/pipelines/${pipeline_id}/runs" "$body"; then
    if [[ "$API_STATUS" == "403" ]]; then
      die_permission_denied "触发流水线" "pipeline-run-write"
    fi
    die "触发流水线失败。HTTP ${API_STATUS}: ${API_BODY}"
  fi

  printf '%s\n' "$API_BODY"
}

# Get the timestamp of the last commit on the current branch
get_last_commit_timestamp() {
  # Returns Unix timestamp (seconds since epoch)
  git log -1 --format=%ct HEAD 2>/dev/null
}

# Check if the latest deployment includes the latest commit on the current branch
# Returns 0 if deployed (deployment time >= commit time), 1 if not
check_if_latest_commit_deployed() {
  local latest_summary_json="$1"
  local current_branch="$2"

  local deploy_create_time commit_timestamp deploy_timestamp

  # Get deployment create time (can be milliseconds timestamp or ISO 8601)
  deploy_create_time="$(printf '%s' "$latest_summary_json" | jq -r '.createTime // empty')"

  if [[ -z "$deploy_create_time" ]]; then
    return 1
  fi

  # Check if current branch is in the deployed branches
  if ! printf '%s' "$latest_summary_json" | jq -e --arg branch "$current_branch" '(.branches // []) | index($branch)' >/dev/null 2>&1; then
    return 1
  fi

  # Get last commit timestamp on current branch
  commit_timestamp="$(get_last_commit_timestamp)"
  if [[ -z "$commit_timestamp" ]]; then
    return 1
  fi

  # Convert deploy time to Unix timestamp
  # Handle both milliseconds timestamp (number) and ISO 8601 string
  if [[ "$deploy_create_time" =~ ^[0-9]+$ ]]; then
    # Milliseconds timestamp - convert to seconds
    deploy_timestamp=$((deploy_create_time / 1000))
  else
    # ISO 8601 format - convert to Unix timestamp (macOS/BSD date compatible)
    deploy_timestamp="$(date -j -f "%Y-%m-%dT%H:%M:%S%z" "$deploy_create_time" +%s 2>/dev/null || date -d "$deploy_create_time" +%s 2>/dev/null)"
  fi

  if [[ -z "$deploy_timestamp" ]]; then
    return 1
  fi

  # Compare: if deployment time >= commit time, the commit is deployed
  if [[ "$deploy_timestamp" -ge "$commit_timestamp" ]]; then
    return 0
  else
    return 1
  fi
}
