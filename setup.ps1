# ============================================================
# OpenClaw 一键部署脚本（Windows PowerShell）
# 支持飞书、钉钉、QQ、企业微信
# ============================================================
#Requires -Version 5.1

$ErrorActionPreference = "Stop"
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$DataDir = "$env:USERPROFILE\.openclaw"

function Write-Info  { Write-Host "[INFO] $args" -ForegroundColor Cyan }
function Write-Ok    { Write-Host "[OK] $args" -ForegroundColor Green }
function Write-Warn  { Write-Host "[WARN] $args" -ForegroundColor Yellow }
function Write-Err   { Write-Host "[ERROR] $args" -ForegroundColor Red }

# ============================================================
# 1. 环境检查
# ============================================================
function Test-Prerequisites {
    Write-Info "检查运行环境..."

    # Docker
    try {
        $dockerVersion = docker --version
        Write-Ok "Docker $dockerVersion"
    } catch {
        Write-Err "未找到 Docker，请安装 Docker Desktop for Windows:"
        Write-Host "  https://docs.docker.com/desktop/install/windows-install/"
        exit 1
    }

    # Docker Compose
    try {
        $composeVersion = docker compose version --short
        Write-Ok "Docker Compose $composeVersion"
    } catch {
        Write-Err "Docker Compose 不可用，请确保 Docker Desktop 已安装"
        exit 1
    }

    # Docker daemon
    try {
        docker info 2>$null | Out-Null
        Write-Ok "Docker 守护进程运行中"
    } catch {
        Write-Err "Docker 守护进程未运行，请启动 Docker Desktop"
        exit 1
    }

    # 内存检查
    $totalMem = [math]::Round((Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory / 1GB)
    if ($totalMem -lt 2) {
        Write-Warn "系统内存 ${totalMem}GB，建议至少 2GB"
    } else {
        Write-Ok "系统内存 ${totalMem}GB"
    }
}

# ============================================================
# 2. 配置 .env
# ============================================================
function Initialize-Env {
    $envFile = Join-Path $ScriptDir ".env"

    if (Test-Path $envFile) {
        Write-Warn ".env 文件已存在"
        $answer = Read-Host "是否重新配置？(y/N)"
        if ($answer -ne "y" -and $answer -ne "Y") {
            Write-Info "跳过配置，使用现有 .env"
            return
        }
    }

    Copy-Item (Join-Path $ScriptDir ".env.example") $envFile

    Write-Host ""
    Write-Host "========================================" -ForegroundColor Cyan
    Write-Host "  OpenClaw 配置向导" -ForegroundColor Cyan
    Write-Host "========================================" -ForegroundColor Cyan
    Write-Host ""

    # 模型配置
    Write-Info "--- 模型配置 ---"
    Write-Host "支持的模型提供商："
    Write-Host "  1) Claude 系列       (Anthropic)"
    Write-Host "  2) GPT / Gemini 等   (OpenAI 兼容协议)"
    Write-Host "  3) 智谱 GLM 系列     (GLM-5 / GLM-4.7 / GLM-4.6)"
    Write-Host "  4) DeepSeek          (DeepSeek-V3 / DeepSeek-R1)"
    Write-Host "  5) 其他 OpenAI 兼容  (中转站 / 自部署)"
    $protoChoice = Read-Host "选择 [1]"
    if (-not $protoChoice) { $protoChoice = "1" }

    switch ($protoChoice) {
        "3" {
            $protocol = "openai-completions"
            Write-Host "  可选模型: GLM-5, GLM-4.7, GLM-4.6, GLM-4.5-Air, GLM-4.5"
            $modelId = Read-Host "模型 ID [glm-5]"
            if (-not $modelId) { $modelId = "glm-5" }
            $baseUrl = "https://open.bigmodel.cn/api/coding/paas/v4"
            Write-Info "API 地址已自动设置: $baseUrl"
            Write-Warn "请确保已开通智谱 Coding Plan，避免 Flash/FlashX 模型产生额外费用"
        }
        "4" {
            $protocol = "openai-completions"
            $modelId = Read-Host "模型 ID [deepseek-chat]"
            if (-not $modelId) { $modelId = "deepseek-chat" }
            $baseUrl = "https://api.deepseek.com/v1"
            Write-Info "API 地址已自动设置: $baseUrl"
        }
        "5" {
            $protocol = "openai-completions"
            $modelId = Read-Host "模型 ID"
            $baseUrl = Read-Host "API Base URL (须含 /v1)"
        }
        "2" {
            $protocol = "openai-completions"
            $modelId = Read-Host "模型 ID [gpt-4o]"
            if (-not $modelId) { $modelId = "gpt-4o" }
            $baseUrl = Read-Host "API Base URL [https://api.openai.com/v1]"
            if (-not $baseUrl) { $baseUrl = "https://api.openai.com/v1" }
        }
        default {
            $protocol = "anthropic-messages"
            $modelId = Read-Host "模型 ID [claude-sonnet-4-5-20250514]"
            if (-not $modelId) { $modelId = "claude-sonnet-4-5-20250514" }
            $baseUrl = Read-Host "API Base URL [https://api.anthropic.com]"
            if (-not $baseUrl) { $baseUrl = "https://api.anthropic.com" }
        }
    }

    $apiKey = Read-Host "API Key"
    if (-not $apiKey) {
        Write-Err "API Key 不能为空"
        exit 1
    }

    # 读取并替换
    $content = Get-Content $envFile -Raw
    $content = $content -replace "(?m)^API_PROTOCOL=.*$", "API_PROTOCOL=$protocol"
    $content = $content -replace "(?m)^MODEL_ID=.*$", "MODEL_ID=$modelId"
    $content = $content -replace "(?m)^BASE_URL=.*$", "BASE_URL=$baseUrl"
    $content = $content -replace "(?m)^API_KEY=.*$", "API_KEY=$apiKey"

    # Gateway Token
    $bytes = New-Object byte[] 16
    [System.Security.Cryptography.RandomNumberGenerator]::Fill($bytes)
    $gwToken = "oc-" + [BitConverter]::ToString($bytes).Replace("-","").ToLower()
    $content = $content -replace "(?m)^OPENCLAW_GATEWAY_TOKEN=.*$", "OPENCLAW_GATEWAY_TOKEN=$gwToken"
    Write-Ok "已生成 Gateway Token: $gwToken"

    # Windows 数据目录
    $content = $content -replace "(?m)^OPENCLAW_DATA_DIR=.*$", "OPENCLAW_DATA_DIR=$DataDir"

    # IM 平台配置
    Write-Host ""
    Write-Info "--- IM 平台配置（留空跳过）---"

    # 飞书
    $enableFeishu = Read-Host "启用飞书？(y/N)"
    if ($enableFeishu -eq "y" -or $enableFeishu -eq "Y") {
        $feishuAppId = Read-Host "  飞书 App ID"
        $feishuSecret = Read-Host "  飞书 App Secret"
        $content = $content -replace "(?m)^FEISHU_APP_ID=.*$", "FEISHU_APP_ID=$feishuAppId"
        $content = $content -replace "(?m)^FEISHU_APP_SECRET=.*$", "FEISHU_APP_SECRET=$feishuSecret"
        Write-Ok "飞书已配置"
    }

    # 钉钉
    $enableDT = Read-Host "启用钉钉？(y/N)"
    if ($enableDT -eq "y" -or $enableDT -eq "Y") {
        $dtClientId = Read-Host "  钉钉 Client ID"
        $dtSecret = Read-Host "  钉钉 Client Secret"
        $dtRobot = Read-Host "  钉钉 Robot Code"
        $dtCorp = Read-Host "  钉钉 Corp ID (可选)"
        $dtAgent = Read-Host "  钉钉 Agent ID (可选)"
        $content = $content -replace "(?m)^DINGTALK_CLIENT_ID=.*$", "DINGTALK_CLIENT_ID=$dtClientId"
        $content = $content -replace "(?m)^DINGTALK_CLIENT_SECRET=.*$", "DINGTALK_CLIENT_SECRET=$dtSecret"
        $content = $content -replace "(?m)^DINGTALK_ROBOT_CODE=.*$", "DINGTALK_ROBOT_CODE=$dtRobot"
        $content = $content -replace "(?m)^DINGTALK_CORP_ID=.*$", "DINGTALK_CORP_ID=$dtCorp"
        $content = $content -replace "(?m)^DINGTALK_AGENT_ID=.*$", "DINGTALK_AGENT_ID=$dtAgent"
        Write-Ok "钉钉已配置"
    }

    # QQ
    $enableQQ = Read-Host "启用 QQ 机器人？(y/N)"
    if ($enableQQ -eq "y" -or $enableQQ -eq "Y") {
        Write-Host "  QQ 接入方式："
        Write-Host "    1) 官方 QQ Bot API"
        Write-Host "    2) NapCat (OneBot v11)"
        $qqMode = Read-Host "  选择 [1]"
        if ($qqMode -eq "2") {
            $napPort = Read-Host "  NapCat 反向 WS 端口"
            $napHttp = Read-Host "  NapCat HTTP URL (可选)"
            $napToken = Read-Host "  NapCat Access Token"
            $napAdmins = Read-Host "  管理员 QQ 号（多个逗号分隔）"
            $content = $content -replace "(?m)^NAPCAT_REVERSE_WS_PORT=.*$", "NAPCAT_REVERSE_WS_PORT=$napPort"
            $content = $content -replace "(?m)^NAPCAT_HTTP_URL=.*$", "NAPCAT_HTTP_URL=$napHttp"
            $content = $content -replace "(?m)^NAPCAT_ACCESS_TOKEN=.*$", "NAPCAT_ACCESS_TOKEN=$napToken"
            $content = $content -replace "(?m)^NAPCAT_ADMINS=.*$", "NAPCAT_ADMINS=$napAdmins"
        } else {
            $qqAppId = Read-Host "  QQ Bot App ID"
            $qqSecret = Read-Host "  QQ Bot Client Secret"
            $content = $content -replace "(?m)^QQBOT_APP_ID=.*$", "QQBOT_APP_ID=$qqAppId"
            $content = $content -replace "(?m)^QQBOT_CLIENT_SECRET=.*$", "QQBOT_CLIENT_SECRET=$qqSecret"
        }
        Write-Ok "QQ 机器人已配置"
    }

    # 企业微信
    $enableWecom = Read-Host "启用企业微信？(y/N)"
    if ($enableWecom -eq "y" -or $enableWecom -eq "Y") {
        $wecomToken = Read-Host "  企业微信 Token"
        $wecomAes = Read-Host "  企业微信 EncodingAESKey"
        $content = $content -replace "(?m)^WECOM_TOKEN=.*$", "WECOM_TOKEN=$wecomToken"
        $content = $content -replace "(?m)^WECOM_ENCODING_AES_KEY=.*$", "WECOM_ENCODING_AES_KEY=$wecomAes"
        Write-Ok "企业微信已配置"
    }

    # Telegram
    $enableTG = Read-Host "启用 Telegram？(y/N)"
    if ($enableTG -eq "y" -or $enableTG -eq "Y") {
        $tgToken = Read-Host "  Telegram Bot Token"
        $content = $content -replace "(?m)^TELEGRAM_BOT_TOKEN=.*$", "TELEGRAM_BOT_TOKEN=$tgToken"
        Write-Ok "Telegram 已配置"
    }

    Set-Content $envFile $content -NoNewline
    Write-Host ""
    Write-Ok "配置完成！.env 已保存"
}

# ============================================================
# 3. 创建数据目录
# ============================================================
function Initialize-Dirs {
    Write-Info "准备数据目录..."
    if (-not (Test-Path $DataDir)) {
        New-Item -ItemType Directory -Path $DataDir -Force | Out-Null
    }
    Write-Ok "数据目录: $DataDir"
}

# ============================================================
# 4. 拉取镜像并启动
# ============================================================
function Start-Service {
    Write-Info "拉取 Docker 镜像（首次可能需要几分钟）..."
    Set-Location $ScriptDir
    docker compose pull openclaw-gateway

    Write-Info "启动 OpenClaw..."
    docker compose up -d openclaw-gateway

    Write-Host ""
    Write-Info "等待服务就绪..."
    $retries = 0
    while ($retries -lt 30) {
        try {
            $response = Invoke-WebRequest -Uri "http://127.0.0.1:18789/healthz" -UseBasicParsing -TimeoutSec 2 -ErrorAction Stop
            if ($response.StatusCode -eq 200) {
                Write-Host ""
                Write-Ok "OpenClaw 已成功启动！"
                Write-Host ""
                Write-Host "========================================" -ForegroundColor Green
                Write-Host "  部署完成！" -ForegroundColor Green
                Write-Host "========================================" -ForegroundColor Green
                Write-Host ""
                Write-Host "  控制面板: http://127.0.0.1:18789/"
                $token = (Select-String -Path (Join-Path $ScriptDir ".env") -Pattern "^OPENCLAW_GATEWAY_TOKEN=(.+)$").Matches.Groups[1].Value
                Write-Host "  Gateway Token: $token"
                Write-Host ""
                Write-Host "  常用命令："
                Write-Host "    查看日志:  docker compose logs -f"
                Write-Host "    停止服务:  docker compose down"
                Write-Host "    重启服务:  docker compose restart"
                Write-Host "    进入容器:  docker compose exec openclaw-gateway /bin/bash"
                Write-Host ""
                return
            }
        } catch { }
        $retries++
        Write-Host "." -NoNewline
        Start-Sleep -Seconds 2
    }

    Write-Warn "服务启动超时，查看日志排查问题："
    docker compose logs --tail=50 openclaw-gateway
}

# ============================================================
# 主流程
# ============================================================
Write-Host ""
Write-Host "+==========================================+" -ForegroundColor Cyan
Write-Host "|   OpenClaw 一键部署（中国 IM 整合版）    |" -ForegroundColor Cyan
Write-Host "|   支持: 飞书 / 钉钉 / QQ / 企业微信     |" -ForegroundColor Cyan
Write-Host "+==========================================+" -ForegroundColor Cyan
Write-Host ""

Test-Prerequisites
Write-Host ""
Initialize-Env
Write-Host ""
Initialize-Dirs
Write-Host ""
Start-Service
