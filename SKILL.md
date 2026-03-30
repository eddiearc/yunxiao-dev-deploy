---
name: yunxiao-dev-deploy
description: 使用阿里云云效 OpenAPI 部署当前仓库的 dev 环境。适用于用户要求部署 dev、触发 dev 流水线、查看当前 dev 环境最近一次部署了哪些分支，或希望把当前已推送到远程的分支加入现有 dev 分支集并触发部署时使用。
---

# Yunxiao Dev Deploy

这个 skill 用于当前仓库的 dev 部署流程，适合放在全局 skills 目录，供不同 agent 复用。

## 默认工作流

1. 检查当前分支不是 `main` / `master`
2. 检查当前分支已经推送到远程，且本地 `HEAD` 与上游分支一致
3. 检查 `YUNXIAO_ACCESS_TOKEN`
4. 第一优先级读取当前仓库 `.yunxiao/project.env`，拿到 `YUNXIAO_ORGANIZATION_ID` 和 `YUNXIAO_DEV_PIPELINE_ID`；在这一步完成前，不允许凭记忆、历史对话或手工猜测直接选流水线
5. 只有 `.yunxiao/project.env` 缺失、字段缺失，或用户明确要求改配置时，才允许回退到“自动发现 / 用户给链接 / 手工录入”，并把结果写回项目配置
6. 获取或校验 `organizationId`；如果项目配置与运行时发现结果冲突，以当前项目 `.yunxiao/project.env` 为准；如果 403，明确提示需要 `组织管理 / 所有权限点只读`
7. 获取流水线详情，如果名称包含 `prod`，严格阻止执行；如果 403，明确提示需要 `流水线 / 只读`
8. 获取最近一次成功部署，提取当前 release 分支和已集成分支列表
9. 对已集成分支先做一次远端存在性校验；如果某个历史分支已经从 `origin` 删除，默认把它从本次分支集中剔除，并在输出里显式打印
10. 把当前分支加入清洗后的分支列表，去重后触发 dev 部署；如果 403，明确提示需要 `流水线运行实例 / 读写`；如果本次参数会删掉仍然存在于远端的已部署分支，默认直接失败
11. 如果运行详情里出现阻塞动作，先区分是不是 `CONFLICT_MERGE`。如果是分支冲突，默认优先走“在当前 `pipelineRunId` 的 `releaseBranch` 上解决，然后对当前 run 执行冲突解决 action”这条路径
12. 不要先取消当前阻塞 run，也不要先重触发新 run。默认先保留当前 `pipelineRunId`，因为云效可能会在同一个 run 里按顺序暴露多轮冲突
13. 在 `releaseBranch` 解决时，必须使用当前 run detail 里最新的 `featureBranch`、`featureBranchCommitId`、`releaseBranch`、`jobId`、`actionId`；不允许沿用上一轮冲突的信息
14. 每解决一轮冲突并 push 到 `releaseBranch` 后，必须调用 `ExecutePipelineJobAction` 继续当前 run，然后重新拉取 run detail；不能凭一次 `HTTP 200 true` 就判定冲突已结束
15. 如果下一次 run detail 里又出现新的 `CONFLICT_MERGE`，说明云效继续集成后暴露了下一轮冲突；必须继续按同样流程循环处理，直到 run 进入 `SUCCESS` / `FAIL` / `CANCELED` / `ABORTED` / `TERMINATED`
16. `releaseBranch` 路径的目标只是在“当前这一次 run”上解冲突；默认接受它可能是一次性有效，不把“让后续 run 也不再冲突”作为必须目标
17. 不要为了让后续 run 持续通过，就把当前分支合进别人的 `featureBranch` / 原业务分支；这会把不同人的分支历史混在一起，默认禁止
18. 如果判断只有直接修改 `featureBranch` / 原业务分支才能继续，则停止自动处理并向用户索取明确答复；没有用户明确答复，不要修改业务分支
19. 如果是人工执行、人工确认等非冲突阻塞，再提醒用户去云效页面处理，不继续盲等
20. 默认不阻塞等待；如果用户明确要求跟进部署结果，或已经进入 `CONFLICT_MERGE` 处理流程，则必须持续轮询到 `SUCCESS` / `FAIL` 等终态，或直到用户明确要求停止

## 配置优先级

必须按下面顺序解析部署配置：

1. 当前仓库 `.yunxiao/project.env`
2. 用户本地 `~/.yunxiao/config.sh` 里的通用配置
3. 用户显式提供的流水线链接或流水线 ID
4. 最后才是通过 API 自动发现

硬规则：

- 只要当前仓库存在 `.yunxiao/project.env`，就必须先读它
- 只要 `.yunxiao/project.env` 里已经有 `YUNXIAO_DEV_PIPELINE_ID`，就必须优先使用它
- 除非用户明确要求覆盖，否则不能绕过项目配置直接改用别的流水线
- 如果项目配置里的流水线和 agent 自己“记得的流水线”不一致，必须以项目配置为准，并在输出里指出差异
- 如果项目配置缺失，先提示“当前仓库未配置 dev 流水线”，再进入发现或询问流程

## 本地配置

优先尝试加载用户级全局 token 配置：

```bash
~/.yunxiao/config.sh
```

如果用户还没配置过，先引导执行：

```bash
bash scripts/setup.sh
```

这个脚本会把 `YUNXIAO_ACCESS_TOKEN` 保存到用户本地，并可选追加进 `~/.zshrc` / `~/.bashrc`，方便后续复用。

然后必须读取当前项目里的 `.yunxiao/project.env`：

```bash
YUNXIAO_DOMAIN="openapi-rdc.aliyuncs.com"
YUNXIAO_ORGANIZATION_ID="your_organization_id"
YUNXIAO_DEV_PIPELINE_ID="your_dev_pipeline_id"
```

只把云效相关的非敏感信息写到这里。`YUNXIAO_ACCESS_TOKEN` 不落仓库。

如果这个文件存在，就把它视为当前仓库的部署事实来源，而不是可选参考。

## Token 要求

如果没有 `YUNXIAO_ACCESS_TOKEN`，提醒用户去这里生成：

- https://account-devops.aliyun.com/settings/personalAccessToken

执行完整 dev 部署，建议至少勾选：

- `组织管理 / 所有权限点只读`
- `流水线 / 只读`
- `流水线运行实例 / 读写`

可选补充：

- `流水线运行任务 / 只读`

如果请求组织列表接口失败，优先提醒用户检查 `组织管理 / 所有权限点只读`。
如果读取流水线详情失败，优先提醒用户检查 `流水线 / 只读`。
如果触发流水线失败且返回 403，优先提醒用户检查 `流水线运行实例 / 读写`。

## 权限矩阵

- `dev_deploy.sh latest`：`流水线 / 只读` + `流水线运行实例 / 只读`
- `dev_deploy.sh run`：`流水线 / 只读` + `流水线运行实例 / 读写`
- `wait_pipeline_run.sh`：`流水线运行实例 / 只读`
- 自动发现 `organizationId`：`组织管理 / 所有权限点只读`
- 查看任务日志：`流水线运行任务 / 只读`

## 项目配置

优先读取当前项目里的 `.yunxiao/project.env`：

```bash
YUNXIAO_DOMAIN="openapi-rdc.aliyuncs.com"
YUNXIAO_ORGANIZATION_ID="your_organization_id"
YUNXIAO_DEV_PIPELINE_ID="your_dev_pipeline_id"
```

只把项目级的非敏感配置写到这里。

执行任何 dev 部署动作前，至少要显式做完下面这 3 个检查：

1. `test -f .yunxiao/project.env`
2. 读取并打印 `YUNXIAO_ORGANIZATION_ID`
3. 读取并打印 `YUNXIAO_DEV_PIPELINE_ID`

如果第 1 步存在而第 2、3 步为空，先报配置缺失，不要直接拿别的流水线顶上。

## Gitignore 配置

**重要**: 确保 `.yunxiao/project.env` 不被 `.gitignore` 排除。

如果项目的 `.gitignore` 包含 `*.env` 规则，需要添加例外：

```gitignore
.env
!.yunxiao/project.env
```

这样 `.yunxiao/project.env` 就能被 git 追踪并提交到仓库。

## 快速用法

首次配置全局 token：

```bash
bash scripts/setup.sh
```

查看最近一次成功部署：

```bash
bash scripts/dev_deploy.sh latest
```

用当前分支发起 dev 部署：

```bash
bash scripts/dev_deploy.sh run
```

显式覆盖分支集：

```bash
bash scripts/dev_deploy.sh run \
  --replace-branches "feature-a,feature-b" \
  --allow-shrink
```

首次配置流水线链接并发起部署：

```bash
bash scripts/dev_deploy.sh run --pipeline-link "https://flow.aliyun.com/pipelines/123456/current"
```

只做预检查和参数预览，不实际触发：

```bash
bash scripts/dev_deploy.sh run --dry-run
```

启动后等待结果：

```bash
bash scripts/dev_deploy.sh run --wait
```

单独等待某次运行：

```bash
bash scripts/wait_pipeline_run.sh 1234
```

## 运行参数策略

当前仓库的 dev 流水线是“分支模式”时，不是直接部署单一业务分支。

触发时使用 `branchModeBranchs`：

- 先读取最近一次成功部署里的已集成分支
- 先剔除那些已经从 `origin` 删除的历史分支，并把它们作为 `deleted_integrated_branches` 打印出来
- 再把当前分支追加进去
- 去重后作为本次运行参数
- 如果新分支集比最近一次成功部署里“仍然存在于远端”的分支更小，默认直接失败，防止静默覆盖
- 只有显式传 `--replace-branches`，并在确实发生 shrink 时再加 `--allow-shrink`，才允许覆盖

示意：

```json
{
  "params": "{\"branchModeBranchs\":[\"feature/weather\",\"codex/foo\"],\"comment\":\"dev deploy from codex: codex/foo\"}"
}
```

## 安全规则

- 流水线名包含 `prod` 时，必须直接终止
- 当前分支未推远程时，必须直接终止
- 当前分支是 `main` / `master` 时，必须直接终止
- 默认只用于 dev 环境，不允许拿这个 skill 触发生产发布
- 不能在未读取 `.yunxiao/project.env` 的情况下直接触发部署
- 不能因为“之前某次对话里用过某个 pipelineId”就默认复用

## 输出要求

执行 `latest` 时，返回：

- 当前 dev 最近一次成功部署的运行 ID
- release 分支名
- 已集成的业务分支列表
- 如果发现历史分支已从远端删除，额外返回 `deleted_integrated_branches`
- **部署时间戳与本地最后 commit 时间对比**，判断最新代码是否已部署
- 如果存在正在运行且被阻塞的实例，返回阻塞阶段、任务、动作类型和关键信息

**时间对比逻辑**：

```
部署触发时间 >= 本地最后 commit 时间 → latest_commit_deployed=true
部署触发时间 < 本地最后 commit 时间 → latest_commit_deployed=false (需要重新部署)
```

这样可以准确判断当前分支的最新改动是否已经被部署，而不仅仅看分支名是否在列表里。

执行 `run` 时，返回：

- 流水线名称
- 当前分支
- 上一次已部署分支列表
- 本次实际提交的 `branchModeBranchs`
- 新的 `pipelineRunId`

如果用户明确要求持续跟踪部署结果，或已经进入 `CONFLICT_MERGE` 处理流程：

- 优先使用 subagent 定时轮询
- 否则再使用 `scripts/wait_pipeline_run.sh`
- 如果检测到阻塞动作，先看 `blocking_summary`
- 如果是 `CONFLICT_MERGE`，默认走 `release_branch`
- `release_branch`：不要取消当前 run；而是根据 run detail 里的最新 `featureBranch` / `featureBranchCommitId` / `releaseBranch` 在 `releaseBranch` 做本地冲突定位与修复，push 后对当前 run 执行 `ExecutePipelineJobAction`
- 不能假设只有一轮冲突；每次 action 后都要重新读取 run detail，确认是进入下一阶段，还是暴露出下一条 `featureBranch` 冲突
- 只有当 run 进入终态 `SUCCESS` / `FAIL` / `CANCELED` / `ABORTED` / `TERMINATED`，这一轮跟踪才算结束
- 不要把“把当前分支反向合进别人的 feature 分支”当作默认续跑手段；这会把不同作者的分支混在一起
- 如果判断必须直接修改 `featureBranch` / 原业务分支，必须先得到用户明确答复
- 非冲突型阻塞才直接提醒用户去云效页面处理

推荐冲突处理顺序：

1. 从 `blocking_summary` 提取 `featureBranch` 和 `releaseBranch`
2. 默认按 `release_branch` 处理
3. 立即重新拉一次当前 `pipelineRunId` 的 run detail，拿到这一轮最新的 `featureBranch`、`featureBranchCommitId`、`releaseBranch`、`jobId`、`actionId`
4. `git fetch origin <releaseBranch> <featureBranch>`
5. 切到本地 `releaseBranch` 跟踪分支，执行 `git merge --no-commit --no-ff <featureBranchCommitId>` 做本地合并演练；如果云效 detail 明确给了 `featureBranchCommitId`，优先用 commit id，不要只按分支名 merge
6. 根据冲突文件完成修复并提交到 `releaseBranch`
7. `git push origin HEAD:<releaseBranch>`
8. 调用 `POST /oapi/v1/flow/organizations/{organizationId}/pipelines/{pipelineId}/pipelineRuns/{pipelineRunId}/jobs/{jobId}/action/{actionId}`，相当于页面上的“我已解决完冲突”
9. 再次拉取同一个 `pipelineRunId` 的 run detail
10. 如果 `blocking=[]` 但 run 仍是 `RUNNING`，继续轮询直到终态
11. 如果出现新的 `CONFLICT_MERGE`，回到第 3 步，按最新 `featureBranch` 再处理一轮
12. 如果 run 进入 `SUCCESS` / `FAIL` / `CANCELED` / `ABORTED` / `TERMINATED`，本次冲突处理闭环结束
13. 如果判断必须直接修改 `featureBranch` / 原业务分支，则停止并向用户报告
14. 当前 skill 不把“直接修改业务分支并继续 pipeline”视为默认支持能力，更不把“把当前分支合进别人的分支”视为默认支持能力
15. 需要用户明确决定是否改走业务分支修复

推荐闭环伪代码：

```text
while true:
  run_detail = fetch current pipelineRunId
  if run_detail.status in [SUCCESS, FAIL, CANCELED, ABORTED, TERMINATED]:
    break

  blocking_actions = latest ExecutePipelineJobAction list
  if blocking_actions is empty:
    continue polling

  if blocking action is not CONFLICT_MERGE:
    report user to handle in Yunxiao page
    break

  refresh featureBranch / featureBranchCommitId / releaseBranch / jobId / actionId
  resolve conflict on latest releaseBranch tip
  push releaseBranch
  execute current job action
```
