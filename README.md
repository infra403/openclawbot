# OpenClaw 一键部署工具包

支持飞书 / 钉钉 / QQ / 企业微信 / Telegram

## 前置条件

安装 Docker Desktop：
- **Windows**: https://docs.docker.com/desktop/install/windows-install/
- **macOS**: https://docs.docker.com/desktop/install/mac-install/ 或 `brew install --cask docker`
- **Linux**: `curl -fsSL https://get.docker.com | sh`

最低配置：2GB 内存，10GB 磁盘空间

## 一键部署

### macOS / Linux

```bash
chmod +x setup.sh
./setup.sh
```

### Windows (PowerShell)

```powershell
# 如遇执行策略限制，先运行：
Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope CurrentUser

.\setup.ps1
```

## 部署完成后

- 控制面板：http://127.0.0.1:18789/
- 用生成的 Gateway Token 登录

## 常用命令

```bash
# 查看日志
docker compose logs -f

# 停止
docker compose down

# 重启
docker compose restart

# 更新镜像
docker compose pull && docker compose up -d

# 进入容器
docker compose exec openclaw-gateway /bin/bash
```

## IM 平台接入指引

### 飞书
1. 前往 https://open.feishu.cn 创建企业自建应用
2. 获取 App ID 和 App Secret
3. 配置事件订阅（最容易遗漏）
4. 添加权限：`im:message`、`im:message.send_as_bot`、`im:resource`

### 钉钉
1. 前往 https://open-dev.dingtalk.com 创建企业内部应用
2. 创建机器人，获取 Client ID、Client Secret、Robot Code
3. 配置消息接收地址

### QQ 机器人
- 官方 API：前往 https://q.qq.com 申请
- NapCat 方式：部署 NapCat，配置反向 WebSocket 连接

### 企业微信
1. 前往 https://work.weixin.qq.com 创建应用
2. 配置接收消息 API，获取 Token 和 EncodingAESKey

## 文件说明

```
openclaw-deploy-kit/
├── docker-compose.yml   # Docker 编排配置
├── .env.example         # 环境变量模板
├── setup.sh             # Linux/macOS 一键部署
├── setup.ps1            # Windows 一键部署
└── README.md            # 本文件
```

## 故障排查

```bash
# 检查容器状态
docker compose ps

# 检查健康状态
curl http://127.0.0.1:18789/healthz

# 查看最近日志
docker compose logs --tail=100

# 重置配置（删除后重启会重新生成）
rm ~/.openclaw/openclaw.json
docker compose restart

# 权限问题（Linux）
sudo chown -R 1000:1000 ~/.openclaw
```
