#!/usr/bin/env bash
set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

CONFIG_DIR="${HOME}/.yunxiao"
CONFIG_FILE="${CONFIG_DIR}/config.sh"
DEFAULT_DOMAIN="openapi-rdc.aliyuncs.com"

info() {
  printf '%b\n' "${BLUE}$*${NC}"
}

success() {
  printf '%b\n' "${GREEN}$*${NC}"
}

warning() {
  printf '%b\n' "${YELLOW}$*${NC}"
}

error() {
  printf '%b\n' "${RED}$*${NC}" >&2
}

detect_shell_rc() {
  case "${SHELL:-}" in
    */zsh)
      printf '%s\n' "${HOME}/.zshrc"
      ;;
    */bash)
      printf '%s\n' "${HOME}/.bashrc"
      ;;
    *)
      if [[ -f "${HOME}/.zshrc" ]]; then
        printf '%s\n' "${HOME}/.zshrc"
      elif [[ -f "${HOME}/.bashrc" ]]; then
        printf '%s\n' "${HOME}/.bashrc"
      fi
      ;;
  esac
}

append_shell_loader() {
  local shell_rc="$1"
  local loader_line="[ -f \"${CONFIG_FILE}\" ] && source \"${CONFIG_FILE}\""

  mkdir -p "$(dirname "$shell_rc")"
  touch "$shell_rc"

  if grep -Fq "$loader_line" "$shell_rc"; then
    success "自动加载配置已存在: ${shell_rc}"
    return 0
  fi

  {
    echo ""
    echo "# Yunxiao token auto load"
    echo "$loader_line"
  } >>"$shell_rc"

  success "已添加自动加载到: ${shell_rc}"
}

test_token() {
  local token="$1"
  local status
  local body_file

  body_file="$(mktemp)"
  status="$(
    curl -sS -o "$body_file" -w '%{http_code}' \
      -X GET \
      "https://${DEFAULT_DOMAIN}/oapi/v1/platform/organizations" \
      -H "x-yunxiao-token: ${token}" \
      -H "Content-Type: application/json"
  )"

  if [[ "$status" == "200" ]]; then
    success "Token 校验成功，可以访问组织列表接口。"
  elif [[ "$status" == "403" ]]; then
    warning "Token 已保存，但当前没有足够权限访问组织列表。"
    warning "请检查是否勾选了“组织管理 / 所有权限点只读”。"
  else
    warning "Token 已保存，但连通性测试返回 HTTP ${status}。"
    warning "请在实际部署时继续确认权限和 domain。"
  fi

  rm -f "$body_file"
}

printf '\n'
info '━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━'
info '   Yunxiao Dev Deploy - Token Setup'
info '━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━'
printf '\n'
printf '该脚本只保存全局 token，不会把敏感信息写进项目仓库。\n'
printf '项目级信息如 organizationId、pipelineId 仍然保存在 .yunxiao/project.env。\n'
printf '\n'

reuse_existing_token="false"
if [[ -f "$CONFIG_FILE" ]]; then
  warning "检测到已存在全局配置: ${CONFIG_FILE}"
  read -r -p "是否继续复用现有 token 配置? (Y/n): " reuse_token
  if [[ ! "$reuse_token" =~ ^[Nn]$ ]]; then
    reuse_existing_token="true"
    success "将保留现有 token 配置。"
  fi
fi

if [[ "$reuse_existing_token" != "true" ]]; then
  printf '请先在以下地址生成 Personal Access Token:\n'
  printf 'https://account-devops.aliyun.com/settings/personalAccessToken\n'
  printf '\n'
  printf '至少勾选以下只读权限:\n'
  printf -- '- 组织管理：所有权限点只读\n'
  printf -- '- 流水线：所有权限点只读\n'
  printf '\n'
  read -r -p "请输入你的 Yunxiao Token: " yunxiao_token

  if [[ -z "$yunxiao_token" ]]; then
    error '❌ Token 不能为空'
    exit 1
  fi

  mkdir -p "$CONFIG_DIR"
  cat >"$CONFIG_FILE" <<EOF
# Yunxiao 全局凭证配置
# 由 setup.sh 自动生成于 $(date)

export YUNXIAO_ACCESS_TOKEN="${yunxiao_token}"
EOF
  chmod 600 "$CONFIG_FILE"
  success "✅ 全局 token 已保存到: ${CONFIG_FILE}"
fi

if [[ -f "$CONFIG_FILE" ]]; then
  # shellcheck disable=SC1090
  source "$CONFIG_FILE"
fi

printf '\n'
info '正在测试 Yunxiao Token 连通性...'
test_token "${YUNXIAO_ACCESS_TOKEN}"

printf '\n'
read -r -p "是否自动追加到你的 shell 配置，以便后续会话自动加载? (y/N): " auto_load
if [[ "$auto_load" =~ ^[Yy]$ ]]; then
  shell_rc="$(detect_shell_rc || true)"
  if [[ -n "${shell_rc:-}" ]]; then
    append_shell_loader "$shell_rc"
    printf '重新打开 shell，或执行以下命令即可生效:\n'
    printf 'source %s\n' "$shell_rc"
  else
    warning '未能识别你的 shell 配置文件，请手动添加 source 行。'
  fi
fi

printf '\n'
printf '后续你可以直接使用:\n'
printf 'bash scripts/dev_deploy.sh latest\n'
printf 'bash scripts/dev_deploy.sh run --dry-run\n'
printf 'bash scripts/dev_deploy.sh run\n'
printf '\n'
