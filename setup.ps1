# ============================================================
# OpenClaw 一键部署脚本（Windows PowerShell）
# 支持飞书、钉钉、QQ、企业微信
# ============================================================
#Requires -Version 5.1

$ErrorActionPreference = "Continue"
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$DataDir = Join-Path $env:USERPROFILE ".openclaw"

function Write-Info  { param([string]$Message) Write-Host "[INFO] $Message" -ForegroundColor Cyan }
function Write-Ok    { param([string]$Message) Write-Host "[OK] $Message" -ForegroundColor Green }
function Write-Warn  { param([string]$Message) Write-Host "[WARN] $Message" -ForegroundColor Yellow }
function Write-Err   { param([string]$Message) Write-Host "[ERROR] $Message" -ForegroundColor Red }

# ============================================================
# 1. 环境检查
# ============================================================
function Test-Prerequisites {
    Write-Info "检查运行环境..."

    # Docker
    $dockerPath = Get-Command docker -ErrorAction SilentlyContinue
    if (-not $dockerPath) {
        Write-Err "未找到 Docker，请安装 Docker Desktop for Windows:"
        Write-Host "  https://docs.docker.com/desktop/install/windows-install/"
        exit 1
    }
    $dockerVersion = & docker --version 2>&1
    Write-Ok "Docker $dockerVersion"

    # Docker Compose
    $composeVersion = & docker compose version --short 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-Err "Docker Compose 不可用，请确保 Docker Desktop 已安装"
        exit 1
    }
    Write-Ok "Docker Compose $composeVersion"

    # Docker daemon
    & docker info 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) {
        Write-Err "Docker 守护进程未运行，请启动 Docker Desktop"
        exit 1
    }
    Write-Ok "Docker 守护进程运行中"

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

    # 逐行读取并替换（避免 regex 转义问题）
    $lines = Get-Content $envFile
    $newLines = @()
    foreach ($line in $lines) {
        if ($line -match "^API_PROTOCOL=") { $newLines += "API_PROTOCOL=$protocol" }
        elseif ($line -match "^MODEL_ID=") { $newLines += "MODEL_ID=$modelId" }
        elseif ($line -match "^BASE_URL=") { $newLines += "BASE_URL=$baseUrl" }
        elseif ($line -match "^API_KEY=") { $newLines += "API_KEY=$apiKey" }
        elseif ($line -match "^OPENCLAW_GATEWAY_TOKEN=") { $newLines += "OPENCLAW_GATEWAY_TOKEN=$gwToken" }
        elseif ($line -match "^OPENCLAW_DATA_DIR=") { $newLines += "OPENCLAW_DATA_DIR=$DataDir" }
        else { $newLines += $line }
    }

    # Gateway Token（兼容 PS 5.1）
    $rng = New-Object System.Security.Cryptography.RNGCryptoServiceProvider
    $bytes = New-Object byte[] 16
    $rng.GetBytes($bytes)
    $rng.Dispose()
    $gwToken = "oc-" + [BitConverter]::ToString($bytes).Replace("-","").ToLower()

    # 再替换 token 行（上面循环时 $gwToken 还没生成，这里修正）
    $finalLines = @()
    foreach ($line in $newLines) {
        if ($line -match "^OPENCLAW_GATEWAY_TOKEN=") {
            $finalLines += "OPENCLAW_GATEWAY_TOKEN=$gwToken"
        } else {
            $finalLines += $line
        }
    }

    Write-Ok "已生成 Gateway Token: $gwToken"

    # IM 平台配置
    Write-Host ""
    Write-Info "--- IM 平台配置（留空跳过）---"

    # 飞书
    $enableFeishu = Read-Host "启用飞书？(y/N)"
    if ($enableFeishu -eq "y" -or $enableFeishu -eq "Y") {
        $feishuAppId = Read-Host "  飞书 App ID"
        $feishuSecret = Read-Host "  飞书 App Secret"
        $finalLines = $finalLines | ForEach-Object {
            if ($_ -match "^FEISHU_APP_ID=") { "FEISHU_APP_ID=$feishuAppId" }
            elseif ($_ -match "^FEISHU_APP_SECRET=") { "FEISHU_APP_SECRET=$feishuSecret" }
            else { $_ }
        }
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
        $finalLines = $finalLines | ForEach-Object {
            if ($_ -match "^DINGTALK_CLIENT_ID=") { "DINGTALK_CLIENT_ID=$dtClientId" }
            elseif ($_ -match "^DINGTALK_CLIENT_SECRET=") { "DINGTALK_CLIENT_SECRET=$dtSecret" }
            elseif ($_ -match "^DINGTALK_ROBOT_CODE=") { "DINGTALK_ROBOT_CODE=$dtRobot" }
            elseif ($_ -match "^DINGTALK_CORP_ID=") { "DINGTALK_CORP_ID=$dtCorp" }
            elseif ($_ -match "^DINGTALK_AGENT_ID=") { "DINGTALK_AGENT_ID=$dtAgent" }
            else { $_ }
        }
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
            $finalLines = $finalLines | ForEach-Object {
                if ($_ -match "^NAPCAT_REVERSE_WS_PORT=") { "NAPCAT_REVERSE_WS_PORT=$napPort" }
                elseif ($_ -match "^NAPCAT_HTTP_URL=") { "NAPCAT_HTTP_URL=$napHttp" }
                elseif ($_ -match "^NAPCAT_ACCESS_TOKEN=") { "NAPCAT_ACCESS_TOKEN=$napToken" }
                elseif ($_ -match "^NAPCAT_ADMINS=") { "NAPCAT_ADMINS=$napAdmins" }
                else { $_ }
            }
        } else {
            $qqAppId = Read-Host "  QQ Bot App ID"
            $qqSecret = Read-Host "  QQ Bot Client Secret"
            $finalLines = $finalLines | ForEach-Object {
                if ($_ -match "^QQBOT_APP_ID=") { "QQBOT_APP_ID=$qqAppId" }
                elseif ($_ -match "^QQBOT_CLIENT_SECRET=") { "QQBOT_CLIENT_SECRET=$qqSecret" }
                else { $_ }
            }
        }
        Write-Ok "QQ 机器人已配置"
    }

    # 企业微信
    $enableWecom = Read-Host "启用企业微信？(y/N)"
    if ($enableWecom -eq "y" -or $enableWecom -eq "Y") {
        $wecomToken = Read-Host "  企业微信 Token"
        $wecomAes = Read-Host "  企业微信 EncodingAESKey"
        $finalLines = $finalLines | ForEach-Object {
            if ($_ -match "^WECOM_TOKEN=") { "WECOM_TOKEN=$wecomToken" }
            elseif ($_ -match "^WECOM_ENCODING_AES_KEY=") { "WECOM_ENCODING_AES_KEY=$wecomAes" }
            else { $_ }
        }
        Write-Ok "企业微信已配置"
    }

    # Telegram
    $enableTG = Read-Host "启用 Telegram？(y/N)"
    if ($enableTG -eq "y" -or $enableTG -eq "Y") {
        $tgToken = Read-Host "  Telegram Bot Token"
        $finalLines = $finalLines | ForEach-Object {
            if ($_ -match "^TELEGRAM_BOT_TOKEN=") { "TELEGRAM_BOT_TOKEN=$tgToken" }
            else { $_ }
        }
        Write-Ok "Telegram 已配置"
    }

    $finalLines | Set-Content $envFile -Encoding UTF8
    Write-Host ""
    Write-Ok "配置完成！.env 已保存到 $envFile"
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
# 辅助: 安全地给 PSObject 设置属性
# ============================================================
function Set-JsonProperty {
    param($Object, [string]$Name, $Value)
    if ($Object.PSObject.Properties[$Name]) {
        $Object.$Name = $Value
    } else {
        $Object | Add-Member -NotePropertyName $Name -NotePropertyValue $Value
    }
}

# ============================================================
# 辅助: 修复 openclaw.json
# ============================================================
function Repair-OpenClawConfig {
    param([string]$ConfigPath, [string]$GwPort, [string]$EnvFile)

    if (-not (Test-Path $ConfigPath)) {
        Write-Warn "配置文件不存在，跳过修复"
        return
    }

    $config = Get-Content $ConfigPath -Raw | ConvertFrom-Json

    # 确保 gateway 和 controlUi 节点存在
    if (-not $config.gateway) { Set-JsonProperty $config "gateway" ([PSCustomObject]@{}) }
    $gw = $config.gateway
    if (-not $gw.controlUi) { Set-JsonProperty $gw "controlUi" ([PSCustomObject]@{}) }
    $ui = $gw.controlUi

    # 1. 修复 allowedOrigins
    $origins = @("http://localhost", "http://localhost:$GwPort", "http://127.0.0.1", "http://127.0.0.1:$GwPort")
    Set-JsonProperty $ui "allowedOrigins" $origins
    Set-JsonProperty $ui "allowInsecureAuth" $true
    Set-JsonProperty $ui "dangerouslyDisableDeviceAuth" $true
    Write-Ok "allowedOrigins + disableDeviceAuth"

    # 2. trustedProxies
    $proxies = @("172.16.0.0/12", "192.168.0.0/16", "127.0.0.1/32")
    Set-JsonProperty $gw "trustedProxies" $proxies
    Write-Ok "trustedProxies"

    # 3. 清理过期 feishu-openclaw-plugin
    if ($config.plugins -and $config.plugins.entries -and $config.plugins.entries.PSObject.Properties["feishu-openclaw-plugin"]) {
        $config.plugins.entries.PSObject.Properties.Remove("feishu-openclaw-plugin")
        Write-Ok "清理过期条目 feishu-openclaw-plugin"
    }

    # 4. 根据 .env 启用 IM 插件
    if (Test-Path $EnvFile) {
        $envVars = @{}
        Get-Content $EnvFile | ForEach-Object {
            if ($_ -match "^([^#][^=]+)=(.+)$") {
                $envVars[$Matches[1].Trim()] = $Matches[2].Trim()
            }
        }

        if (-not $config.plugins) { Set-JsonProperty $config "plugins" ([PSCustomObject]@{}) }
        if (-not $config.plugins.entries) { Set-JsonProperty $config.plugins "entries" ([PSCustomObject]@{}) }
        $entries = $config.plugins.entries

        $imMap = @{
            "DINGTALK_CLIENT_ID"    = "dingtalk"
            "QQBOT_APP_ID"          = "qqbot"
            "NAPCAT_REVERSE_WS_PORT" = "qq"
            "WECOM_TOKEN"           = "wecom"
        }
        foreach ($envKey in $imMap.Keys) {
            $pluginId = $imMap[$envKey]
            if ($envVars[$envKey]) {
                if (-not $entries.PSObject.Properties[$pluginId]) {
                    Set-JsonProperty $entries $pluginId ([PSCustomObject]@{ enabled = $true })
                } else {
                    Set-JsonProperty $entries.$pluginId "enabled" $true
                }
                Write-Ok "启用插件: $pluginId"
            }
        }
    }

    $config | ConvertTo-Json -Depth 20 | Set-Content $ConfigPath -Encoding UTF8
    Write-Ok "配置已保存"
}

# ============================================================
# 4. 拉取镜像并启动
# ============================================================
function Start-OpenClaw {
    Write-Info "拉取 Docker 镜像（首次可能需要几分钟）..."
    Set-Location $ScriptDir
    & docker compose pull openclaw-gateway

    # 确保没有残留容器
    & docker compose down 2>&1 | Out-Null

    Write-Info "启动 OpenClaw..."
    & docker compose up -d openclaw-gateway

    Write-Host ""
    Write-Info "等待服务初始化（首次约 15 秒）..."
    Start-Sleep -Seconds 12

    $envFile = Join-Path $ScriptDir ".env"
    $gwPort = "18789"
    $portMatch = Select-String -Path $envFile -Pattern "^OPENCLAW_GATEWAY_PORT=(.+)$" -ErrorAction SilentlyContinue
    if ($portMatch) { $gwPort = $portMatch.Matches.Groups[1].Value }

    $configPath = Join-Path $DataDir "openclaw.json"

    # ---- 修复 1: 插件 ownership ----
    Write-Info "修复插件权限..."
    & docker exec openclaw-gateway chown -R root:root /home/node/.openclaw/extensions/ 2>&1 | Out-Null
    Write-Ok "插件权限已修复"

    # ---- 修复 2: openclaw.json 配置 ----
    Write-Info "修复控制面板和插件配置..."
    Repair-OpenClawConfig -ConfigPath $configPath -GwPort $gwPort -EnvFile $envFile

    # 重启让修改生效
    Write-Info "重启服务使配置生效..."
    & docker compose restart openclaw-gateway
    Start-Sleep -Seconds 5

    Write-Info "等待服务就绪..."
    $retries = 0
    while ($retries -lt 30) {
        try {
            $response = Invoke-WebRequest -Uri "http://127.0.0.1:$gwPort/healthz" -UseBasicParsing -TimeoutSec 2 -ErrorAction Stop
            if ($response.StatusCode -eq 200) {
                Write-Host ""

                # 自动批准内部 agent 的设备配对
                Write-Info "批准内部设备配对..."
                & docker exec openclaw-gateway openclaw devices approve --latest 2>&1 | Out-Null
                if ($LASTEXITCODE -eq 0) {
                    Write-Ok "设备配对已批准"
                } else {
                    Write-Warn "无待批准的配对请求（可忽略）"
                }

                # 清理重启后重新生成的过期插件条目
                if (Test-Path $configPath) {
                    try {
                        $cfg = Get-Content $configPath -Raw | ConvertFrom-Json
                        if ($cfg.plugins -and $cfg.plugins.entries -and $cfg.plugins.entries.PSObject.Properties["feishu-openclaw-plugin"]) {
                            $cfg.plugins.entries.PSObject.Properties.Remove("feishu-openclaw-plugin")
                            $cfg | ConvertTo-Json -Depth 20 | Set-Content $configPath -Encoding UTF8
                            Write-Ok "清理过期条目 feishu-openclaw-plugin"
                        }
                    } catch {
                        Write-Warn "清理过期条目失败（可忽略）"
                    }
                }

                Write-Ok "OpenClaw 已成功启动！"
                Write-Host ""

                $tokenMatch = Select-String -Path $envFile -Pattern "^OPENCLAW_GATEWAY_TOKEN=(.+)$"
                $token = $tokenMatch.Matches.Groups[1].Value
                $url = "http://127.0.0.1:${gwPort}/overview?token=$token"

                Write-Host "========================================" -ForegroundColor Green
                Write-Host "  部署完成！" -ForegroundColor Green
                Write-Host "========================================" -ForegroundColor Green
                Write-Host ""
                Write-Host "  打开以下链接，自动连接控制面板（token 已内置）：" -ForegroundColor White
                Write-Host ""
                Write-Host "    $url" -ForegroundColor Yellow
                Write-Host ""
                Write-Host "  提示: 首次打开后 token 会保存到浏览器，后续直接访问即可" -ForegroundColor Cyan
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
    & docker compose logs --tail=50 openclaw-gateway
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
Start-OpenClaw
