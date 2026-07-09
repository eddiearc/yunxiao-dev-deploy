# yunxiao-dev-deploy

阿里云云效 dev 部署 skill，兼容 [skills](https://github.com/vercel-labs/skills) 分发方式，可安装到 Codex、Claude Code 等 agent。

它解决的是一个常见但容易出错的流程：

- 只允许从非主分支触发 dev 部署
- 要求当前分支已经推送到远程
- 自动发现或校验 `organizationId`
- 从项目本地配置读取 dev 流水线
- 拒绝名称带 `prod` 的流水线
- 自动识别流水线 source 模式（读 `data.isBranchMode`）：分支模式走 opencli 页面点击触发，普通代码源走 OpenAPI `runningBranchs`
- 分支模式禁止 POP API 触发（会重建分支集成、重复合并历史分支，让已解决的冲突反复出现），改用 opencli 只把当前分支加入运行配置，不删除、不重排其他分支
- opencli 未安装时不回退 API，而是打印页面手动触发指引并终止
- 普通代码源流水线下用 repo URL -> 当前分支构造 `runningBranchs`，触发后校验 run detail 的实际 source branch
- 识别阻塞态；如果是 `CONFLICT_MERGE`，默认优先在 `releaseBranch` 解决，且优先使用独立 git worktree 处理，修改业务分支前必须得到用户明确答复

## 目录结构

```text
SKILL.md
scripts/
  common.sh
  setup.sh
  dev_deploy.sh
  wait_pipeline_run.sh
examples/
  .yunxiao/project.env.example
```

## 安装

推荐直接用 `skills` CLI 从 GitHub 安装。

同时安装到 Codex 和 Claude Code：

```bash
npx skills add eddiearc/yunxiao-dev-deploy -g -a codex -a claude-code -y
```

只安装到 Codex：

```bash
npx skills add eddiearc/yunxiao-dev-deploy -g -a codex -y
```

只安装到 Claude Code：

```bash
npx skills add eddiearc/yunxiao-dev-deploy -g -a claude-code -y
```

查看是否安装成功：

```bash
npx skills ls -g
```

更新：

```bash
npx skills update
```

### 手工安装

如果你不想依赖 `skills` CLI，也可以手工复制。

把这个目录复制到你的 agent skills 目录。

Codex：

```bash
mkdir -p "$CODEX_HOME/skills"
cp -R yunxiao-dev-deploy "$CODEX_HOME/skills/yunxiao-dev-deploy"
```

如果你的环境没有设置 `CODEX_HOME`，通常是 `~/.codex`。

Claude Code：

```bash
mkdir -p "$HOME/.claude/skills"
cp -R yunxiao-dev-deploy "$HOME/.claude/skills/yunxiao-dev-deploy"
```

## Token 配置

推荐先运行一次：

```bash
bash scripts/setup.sh
```

这个脚本会：

- 把 `YUNXIAO_ACCESS_TOKEN` 保存到 `~/.yunxiao/config.sh`
- 可选追加 `source ~/.yunxiao/config.sh` 到 `~/.zshrc` 或 `~/.bashrc`
- 顺手验证 token 是否能访问组织列表接口，并提醒完整 dev 部署所需的额外权限

如果你不想跑向导，也可以手动配置：

```bash
mkdir -p ~/.yunxiao
cat > ~/.yunxiao/config.sh <<'EOF'
export YUNXIAO_ACCESS_TOKEN="your_yunxiao_token"
EOF
chmod 600 ~/.yunxiao/config.sh
```

`YUNXIAO_ACCESS_TOKEN` 不要写进仓库。

## 项目内配置

在你的项目根目录创建 `.yunxiao/project.env`：

```bash
YUNXIAO_DOMAIN="openapi-rdc.aliyuncs.com"
YUNXIAO_ORGANIZATION_ID="your_organization_id"
YUNXIAO_DEV_PIPELINE_ID="your_dev_pipeline_id"
```

这里只保存项目级的非敏感配置，不保存 token。

## Token 权限

创建地址：

- <https://account-devops.aliyun.com/settings/personalAccessToken>

执行完整 dev 部署，建议至少勾选：

- `组织管理 / 所有权限点只读`
- `流水线 / 只读`
- `流水线运行实例 / 读写`

可选补充：

- `流水线运行任务 / 只读`

权限矩阵：

- `dev_deploy.sh latest`：`流水线 / 只读` + `流水线运行实例 / 只读`
- `dev_deploy.sh run`：`流水线 / 只读` + `流水线运行实例 / 读写`
- `wait_pipeline_run.sh`：`流水线运行实例 / 只读`
- 自动发现 `organizationId`：`组织管理 / 所有权限点只读`
- 查看任务日志：`流水线运行任务 / 只读`

## 用法

首次配置全局 token：

```bash
bash scripts/setup.sh
```

查看最近一次成功部署：

```bash
bash scripts/dev_deploy.sh latest
```

只做预检查：

```bash
bash scripts/dev_deploy.sh run --dry-run
```

执行部署：

```bash
bash scripts/dev_deploy.sh run
```

首次通过链接注入流水线 ID：

```bash
bash scripts/dev_deploy.sh run \
  --pipeline-link "https://flow.aliyun.com/pipelines/123456/current"
```

等待某次运行：

```bash
bash scripts/wait_pipeline_run.sh 1234
```

## 分支模式：页面点击触发，禁止 POP API

**为什么不用 API 自动触发？** 分支模式（`data.isBranchMode=true`）流水线是「分支合并
发布 / 分支集成」模型：一次 run 会把一组 feature 分支合并到 release 分支再发布。如果用
POP API（`POST .../pipelines/{id}/runs`）触发，云效会**重建整个分支集成 run，把历史分支
重新合并一遍**——你上一次辛辛苦苦解决过的合并冲突，可能每次部署都要重新解一遍。这在多人
共享的 dev 流水线上尤其痛。

所以本 skill 对分支模式**默认改为「页面点击」触发**（等价于人在云效页面点「运行」）：

- 依赖 [opencli](https://www.npmjs.com/package/@jackwener/opencli) 打开运行配置弹窗，
  只把当前分支加入运行配置；如果分支已在列表里，不删除、不重排其他分支，直接运行。
- 触发前做幂等与并发检查：同一分支同一 commit 的非 POP 页面 run 已存在且处于
  `SUCCESS`/`RUNNING`/`WAITING` 时直接复用；已有其它 `WAITING`/`RUNNING` run 时先等它结束。
- **没装 opencli 时不会偷偷回退到 POP API**，而是停下来打印指引：给出流水线 URL、解释
  原因，并建议 `npm install -g @jackwener/opencli` 或手动到页面按同样规则触发。
- 因此分支模式下 `--replace-branches` / `--allow-shrink` 已不再支持（那是 POP API 时代的
  整集替换语义）；如需替换整个分支集，请手动到云效页面调整。

普通代码源（`running_branch`，`data.repo` 存在且非分支模式）不受影响，继续用 OpenAPI
`runningBranchs` 触发——它只跑单一分支、不做分支集成合并，用 API 是安全的。

触发后的 run 查询、等待、`CONFLICT_MERGE` 冲突处理仍然走 API（`ExecutePipelineJobAction`），
只有「初次触发」这一步用页面点击。

## 冲突处理工作区约定

当云效 `run` 因 `CONFLICT_MERGE` 阻塞时，默认不要直接在当前本地开发分支所在工作目录里处理冲突。

推荐做法：

- 保留当前开发分支工作区不动
- 为当前 `pipelineRunId` 新建独立 git worktree
- 在该 worktree 内检出 `releaseBranch`
- 只在该 worktree 内完成 `fetch / merge / resolve / commit / push`
- 续跑当前 run 后，删除临时 worktree

这样可以避免：

- 污染当前开发分支的工作区
- 把 release 分支冲突修复误提交到本地业务分支
- 多轮 `CONFLICT_MERGE` 时把本地现场越搞越乱

## 依赖

- `bash`
- `curl`
- `jq`
- `git`
- [`opencli`](https://www.npmjs.com/package/@jackwener/opencli)（可选；仅分支模式自动页面触发需要，`npm install -g @jackwener/opencli`。未安装时分支模式会打印手动触发指引并终止）

## 许可证

MIT
