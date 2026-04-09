# yunxiao-dev-deploy

阿里云云效 dev 部署 skill，兼容 [skills](https://github.com/vercel-labs/skills) 分发方式，可安装到 Codex、Claude Code 等 agent。

它解决的是一个常见但容易出错的流程：

- 只允许从非主分支触发 dev 部署
- 要求当前分支已经推送到远程
- 自动发现或校验 `organizationId`
- 从项目本地配置读取 dev 流水线
- 拒绝名称带 `prod` 的流水线
- 读取最近一次成功部署里已经集成的分支
- 默认把当前分支加入 `branchModeBranchs` 后再触发，不允许静默删掉已有分支
- 如果确实要覆盖分支集，必须显式传 `--replace-branches`；如果发生 shrink，还要再加 `--allow-shrink`
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

显式覆盖分支集：

```bash
bash scripts/dev_deploy.sh run \
  --replace-branches "feature-a,feature-b" \
  --allow-shrink
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

## 分支模式保护

默认 `run` 的语义是：

- 读取最近一次成功部署里的分支集
- 把当前分支追加进去
- 去重后再触发

这意味着脚本默认不会把别人已经在 dev 上的分支静默踢掉。

如果你传了 `--replace-branches`，脚本会把它视为“我明确要覆盖分支集”。  
但只要这个新分支集会删掉上一次成功部署里的任意分支，仍然会直接失败，除非你额外显式传：

```bash
--allow-shrink
```

这样误操作至少需要两个明确动作，不能再被默认参数悄悄覆盖。

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

## 许可证

MIT
