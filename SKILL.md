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
4. 获取或校验 `organizationId`
5. 从项目本地配置读取 dev 流水线 ID，没有的话要求用户给流水线链接，并自动写入本地配置
6. 获取流水线详情，如果名称包含 `prod`，严格阻止执行
7. 获取最近一次成功部署，提取当前 release 分支和已集成分支列表
8. 把当前分支加入分支列表，去重后触发 dev 部署
9. 如果运行详情里出现阻塞动作，例如冲突解决、人工执行、人工确认，则立即提醒用户去云效处理，不继续盲等
10. 默认不阻塞等待；如果用户明确要求跟进部署结果，再调用等待脚本，或优先使用 subagent 轮询

## 本地配置

优先读取当前项目里的 `.yunxiao/project.env`：

```bash
YUNXIAO_DOMAIN="openapi-rdc.aliyuncs.com"
YUNXIAO_ORGANIZATION_ID="your_organization_id"
YUNXIAO_DEV_PIPELINE_ID="your_dev_pipeline_id"
```

只把云效相关的非敏感信息写到这里。`YUNXIAO_ACCESS_TOKEN` 必须来自环境变量，不落仓库。

## Token 要求

如果没有 `YUNXIAO_ACCESS_TOKEN`，提醒用户去这里生成：

- https://account-devops.aliyun.com/settings/personalAccessToken

权限至少需要：

- `组织管理`：所有权限点只读
- `流水线`：所有权限点只读

如果请求组织列表接口失败，优先提醒用户检查 `组织管理` 的只读权限是否已勾选。

## 快速用法

查看最近一次成功部署：

```bash
bash scripts/dev_deploy.sh latest
```

用当前分支发起 dev 部署：

```bash
bash scripts/dev_deploy.sh run
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
- 再把当前分支追加进去
- 去重后作为本次运行参数

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

## 输出要求

执行 `latest` 时，返回：

- 当前 dev 最近一次成功部署的运行 ID
- release 分支名
- 已集成的业务分支列表
- 如果存在正在运行且被阻塞的实例，返回阻塞阶段、任务、动作类型和关键信息

执行 `run` 时，返回：

- 流水线名称
- 当前分支
- 上一次已部署分支列表
- 本次实际提交的 `branchModeBranchs`
- 新的 `pipelineRunId`

如果用户明确要求持续跟踪部署结果：

- 优先使用 subagent 定时轮询
- 否则再使用 `scripts/wait_pipeline_run.sh`
- 如果检测到阻塞动作，例如 `CONFLICT_MERGE`，直接提醒用户去云效页面处理
