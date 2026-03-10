#!/usr/bin/env bash
# ============================================================
# OpenClaw 一键部署脚本（Linux / macOS）
# 支持飞书、钉钉、QQ、企业微信
# ============================================================
set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

info()  { echo -e "${CYAN}[INFO]${NC} $*"; }
ok()    { echo -e "${GREEN}[OK]${NC} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
err()   { echo -e "${RED}[ERROR]${NC} $*" >&2; }

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DATA_DIR="$HOME/.openclaw"

# ============================================================
# 1. 环境检查
# ============================================================
check_prerequisites() {
    info "检查运行环境..."

    # Docker
    if ! command -v docker &>/dev/null; then
        err "未找到 Docker，请先安装："
        case "$(uname -s)" in
            Darwin) echo "  brew install --cask docker  (或从 https://docker.com 下载 Docker Desktop)" ;;
            Linux)  echo "  curl -fsSL https://get.docker.com | sh" ;;
        esac
        exit 1
    fi
    ok "Docker $(docker --version | awk '{print $3}' | tr -d ',')"

    # Docker Compose
    if docker compose version &>/dev/null; then
        ok "Docker Compose $(docker compose version --short)"
    elif command -v docker-compose &>/dev/null; then
        ok "docker-compose $(docker-compose --version | awk '{print $4}' | tr -d ',')"
        warn "建议升级到 Docker Compose V2"
    else
        err "未找到 Docker Compose"
        exit 1
    fi

    # Docker daemon
    if ! docker info &>/dev/null; then
        err "Docker 守护进程未运行，请启动 Docker Desktop 或 systemctl start docker"
        exit 1
    fi
    ok "Docker 守护进程运行中"

    # 内存检查
    local mem_gb
    case "$(uname -s)" in
        Darwin) mem_gb=$(sysctl -n hw.memsize | awk '{printf "%.0f", $1/1024/1024/1024}') ;;
        Linux)  mem_gb=$(awk '/MemTotal/{printf "%.0f", $2/1024/1024}' /proc/meminfo) ;;
    esac
    if [ "$mem_gb" -lt 2 ]; then
        warn "系统内存 ${mem_gb}GB，建议至少 2GB"
    else
        ok "系统内存 ${mem_gb}GB"
    fi
}

# ============================================================
# 2. 配置 .env
# ============================================================
setup_env() {
    local env_file="$SCRIPT_DIR/.env"

    if [ -f "$env_file" ]; then
        warn ".env 文件已存在"
        read -rp "是否重新配置？(y/N): " answer < /dev/tty
        if [[ ! "$answer" =~ ^[Yy]$ ]]; then
            info "跳过配置，使用现有 .env"
            return
        fi
    fi

    cp "$SCRIPT_DIR/.env.example" "$env_file"

    echo ""
    echo -e "${CYAN}========================================${NC}"
    echo -e "${CYAN}  OpenClaw 配置向导${NC}"
    echo -e "${CYAN}========================================${NC}"
    echo ""

    # 模型配置
    info "--- 模型配置 ---"
    echo "支持的模型提供商："
    echo "  1) Claude 系列       (Anthropic)"
    echo "  2) GPT / Gemini 等   (OpenAI 兼容协议)"
    echo "  3) 智谱 GLM 系列     (GLM-5 / GLM-4.7 / GLM-4.6)"
    echo "  4) DeepSeek          (DeepSeek-V3 / DeepSeek-R1)"
    echo "  5) 其他 OpenAI 兼容  (中转站 / 自部署)"
    read -rp "选择 [1]: " proto_choice < /dev/tty
    case "${proto_choice:-1}" in
        3)
            local protocol="openai-completions"
            echo "  可选模型: GLM-5, GLM-4.7, GLM-4.6, GLM-4.5-Air, GLM-4.5"
            read -rp "模型 ID [glm-5]: " model_id < /dev/tty
            model_id="${model_id:-glm-5}"
            local base_url="https://open.bigmodel.cn/api/coding/paas/v4"
            info "API 地址已自动设置: $base_url"
            warn "请确保已开通智谱 Coding Plan，避免 Flash/FlashX 模型产生额外费用"
            ;;
        4)
            local protocol="openai-completions"
            read -rp "模型 ID [deepseek-chat]: " model_id < /dev/tty
            model_id="${model_id:-deepseek-chat}"
            local base_url="https://api.deepseek.com/v1"
            info "API 地址已自动设置: $base_url"
            ;;
        5)
            local protocol="openai-completions"
            read -rp "模型 ID: " model_id < /dev/tty
            read -rp "API Base URL (须含 /v1): " base_url < /dev/tty
            ;;
        2)
            local protocol="openai-completions"
            read -rp "模型 ID [gpt-4o]: " model_id < /dev/tty
            model_id="${model_id:-gpt-4o}"
            read -rp "API Base URL [https://api.openai.com/v1]: " base_url < /dev/tty
            base_url="${base_url:-https://api.openai.com/v1}"
            ;;
        *)
            local protocol="anthropic-messages"
            read -rp "模型 ID [claude-sonnet-4-5-20250514]: " model_id < /dev/tty
            model_id="${model_id:-claude-sonnet-4-5-20250514}"
            read -rp "API Base URL [https://api.anthropic.com]: " base_url < /dev/tty
            base_url="${base_url:-https://api.anthropic.com}"
            ;;
    esac
    read -rp "API Key: " api_key < /dev/tty
    if [ -z "$api_key" ]; then
        err "API Key 不能为空"
        exit 1
    fi

    # 写入模型配置
    sed -i.bak "s|^API_PROTOCOL=.*|API_PROTOCOL=$protocol|" "$env_file"
    sed -i.bak "s|^MODEL_ID=.*|MODEL_ID=$model_id|" "$env_file"
    sed -i.bak "s|^BASE_URL=.*|BASE_URL=$base_url|" "$env_file"
    sed -i.bak "s|^API_KEY=.*|API_KEY=$api_key|" "$env_file"

    # Gateway Token
    local gw_token
    gw_token="oc-$(openssl rand -hex 16 2>/dev/null || head -c 32 /dev/urandom | xxd -p | head -c 32)"
    sed -i.bak "s|^OPENCLAW_GATEWAY_TOKEN=.*|OPENCLAW_GATEWAY_TOKEN=$gw_token|" "$env_file"
    ok "已生成 Gateway Token: $gw_token"

    # 数据目录
    sed -i.bak "s|^OPENCLAW_DATA_DIR=.*|OPENCLAW_DATA_DIR=$DATA_DIR|" "$env_file"

    # IM 平台配置
    echo ""
    info "--- IM 平台配置（留空跳过）---"

    # 飞书
    read -rp "启用飞书？(y/N): " enable_feishu < /dev/tty
    if [[ "$enable_feishu" =~ ^[Yy]$ ]]; then
        read -rp "  飞书 App ID: " feishu_app_id < /dev/tty
        read -rp "  飞书 App Secret: " feishu_app_secret < /dev/tty
        sed -i.bak "s|^FEISHU_APP_ID=.*|FEISHU_APP_ID=$feishu_app_id|" "$env_file"
        sed -i.bak "s|^FEISHU_APP_SECRET=.*|FEISHU_APP_SECRET=$feishu_app_secret|" "$env_file"
        ok "飞书已配置"
    fi

    # 钉钉
    read -rp "启用钉钉？(y/N): " enable_dingtalk < /dev/tty
    if [[ "$enable_dingtalk" =~ ^[Yy]$ ]]; then
        read -rp "  钉钉 Client ID: " dt_client_id < /dev/tty
        read -rp "  钉钉 Client Secret: " dt_client_secret < /dev/tty
        read -rp "  钉钉 Robot Code: " dt_robot_code < /dev/tty
        read -rp "  钉钉 Corp ID (可选): " dt_corp_id < /dev/tty
        read -rp "  钉钉 Agent ID (可选): " dt_agent_id < /dev/tty
        sed -i.bak "s|^DINGTALK_CLIENT_ID=.*|DINGTALK_CLIENT_ID=$dt_client_id|" "$env_file"
        sed -i.bak "s|^DINGTALK_CLIENT_SECRET=.*|DINGTALK_CLIENT_SECRET=$dt_client_secret|" "$env_file"
        sed -i.bak "s|^DINGTALK_ROBOT_CODE=.*|DINGTALK_ROBOT_CODE=$dt_robot_code|" "$env_file"
        sed -i.bak "s|^DINGTALK_CORP_ID=.*|DINGTALK_CORP_ID=$dt_corp_id|" "$env_file"
        sed -i.bak "s|^DINGTALK_AGENT_ID=.*|DINGTALK_AGENT_ID=$dt_agent_id|" "$env_file"
        ok "钉钉已配置"
    fi

    # QQ
    read -rp "启用 QQ 机器人？(y/N): " enable_qq < /dev/tty
    if [[ "$enable_qq" =~ ^[Yy]$ ]]; then
        echo "  QQ 接入方式："
        echo "    1) 官方 QQ Bot API"
        echo "    2) NapCat (OneBot v11)"
        read -rp "  选择 [1]: " qq_mode < /dev/tty
        case "${qq_mode:-1}" in
            2)
                read -rp "  NapCat 反向 WS 端口: " napcat_port < /dev/tty
                read -rp "  NapCat HTTP URL (可选): " napcat_http < /dev/tty
                read -rp "  NapCat Access Token: " napcat_token < /dev/tty
                read -rp "  管理员 QQ 号（多个逗号分隔）: " napcat_admins < /dev/tty
                sed -i.bak "s|^NAPCAT_REVERSE_WS_PORT=.*|NAPCAT_REVERSE_WS_PORT=$napcat_port|" "$env_file"
                sed -i.bak "s|^NAPCAT_HTTP_URL=.*|NAPCAT_HTTP_URL=$napcat_http|" "$env_file"
                sed -i.bak "s|^NAPCAT_ACCESS_TOKEN=.*|NAPCAT_ACCESS_TOKEN=$napcat_token|" "$env_file"
                sed -i.bak "s|^NAPCAT_ADMINS=.*|NAPCAT_ADMINS=$napcat_admins|" "$env_file"
                ;;
            *)
                read -rp "  QQ Bot App ID: " qq_app_id < /dev/tty
                read -rp "  QQ Bot Client Secret: " qq_secret < /dev/tty
                sed -i.bak "s|^QQBOT_APP_ID=.*|QQBOT_APP_ID=$qq_app_id|" "$env_file"
                sed -i.bak "s|^QQBOT_CLIENT_SECRET=.*|QQBOT_CLIENT_SECRET=$qq_secret|" "$env_file"
                ;;
        esac
        ok "QQ 机器人已配置"
    fi

    # 企业微信
    read -rp "启用企业微信？(y/N): " enable_wecom < /dev/tty
    if [[ "$enable_wecom" =~ ^[Yy]$ ]]; then
        read -rp "  企业微信 Token: " wecom_token < /dev/tty
        read -rp "  企业微信 EncodingAESKey: " wecom_aes < /dev/tty
        sed -i.bak "s|^WECOM_TOKEN=.*|WECOM_TOKEN=$wecom_token|" "$env_file"
        sed -i.bak "s|^WECOM_ENCODING_AES_KEY=.*|WECOM_ENCODING_AES_KEY=$wecom_aes|" "$env_file"
        ok "企业微信已配置"
    fi

    # Telegram
    read -rp "启用 Telegram？(y/N): " enable_tg < /dev/tty
    if [[ "$enable_tg" =~ ^[Yy]$ ]]; then
        read -rp "  Telegram Bot Token: " tg_token < /dev/tty
        sed -i.bak "s|^TELEGRAM_BOT_TOKEN=.*|TELEGRAM_BOT_TOKEN=$tg_token|" "$env_file"
        ok "Telegram 已配置"
    fi

    # 清理 sed 备份文件
    rm -f "$env_file.bak"

    echo ""
    ok "配置完成！.env 已保存到 $env_file"
}

# ============================================================
# 3. 准备数据目录（清理旧配置确保干净启动）
# ============================================================
prepare_dirs() {
    info "准备数据目录..."

    if [ -f "$DATA_DIR/openclaw.json" ]; then
        warn "检测到旧配置文件，备份并清除以确保干净启动"
        cp "$DATA_DIR/openclaw.json" "$DATA_DIR/openclaw.json.bak.$(date +%s)"
        rm -f "$DATA_DIR/openclaw.json"
    fi

    mkdir -p "$DATA_DIR"
    ok "数据目录: $DATA_DIR"
}

# ============================================================
# 4. 拉取镜像并启动
# ============================================================
start_service() {
    info "拉取 Docker 镜像（首次可能需要几分钟）..."
    cd "$SCRIPT_DIR"
    docker compose pull openclaw-gateway

    # 确保没有残留容器
    docker compose down 2>/dev/null || true

    info "启动 OpenClaw..."
    docker compose up -d openclaw-gateway

    echo ""
    info "等待服务初始化（首次约 15 秒）..."
    sleep 12

    local gw_port
    gw_port="$(grep '^OPENCLAW_GATEWAY_PORT=' "$SCRIPT_DIR/.env" | cut -d= -f2)"
    gw_port="${gw_port:-18789}"

    # ---- 修复 1: 插件 ownership（第三方插件 uid 不匹配会被拦截）----
    info "修复插件权限..."
    docker exec openclaw-gateway chown -R root:root /home/node/.openclaw/extensions/ 2>/dev/null || true
    ok "插件权限已修复"

    # ---- 修复 2: openclaw.json 配置 ----
    info "修复控制面板和插件配置..."
    if [ -f "$DATA_DIR/openclaw.json" ] && command -v python3 &>/dev/null; then
        python3 -c "
import json
config_path = '$DATA_DIR/openclaw.json'
port = '$gw_port'
with open(config_path, 'r') as f:
    config = json.load(f)
gw = config.setdefault('gateway', {})

# 1. 修复 allowedOrigins（容器 init 只写 http://localhost）
ui = gw.setdefault('controlUi', {})
ui['allowedOrigins'] = [
    'http://localhost',
    'http://localhost:' + port,
    'http://127.0.0.1',
    'http://127.0.0.1:' + port,
]
ui['allowInsecureAuth'] = True
ui['dangerouslyDisableDeviceAuth'] = True
print('  [OK] allowedOrigins + disableDeviceAuth')

# 2. 添加 Docker 子网到 trustedProxies（解决 pairing required）
gw['trustedProxies'] = ['172.16.0.0/12', '192.168.0.0/16', '127.0.0.1/32']
print('  [OK] trustedProxies')

# 3. 清理过期的 feishu-openclaw-plugin 条目（飞书是内置 stock 插件，ID 为 feishu）
plugins = config.get('plugins', {})
entries = plugins.get('entries', {})
if 'feishu-openclaw-plugin' in entries:
    del entries['feishu-openclaw-plugin']
    print('  [OK] 清理过期条目 feishu-openclaw-plugin')

# 4. 确保已启用的 IM 插件在 config 中标记为 enabled
# 飞书（stock 内置，通过 channels.feishu 控制，无需额外 enable）
# 钉钉/QQ/企微（global 第三方插件，需要在 plugins.entries 中 enable）
import os
env_path = '$SCRIPT_DIR/.env'
env_vars = {}
if os.path.exists(env_path):
    with open(env_path) as ef:
        for line in ef:
            line = line.strip()
            if line and not line.startswith('#') and '=' in line:
                k, v = line.split('=', 1)
                env_vars[k] = v

im_plugin_map = {
    'DINGTALK_CLIENT_ID': 'dingtalk',
    'QQBOT_APP_ID': 'qqbot',
    'NAPCAT_REVERSE_WS_PORT': 'qq',
    'WECOM_TOKEN': 'wecom',
}
for env_key, plugin_id in im_plugin_map.items():
    if env_vars.get(env_key, ''):
        entries.setdefault(plugin_id, {})['enabled'] = True
        print(f'  [OK] 启用插件: {plugin_id}')

if entries:
    plugins['entries'] = entries
    config['plugins'] = plugins

with open(config_path, 'w') as f:
    json.dump(config, f, indent=2, ensure_ascii=False)
print('  [OK] 配置已保存')
"
        ok "全部配置已修复"
    else
        warn "无法自动修复（需要 python3），请手动编辑 $DATA_DIR/openclaw.json"
    fi

    # 重启让所有修改生效
    info "重启服务使配置生效..."
    docker compose restart openclaw-gateway
    sleep 5

    info "等待服务就绪..."
    local retries=0
    while [ $retries -lt 30 ]; do
        if curl -fsS "http://127.0.0.1:${gw_port}/healthz" &>/dev/null; then
            echo ""
            # 自动批准内部 agent 的设备配对（bind=lan 要求 device pairing）
            info "批准内部设备配对..."
            docker exec openclaw-gateway openclaw devices approve --latest 2>/dev/null && \
                ok "设备配对已批准" || \
                warn "无待批准的配对请求（可忽略）"

            # 清理 init 脚本重启后重新生成的过期插件条目
            if [ -f "$DATA_DIR/openclaw.json" ] && command -v python3 &>/dev/null; then
                python3 -c "
import json
config_path = '$DATA_DIR/openclaw.json'
with open(config_path, 'r') as f:
    config = json.load(f)
entries = config.get('plugins', {}).get('entries', {})
if 'feishu-openclaw-plugin' in entries:
    del entries['feishu-openclaw-plugin']
    with open(config_path, 'w') as f:
        json.dump(config, f, indent=2, ensure_ascii=False)
    print('  [OK] 清理过期条目 feishu-openclaw-plugin')
" 2>/dev/null || true
            fi

            ok "OpenClaw 已成功启动！"
            echo ""
            local _token _url
            _token="$(grep '^OPENCLAW_GATEWAY_TOKEN=' "$SCRIPT_DIR/.env" | cut -d= -f2)"
            _url="http://127.0.0.1:${gw_port}/overview?token=${_token}"
            echo -e "${GREEN}========================================${NC}"
            echo -e "${GREEN}  部署完成！${NC}"
            echo -e "${GREEN}========================================${NC}"
            echo ""
            echo -e "  打开以下链接，自动连接控制面板（token 已内置）："
            echo ""
            echo -e "    ${YELLOW}${_url}${NC}"
            echo ""
            echo -e "  ${CYAN}提示: 首次打开后 token 会保存到浏览器，后续直接访问即可${NC}"
            echo ""
            echo "  常用命令："
            echo "    查看日志:  docker compose logs -f"
            echo "    停止服务:  docker compose down"
            echo "    重启服务:  docker compose restart"
            echo "    进入容器:  docker compose exec openclaw-gateway /bin/bash"
            echo ""
            return
        fi
        retries=$((retries + 1))
        printf "."
        sleep 2
    done

    warn "服务启动超时，查看日志排查问题："
    docker compose logs --tail=50 openclaw-gateway
}

# ============================================================
# 主流程
# ============================================================
main() {
    echo ""
    echo -e "${CYAN}╔══════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║   OpenClaw 一键部署（中国 IM 整合版）   ║${NC}"
    echo -e "${CYAN}║   支持: 飞书 / 钉钉 / QQ / 企业微信    ║${NC}"
    echo -e "${CYAN}╚══════════════════════════════════════════╝${NC}"
    echo ""

    check_prerequisites
    echo ""
    setup_env
    echo ""
    prepare_dirs
    echo ""
    start_service
}

main "$@"
