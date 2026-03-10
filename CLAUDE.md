# OpenClaw Deploy Kit - CLAUDE.md

## Project Overview

OpenClaw 一键部署工具包，目标是让用户 `bash ./setup.sh` 一次跑通，打开输出的 URL 直接能用。
Docker 镜像：`justlikemaki/openclaw-docker-cn-im:latest`，OpenClaw v2026.3.8。

## Architecture

```
setup.sh (交互式配置)
  → 生成 .env
  → cp .env.example → .env + sed 替换
  → docker compose up
  → 等待健康 → 修复插件权限 → python3 修补 openclaw.json → 重启
  → 等待健康 → 自动批准设备配对 → 清理过期插件条目
  → 输出带 token 的 URL
```

### Key Files

- `setup.sh` — 主部署脚本 (Linux/macOS)，所有 `read` 必须带 `< /dev/tty`
- `setup.ps1` — Windows 版（尚未同步最新修复）
- `docker-compose.yml` — 单容器 gateway 服务 + installer 工具容器
- `.env.example` — 环境变量模板，`.env` 由 setup.sh 生成（含密钥，已 gitignore）

### Container Internals

- 容器内 init 脚本 `/usr/local/bin/init.sh` 每次启动都会从环境变量重写 openclaw.json
- init 脚本**不会覆盖** `trustedProxies`、`allowedOrigins`（我们添加的配置可持久化）
- init 脚本**会重新写入** `feishu-openclaw-plugin` 过期条目，需要在重启后再次清理
- 配置路径：容器内 `/home/node/.openclaw/openclaw.json`，宿主机 `~/.openclaw/openclaw.json`

## Critical Technical Decisions

### Gateway bind=lan

必须用 `bind=lan`（0.0.0.0），因为 Docker 端口映射无法到达 `bind=loopback`（127.0.0.1）。
`bind=lan` 副作用：所有 WebSocket 连接都要求 device pairing，包括容器内部 agent 自己的连接。

**解决方案：** 部署后执行 `docker exec openclaw-gateway openclaw devices approve --latest` 自动批准。

### Token 注入

Control UI SPA 支持 URL 参数 `?token=xxx`，JS 函数 `Vf()` 解析后存入 localStorage `openclaw.control.settings.v1`，然后从 URL 中剥离。首次打开后无需再传 token。

### 访问路径

使用根路径 `http://host:port/overview` 而非 `/dashboard/overview`，后者会导致 `favicon.svg` 和 `control-ui-config.json` 404。

### python3 配置修补

setup.sh 在首次启动后用 python3 修补 openclaw.json：
- `controlUi.allowedOrigins` — 添加 localhost + 127.0.0.1 含端口
- `controlUi.allowInsecureAuth=true` — 允许 HTTP 访问
- `controlUi.dangerouslyDisableDeviceAuth=true` — 跳过 Control UI 的设备认证
- `gateway.trustedProxies` — Docker 子网
- 清理过期 `feishu-openclaw-plugin` 条目
- 根据 .env 中的 IM 凭证启用对应插件

### 插件权限

第三方插件（extensions 目录）必须 root 拥有（uid=0），否则会被 "suspicious ownership" 拦截。
setup.sh 每次用 `docker exec chown -R root:root` 修复。

## Known Issues

- `feishu-openclaw-plugin` 过期条目：容器 init 每次重启都会重新写入，需要在重启后清理
- `setup.ps1` (Windows) 尚未同步 `< /dev/tty`、设备配对、过期条目清理等修复
- `auth.mode=none` + `bind=lan` 会导致容器拒绝启动（"Refusing to bind gateway to lan without auth"）
- `gateway.dangerouslyDisableDeviceAuth` 是无效的顶层 key，只能在 `controlUi` 下使用

## Coding Conventions

- setup.sh 中所有 `read -rp` 必须加 `< /dev/tty`，防止管道/stdin 污染输入
- sed 替换用 `|` 作分隔符（URL 中含 `/`）
- 环境变量写入用 `sed -i.bak`，结束后 `rm -f .bak`
- 错误处理函数：`info()`、`ok()`、`warn()`、`err()`，带颜色前缀
- `set -euo pipefail` 严格模式

## Gateway Config Schema (Valid Keys)

```
gateway.auth.mode, gateway.auth.token, gateway.auth.password
gateway.controlUi.allowedOrigins, gateway.controlUi.allowInsecureAuth
gateway.controlUi.dangerouslyDisableDeviceAuth, gateway.controlUi.enabled
gateway.trustedProxies
gateway.nodes.allowCommands, gateway.nodes.browser, gateway.nodes.denyCommands
gateway.tools.allow, gateway.tools.deny
```

## Model Providers

| Provider | Protocol | Base URL |
|----------|----------|----------|
| Anthropic | anthropic-messages | https://api.anthropic.com |
| OpenAI | openai-completions | https://api.openai.com/v1 |
| 智谱 GLM | openai-completions | https://open.bigmodel.cn/api/coding/paas/v4 |
| DeepSeek | openai-completions | https://api.deepseek.com/v1 |

## Testing

从零测试流程：
```bash
cd ~/openclaw-deploy-kit
docker compose down -v && rm -f .env && rm -rf ~/.openclaw
bash ./setup.sh
# 自动化测试输入：printf '3\n\n<apikey>\nN\nN\nN\nN\nN\n' | bash ./setup.sh
```

验证清单：
1. 容器 healthy
2. URL `?token=xxx` 打开后 gateway 连接成功（状态"正常"）
3. 聊天页面发消息有回复
4. Agent 的 gateway tool 返回 `"ok": true`（设备配对已批准）
