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
  local pipeline_name_lower
  pipeline_name_lower="$(printf '%s' "$pipeline_name" | tr '[:upper:]' '[:lower:]')"
  if [[ "$pipeline_name_lower" == *prod* ]]; then
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

remote_branch_exists() {
  local branch="$1"

  if [[ -z "$branch" ]]; then
    return 1
  fi

  git ls-remote --exit-code --heads origin "$branch" >/dev/null 2>&1
}

prune_deleted_remote_branches() {
  local branches_json="$1"
  local branch
  local kept=()
  local removed=()

  while IFS= read -r branch; do
    [[ -z "$branch" ]] && continue
    if remote_branch_exists "$branch"; then
      kept+=("$branch")
    else
      removed+=("$branch")
    fi
  done < <(printf '%s' "$branches_json" | jq -r '.[]?')

  jq -cn \
    --argjson kept "$(printf '%s\n' "${kept[@]-}" | jq -Rsc 'split("\n") | map(select(length > 0))')" \
    --argjson removed "$(printf '%s\n' "${removed[@]-}" | jq -Rsc 'split("\n") | map(select(length > 0))')" '
      {
        kept: $kept,
        removed: $removed
      }
    '
}

sanitize_latest_summary_branches() {
  local latest_summary_json="$1"
  local prune_result_json="$2"

  jq -cn \
    --argjson latest "$latest_summary_json" \
    --argjson prune "$prune_result_json" '
      $latest
      | .branches = ($prune.kept // [])
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

detect_pipeline_trigger_mode() {
  local pipeline_detail_json="$1"

  printf '%s' "$pipeline_detail_json" | jq -r '
    if any(.pipelineConfig.sources[]?; .data.isBranchMode == true) then
      "branch_mode"
    elif ([.pipelineConfig.sources[]? | select((.data.repo // "") != "")] | length) > 0 then
      "running_branch"
    else
      "unknown"
    end
  '
}

primary_pipeline_source_repo() {
  local pipeline_detail_json="$1"

  printf '%s' "$pipeline_detail_json" | jq -r '
    [.pipelineConfig.sources[]? | select((.data.repo // "") != "") | .data.repo][0] // ""
  '
}

build_running_branch_payload() {
  local repo_url="$1"
  local branch="$2"
  local comment="${3:-}"

  jq -cn \
    --arg repo "$repo_url" \
    --arg branch "$branch" \
    --arg comment "$comment" '
      {
        runningBranchs: {
          ($repo): $branch
        }
      }
      | if $comment == "" then . else . + {comment: $comment} end
    '
}

validate_run_source_branch() {
  local run_detail_json="$1"
  local expected_branch="$2"

  # 情况一：单分支 / 非 branch-mode 触发，目标分支直接作为 source 分支出现。
  if printf '%s' "$run_detail_json" | jq -e --arg branch "$expected_branch" '
    any(.sources[]?; (.data.branch // "") == $branch)
  ' >/dev/null; then
    return 0
  fi

  # 情况二：branch-mode 触发。顶层 source 只显示 base 分支（如 main），
  # 目标分支进入「分支集成」阶段的 CI_SOURCE_BRANCHES 集成分支集
  # （与 fetch_latest_success_summary 读取集成分支的位置一致）。
  # 用精确 index 匹配，避免前缀分支（如 feat vs feat-x）误判。
  if printf '%s' "$run_detail_json" | jq -e --arg branch "$expected_branch" '
    [
      .stages[]?
      | select(.name == "分支集成")
      | .stageInfo.jobs[]?.params
      | fromjson?
      | .CI_SOURCE_BRANCHES[]?.CI_COMMIT_REF_NAME
    ] | index($branch) != null
  ' >/dev/null; then
    return 0
  fi

  printf '%s' "$run_detail_json" | jq -c '
    {
      status,
      sources: [.sources[]? | {
        sign,
        type,
        repo: .data.repo,
        branch: .data.branch,
        commit: .data.commit
      }]
    }
  ' >&2
  die "流水线触发参数未生效：run detail 中没有目标分支 ${expected_branch}。请检查流水线 source 模式和 params。"
}

format_run_sources_summary() {
  local run_detail_json="$1"

  printf '%s' "$run_detail_json" | jq -r '
    [.sources[]? | [
      (.sign // ""),
      (.type // ""),
      (.data.repo // ""),
      (.data.branch // ""),
      ((.data.commit // "") | tostring)
    ] | @tsv] | .[]
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

# ---------------------------------------------------------------------------
# 分支模式（branch integration）页面触发
#
# 分支模式流水线是「分支合并发布」模型：POP API 触发会重建分支集成 run，把历史
# 分支重新合并一遍，已经解决过的合并冲突可能每次都要重新处理。因此分支模式默认
# 改为「页面点击」触发（依赖 opencli），只把当前分支加入运行配置，不删除、不重排
# 其他分支。冲突处理仍走 API（ExecutePipelineJobAction），只有初次触发用页面。
# ---------------------------------------------------------------------------

run_status() {
  local run_detail_json="$1"
  printf '%s' "$run_detail_json" | jq -r '.status // ""'
}

fetch_pipeline_runs() {
  local organization_id="$1"
  local pipeline_id="$2"

  if ! api_request GET "/oapi/v1/flow/organizations/${organization_id}/pipelines/${pipeline_id}/runs?perPage=20&page=1"; then
    if [[ "$API_STATUS" == "403" ]]; then
      die_permission_denied "获取流水线运行列表" "pipeline-run-read"
    fi
    die "获取流水线运行列表失败。HTTP ${API_STATUS}: ${API_BODY}"
  fi
  printf '%s\n' "$API_BODY"
}

# 判断一次 run 是否是「当前分支 + 当前 commit」的非 POP 页面触发。
# 分支集成信息在云效可能有两种表示（CI_SOURCE_BRANCHES / branchRepoInfo），
# 这里对两者取并集，避免因字段命名差异误判。
run_matches_branch_commit_and_non_pop_trigger() {
  local run_json="$1"
  local branch="$2"
  local commit="$3"
  local comment="$4"

  printf '%s' "$run_json" | jq -e --arg branch "$branch" --arg commit "$commit" --arg comment "$comment" '
    def same_commit($value; $commit):
      ($value == $commit)
      or (($value | length) >= 7 and ($commit | startswith($value)))
      or (($commit | length) >= 7 and ($value | startswith($commit)));

    [
      .stages[]?
      | select(.name == "分支集成")
      | .stageInfo.jobs[]?.params
      | fromjson?
      | (.FLOW_INST_RUNNING_COMMENT // .BUILD_REMARK // "") as $remark
      | (.BUILD_MESSAGE // "") as $buildmsg
      | (((.FLOW_SYSTEM_IDENTIFICATION_PARAM_TRIGGER_SOURCE // "") | ascii_upcase)) as $source
      | (
          ((.CI_SOURCE_BRANCHES // [])
            | map({name: .CI_COMMIT_REF_NAME, commit: (.CI_COMMIT_ID // .CI_COMMIT_SHA // "")}))
          + ([ .branchRepoInfo? | fromjson? | .[]?.featureBranchs[]?
                | {name: .branchName, commit: (.commitId // .commit // .commitSha // .featureBranchCommitId // "")} ])
        ) as $entries
      | select(
          ($buildmsg | contains("页面手动触发"))
          and ($source != "POP_API" and $source != "POP")
          and (($entries | map(.name) | index($branch)) != null)
          and (
            if $commit == "" then
              ($remark == $comment)
            else
              ($remark | contains($branch + "@" + $commit))
              or any(
                $entries[]
                | select(.name == $branch)
                | .commit
                | select(type == "string" and length > 0);
                same_commit(.; $commit)
              )
            end
          )
        )
    ] | length > 0
  ' >/dev/null
}

# 幂等复用：同一分支同一 commit、非 POP 的页面 run 已存在且处于
# SUCCESS / RUNNING / WAITING 时，直接复用，不再重复点页面创建新 run。
find_existing_page_run() {
  local organization_id="$1"
  local pipeline_id="$2"
  local runs_json="$3"
  local branch="$4"
  local commit="$5"
  local comment="$6"
  local run_id run_json status

  while IFS= read -r run_id; do
    [[ -n "$run_id" ]] || continue
    run_json="$(fetch_pipeline_run_detail "$organization_id" "$pipeline_id" "$run_id")"
    status="$(run_status "$run_json")"
    case "$status" in
      SUCCESS|RUNNING|WAITING)
        if run_matches_branch_commit_and_non_pop_trigger "$run_json" "$branch" "$commit" "$comment"; then
          printf '%s\n' "$run_id"
          return 0
        fi
        ;;
    esac
  done < <(printf '%s' "$runs_json" | jq -r '.[]? | ((.pipelineRunId // .id // .runId) | tostring)')

  return 1
}

# 返回第一个处于 WAITING / RUNNING 的 run id（用于并发防护）。
find_active_pipeline_run() {
  local runs_json="$1"

  printf '%s' "$runs_json" | jq -r '
    .[]?
    | ((.pipelineRunId // .id // .runId) | tostring) as $id
    | (.status // "") as $status
    | select($id != "" and $id != "null" and ($status == "WAITING" or $status == "RUNNING"))
    | $id
  ' | head -n 1
}

print_branch_mode_page_trigger_help() {
  local pipeline_id="$1"
  local branch="$2"
  local url="https://flow.aliyun.com/pipelines/${pipeline_id}/current"

  cat >&2 <<EOF
分支模式（branch integration）流水线禁止用 POP API 触发。
原因：POP API 触发会重建分支集成 run，把历史分支重新合并一遍，
已经解决过的合并冲突可能每次都要重新处理，非常容易反复踩坑。

因此分支模式默认改为「页面点击」触发，只把当前分支加入运行配置，
不删除、不重排其他分支。

自动化方式（推荐）：安装 opencli 后重跑本脚本，即可自动完成页面点击：
   npm install -g @jackwener/opencli

或手动到云效页面触发：
   ${url}

   手动步骤：
   - 点击「运行」
   - 在「运行配置」里确认当前分支存在：${branch}
   - 若不存在，点「添加运行分支」并添加该分支
   - 不删除、不替换、不重排其他分支
   - 点弹窗底部「运行」

触发后，run 查询 / 等待 / 冲突处理仍可继续用本脚本（这些走 API，不受影响）：
   bash scripts/wait_pipeline_run.sh <pipelineRunId>
EOF
}

# 用 opencli 页面点击触发分支模式 run：打开运行配置弹窗，若当前分支不在集成列表
# 就「添加运行分支」，写运行备注，点「运行」。触发后轮询 runs，找到新出现的、
# 匹配当前分支/commit 的非 POP run 并返回其 id。opencli 缺失时打印指引并终止，
# 绝不回退到 POP API。
trigger_branch_mode_run_with_opencli() {
  local organization_id="$1"
  local pipeline_id="$2"
  local branch="$3"
  local commit="$4"
  local comment="$5"
  local before_runs_json="$6"
  local session="${OPENCLI_YUNXIAO_SESSION:-yunxiao-dev-deploy}"
  local url="https://flow.aliyun.com/pipelines/${pipeline_id}/current"
  local branch_json comment_json js before_ids_json after_runs_json new_run_id candidate_ids_json run_json

  if ! command -v opencli >/dev/null 2>&1; then
    print_branch_mode_page_trigger_help "$pipeline_id" "$branch"
    die "分支模式需要 opencli 才能自动页面触发；已拒绝回退到 POP API。"
  fi

  branch_json="$(jq -cn --arg value "$branch" '$value')"
  comment_json="$(jq -cn --arg value "$comment" '$value')"

  printf 'opencli_session=%s\n' "$session" >&2
  if ! opencli browser "$session" open "$url" >&2; then
    print_branch_mode_page_trigger_help "$pipeline_id" "$branch"
    die "opencli 打开云效流水线页面失败。"
  fi
  if ! opencli browser "$session" wait time 2 >&2; then
    print_branch_mode_page_trigger_help "$pipeline_id" "$branch"
    die "opencli 等待云效流水线页面加载失败。"
  fi

  read -r -d '' js <<'OPENCLI_JS' || true
(async () => {
  const branch = __BRANCH__;
  const comment = __COMMENT__;
  const sleep = (ms) => new Promise(resolve => setTimeout(resolve, ms));
  const visible = (el) => !!el && !!(el.offsetWidth || el.offsetHeight || el.getClientRects().length);
  const text = (el) => ((el && (el.innerText || el.textContent)) || "").trim();
  const buttons = (root = document) => [...root.querySelectorAll("button")].filter(visible);
  const buttonByText = (root, label) => buttons(root).find(btn => text(btn) === label);
  const dialogs = () => [...document.querySelectorAll("[role=dialog]")].filter(visible);
  const dialogByText = (needle) => dialogs().find(dialog => text(dialog).includes(needle));
  const waitFor = async (fn, description, timeout = 15000) => {
    const started = Date.now();
    while (Date.now() - started < timeout) {
      const value = fn();
      if (value) return value;
      await sleep(300);
    }
    throw new Error("timeout waiting for " + description);
  };
  const setNativeValue = (el, value) => {
    const proto = el.tagName === "TEXTAREA" ? window.HTMLTextAreaElement.prototype : window.HTMLInputElement.prototype;
    const setter = Object.getOwnPropertyDescriptor(proto, "value").set;
    setter.call(el, value);
    el.dispatchEvent(new Event("input", { bubbles: true }));
    el.dispatchEvent(new Event("change", { bubbles: true }));
  };
  const words = (el) => text(el).split(/\s+/).filter(Boolean);
  const hasBranch = (dialog) => words(dialog).includes(branch);

  let runConfig = dialogByText("运行配置");
  if (!runConfig) {
    const topRun = buttons(document).find(btn => text(btn) === "运行" && !btn.closest("[role=dialog]"));
    if (!topRun) throw new Error("top run button not found");
    topRun.click();
    runConfig = await waitFor(() => dialogByText("运行配置"), "run config dialog");
  }

  const branchesBefore = words(runConfig).filter(item =>
    item === branch ||
    item.startsWith("codex/") ||
    item.startsWith("feature/") ||
    item.startsWith("feat/")
  );
  let branchAdded = false;
  if (!hasBranch(runConfig)) {
    const addBranch = buttonByText(runConfig, "添加运行分支");
    if (!addBranch) throw new Error("add branch button not found");
    addBranch.click();

    const addDialog = await waitFor(() => dialogByText("添加运行分支"), "add branch dialog");
    const input = await waitFor(
      () => addDialog.querySelector("#branchName, input[placeholder*='分支']"),
      "branch input"
    );
    input.focus();
    setNativeValue(input, branch);
    await sleep(1200);

    const option = [...document.querySelectorAll("[role=option], .next-menu-item, .next-select-menu-item, li")]
      .find(el => visible(el) && words(el).includes(branch));
    if (option) {
      option.click();
      await sleep(500);
    }

    const submitAdd = buttonByText(addDialog, "添加");
    if (!submitAdd) throw new Error("add submit button not found");
    if (submitAdd.disabled || /disabled/.test(submitAdd.className)) {
      throw new Error("add submit button is disabled: " + text(addDialog));
    }
    submitAdd.click();

    runConfig = await waitFor(() => {
      const dialog = dialogByText("运行配置");
      return dialog && hasBranch(dialog) ? dialog : null;
    }, "branch in run config", 20000);
    branchAdded = true;
  }

  const remark = runConfig.querySelector("textarea[placeholder*='运行备注'], textarea");
  if (remark) {
    setNativeValue(remark, comment);
  }

  const submitRun = buttonByText(runConfig, "运行");
  if (!submitRun) throw new Error("dialog run button not found");
  if (submitRun.disabled || /disabled/.test(submitRun.className)) {
    throw new Error("dialog run button is disabled");
  }
  submitRun.click();
  await sleep(1200);

  const confirmDialog = dialogs().find(dialog => dialog !== runConfig && /确认|提示/.test(text(dialog)));
  if (confirmDialog) {
    const confirm = buttonByText(confirmDialog, "确定") || buttonByText(confirmDialog, "确认");
    if (confirm) {
      confirm.click();
      await sleep(600);
    }
  }

  return { submitted: true, branch, branchAdded, branchesBefore };
})()
OPENCLI_JS

  js="${js//__BRANCH__/$branch_json}"
  js="${js//__COMMENT__/$comment_json}"

  if ! opencli browser "$session" eval "$js" >&2; then
    print_branch_mode_page_trigger_help "$pipeline_id" "$branch"
    die "opencli 提交云效页面触发失败。"
  fi

  before_ids_json="$(printf '%s' "$before_runs_json" | jq -c '[.[]? | ((.pipelineRunId // .id // .runId) | tostring)]')"
  for _ in {1..20}; do
    after_runs_json="$(fetch_pipeline_runs "$organization_id" "$pipeline_id")"
    candidate_ids_json="$(
      printf '%s' "$after_runs_json" | jq -r --argjson before "$before_ids_json" '
        [
          .[]?
          | ((.pipelineRunId // .id // .runId) | tostring) as $id
          | select($id != "" and (($before | index($id)) | not))
          | $id
        ]
      '
    )"
    while IFS= read -r new_run_id; do
      [[ -n "$new_run_id" ]] || continue
      run_json="$(fetch_pipeline_run_detail "$organization_id" "$pipeline_id" "$new_run_id")"
      if run_matches_branch_commit_and_non_pop_trigger "$run_json" "$branch" "$commit" "$comment"; then
        printf '%s\n' "$new_run_id"
        return 0
      fi
    done < <(printf '%s' "$candidate_ids_json" | jq -r '.[]?')
    sleep 3
  done

  die "页面触发已提交，但没有找到匹配的非 POP 流水线 run。"
}

terminate_pipeline_run() {
  local organization_id="$1"
  local pipeline_id="$2"
  local run_id="$3"

  if ! api_request PUT "/oapi/v1/flow/organizations/${organization_id}/pipelines/${pipeline_id}/runs/${run_id}"; then
    if [[ "$API_STATUS" == "403" ]]; then
      die_permission_denied "终止流水线运行实例" "pipeline-run-write"
    fi
    die "终止流水线运行实例失败。HTTP ${API_STATUS}: ${API_BODY}"
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

  local deploy_create_time commit_timestamp deploy_timestamp branch_count release_branch

  # Get deployment create time (can be milliseconds timestamp or ISO 8601)
  deploy_create_time="$(printf '%s' "$latest_summary_json" | jq -r '.createTime // empty')"

  if [[ -z "$deploy_create_time" ]]; then
    return 1
  fi

  branch_count="$(printf '%s' "$latest_summary_json" | jq '(.branches // []) | length')"
  if [[ "$branch_count" -gt 0 ]]; then
    # Branch-mode pipelines expose integrated feature branches.
    if ! printf '%s' "$latest_summary_json" | jq -e --arg branch "$current_branch" '(.branches // []) | index($branch)' >/dev/null 2>&1; then
      return 1
    fi
  else
    # Regular source pipelines expose the actual source branch as releaseBranch.
    release_branch="$(printf '%s' "$latest_summary_json" | jq -r '.releaseBranch // ""')"
    if [[ "$release_branch" != "$current_branch" ]]; then
      return 1
    fi
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
