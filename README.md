# yunxiao-dev-deploy-skill

阿里云云效 dev 部署 Skill，面向 Codex 风格的本地 skill 目录。

它解决的是一个常见但容易出错的流程：

- 只允许从非主分支触发 dev 部署
- 要求当前分支已经推送到远程
- 自动发现或校验 `organizationId`
- 从项目本地配置读取 dev 流水线
- 拒绝名称带 `prod` 的流水线
- 读取最近一次成功部署里已经集成的分支
- 把当前分支加入 `branchModeBranchs` 后再触发
- 识别阻塞态，例如冲突解决，直接提醒用户去云效页面处理

## 目录结构

```text
SKILL.md
scripts/
  common.sh
  dev_deploy.sh
  wait_pipeline_run.sh
examples/
  .yunxiao/project.env.example
```

## 安装

把这个目录复制到你的 Codex skills 目录：

```bash
mkdir -p "$CODEX_HOME/skills"
cp -R yunxiao-dev-deploy-skill "$CODEX_HOME/skills/yunxiao-dev-deploy"
```

如果你的环境没有设置 `CODEX_HOME`，通常是 `~/.codex`。

## 项目内配置

在你的项目根目录创建 `.yunxiao/project.env`：

```bash
YUNXIAO_DOMAIN="openapi-rdc.aliyuncs.com"
YUNXIAO_ORGANIZATION_ID="your_organization_id"
YUNXIAO_DEV_PIPELINE_ID="your_dev_pipeline_id"
```

`YUNXIAO_ACCESS_TOKEN` 不要写进仓库，走环境变量。

## Token 权限

创建地址：

- <https://account-devops.aliyun.com/settings/personalAccessToken>

建议至少勾选：

- `组织管理`：所有权限点只读
- `流水线`：所有权限点只读

## 用法

查看最近一次成功部署：

```bash
bash "$CODEX_HOME/skills/yunxiao-dev-deploy/scripts/dev_deploy.sh" latest
```

只做预检查：

```bash
bash "$CODEX_HOME/skills/yunxiao-dev-deploy/scripts/dev_deploy.sh" run --dry-run
```

执行部署：

```bash
bash "$CODEX_HOME/skills/yunxiao-dev-deploy/scripts/dev_deploy.sh" run
```

首次通过链接注入流水线 ID：

```bash
bash "$CODEX_HOME/skills/yunxiao-dev-deploy/scripts/dev_deploy.sh" run \
  --pipeline-link "https://flow.aliyun.com/pipelines/123456/current"
```

等待某次运行：

```bash
bash "$CODEX_HOME/skills/yunxiao-dev-deploy/scripts/wait_pipeline_run.sh" 1234
```

## 依赖

- `bash`
- `curl`
- `jq`
- `git`

## 许可证

MIT
