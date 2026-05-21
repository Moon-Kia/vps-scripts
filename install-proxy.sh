#!/usr/bin/env bash
set -Eeuo pipefail

# ============================================================
# CF Proxy 一键脚本
# 说明：
# 1. 默认推荐使用 cert 模式，可自动创建/复用隧道并绑定 DNS。
# 2. 若你已经在 CF Zero Trust 后台建好了固定隧道，也可改成 token 模式。
# 3. 默认不自动注册快捷命令，避免旧副本 / 自覆盖问题。
# 4. 支持 systemd；若当前环境没有 systemctl，则自动降级为进程守护模式。
# ============================================================

# --------------------------- 配置区 ---------------------------
# 必填/密钥类放在最前面；你已经直接写入脚本的密钥会保留，不再自动清空。

# 【0】必须先确认 / 常用密钥
MAIN_DOMAIN="214114.xyz"                 # Cloudflare 主域名；cert 模式会绑定 别名-后缀.主域名
CF_AUTH_MODE="cert"                      # cert=自动创建/复用隧道并绑 DNS；token=接入已有 Zero Trust 隧道
CERT_PEM_CONTENT=$(cat <<'CERT_EOF'

CERT_EOF
)                                        # 可直接内嵌 cert.pem；若留空则运行时粘贴或读取一次性密钥文件
CF_TUNNEL_TOKEN=""                       # token 模式的 Cloudflare Tunnel Token；cert 模式可留空
UPTIMEROBOT_API_KEY="u3484423-1ee45dc8f4ec2419682a475f"                   # UptimeRobot Main API key；公网入站探测需要
NGROK_AUTHTOKEN_POOL=$(cat <<'NGROK_TOKEN_EOF'
3CGea3qbUHXnxHZdYf7aeAcnbHc_4pAHEVemwHZ4riduxnpJi
3DLvfv8nLTh8GCX13pLbzboR3c3_4NpUBJCUheLbCEp2C5XsD
3CGLyR0EJI05vcBygM0ZvafYNnT_6UKv77CnrBf7uFAHizNCH
3DLw53znHbd4DEKeIJLh0VE8GjN_54znjHbde8Cb9A9Rykfbe
3DO2Tdkoq2fMruywlIZWt1JNIgQ_2hteanaPVEHerBxiHBTMQ
3CF6PfToh18d7bp6xx3RQs2AFHY_2dhHS4usLx2VKC5C6yz2z
NGROK_TOKEN_EOF
)                                        # ngrok token 池；一行一个，满额/失败会自动换下一个
FB_USER="fenghuixianyu"                        # FileBrowser 用户名
FB_PASS="fenghuixianyu"                               # FileBrowser 密码；留空自动生成，建议至少 12 位

# 【1】基础身份 / 输出
DOMAIN_SUFFIX="proxy"                    # 节点域名后缀；最终域名形如 hk-1-proxy.214114.xyz
DEFAULT_PROTOCOL="vmess"                 # 默认协议：vmess / vless；不确定就用 vmess
CONFIG_DIR="/root/proxy-configs"         # 客户端配置与信息文件输出目录；不可写时自动回退 /tmp/cfproxy-configs
QUICK_CMD="sb"                           # 面板快捷命令；普通用户执行时会尝试 sudo 提权
ENABLE_QUICK_CMD="on"                    # on=自动注册快捷命令；off=只用 bash 固定路径唤起

# 【2】启动预检 / 基础组件
INSTALL_CORE_ON_START="off"               # off=面板秒进，不联网检查；missing_only=缺失时补装；on=每次完整检查
CHECK_CF_EDGE_ON_START="off"              # off=面板秒进，仅显示上次结果；cached/on=启动时预检 CF 7844
BOOTSTRAP_CERT_PATH="/etc/cfproxy/bootstrap/cloudfarecert.pem" # 一次性 cert.pem 路径；首条带密钥命令会下载到这里
AUTO_DESTROY_CERT="on"                   # on=cert 管理操作完成后删除服务器上的 cert.pem；off=保留

# 【3】客户端入口参数
CLIENT_SERVER="cloudflare-ech.com"       # 推荐入口地址；客户端 Host/SNI 仍是你的隧道域名
CLIENT_PORT=8443                         # 推荐入口端口
DIRECT_PORT=443                          # CF 域名备用直连端口
EXPORT_DIRECT_NODE="off"                 # off=客户端配置只保留推荐节点；on=额外写入 CF 域名直连节点
LOCAL_PORT=0                             # 服务端 sing-box 端口；0=随机，非0=固定；公网直连复用该端口

# 【4】FileBrowser 下载页
ENABLE_TEMP_FILEBROWSER="on"             # on=部署后自动开临时下载页；适合没 SFTP 的服务器
FB_ROOT_DIR="$CONFIG_DIR"                # FileBrowser 初始目录；默认就是配置文件输出目录
FB_ROOT_FALLBACKS="/root /tmp /"         # 初始目录不可用时按顺序回退
FB_PORT=0                                # FileBrowser 本地端口；0=随机，非0=固定
FB_QUICK_TUNNEL_TIMEOUT=45               # 抓 trycloudflare 链接等待秒数；CF 7844 不通时通常抓不到

# 【5】CF 失败后的公网直连兜底
ENABLE_DIRECT_PUBLIC_FALLBACK="off"      # on=CF 未唤醒时自动生成公网直连；off=只在面板手动选择
DIRECT_PUBLIC_HOST=""                    # 公网直连地址；留空自动探测公网 IPv4，也可手动填公网 IP / 域名
DIRECT_PUBLIC_LISTEN_ADDR="0.0.0.0"      # 生成公网直连配置时 sing-box 监听地址；通常保持 0.0.0.0
ENABLE_FB_PUBLIC_ON_DIRECT="on"          # on=公网直连模式下 FileBrowser 输出 http://公网IP:端口

# 【6】公网入站探测：UptimeRobot Port Monitor API
ENABLE_UPTIMEROBOT_PROBE="on"            # on=面板可用 UptimeRobot 从外部探测 公网IP:端口 是否可连
UPTIMEROBOT_API_KEY_FILE="/etc/cfproxy/bootstrap/uptimerobot_api_key.txt" # API key 文件备用路径；配置区已填时可不用
UPTIMEROBOT_PROBE_WAIT_SECONDS=120        # 创建 monitor 后等待结果秒数；慢时可调到 360
UPTIMEROBOT_PROBE_INTERVAL=300            # UptimeRobot 免费计划常用检查间隔 300 秒
UPTIMEROBOT_PROBE_TIMEOUT=10              # 单次端口探测超时秒数
UPTIMEROBOT_DELETE_AFTER_PROBE="on"       # on=探测结束后删除临时 monitor，避免占用免费额度

# 【7】ngrok 兜底：无公网入站且 CF 7844 不通时手动启用
ENABLE_NGROK_FALLBACK="off"              # on=部署时 CF 未唤醒后自动尝试 ngrok；off=面板手动启用
NGROK_REGION=""                          # ngrok 区域；留空=自动，可填 us/eu/ap/au/sa/jp/in 等
NGROK_PROXY_MODE="auto"                  # auto=http_ws 优先、失败再 tcp；http_ws=443/WSS；tcp=随机 TCP 端口
NGROK_TRY_TIMEOUT=30                     # 每个 token 等待 ngrok URL 的秒数
NGROK_ENABLE_FILEBROWSER="on"            # on=ngrok 模式下也给 FileBrowser 入口；配合 NGROK_MUX_FILEBROWSER=on 时不额外占 endpoint
NGROK_MUX_FILEBROWSER="on"               # on=ngrok HTTP 模式下单入口复用代理+FB；off=FB 另开 ngrok 入口
NGROK_FB_AUTO_STOP_MINUTES=30             # FileBrowser 的 ngrok 链接自动停止分钟数；0=不自动停；单入口复用时不单独停止

# 【8】进阶 / 兼容性
CF_EDGE_PROTOCOL="auto"                  # auto / quic / http2；7844 被封时单改协议通常无效
CF_REQUIRE_TUNNEL_ONLINE="off"           # on=部署时没连上 CF Edge 就中止；off=保留服务并提示
CF_ONLINE_CHECK_TIMEOUT=55               # 等待 cloudflared 出现 Registered tunnel connection 的秒数
CF_EDGE_PRECHECK_CACHE_SECONDS=900        # sb 面板启动时 CF 7844 预检缓存秒数，避免每次都卡等待
PROCESS_RESTART_SEC=5                    # 无 systemd 进程守护模式下，子进程退出后的重启间隔
ENABLE_LOGIN_AUTOSTART="on"              # 无 systemd/cron 不可靠时，登录 shell 自动补拉起服务
ENABLE_PID1_ENTRYPOINT_HOOK="on"         # 容器 PID1 是可写 shell entrypoint 时，注入轻量开机钩子
DNS_CONFLICT_ACTION="auto_suffix"        # hostname 冲突策略：auto_suffix=自动加后缀避让；fail=直接失败
DNS_CONFLICT_SUFFIX="fix"                # 自动避让 hostname 冲突时追加的后缀
MAX_DNS_CONFLICT_TRIES=8                 # 自动避让 hostname 冲突最大尝试次数
# ------------------------------------------------------------

SCRIPT_VERSION="2026.05.07-r26"
WORK_DIR="/etc/cfproxy"
INSTALL_DIR="/usr/local/lib/cfproxy"
INSTALLED_SCRIPT="${INSTALL_DIR}/cfproxy.sh"
STATE_FILE="${WORK_DIR}/state.env"
SB_DIR="${WORK_DIR}/sing-box"
SB_CONFIG="${SB_DIR}/config.json"
CF_WORK_DIR="${WORK_DIR}/cloudflared"
CF_CONFIG="${CF_WORK_DIR}/config.yml"
RUN_DIR="${WORK_DIR}/run"
BOOTSTRAP_DIR="${WORK_DIR}/bootstrap"
BOOTSTRAP_SCRIPT="${BOOTSTRAP_DIR}/start-services.sh"
LOGIN_AUTOSTART_FILE="/etc/profile.d/cfproxy-autostart.sh"
BOOTSTRAP_CERT_FILE="${BOOTSTRAP_CERT_PATH}"
BOOTSTRAP_CERT_DIR="$(dirname "$BOOTSTRAP_CERT_FILE")"
CF_DIR="/root/.cloudflared"
SB_BIN="/usr/local/bin/sing-box"
CF_BIN="/usr/local/bin/cloudflared"
NGROK_BIN="/usr/local/bin/ngrok"
CADDY_BIN="/usr/local/bin/caddy"
CADDY_WORK_DIR="${WORK_DIR}/caddy"
NGROK_MUX_CADDYFILE="${CADDY_WORK_DIR}/ngrok-mux.Caddyfile"
FB_WORK_DIR="${WORK_DIR}/filebrowser"
FB_DB="${FB_WORK_DIR}/filebrowser.db"
FB_BIN="/usr/local/bin/filebrowser"

GREEN="\033[32m"
YELLOW="\033[33m"
RED="\033[31m"
BLUE="\033[34m"
CYAN="\033[36m"
RESET="\033[0m"

CURRENT_ALIAS=""
TUNNEL_NAME=""
TUNNEL_DOMAIN=""
TUNNEL_UUID_CF=""
PROXY_UUID=""
PROXY_PORT=""
PROXY_PROTOCOL=""
WS_PATH=""
SB_SERVICE_NAME=""
CF_SERVICE_NAME=""
CF_RUN_MODE=""
SERVICE_BACKEND=""
BOOT_HOOK_BACKEND=""
DEPLOY_AUTH_MODE=""
MGMT_CRED_TEMP_WRITTEN="0"
CF_LAST_HEALTH="未检测"
FB_ENABLED_STATE=""
FB_LOCAL_PORT=""
FB_SERVICE_NAME=""
FB_CF_SERVICE_NAME=""
FB_QUICK_URL=""
FB_PASSWORD_EFFECTIVE=""
SB_LISTEN_ADDR="127.0.0.1"
DIRECT_PUBLIC_STATE=""
DIRECT_PUBLIC_HOST_EFFECTIVE=""
DIRECT_PUBLIC_LINK=""
FB_PUBLIC_URL=""
NGROK_ENABLED_STATE=""
NGROK_PROXY_SERVICE_NAME=""
NGROK_FB_SERVICE_NAME=""
NGROK_PROXY_URL=""
NGROK_PROXY_KIND=""
NGROK_FB_URL=""
NGROK_MUX_SERVICE_NAME=""
NGROK_MUX_PORT=""
NGROK_MUX_STATE=""
NGROK_AUTHTOKEN_FINGERPRINT=""
STARTUP_CF_EDGE_STATUS="未检测"
STARTUP_CORE_READY="未检测"

INFO_FILE=""
CLASH_FILE=""
SINGBOX_CLIENT_FILE=""
DIRECT_CLASH_FILE=""
DIRECT_SINGBOX_CLIENT_FILE=""
NGROK_CLASH_FILE=""
NGROK_SINGBOX_CLIENT_FILE=""

fail() { echo -e "${RED}✘ $*${RESET}"; exit 1; }
warn() { echo -e "${YELLOW}⚠ $*${RESET}"; }
ok()   { echo -e "${GREEN}✔ $*${RESET}"; }
info() { echo -e "${CYAN}➜ $*${RESET}"; }

on_err() {
  local line="$1"
  echo -e "${RED}脚本执行失败（第 ${line} 行）${RESET}"
}

on_exit_cleanup() {
  destroy_cert >/dev/null 2>&1 || true
}

trap 'on_err $LINENO' ERR
trap 'on_exit_cleanup' EXIT

if [ "${EUID}" -ne 0 ]; then
  if command -v sudo >/dev/null 2>&1; then
    echo -e "${YELLOW}⚠ 检测到当前为普通用户，正在尝试通过 sudo 提权运行面板...${RESET}"
    exec sudo bash "$0" "$@"
  fi
  fail "请使用 root 运行此脚本，或为当前用户准备 sudo 后重试。"
fi

ORIGINAL_CONFIG_DIR="$CONFIG_DIR"
if ! mkdir -p "$CONFIG_DIR" 2>/dev/null || [ ! -w "$CONFIG_DIR" ]; then
  warn "配置输出目录 ${CONFIG_DIR} 不可用，自动回退到 /tmp/cfproxy-configs。"
  CONFIG_DIR="/tmp/cfproxy-configs"
  [ "$FB_ROOT_DIR" = "$ORIGINAL_CONFIG_DIR" ] && FB_ROOT_DIR="$CONFIG_DIR"
fi

mkdir -p "$WORK_DIR" "$SB_DIR" "$CF_WORK_DIR" "$CONFIG_DIR" "$CF_DIR" "$RUN_DIR" "$BOOTSTRAP_DIR" "$BOOTSTRAP_CERT_DIR" "$FB_WORK_DIR"
mkdir -p "$INSTALL_DIR"
chmod 700 "$WORK_DIR" "$SB_DIR" "$CF_WORK_DIR" "$RUN_DIR" "$BOOTSTRAP_DIR" "$BOOTSTRAP_CERT_DIR" "$FB_WORK_DIR" || true

refresh_output_paths() {
  INFO_FILE="${CONFIG_DIR}/proxy_info_${CURRENT_ALIAS}.txt"
  CLASH_FILE="${CONFIG_DIR}/clash_meta_${CURRENT_ALIAS}.yaml"
  SINGBOX_CLIENT_FILE="${CONFIG_DIR}/singbox_client_${CURRENT_ALIAS}.json"
  DIRECT_CLASH_FILE="${CONFIG_DIR}/clash_public_direct_${CURRENT_ALIAS}.yaml"
  DIRECT_SINGBOX_CLIENT_FILE="${CONFIG_DIR}/singbox_public_direct_${CURRENT_ALIAS}.json"
  NGROK_CLASH_FILE="${CONFIG_DIR}/clash_ngrok_${CURRENT_ALIAS}.yaml"
  NGROK_SINGBOX_CLIENT_FILE="${CONFIG_DIR}/singbox_ngrok_${CURRENT_ALIAS}.json"
}

service_file_path() {
  echo "/etc/systemd/system/$1.service"
}

service_launcher_file() {
  echo "${RUN_DIR}/$1.sh"
}

service_pid_file() {
  echo "${RUN_DIR}/$1.pid"
}

service_log_file() {
  echo "${RUN_DIR}/$1.log"
}

service_recent_log() {
  local name="$1" lines="${2:-220}" logfile output
  [ -n "$name" ] || return 0
  if [ "${SERVICE_BACKEND:-}" = "systemd" ]; then
    if command -v journalctl >/dev/null 2>&1; then
      output="$(journalctl -u "$name" -n "$lines" --no-pager -o cat 2>/dev/null || true)"
      if [ -n "$output" ]; then
        printf '%s\n' "$output"
        return 0
      fi
    fi
    systemctl status "$name" -n "$lines" --no-pager --full 2>/dev/null || true
  else
    logfile=$(service_log_file "$name")
    tail -n "$lines" "$logfile" 2>/dev/null || true
  fi
}

detect_service_backend() {
  # Do not trust systemctl binary alone in containers; PID1 may be dumb-init/supervisord.
  if command -v systemctl >/dev/null 2>&1     && [ -d /run/systemd/system ]     && systemctl is-system-running >/dev/null 2>&1; then
    SERVICE_BACKEND="systemd"
  else
    SERVICE_BACKEND="process"
  fi
}

detect_boot_hook_backend() {
  local hooks=() pid1_cmd token
  if [ "$SERVICE_BACKEND" = "systemd" ]; then
    BOOT_HOOK_BACKEND="systemd"
    return
  fi

  command -v crontab >/dev/null 2>&1 && crontab -l 2>/dev/null | grep -Fq "$BOOTSTRAP_SCRIPT" && hooks+=("cron")
  [ -f /etc/rc.local ] && grep -Fq "$BOOTSTRAP_SCRIPT" /etc/rc.local 2>/dev/null && hooks+=("rc.local")
  [ -f "$LOGIN_AUTOSTART_FILE" ] && grep -Fq "$BOOTSTRAP_SCRIPT" "$LOGIN_AUTOSTART_FILE" 2>/dev/null && hooks+=("login")
  pid1_cmd="$(tr '\0' ' ' < /proc/1/cmdline 2>/dev/null || true)"
  for token in $pid1_cmd; do
    if [ -f "$token" ] && grep -Fq "CFPROXY-PID1-BOOTSTRAP" "$token" 2>/dev/null; then
      hooks+=("pid1")
      break
    fi
  done
  if [ ${#hooks[@]} -gt 0 ]; then
    BOOT_HOOK_BACKEND="$(IFS=+; echo "${hooks[*]}")"
  else
    BOOT_HOOK_BACKEND="manual"
  fi
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || fail "缺少命令：$1"
}

ensure_base_tools() {
  local pkgs=()
  command -v curl >/dev/null 2>&1 || pkgs+=(curl)
  command -v tar >/dev/null 2>&1 || pkgs+=(tar)
  command -v openssl >/dev/null 2>&1 || pkgs+=(openssl)
  command -v ss >/dev/null 2>&1 || pkgs+=(iproute2)
  command -v timeout >/dev/null 2>&1 || pkgs+=(coreutils)

  if [ ${#pkgs[@]} -eq 0 ]; then
    return
  fi

  info "正在安装缺失依赖：${pkgs[*]}"
  if command -v apt-get >/dev/null 2>&1; then
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -y >/dev/null
    apt-get install -y "${pkgs[@]}"
  elif command -v dnf >/dev/null 2>&1; then
    dnf install -y "${pkgs[@]}"
  elif command -v yum >/dev/null 2>&1; then
    yum install -y "${pkgs[@]}"
  elif command -v apk >/dev/null 2>&1; then
    apk add --no-cache "${pkgs[@]}"
  else
    fail "无法自动安装依赖，请先安装：${pkgs[*]}"
  fi
}

ensure_base_tools
need_cmd curl
need_cmd tar
need_cmd openssl
need_cmd ss
detect_service_backend
detect_boot_hook_backend

if [ "$SERVICE_BACKEND" = "process" ]; then
  need_cmd nohup
  warn "检测到当前环境没有可用的 systemd，将自动改用进程守护模式。"
fi

arch_name() {
  case "$(uname -m)" in
    x86_64|amd64) echo "amd64" ;;
    aarch64|arm64) echo "arm64" ;;
    armv7l) echo "arm" ;;
    *) fail "暂不支持当前架构：$(uname -m)" ;;
  esac
}

lower() {
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]'
}

rand_uuid() {
  cat /proc/sys/kernel/random/uuid
}

b64() {
  openssl base64 -A
}

urlencode_path() {
  printf '%s' "$1" | sed 's|/|%2F|g'
}

port_in_use() {
  ss -lnt 2>/dev/null | awk 'NR>1 {print $4}' | grep -Eq "(^|[:.])$1$"
}

pick_random_port() {
  local p
  for _ in $(seq 1 200); do
    p=$((10000 + RANDOM % 50001))
    if ! port_in_use "$p"; then
      echo "$p"
      return
    fi
  done
  fail "找不到可用端口，请稍后重试。"
}

pick_port() {
  if [ "$LOCAL_PORT" -gt 0 ]; then
    if port_in_use "$LOCAL_PORT"; then
      warn "固定端口 $LOCAL_PORT 已被占用，已自动改为随机端口。"
    else
      echo "$LOCAL_PORT"
      return
    fi
  fi

  pick_random_port
}

save_state() {
  cat > "$STATE_FILE" <<STATE_EOF
CURRENT_ALIAS=$(printf '%q' "$CURRENT_ALIAS")
TUNNEL_NAME=$(printf '%q' "$TUNNEL_NAME")
TUNNEL_DOMAIN=$(printf '%q' "$TUNNEL_DOMAIN")
TUNNEL_UUID_CF=$(printf '%q' "$TUNNEL_UUID_CF")
PROXY_UUID=$(printf '%q' "$PROXY_UUID")
PROXY_PORT=$(printf '%q' "$PROXY_PORT")
PROXY_PROTOCOL=$(printf '%q' "$PROXY_PROTOCOL")
WS_PATH=$(printf '%q' "$WS_PATH")
SB_SERVICE_NAME=$(printf '%q' "$SB_SERVICE_NAME")
CF_SERVICE_NAME=$(printf '%q' "$CF_SERVICE_NAME")
CF_RUN_MODE=$(printf '%q' "$CF_RUN_MODE")
DEPLOY_AUTH_MODE=$(printf '%q' "$DEPLOY_AUTH_MODE")
CF_LAST_HEALTH=$(printf '%q' "$CF_LAST_HEALTH")
SB_LISTEN_ADDR=$(printf '%q' "$SB_LISTEN_ADDR")
FB_ENABLED_STATE=$(printf '%q' "$FB_ENABLED_STATE")
FB_LOCAL_PORT=$(printf '%q' "$FB_LOCAL_PORT")
FB_SERVICE_NAME=$(printf '%q' "$FB_SERVICE_NAME")
FB_CF_SERVICE_NAME=$(printf '%q' "$FB_CF_SERVICE_NAME")
FB_QUICK_URL=$(printf '%q' "$FB_QUICK_URL")
FB_PASSWORD_EFFECTIVE=$(printf '%q' "$FB_PASSWORD_EFFECTIVE")
DIRECT_PUBLIC_STATE=$(printf '%q' "$DIRECT_PUBLIC_STATE")
DIRECT_PUBLIC_HOST_EFFECTIVE=$(printf '%q' "$DIRECT_PUBLIC_HOST_EFFECTIVE")
DIRECT_PUBLIC_LINK=$(printf '%q' "$DIRECT_PUBLIC_LINK")
FB_PUBLIC_URL=$(printf '%q' "$FB_PUBLIC_URL")
NGROK_ENABLED_STATE=$(printf '%q' "$NGROK_ENABLED_STATE")
NGROK_PROXY_SERVICE_NAME=$(printf '%q' "$NGROK_PROXY_SERVICE_NAME")
NGROK_FB_SERVICE_NAME=$(printf '%q' "$NGROK_FB_SERVICE_NAME")
NGROK_PROXY_URL=$(printf '%q' "$NGROK_PROXY_URL")
NGROK_PROXY_KIND=$(printf '%q' "$NGROK_PROXY_KIND")
NGROK_FB_URL=$(printf '%q' "$NGROK_FB_URL")
NGROK_MUX_SERVICE_NAME=$(printf '%q' "$NGROK_MUX_SERVICE_NAME")
NGROK_MUX_PORT=$(printf '%q' "$NGROK_MUX_PORT")
NGROK_MUX_STATE=$(printf '%q' "$NGROK_MUX_STATE")
NGROK_AUTHTOKEN_FINGERPRINT=$(printf '%q' "$NGROK_AUTHTOKEN_FINGERPRINT")
STATE_EOF
  chmod 600 "$STATE_FILE"
}

load_state() {
  if [ -f "$STATE_FILE" ]; then
    # shellcheck disable=SC1090
    source "$STATE_FILE"
    if [ -n "${CURRENT_ALIAS:-}" ]; then
      refresh_output_paths
    fi
  fi
}

current_auth_mode() {
  if [ -n "${DEPLOY_AUTH_MODE:-}" ]; then
    printf '%s\n' "$DEPLOY_AUTH_MODE"
  else
    printf '%s\n' "$CF_AUTH_MODE"
  fi
}

set_current_auth_mode() {
  CF_AUTH_MODE="$1"
  DEPLOY_AUTH_MODE="$1"
}

auth_blob_nonempty() {
  [ -n "$(printf '%s' "${CERT_PEM_CONTENT:-}" | tr -d '[:space:]')" ]
}

is_regular_script_source() {
  local src="$1"
  [ -n "$src" ] || return 1
  [ -f "$src" ] || return 1
  case "$src" in
    /dev/fd/*|/proc/*/fd/*|/proc/self/fd/*|stdin|-) return 1 ;;
  esac
  [ -r "$src" ]
}

extract_url_from_cmdline() {
  local cmdline="$1"
  printf '%s\n' "$cmdline" \
    | grep -Eo 'https?://[^ '"'"'\"()<>]+' \
    | awk '
        /cfproxy/ || /gist\.githubusercontent/ || /raw\.githubusercontent/ || /\.sh(\?|$)/ { print; found=1; exit }
        { if (!first) first=$0 }
        END { if (!found && first) print first }
      ' \
    | head -n1
}

guess_script_install_url() {
  local parent grandparent cmdline url

  if [ -n "${CFPROXY_SCRIPT_URL:-}" ]; then
    printf '%s\n' "$CFPROXY_SCRIPT_URL"
    return 0
  fi

  parent="${PPID:-}"
  grandparent="$(ps -o ppid= -p "${parent:-0}" 2>/dev/null | tr -d '[:space:]' || true)"

  for pid in "$parent" "$grandparent"; do
    [ -n "$pid" ] || continue
    cmdline="$(ps -o args= -p "$pid" 2>/dev/null || true)"
    [ -n "$cmdline" ] || continue
    url="$(extract_url_from_cmdline "$cmdline" || true)"
    if [ -n "$url" ]; then
      printf '%s\n' "$url"
      return 0
    fi
  done

  return 1
}

bootstrap_script_url() {
  printf '%s\n' "${CFPROXY_SCRIPT_URL:-你的Raw链接}"
}

bootstrap_cert_url() {
  printf '%s\n' "${CFPROXY_CERT_URL:-你的cert链接}"
}

bootstrap_install_command() {
  local url q_url q_install_dir q_bin_dir q_script
  url="$(bootstrap_script_url)"
  q_url=$(printf '%q' "$url")
  q_install_dir=$(printf '%q' "$INSTALL_DIR")
  q_bin_dir=$(printf '%q' "/usr/local/bin")
  q_script=$(printf '%q' "$INSTALLED_SCRIPT")
  printf "%s\n" \
    "install -d ${q_install_dir} ${q_bin_dir} && curl -fsSL ${q_url} -o ${q_script} && chmod 755 ${q_script} && bash ${q_script}"
}

bootstrap_install_command_with_cert() {
  local script_url cert_url q_script_url q_cert_url q_install_dir q_bin_dir q_bootstrap_dir q_script q_cert_file
  script_url="$(bootstrap_script_url)"
  cert_url="$(bootstrap_cert_url)"
  q_script_url=$(printf '%q' "$script_url")
  q_cert_url=$(printf '%q' "$cert_url")
  q_install_dir=$(printf '%q' "$INSTALL_DIR")
  q_bin_dir=$(printf '%q' "/usr/local/bin")
  q_bootstrap_dir=$(printf '%q' "$BOOTSTRAP_DIR")
  q_script=$(printf '%q' "$INSTALLED_SCRIPT")
  q_cert_file=$(printf '%q' "$BOOTSTRAP_CERT_FILE")
  printf "%s\n" \
    "install -d ${q_install_dir} ${q_bin_dir} ${q_bootstrap_dir} && curl -fsSL ${q_script_url} -o ${q_script} && chmod 755 ${q_script} && curl -fsSL ${q_cert_url} -o ${q_cert_file} && chmod 600 ${q_cert_file} && bash ${q_script}"
}

bootstrap_cert_ready() {
  [ -s "$BOOTSTRAP_CERT_FILE" ]
}

local_mgmt_cred_exists() {
  [ -s "$BOOTSTRAP_CERT_FILE" ] || [ -s "$CF_DIR/cert.pem" ]
}

purge_local_mgmt_cred() {
  local removed=0
  if [ -f "$BOOTSTRAP_CERT_FILE" ]; then
    rm -f "$BOOTSTRAP_CERT_FILE"
    removed=1
  fi
  if [ -f "$CF_DIR/cert.pem" ]; then
    rm -f "$CF_DIR/cert.pem"
    removed=1
  fi
  history -c 2>/dev/null || true
  if [ "$removed" -eq 1 ]; then
    ok "本地管理凭证痕迹已清理完成。"
  else
    warn "当前没有检测到可清理的本地管理凭证文件。"
  fi
}

get_script_version_from_file() {
  local file="$1"
  [ -r "$file" ] || return 1
  sed -n 's/^SCRIPT_VERSION="\([^"]*\)"$/\1/p' "$file" | head -n1
}

require_cert() {
  [ "$(current_auth_mode)" = "cert" ] || return 0
  mkdir -p "$CF_DIR"
  chmod 700 "$CF_DIR" || true

  if [ -s "$CF_DIR/cert.pem" ]; then
    return 0
  fi

  if bootstrap_cert_ready; then
    mv -f "$BOOTSTRAP_CERT_FILE" "$CF_DIR/cert.pem"
    chmod 600 "$CF_DIR/cert.pem"
    MGMT_CRED_TEMP_WRITTEN="1"
    ok "已载入一次性管理凭证，完成 cert 模式操作后会自动销毁。"
    return 0
  fi

  if auth_blob_nonempty; then
    printf '%s\n' "$CERT_PEM_CONTENT" > "$CF_DIR/cert.pem"
    chmod 600 "$CF_DIR/cert.pem"
    MGMT_CRED_TEMP_WRITTEN="1"
    ok "已注入临时管理凭证。"
    return 0
  fi

  echo ""
  warn "当前操作需要 Cloudflare 管理凭证。"
  echo "请直接粘贴你的 cert.pem / 认证块内容，结束后按 Ctrl+D 提交。"
  cat > "$CF_DIR/cert.pem"
  [ -s "$CF_DIR/cert.pem" ] || fail "没有收到任何凭证内容，操作终止。"
  chmod 600 "$CF_DIR/cert.pem"
  MGMT_CRED_TEMP_WRITTEN="1"
  ok "临时管理凭证已注入。"
}

destroy_cert() {
  [ "$(current_auth_mode)" = "cert" ] || return 0
  [ "${AUTO_DESTROY_CERT}" = "on" ] || return 0
  if [ -f "$CF_DIR/cert.pem" ]; then
    rm -f "$CF_DIR/cert.pem"
    MGMT_CRED_TEMP_WRITTEN="0"
    history -c 2>/dev/null || true
    ok "管理凭证已从服务器销毁。"
  fi
}

install_manager_copy() {
  local src="${BASH_SOURCE[0]}"
  local tmp url installed_version
  [ "${ENABLE_QUICK_CMD}" = "on" ] || return 0

  if [ "$src" = "$INSTALLED_SCRIPT" ] && [ -f "$INSTALLED_SCRIPT" ]; then
    return 0
  fi

  installed_version="$(get_script_version_from_file "$INSTALLED_SCRIPT" 2>/dev/null || true)"
  if [ -f "$INSTALLED_SCRIPT" ] && [ "$installed_version" = "$SCRIPT_VERSION" ]; then
    return 0
  fi

  mkdir -p "$INSTALL_DIR"
  tmp=$(mktemp)

  if is_regular_script_source "$src"; then
    cat "$src" > "$tmp"
  else
    url="$(guess_script_install_url || true)"
    if [ -z "$url" ]; then
      rm -f "$tmp"
      warn "当前脚本是临时流式执行（如 bash <(curl ...)），无法直接复制自身。"
      warn "请改用“首条安装命令”先把脚本完整落盘到 $INSTALLED_SCRIPT，再启动面板。"
      return 1
    fi
    info "正在从脚本源地址刷新快捷命令副本：$url"
    if ! curl -fsSL "$url" -o "$tmp"; then
      rm -f "$tmp"
      warn "快捷命令副本刷新失败：$url"
      return 1
    fi
  fi

  if ! bash -n "$tmp" >/dev/null 2>&1; then
    rm -f "$tmp"
    warn "快捷命令副本语法校验失败，已放弃覆盖旧副本。"
    return 1
  fi

  chmod 755 "$tmp"
  mv -f "$tmp" "$INSTALLED_SCRIPT"
  return 0
}

register_quick_cmd() {
  if [ "${ENABLE_QUICK_CMD}" != "on" ]; then
    return 0
  fi

  local dst="/usr/local/bin/${QUICK_CMD}"
  local tmp
  if ! install_manager_copy; then
    return 0
  fi
  if [ ! -r "$INSTALLED_SCRIPT" ]; then
    warn "未能写入管理脚本副本，跳过快捷命令注册。"
    return 0
  fi

  tmp=$(mktemp)
  cat > "$tmp" <<EOF
#!/usr/bin/env bash
if [ "\$(id -u)" -ne 0 ]; then
  if command -v sudo >/dev/null 2>&1; then
    exec sudo bash "$INSTALLED_SCRIPT" "\$@"
  fi
  echo "当前不是 root，且未检测到 sudo。请先切到 root 后再运行 ${QUICK_CMD}。" >&2
  exit 1
fi
exec bash "$INSTALLED_SCRIPT" "\$@"
EOF
  chmod 755 "$tmp"
  if [ -f "$dst" ] && cmp -s "$tmp" "$dst" 2>/dev/null; then
    rm -f "$tmp"
    return 0
  fi
  mv -f "$tmp" "$dst"
  ok "快捷命令已更新：${QUICK_CMD}"
}

show_boot_log() {
  echo ""
  echo -e "${BLUE}CF Proxy 启动中${RESET}"
  echo "认证模式 : $(current_auth_mode)"
  echo "服务后端 : ${SERVICE_BACKEND}"
  echo "基础组件 : ${STARTUP_CORE_READY}"
  echo "CF 预检  : ${STARTUP_CF_EDGE_STATUS}"
  if [ "$SERVICE_BACKEND" = "process" ]; then
    echo "开机拉起 : ${BOOT_HOOK_BACKEND}"
  fi
  if quick_cmd_installed; then
    echo "快捷命令 : ${QUICK_CMD}（已安装）"
  elif [ "${ENABLE_QUICK_CMD}" = "on" ]; then
    echo "快捷命令 : ${QUICK_CMD}（自动注册开启）"
  else
    echo "快捷命令 : 已关闭自动注册"
  fi
  if local_mgmt_cred_exists; then
    echo "临时凭证 : 已检测到本地管理凭证文件；建议首次 cert 建隧道后自动销毁，或选 6 -> 2 手动彻底删除"
  fi
}

require_deployment() {
  if [ ! -f "$STATE_FILE" ]; then
    warn "当前还没有部署记录。若 CF 预检已显示 7844 不通，可以直接在兜底菜单创建本地代理并走公网/ngrok。"
    return 1
  fi
  return 0
}

has_deployment() {
  [ -f "$STATE_FILE" ] && [ -n "${PROXY_PORT:-}" ] && [ -n "${PROXY_UUID:-}" ] && [ -n "${PROXY_PROTOCOL:-}" ]
}

get_latest_release_tag() {
  local repo="$1"
  curl -fsSL "https://api.github.com/repos/${repo}/releases/latest" \
    | sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' \
    | head -n 1
}

install_singbox() {
  local arch version tmpdir candidate url bin candidates
  if [ -x "$SB_BIN" ]; then
    ok "sing-box 已存在：$($SB_BIN version 2>/dev/null | awk '/version/{print $NF}' | head -n1)"
    return
  fi

  arch=$(arch_name)
  version=$(get_latest_release_tag "SagerNet/sing-box")
  [ -n "$version" ] || fail "获取 sing-box 最新版本失败。"
  version="${version#v}"
  case "$arch" in
    arm64) candidates=("linux-arm64" "linux-arm64-musl" "android-arm64") ;;
    amd64) candidates=("linux-amd64" "linux-amd64-musl" "android-amd64") ;;
    arm)   candidates=("linux-armv7" "linux-armv7-musl" "android-arm") ;;
    *)     candidates=("linux-${arch}") ;;
  esac

  info "正在安装 sing-box v${version} (${arch})"
  tmpdir=$(mktemp -d)

  for candidate in "${candidates[@]}"; do
    url="https://github.com/SagerNet/sing-box/releases/download/v${version}/sing-box-${version}-${candidate}.tar.gz"
    rm -rf "$tmpdir"/*
    if ! curl -fL --progress-bar "$url" -o "$tmpdir/sing-box.tar.gz"; then
      continue
    fi
    tar -xzf "$tmpdir/sing-box.tar.gz" -C "$tmpdir" >/dev/null 2>&1 || continue
    bin=$(find "$tmpdir" -type f -name sing-box | head -n1)
    [ -n "$bin" ] || continue
    chmod +x "$bin"
    if "$bin" version >/dev/null 2>&1; then
      install -m 755 "$bin" "$SB_BIN"
      rm -rf "$tmpdir"
      ok "sing-box 安装完成，使用构建：${candidate}"
      return
    fi
  done

  rm -rf "$tmpdir"
  fail "sing-box 安装失败：所有候选构建均无法在当前环境运行。"
}

install_cloudflared() {
  local arch url tmpbin
  if [ -x "$CF_BIN" ]; then
    ok "cloudflared 已存在：$($CF_BIN --version 2>/dev/null | head -n1)"
    return
  fi

  arch=$(arch_name)
  url="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-${arch}"
  tmpbin=$(mktemp)

  info "正在安装 cloudflared (${arch})"
  curl -fL --progress-bar "$url" -o "$tmpbin"
  install -m 755 "$tmpbin" "$CF_BIN"
  rm -f "$tmpbin"
  ok "cloudflared 安装完成。"
}

startup_prepare_runtime() {
  local mode="${INSTALL_CORE_ON_START:-missing_only}" need=0
  if [ "$mode" = "off" ]; then
    if [ -x "$SB_BIN" ] && [ -x "$CF_BIN" ]; then
      STARTUP_CORE_READY="本地已安装（未联网检查）"
    else
      STARTUP_CORE_READY="未检测/可能缺失（服务管理可手动安装）"
    fi
    return 0
  fi

  if [ "$mode" = "missing_only" ] && [ -x "$SB_BIN" ] && [ -x "$CF_BIN" ]; then
    STARTUP_CORE_READY="已安装（跳过重复检查）"
    return 0
  fi

  if [ "$mode" = "missing_only" ]; then
    [ -x "$SB_BIN" ] || need=1
    [ -x "$CF_BIN" ] || need=1
    if [ "$need" -eq 1 ]; then
      info "启动预检：缺少基础组件，开始补装"
      { [ -x "$SB_BIN" ] || install_singbox; } && { [ -x "$CF_BIN" ] || install_cloudflared; } \
        && STARTUP_CORE_READY="已补齐" \
        || { STARTUP_CORE_READY="安装/检查失败"; warn "基础组件自动安装未完全成功；仍进入面板，部署时会再次尝试。"; }
    else
      STARTUP_CORE_READY="已安装（跳过重复检查）"
    fi
    return 0
  fi

  info "启动预检：检查基础组件 sing-box / cloudflared"
  if ( install_singbox ) && ( install_cloudflared ); then
    STARTUP_CORE_READY="已就绪"
  else
    STARTUP_CORE_READY="安装/检查失败"
    warn "基础组件自动安装未完全成功；仍进入面板，部署时会再次尝试。"
  fi
}

startup_cf_edge_precheck() {
  local rc mode cache now ts status
  mode="${CHECK_CF_EDGE_ON_START:-cached}"
  cache="${RUN_DIR}/cf-edge-precheck.cache"
  mkdir -p "$RUN_DIR" 2>/dev/null || true

  if [ "$mode" = "off" ]; then
    status=$(sed -n '2p' "$cache" 2>/dev/null || true)
    if [ -n "$status" ]; then
      STARTUP_CF_EDGE_STATUS="${status}（上次记录）"
    else
      STARTUP_CF_EDGE_STATUS="未检测（服务管理可手动检测）"
    fi
    return 0
  fi

  if [ "$mode" = "cached" ] && [ -f "$cache" ]; then
    now=$(date +%s)
    ts=$(sed -n '1p' "$cache" 2>/dev/null || echo 0)
    status=$(sed -n '2p' "$cache" 2>/dev/null || true)
    if [ -n "$status" ] && [ $((now - ts)) -lt "${CF_EDGE_PRECHECK_CACHE_SECONDS:-900}" ] 2>/dev/null; then
      STARTUP_CF_EDGE_STATUS="${status}（缓存）"
      return 0
    fi
  fi

  if cf_edge_tcp7844_probe; then rc=0; else rc=$?; fi
  case "$rc" in
    0)
      STARTUP_CF_EDGE_STATUS="可连通"
      ok "启动预检：Cloudflare Tunnel Edge 7844 可连通。"
      ;;
    1)
      STARTUP_CF_EDGE_STATUS="不可连通：疑似 7844 被拦截"
      warn "启动预检：Cloudflare Tunnel Edge 7844 不可连通。CF 固定隧道可能创建成功但不在线；可准备使用面板 4 的公网/Ngrok 兜底。"
      ;;
    *)
      STARTUP_CF_EDGE_STATUS="未检测：缺少 timeout/getent 或解析失败"
      warn "启动预检：暂无法检测 Cloudflare Tunnel Edge 7844。"
      ;;
  esac
  { printf '%s\n%s\n' "$(date +%s)" "$STARTUP_CF_EDGE_STATUS" > "$cache"; chmod 600 "$cache" 2>/dev/null || true; } 2>/dev/null || true
}

manual_check_install_runtime() {
  local rc cache status
  echo ""
  echo -e "${BLUE}========== 手动检查 / 安装 ==========${RESET}"
  info "[1/3] 检查/安装核心组件 sing-box / cloudflared"
  install_singbox
  install_cloudflared

  info "[2/3] 检查/安装已启用的可选组件"
  if [ "${ENABLE_TEMP_FILEBROWSER}" = "on" ] || [ "${FB_ENABLED_STATE:-}" = "on" ]; then
    install_filebrowser || true
  else
    echo "FileBrowser 未启用，跳过。"
  fi
  if [ -n "$(ngrok_tokens 2>/dev/null || true)" ]; then
    install_ngrok || true
  else
    echo "ngrok token 池为空，跳过 ngrok 安装。"
  fi

  info "[3/3] 手动检测 Cloudflare Tunnel Edge 7844"
  if cf_edge_tcp7844_probe; then rc=0; else rc=$?; fi
  case "$rc" in
    0) status="可连通"; ok "CF Edge 7844 可连通。" ;;
    1) status="不可连通：疑似 7844 被拦截"; warn "CF Edge 7844 不可连通；固定隧道可能创建但不在线，建议用公网/ngrok 兜底。" ;;
    *) status="未检测：缺少 timeout/getent 或解析失败"; warn "暂无法检测 CF Edge 7844。" ;;
  esac
  STARTUP_CF_EDGE_STATUS="$status"
  STARTUP_CORE_READY="本地已安装（刚手动检查）"
  cache="${RUN_DIR}/cf-edge-precheck.cache"
  mkdir -p "$RUN_DIR" 2>/dev/null || true
  { printf '%s\n%s\n' "$(date +%s)" "$status" > "$cache"; chmod 600 "$cache" 2>/dev/null || true; } 2>/dev/null || true
  echo -e "${BLUE}=====================================${RESET}"
}

validate_alias() {
  local alias="$1"
  [[ "$alias" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?$ ]]
}

prompt_alias() {
  local input
  while true; do
    read -r -p "请输入服务器别名（仅支持英文/数字/中间-，例如 hk-1）: " input
    input=$(lower "$input")
    if validate_alias "$input"; then
      CURRENT_ALIAS="$input"
      refresh_output_paths
      return
    fi
    echo -e "${RED}格式不正确，请重新输入。${RESET}"
  done
}

prompt_protocol() {
  local choice default_no
  case "$DEFAULT_PROTOCOL" in
    vless) default_no="2" ;;
    *) default_no="1" ;;
  esac

  echo ""
  echo "请选择协议："
  echo "1. vmess-ws（默认推荐，兼容甬哥固定隧道思路）"
  echo "2. vless-ws（备用）"
  read -r -p "请输入数字（默认 ${default_no}）: " choice
  case "${choice:-$default_no}" in
    2) PROXY_PROTOCOL="vless" ;;
    *) PROXY_PROTOCOL="vmess" ;;
  esac
}

prompt_token_value() {
  echo ""
  read -r -s -p "请输入 Cloudflare Tunnel Token: " CF_TUNNEL_TOKEN
  echo ""
  [ -n "${CF_TUNNEL_TOKEN:-}" ] || fail "你选择了 token 模式，但没有输入 tunnel token。"
}

prompt_token_hostname() {
  local input default_domain
  default_domain="${CURRENT_ALIAS}-${DOMAIN_SUFFIX}.${MAIN_DOMAIN}"
  read -r -p "请输入已在 Zero Trust 后台配置好的 tunnel 域名（默认 ${default_domain}）: " input
  TUNNEL_DOMAIN="${input:-$default_domain}"
}

pick_service_name() {
  local base="$1"
  local marker="$2"
  local file

  if [ "$SERVICE_BACKEND" = "systemd" ]; then
    file=$(service_file_path "$base")
    if [ -f "$file" ]; then
      if grep -q "$marker" "$file"; then
        echo "$base"
      else
        echo "cfproxy-${base}"
      fi
    else
      echo "$base"
    fi
  else
    file=$(service_launcher_file "$base")
    if [ -f "$file" ]; then
      if grep -q "$marker" "$file"; then
        echo "$base"
      else
        echo "cfproxy-${base}"
      fi
    else
      echo "$base"
    fi
  fi
}

process_is_active() {
  local name="$1"
  local pidfile pid cmdline launcher marker

  pidfile=$(service_pid_file "$name")
  launcher=$(service_launcher_file "$name")
  marker="cfproxy-${name}"
  [ -s "$pidfile" ] || return 1
  pid=$(cat "$pidfile" 2>/dev/null || true)
  [ -n "$pid" ] || return 1
  kill -0 "$pid" 2>/dev/null || return 1
  cmdline=$(tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null || true)
  [[ "$cmdline" == *"$marker"* || "$cmdline" == *"$launcher"* ]]
}

write_bootstrap_script() {
  cat > "$BOOTSTRAP_SCRIPT" <<EOF
#!/usr/bin/env bash
set -u
RUN_DIR="${RUN_DIR}"

process_active() {
  local pidfile="\$1" pid cmdline name launcher marker
  name="\$(basename "\$pidfile" .pid)"
  launcher="\$RUN_DIR/\${name}.sh"
  marker="cfproxy-\${name}"
  [ -s "\$pidfile" ] || return 1
  pid=\$(cat "\$pidfile" 2>/dev/null || true)
  [ -n "\$pid" ] || return 1
  kill -0 "\$pid" 2>/dev/null || return 1
  cmdline=\$(tr '\\0' ' ' < "/proc/\$pid/cmdline" 2>/dev/null || true)
  [[ "\$cmdline" == *"\$marker"* || "\$cmdline" == *"\$launcher"* ]]
}

shopt -s nullglob
for launcher in "\$RUN_DIR"/*.sh; do
  name="\$(basename "\$launcher" .sh)"
  pidfile="\$RUN_DIR/\${name}.pid"
  logfile="\$RUN_DIR/\${name}.log"
  if process_active "\$pidfile"; then
    continue
  fi
  nohup bash "\$launcher" >> "\$logfile" 2>&1 &
  echo \$! > "\$pidfile"
done
EOF
  chmod 700 "$BOOTSTRAP_SCRIPT"
}

install_bootstrap_cron() {
  local tmp line
  line="@reboot bash $BOOTSTRAP_SCRIPT >/dev/null 2>&1"
  tmp=$(mktemp)
  crontab -l 2>/dev/null | grep -Fv "$BOOTSTRAP_SCRIPT" > "$tmp" || true
  printf '%s\n' "$line" >> "$tmp"
  crontab "$tmp" || { rm -f "$tmp"; return 1; }
  rm -f "$tmp"
  return 0
}

install_bootstrap_rc_local() {
  local file="/etc/rc.local"
  local tmp

  if [ ! -f "$file" ]; then
    cat > "$file" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
    chmod 755 "$file"
  fi

  grep -Fq "$BOOTSTRAP_SCRIPT" "$file" && return 0

  tmp=$(mktemp)
  awk -v cmd="bash $BOOTSTRAP_SCRIPT >/dev/null 2>&1" '
    BEGIN { inserted=0 }
    /^exit 0$/ && !inserted {
      print "# >>> CFPROXY-BOOTSTRAP >>>"
      print cmd
      print "# <<< CFPROXY-BOOTSTRAP <<<"
      inserted=1
    }
    { print }
    END {
      if (!inserted) {
        print "# >>> CFPROXY-BOOTSTRAP >>>"
        print cmd
        print "# <<< CFPROXY-BOOTSTRAP <<<"
        print "exit 0"
      }
    }
  ' "$file" > "$tmp"
  chmod 755 "$tmp"
  mv -f "$tmp" "$file"
  return 0
}

install_login_autostart_hook() {
  [ "${ENABLE_LOGIN_AUTOSTART}" = "on" ] || return 1
  cat > "$LOGIN_AUTOSTART_FILE" <<EOF
# CFPROXY-MANAGED
# 极简环境兜底：没有 systemd/cron 或 rc.local 不执行时，登录 shell 自动补拉起服务。
if [ -x "$BOOTSTRAP_SCRIPT" ]; then
  if [ "\$(id -u 2>/dev/null)" = "0" ]; then
    nohup bash "$BOOTSTRAP_SCRIPT" >/dev/null 2>&1 &
  elif command -v sudo >/dev/null 2>&1 && sudo -n true >/dev/null 2>&1; then
    nohup sudo -n bash "$BOOTSTRAP_SCRIPT" >/dev/null 2>&1 &
  fi
fi
EOF
  chmod 644 "$LOGIN_AUTOSTART_FILE"
  return 0
}

pid1_entrypoint_candidate() {
  local pid1_cmd token
  pid1_cmd="$(tr '\0' ' ' < /proc/1/cmdline 2>/dev/null || true)"
  for token in $pid1_cmd; do
    case "$token" in
      /*.sh|/*.bash)
        [ -f "$token" ] && [ -w "$token" ] && printf '%s\n' "$token" && return 0
        ;;
    esac
  done
  return 1
}

install_pid1_entrypoint_hook() {
  local file tmp mode
  [ "${ENABLE_PID1_ENTRYPOINT_HOOK}" = "on" ] || return 1
  file="$(pid1_entrypoint_candidate 2>/dev/null || true)"
  [ -n "$file" ] || return 1
  grep -Fq "CFPROXY-PID1-BOOTSTRAP" "$file" 2>/dev/null && return 0
  mode=$(stat -c '%a' "$file" 2>/dev/null || echo 755)
  cp -n "$file" "${file}.cfproxy.bak" 2>/dev/null || true
  tmp=$(mktemp)
  awk -v boot="$BOOTSTRAP_SCRIPT" '
    NR==1 {
      print
      print "# >>> CFPROXY-PID1-BOOTSTRAP >>>"
      print "[ -x " q boot q " ] && nohup bash " q boot q " >/dev/null 2>&1 &"
      print "# <<< CFPROXY-PID1-BOOTSTRAP <<<"
      next
    }
    { print }
  ' q="'" "$file" > "$tmp"
  chmod "$mode" "$tmp" 2>/dev/null || chmod 755 "$tmp"
  mv -f "$tmp" "$file"
  return 0
}

install_bootstrap_hook() {
  local hooks=()
  [ "$SERVICE_BACKEND" = "process" ] || return 0
  write_bootstrap_script

  if command -v crontab >/dev/null 2>&1; then
    install_bootstrap_cron && hooks+=("cron")
  fi

  install_bootstrap_rc_local && hooks+=("rc.local")
  install_login_autostart_hook && hooks+=("login")
  install_pid1_entrypoint_hook && hooks+=("pid1")

  if [ ${#hooks[@]} -gt 0 ]; then
    BOOT_HOOK_BACKEND="$(IFS=+; echo "${hooks[*]}")"
  else
    BOOT_HOOK_BACKEND="manual"
    warn "当前环境没有可用的 systemd / crontab / rc.local / login hook，已仅保证当前会话可运行；重启后请手动执行：bash $BOOTSTRAP_SCRIPT"
  fi
}

remove_bootstrap_hook() {
  local tmp pid1_file
  [ "$SERVICE_BACKEND" = "process" ] || return 0

  if command -v crontab >/dev/null 2>&1; then
    tmp=$(mktemp)
    crontab -l 2>/dev/null | grep -Fv "$BOOTSTRAP_SCRIPT" > "$tmp" || true
    crontab "$tmp" 2>/dev/null || true
    rm -f "$tmp"
  fi

  if [ -f /etc/rc.local ] && grep -Fq "$BOOTSTRAP_SCRIPT" /etc/rc.local 2>/dev/null; then
    tmp=$(mktemp)
    awk '
      /# >>> CFPROXY-BOOTSTRAP >>>/ { skip=1; next }
      /# <<< CFPROXY-BOOTSTRAP <<</ { skip=0; next }
      !skip { print }
    ' /etc/rc.local > "$tmp"
    chmod 755 "$tmp"
    mv -f "$tmp" /etc/rc.local
  fi

  pid1_file="$(pid1_entrypoint_candidate 2>/dev/null || true)"
  if [ -n "${pid1_file:-}" ] && grep -Fq "CFPROXY-PID1-BOOTSTRAP" "$pid1_file" 2>/dev/null; then
    tmp=$(mktemp)
    awk '
      /# >>> CFPROXY-PID1-BOOTSTRAP >>>/ { skip=1; next }
      /# <<< CFPROXY-PID1-BOOTSTRAP <<</ { skip=0; next }
      !skip { print }
    ' "$pid1_file" > "$tmp"
    chmod --reference="$pid1_file" "$tmp" 2>/dev/null || chmod 755 "$tmp"
    mv -f "$tmp" "$pid1_file"
  fi

  rm -f "$LOGIN_AUTOSTART_FILE"
  rm -f "$BOOTSTRAP_SCRIPT"
  BOOT_HOOK_BACKEND="manual"
}

write_process_service() {
  local name="$1"
  local desc="$2"
  local exec_line="$3"
  local launcher

  launcher=$(service_launcher_file "$name")
  cat > "$launcher" <<EOF
#!/usr/bin/env bash
# CFPROXY-MANAGED
# ${desc}
set -Eeuo pipefail
child_pid=""
term_handler() {
  if [ -n "\${child_pid:-}" ] && kill -0 "\$child_pid" 2>/dev/null; then
    kill "\$child_pid" 2>/dev/null || true
    sleep 1
    kill -9 "\$child_pid" 2>/dev/null || true
  fi
  exit 0
}
trap term_handler TERM INT

while true; do
  echo "[\$(date -Is)] starting ${name}: ${exec_line}"
  bash -lc 'exec -a "cfproxy-${name}" ${exec_line}' &
  child_pid=\$!
  if wait "\$child_pid"; then
    rc=0
  else
    rc=\$?
  fi
  child_pid=""
  echo "[\$(date -Is)] ${name} exited with code \$rc; restart in ${PROCESS_RESTART_SEC}s"
  sleep ${PROCESS_RESTART_SEC}
done
EOF
  chmod 700 "$launcher"
  install_bootstrap_hook
}

write_service_definition() {
  if [ "$SERVICE_BACKEND" = "systemd" ]; then
    write_systemd_service "$@"
  else
    write_process_service "$@"
  fi
}

start_process_service() {
  local name="$1"
  local launcher logfile pidfile

  launcher=$(service_launcher_file "$name")
  logfile=$(service_log_file "$name")
  pidfile=$(service_pid_file "$name")
  [ -x "$launcher" ] || fail "启动失败，缺少服务启动脚本：$launcher"

  if process_is_active "$name"; then
    stop_process_service "$name"
  fi

  nohup bash "$launcher" >> "$logfile" 2>&1 &
  echo $! > "$pidfile"
  sleep 2

  if ! process_is_active "$name"; then
    tail -n 80 "$logfile" 2>/dev/null || true
    fail "服务 ${name} 启动失败。"
  fi
}

stop_process_service() {
  local name="$1"
  local pidfile pid marker launcher

  pidfile=$(service_pid_file "$name")
  marker="cfproxy-${name}"
  launcher=$(service_launcher_file "$name")
  if [ -s "$pidfile" ]; then
    pid=$(cat "$pidfile" 2>/dev/null || true)
    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
      kill "$pid" 2>/dev/null || true
      sleep 1
      kill -9 "$pid" 2>/dev/null || true
    fi
  fi
  ps -eo pid=,args= 2>/dev/null | awk -v marker="$marker" -v launcher="$launcher" '
    $0 ~ marker || $0 ~ launcher {print $1}
  ' | sort -u | while read -r child; do
    [ -n "$child" ] || continue
    [ "$child" != "$$" ] || continue
    kill "$child" 2>/dev/null || true
    sleep 1
    kill -9 "$child" 2>/dev/null || true
  done
  rm -f "$pidfile"
}

service_is_active() {
  local name="$1"
  if [ "$SERVICE_BACKEND" = "systemd" ]; then
    systemctl is-active --quiet "$name"
  else
    process_is_active "$name"
  fi
}

stop_service_runtime() {
  local name="$1"
  if [ "$SERVICE_BACKEND" = "systemd" ]; then
    systemctl stop "$name" >/dev/null 2>&1 || true
  else
    stop_process_service "$name" || true
  fi
}

start_service() {
  local name="$1"
  if [ "$SERVICE_BACKEND" = "systemd" ]; then
    systemctl enable "$name" >/dev/null 2>&1 || true
    systemctl restart "$name"
    sleep 2
    systemctl is-active --quiet "$name" || {
      journalctl -u "$name" -n 50 --no-pager || true
      fail "服务 ${name} 启动失败。"
    }
  else
    start_process_service "$name"
  fi
}

restart_service() {
  local name="$1"
  if [ "$SERVICE_BACKEND" = "systemd" ]; then
    systemctl restart "$name"
    sleep 2
    systemctl is-active --quiet "$name" || {
      journalctl -u "$name" -n 50 --no-pager || true
      fail "服务 ${name} 重启失败。"
    }
  else
    stop_process_service "$name"
    start_process_service "$name"
  fi
}

ensure_service_running() {
  local name="$1"
  service_is_active "$name" && return 0
  start_service "$name"
}

has_process_services() {
  compgen -G "${RUN_DIR}/*.sh" >/dev/null 2>&1
}

write_systemd_service() {
  local name="$1"
  local desc="$2"
  local exec_line="$3"
  local file
  file=$(service_file_path "$name")

  cat > "$file" <<SERVICE_EOF
# CFPROXY-MANAGED
[Unit]
Description=${desc}
After=network-online.target nss-lookup.target
Wants=network-online.target

[Service]
Type=simple
User=root
ExecStart=${exec_line}
Restart=always
RestartSec=5
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
SERVICE_EOF

  systemctl daemon-reload
}

stop_disable_remove_service() {
  local name="$1"
  local file launcher pidfile logfile

  if [ "$SERVICE_BACKEND" = "systemd" ]; then
    file=$(service_file_path "$name")
    systemctl stop "$name" >/dev/null 2>&1 || true
    systemctl disable "$name" >/dev/null 2>&1 || true
    rm -f "$file"
    systemctl daemon-reload >/dev/null 2>&1 || true
  else
    launcher=$(service_launcher_file "$name")
    pidfile=$(service_pid_file "$name")
    logfile=$(service_log_file "$name")
    stop_process_service "$name"
    rm -f "$launcher" "$pidfile" "$logfile"
    if ! has_process_services; then
      remove_bootstrap_hook
    else
      detect_boot_hook_backend
    fi
  fi
}

build_singbox_config() {
  local check_output
  mkdir -p "$SB_DIR"

  case "$PROXY_PROTOCOL" in
    vmess)
      cat > "$SB_CONFIG" <<EOF_JSON
{
  "log": { "level": "warn", "timestamp": true },
  "inbounds": [
    {
      "type": "vmess",
      "tag": "vmess-in",
      "listen": "${SB_LISTEN_ADDR}",
      "listen_port": ${PROXY_PORT},
      "users": [
        { "uuid": "${PROXY_UUID}", "alterId": 0 }
      ],
      "transport": {
        "type": "ws",
        "path": "${WS_PATH}",
        "max_early_data": 2048,
        "early_data_header_name": "Sec-WebSocket-Protocol"
      }
    }
  ],
  "outbounds": [
    { "type": "direct", "tag": "direct" }
  ]
}
EOF_JSON
      ;;
    vless)
      cat > "$SB_CONFIG" <<EOF_JSON
{
  "log": { "level": "warn", "timestamp": true },
  "inbounds": [
    {
      "type": "vless",
      "tag": "vless-in",
      "listen": "${SB_LISTEN_ADDR}",
      "listen_port": ${PROXY_PORT},
      "users": [
        { "uuid": "${PROXY_UUID}" }
      ],
      "transport": {
        "type": "ws",
        "path": "${WS_PATH}",
        "max_early_data": 2048,
        "early_data_header_name": "Sec-WebSocket-Protocol"
      }
    }
  ],
  "outbounds": [
    { "type": "direct", "tag": "direct" }
  ]
}
EOF_JSON
      ;;
    *)
      fail "未知协议：${PROXY_PROTOCOL}"
      ;;
  esac

  if ! check_output=$("$SB_BIN" check -c "$SB_CONFIG" 2>&1); then
    echo "$check_output"
    fail "sing-box 配置校验失败：$SB_CONFIG"
  fi
}

setup_singbox_service() {
  SB_SERVICE_NAME=$(pick_service_name "sing-box" "CFPROXY-MANAGED")
  write_service_definition "$SB_SERVICE_NAME" "CFProxy sing-box service" "$SB_BIN run -c $SB_CONFIG"
  start_service "$SB_SERVICE_NAME"
  if [ "$SERVICE_BACKEND" = "systemd" ]; then
    ok "${SB_SERVICE_NAME}.service 已启动并设置开机自启。"
  else
    ok "${SB_SERVICE_NAME} 已启动（进程守护模式，开机拉起：${BOOT_HOOK_BACKEND}）。"
  fi
}

restart_singbox_after_config_change() {
  build_singbox_config
  if [ -n "${SB_SERVICE_NAME:-}" ]; then
    restart_service "$SB_SERVICE_NAME"
  else
    setup_singbox_service
  fi
}

prepare_cf_auth() {
  local compact_content auth_mode
  mkdir -p "$CF_DIR" "$CF_WORK_DIR"
  chmod 700 "$CF_DIR" "$CF_WORK_DIR" || true
  auth_mode="$(current_auth_mode)"

  case "$auth_mode" in
    cert)
      require_cert
      compact_content="$(tr -d '[:space:]' < "$CF_DIR/cert.pem" 2>/dev/null || true)"
      [ -n "$compact_content" ] || fail "cert 模式需要有效的管理凭证。"
      CF_RUN_MODE="config"
      ;;
    token)
      [ -n "$CF_TUNNEL_TOKEN" ] || fail "当前是 token 模式，但 CF_TUNNEL_TOKEN 为空。"
      CF_RUN_MODE="token"
      ;;
    local)
      CF_RUN_MODE="skipped"
      ;;
    *)
      fail "认证模式只能是 cert / token / local。"
      ;;
  esac
}

find_tunnel_uuid_by_name() {
  local name="$1" output
  output="$("$CF_BIN" tunnel list 2>/tmp/cfproxy_tunnel_list.log || true)"
  if [ -z "$output" ]; then
    [ -s /tmp/cfproxy_tunnel_list.log ] && warn "读取 Cloudflare 隧道列表失败，先按无同名隧道处理。详情：$(tail -n 1 /tmp/cfproxy_tunnel_list.log)" >&2
    return 0
  fi
  printf '%s\n' "$output" | awk -v name="$name" 'NR>1 && $2==name {print $1; exit}'
}

route_dns_with_policy() {
  local output label candidate i

  if output=$("$CF_BIN" tunnel route dns "$TUNNEL_NAME" "$TUNNEL_DOMAIN" 2>&1); then
    return 0
  fi

  echo "$output"

  if ! echo "$output" | grep -q "record with that host already exists"; then
    warn "绑定 DNS 失败：$TUNNEL_DOMAIN"
    return 1
  fi

  if [ "$DNS_CONFLICT_ACTION" != "auto_suffix" ]; then
    warn "DNS 记录冲突：$TUNNEL_DOMAIN 已存在同名 A/AAAA/CNAME 记录。请先删除旧记录，或换一个新的别名/域名后重试。"
    return 1
  fi

  label="${TUNNEL_DOMAIN%.${MAIN_DOMAIN}}"
  warn "检测到 hostname 冲突，开始自动避让。"

  for i in $(seq 1 "$MAX_DNS_CONFLICT_TRIES"); do
    if [ "$i" -eq 1 ]; then
      candidate="${label}-${DNS_CONFLICT_SUFFIX}.${MAIN_DOMAIN}"
    else
      candidate="${label}-${DNS_CONFLICT_SUFFIX}${i}.${MAIN_DOMAIN}"
    fi
    info "尝试备用域名：$candidate"
    if "$CF_BIN" tunnel route dns "$TUNNEL_NAME" "$candidate" >/dev/null 2>&1; then
      TUNNEL_DOMAIN="$candidate"
      ok "已自动切换为可用域名：$TUNNEL_DOMAIN"
      return 0
    fi
  done

  warn "DNS 冲突自动避让失败。请手动清理旧 DNS 记录，或换一个新的别名后重试。"
  return 1
}

ensure_tunnel_cert_mode() {
  local existing_uuid token_value route_output

  existing_uuid="$(find_tunnel_uuid_by_name "$TUNNEL_NAME" || true)"

  if [ -n "$existing_uuid" ]; then
    TUNNEL_UUID_CF="$existing_uuid"
    ok "发现远端已有同名隧道，直接复用：${TUNNEL_NAME} (${TUNNEL_UUID_CF})"
  else
    info "正在创建隧道：${TUNNEL_NAME}"
    "$CF_BIN" tunnel create "$TUNNEL_NAME" >/tmp/cfproxy_tunnel_create.log 2>&1 || {
      cat /tmp/cfproxy_tunnel_create.log || true
      warn "创建隧道失败，请检查 cert.pem 是否有效；本次将跳过 CF 固定隧道，仍可继续使用公网直连 / ngrok 兜底。"
      return 1
    }
    TUNNEL_UUID_CF="$(find_tunnel_uuid_by_name "$TUNNEL_NAME" || true)"
    [ -n "$TUNNEL_UUID_CF" ] || { warn "隧道已创建，但未能解析出 UUID；本次跳过 CF 固定隧道。"; return 1; }
    ok "隧道创建成功：${TUNNEL_UUID_CF}"
  fi

  if [ -f "$CF_DIR/${TUNNEL_UUID_CF}.json" ]; then
    CF_RUN_MODE="config"
  else
    warn "本地没有 ${TUNNEL_UUID_CF}.json，尝试自动拉取 tunnel token 运行。"
    token_value=$("$CF_BIN" tunnel token "$TUNNEL_NAME" 2>/dev/null | tr -d '\r' | tail -n 1 || true)
    if [ -n "$token_value" ] && [[ "$token_value" == ey* ]]; then
      CF_TUNNEL_TOKEN="$token_value"
      CF_RUN_MODE="token"
      ok "已切换为 token 运行模式，避免因缺少本地 json 凭证而报错。"
    else
      warn "复用同名隧道时本地缺少 json 凭证，且自动获取 token 失败；本次跳过 CF 固定隧道，仍可继续使用公网直连 / ngrok 兜底。"
      return 1
    fi
  fi

  if [ -n "$TUNNEL_UUID_CF" ]; then
    route_dns_with_policy || { warn "DNS/Public Hostname 绑定失败；本次跳过 CF 固定隧道，仍可继续使用公网直连 / ngrok 兜底。"; return 1; }
  fi

  if [ "$CF_RUN_MODE" = "config" ]; then
    cat > "$CF_CONFIG" <<EOF_CF
# CFPROXY-MANAGED
tunnel: ${TUNNEL_UUID_CF}
credentials-file: ${CF_DIR}/${TUNNEL_UUID_CF}.json
ingress:
  - hostname: ${TUNNEL_DOMAIN}
    service: http://127.0.0.1:${PROXY_PORT}
  - service: http_status:404
EOF_CF
  else
    warn "当前 cloudflared 将用 token 方式运行，请确认 Zero Trust 后台已把 ${TUNNEL_DOMAIN} 绑定到 http://127.0.0.1:${PROXY_PORT}"
  fi
}

ensure_tunnel_token_mode() {
  TUNNEL_UUID_CF="token-mode"
  CF_RUN_MODE="token"
  warn "你当前使用 token 模式：脚本不会替你自动创建 DNS/Public Hostname。"
  warn "请先在 Cloudflare Zero Trust 后台确认 ${TUNNEL_DOMAIN} -> http://127.0.0.1:${PROXY_PORT} 已配置好。"
}

setup_cf_tunnel() {
  prepare_cf_auth
  case "$(current_auth_mode)" in
    cert)  ensure_tunnel_cert_mode ;;
    token) ensure_tunnel_token_mode ;;
    local) return 1 ;;
  esac
}

cf_edge_tcp7844_probe() {
  local hosts host ip tried=0
  command -v timeout >/dev/null 2>&1 || return 2
  hosts="region1.argotunnel.com region2.argotunnel.com"
  for host in $hosts; do
    while read -r ip _; do
      [ -n "$ip" ] || continue
      tried=$((tried + 1))
      timeout 4 bash -lc "cat </dev/null >/dev/tcp/${ip}/7844" >/dev/null 2>&1 && return 0
      [ "$tried" -ge 4 ] && return 1
    done < <(getent hosts "$host" 2>/dev/null | awk '{print $1, $2}' | head -n 4)
  done
  return 1
}

warn_if_cf_edge_unreachable() {
  local rc
  if cf_edge_tcp7844_probe; then rc=0; else rc=$?; fi
  case "$rc" in
    0)
      ok "Cloudflare Tunnel Edge 7844 连通性预检通过。"
      ;;
    1)
      warn "Cloudflare Tunnel Edge 7844 预检失败：当前服务器可能拦截出站 7844。"
      warn "这种情况下 cloudflared 进程会在本地运行，但 CF 后台会显示隧道从未唤醒；Quick Tunnel / 临时 FileBrowser 链接也会失败。"
      ;;
    *)
      warn "缺少 timeout 或解析能力，跳过 Cloudflare Edge 7844 预检。"
      ;;
  esac
}

cloudflared_recent_log() {
  service_recent_log "$1" 220
}

cf_quick_tunnel_allowed() {
  local log_text
  [[ "${CF_LAST_HEALTH:-}" == 已连接* ]] && return 0

  if [ -n "${CF_SERVICE_NAME:-}" ] && service_is_active "$CF_SERVICE_NAME"; then
    log_text="$(service_recent_log "$CF_SERVICE_NAME" 260)"
    if [[ "$log_text" == *"Registered tunnel connection"* ]]; then
      CF_LAST_HEALTH="已连接 CF Edge"
      return 0
    fi
  fi

  [[ "${STARTUP_CF_EDGE_STATUS:-}" == 可连通* ]] && return 0
  return 1
}

wait_cloudflared_online() {
  local name="$1" deadline log_text
  [ "${CF_ONLINE_CHECK_TIMEOUT:-0}" -gt 0 ] || return 0
  deadline=$(( $(date +%s) + CF_ONLINE_CHECK_TIMEOUT ))
  CF_LAST_HEALTH="等待 cloudflared 连接 CF Edge"

  while [ "$(date +%s)" -lt "$deadline" ]; do
    if ! service_is_active "$name"; then
      CF_LAST_HEALTH="cloudflared 进程已退出"
      cloudflared_recent_log "$name" | tail -n 80
      return 1
    fi
    log_text="$(cloudflared_recent_log "$name")"
    if printf '%s\n' "$log_text" | grep -q "Registered tunnel connection"; then
      CF_LAST_HEALTH="已连接 CF Edge"
      ok "cloudflared 已出现 Registered tunnel connection，隧道已唤醒。"
      return 0
    fi
    sleep 2
  done

  log_text="$(cloudflared_recent_log "$name")"
  if printf '%s\n' "$log_text" | grep -Eq "7844: i/o timeout|no recent network activity|Failed to dial a quic connection|Unable to establish connection with Cloudflare edge"; then
    CF_LAST_HEALTH="未唤醒：疑似出站 7844 被拦截或严重丢包"
    warn "cloudflared 进程存在，但在 ${CF_ONLINE_CHECK_TIMEOUT}s 内没有连接上 CF Edge。最近日志显示 7844 超时/QUIC 超时。"
  else
    CF_LAST_HEALTH="未唤醒：超时未观察到 Registered tunnel connection"
    warn "cloudflared 进程存在，但在 ${CF_ONLINE_CHECK_TIMEOUT}s 内未观察到 Registered tunnel connection。"
  fi
  echo ""
  cloudflared_recent_log "$name" | tail -n 80
  return 1
}

handle_cloudflared_online_result() {
  local name="$1"
  if wait_cloudflared_online "$name"; then
    return 0
  fi
  if [ "${CF_REQUIRE_TUNNEL_ONLINE}" = "on" ]; then
    fail "隧道未真正唤醒，已按 CF_REQUIRE_TUNNEL_ONLINE=on 中止，避免制造“后台已创建但从未在线”的假成功。"
  fi
  warn "已保留服务并继续输出配置，但当前隧道健康状态为：${CF_LAST_HEALTH}"
  warn "如果 CF 后台显示从未唤醒，优先换服务器/平台；单靠改协议通常无法绕过出站 7844 封锁。"
}

detect_public_host() {
  local ip
  if [ -n "${DIRECT_PUBLIC_HOST:-}" ]; then
    printf '%s\n' "$DIRECT_PUBLIC_HOST"
    return 0
  fi
  for url in \
    "https://api.ipify.org" \
    "https://ifconfig.me/ip" \
    "https://ipv4.icanhazip.com"; do
    ip="$(curl -4fsS --max-time 6 "$url" 2>/dev/null | tr -d '[:space:]' || true)"
    if [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
      printf '%s\n' "$ip"
      return 0
    fi
  done
  return 1
}

uptimerobot_api_key_effective() {
  if [ -n "${CFPROXY_UPTIMEROBOT_API_KEY:-}" ]; then
    printf '%s\n' "$CFPROXY_UPTIMEROBOT_API_KEY"
    return 0
  fi
  if [ -n "${UPTIMEROBOT_API_KEY:-}" ]; then
    printf '%s\n' "$UPTIMEROBOT_API_KEY"
    return 0
  fi
  if [ -n "${UPTIMEROBOT_API_KEY_FILE:-}" ] && [ -s "$UPTIMEROBOT_API_KEY_FILE" ]; then
    sed -n '1{s/[[:space:]]//g;p;q;}' "$UPTIMEROBOT_API_KEY_FILE"
    return 0
  fi
  return 1
}

json_value() {
  local key="$1"
  sed -n "s/.*\"${key}\"[[:space:]]*:[[:space:]]*\"\{0,1\}\([^\",}]*\)\"\{0,1\}.*/\1/p" | head -n1
}

uptimerobot_api_post() {
  local endpoint="$1" api_key="$2"
  shift 2
  curl -fsS --max-time 25 -X POST "https://api.uptimerobot.com/v2/${endpoint}" \
    -H "Content-Type: application/x-www-form-urlencoded" \
    --data-urlencode "api_key=${api_key}" \
    --data "format=json" \
    "$@"
}

uptimerobot_delete_monitor() {
  local api_key="$1" monitor_id="$2" resp
  [ -n "$monitor_id" ] || return 0
  resp="$(uptimerobot_api_post "deleteMonitor" "$api_key" --data "id=${monitor_id}" 2>/dev/null || true)"
  if printf '%s' "$resp" | grep -q '"stat"[[:space:]]*:[[:space:]]*"ok"'; then
    ok "已删除 UptimeRobot 临时 monitor：${monitor_id}"
  else
    warn "删除 UptimeRobot 临时 monitor 失败或未确认成功：${monitor_id}"
  fi
}

uptimerobot_create_port_monitor() {
  local api_key="$1" host="$2" port="$3" friendly resp stat monitor_id
  friendly="cfproxy-${CURRENT_ALIAS:-node}-${host}-${port}-$(date +%s)"
  friendly="$(printf '%s' "$friendly" | tr -c 'A-Za-z0-9_.-' '-')"

  resp="$(uptimerobot_api_post "newMonitor" "$api_key" \
    --data-urlencode "friendly_name=${friendly}" \
    --data-urlencode "url=${host}" \
    --data "type=4" \
    --data "sub_type=99" \
    --data "port=${port}" \
    --data "interval=${UPTIMEROBOT_PROBE_INTERVAL:-300}" \
    --data "timeout=${UPTIMEROBOT_PROBE_TIMEOUT:-10}" 2>&1)" || {
      warn "UptimeRobot 创建 Port Monitor 请求失败：${resp}" >&2
      return 1
    }

  stat="$(printf '%s' "$resp" | json_value stat)"
  if [ "$stat" != "ok" ]; then
    warn "UptimeRobot 创建 Port Monitor 未成功：${resp}" >&2
    return 1
  fi
  monitor_id="$(printf '%s' "$resp" | sed -n 's/.*"id"[[:space:]]*:[[:space:]]*\([0-9][0-9]*\).*/\1/p' | head -n1)"
  [ -n "$monitor_id" ] || { warn "UptimeRobot 返回成功但未解析到 monitor id：${resp}" >&2; return 1; }
  printf '%s\n' "$monitor_id"
}

uptimerobot_get_monitor_status() {
  local api_key="$1" monitor_id="$2" resp status
  resp="$(uptimerobot_api_post "getMonitors" "$api_key" --data "monitors=${monitor_id}" 2>/dev/null || true)"
  status="$(printf '%s' "$resp" | json_value status)"
  [ -n "$status" ] || return 1
  printf '%s\n' "$status"
}

uptimerobot_probe_public_port() {
  local host="$1" port="$2" api_key monitor_id deadline status label
  [ "${ENABLE_UPTIMEROBOT_PROBE}" = "on" ] || { warn "ENABLE_UPTIMEROBOT_PROBE=off，已跳过外部探测。"; return 2; }
  api_key="$(uptimerobot_api_key_effective 2>/dev/null || true)"
  if [ -z "$api_key" ]; then
    warn "未配置 UptimeRobot Main API key。可填 UPTIMEROBOT_API_KEY，或写入 ${UPTIMEROBOT_API_KEY_FILE}，或设置环境变量 CFPROXY_UPTIMEROBOT_API_KEY。"
    return 2
  fi

  info "正在通过 UptimeRobot 创建临时 Port Monitor：${host}:${port}"
  monitor_id="$(uptimerobot_create_port_monitor "$api_key" "$host" "$port")" || return 1
  ok "UptimeRobot 临时 monitor 已创建：${monitor_id}"

  deadline=$(( $(date +%s) + ${UPTIMEROBOT_PROBE_WAIT_SECONDS:-120} ))
  status=""
  while [ "$(date +%s)" -lt "$deadline" ]; do
    status="$(uptimerobot_get_monitor_status "$api_key" "$monitor_id" 2>/dev/null || true)"
    case "$status" in
      2)
        ok "公网入站探测通过：UptimeRobot 判定 ${host}:${port} 为 UP。"
        [ "${UPTIMEROBOT_DELETE_AFTER_PROBE}" = "on" ] && uptimerobot_delete_monitor "$api_key" "$monitor_id"
        return 0
        ;;
      8|9)
        warn "公网入站探测失败：UptimeRobot 判定 ${host}:${port} 为 DOWN。"
        [ "${UPTIMEROBOT_DELETE_AFTER_PROBE}" = "on" ] && uptimerobot_delete_monitor "$api_key" "$monitor_id"
        return 1
        ;;
      0) label="paused" ;;
      1|"") label="尚未完成首次检查" ;;
      *) label="状态码 ${status}" ;;
    esac
    info "等待 UptimeRobot 首次检查结果：${label}"
    sleep 10
  done

  warn "UptimeRobot 在 ${UPTIMEROBOT_PROBE_WAIT_SECONDS}s 内没有给出明确 UP/DOWN 结果，最后状态：${status:-未解析}。"
  [ "${UPTIMEROBOT_DELETE_AFTER_PROBE}" = "on" ] && uptimerobot_delete_monitor "$api_key" "$monitor_id"
  return 2
}

setup_public_direct_fallback() {
  local mode="${1:-auto}"
  if [ "$mode" != "force" ]; then
    [ "${ENABLE_DIRECT_PUBLIC_FALLBACK}" = "on" ] || return 0
    if [[ "${CF_LAST_HEALTH:-}" == 已连接* ]]; then
      return 0
    fi
  fi

  if [ -z "${PROXY_PORT:-}" ] || [ -z "${PROXY_UUID:-}" ] || [ -z "${PROXY_PROTOCOL:-}" ]; then
    fail "缺少代理运行参数，无法生成公网直连配置。"
  fi

  DIRECT_PUBLIC_HOST_EFFECTIVE="$(detect_public_host 2>/dev/null || true)"
  if [ -z "$DIRECT_PUBLIC_HOST_EFFECTIVE" ]; then
    warn "未能自动探测公网 IP，跳过纯 sing-box 公网直连配置。你可手动设置 DIRECT_PUBLIC_HOST 后重试。"
    return 0
  fi

  DIRECT_PUBLIC_STATE="on"
  SB_LISTEN_ADDR="${DIRECT_PUBLIC_LISTEN_ADDR:-0.0.0.0}"
  warn "启用公网直连兜底：sing-box 将监听 ${SB_LISTEN_ADDR}:${PROXY_PORT}"
  restart_singbox_after_config_change
  DIRECT_PUBLIC_LINK="$(public_direct_link)"
  generate_direct_public_client_files
  if [ "${FB_ENABLED_STATE:-}" = "on" ] || [ "${ENABLE_TEMP_FILEBROWSER}" = "on" ]; then
    setup_temp_filebrowser || true
  fi
  generate_info_file
  save_state
  ok "已生成公网直连临时节点。若服务器没有公网入站或端口被拦，客户端仍可能连不上。"
}

probe_public_ip_then_generate_direct() {
  local old_state old_listen old_host old_link host result
  require_deployment || return 0
  old_state="${DIRECT_PUBLIC_STATE:-}"
  old_listen="${SB_LISTEN_ADDR:-127.0.0.1}"
  old_host="${DIRECT_PUBLIC_HOST_EFFECTIVE:-}"
  old_link="${DIRECT_PUBLIC_LINK:-}"

  host="$(detect_public_host 2>/dev/null || true)"
  if [ -z "$host" ]; then
    warn "未能自动探测公网 IP。你可以在配置区填写 DIRECT_PUBLIC_HOST，或选择“跳过检测直接生成公网配置”。"
    return 0
  fi
  DIRECT_PUBLIC_HOST_EFFECTIVE="$host"
  SB_LISTEN_ADDR="${DIRECT_PUBLIC_LISTEN_ADDR:-0.0.0.0}"
  info "为外部端口探测临时打开 sing-box 监听：${SB_LISTEN_ADDR}:${PROXY_PORT}"
  restart_singbox_after_config_change

  if uptimerobot_probe_public_port "$DIRECT_PUBLIC_HOST_EFFECTIVE" "$PROXY_PORT"; then
    DIRECT_PUBLIC_STATE="on"
    DIRECT_PUBLIC_LINK="$(public_direct_link)"
    generate_direct_public_client_files
    if [ "${FB_ENABLED_STATE:-}" = "on" ] || [ "${ENABLE_TEMP_FILEBROWSER}" = "on" ]; then
      setup_temp_filebrowser || true
    fi
    generate_info_file
    save_state
    show_links_brief
    ok "公网探测通过，公网直连配置已生成。"
    return 0
  fi
  warn "公网探测没有通过；但你仍可强行生成公网配置导入客户端试一试。"
  read -r -p "是否仍然生成公网直连配置？回车=生成 / n=恢复探测前状态：" still_generate || true
  if [[ ! "${still_generate:-}" =~ ^[Nn]$ ]]; then
    DIRECT_PUBLIC_STATE="on"
    DIRECT_PUBLIC_LINK="$(public_direct_link)"
    generate_direct_public_client_files
    if [ "${FB_ENABLED_STATE:-}" = "on" ] || [ "${ENABLE_TEMP_FILEBROWSER}" = "on" ]; then
      setup_temp_filebrowser || true
    fi
    generate_info_file
    save_state
    show_links_brief
    warn "已按你的选择生成公网直连配置；若仍不可用，再切 ngrok。"
    return 0
  fi

  warn "已恢复 sing-box 到探测前监听状态。若之后仍想试，可在兜底菜单选择“跳过检测直接生成公网配置”。"
  DIRECT_PUBLIC_STATE="$old_state"
  DIRECT_PUBLIC_HOST_EFFECTIVE="$old_host"
  DIRECT_PUBLIC_LINK="$old_link"
  SB_LISTEN_ADDR="$old_listen"
  restart_singbox_after_config_change
  generate_info_file
  save_state
  return 0
}


setup_cloudflared_service() {
  local exec_line proto_arg=""

  CF_SERVICE_NAME=$(pick_service_name "cloudflared" "CFPROXY-MANAGED")
  if [ "$CF_SERVICE_NAME" != "cloudflared" ]; then
    warn "检测到现有 cloudflared.service 可能已经服务于别的项目，已自动改用独立服务：${CF_SERVICE_NAME}.service"
  fi

  case "$CF_EDGE_PROTOCOL" in
    auto|"") proto_arg="" ;;
    quic|http2) proto_arg=" --protocol $CF_EDGE_PROTOCOL" ;;
    *) warn "未知 CF_EDGE_PROTOCOL=$CF_EDGE_PROTOCOL，已按 auto 处理。" ;;
  esac

  if [ "$CF_RUN_MODE" = "config" ]; then
    exec_line="$CF_BIN tunnel --no-autoupdate${proto_arg} --config $CF_CONFIG run"
  else
    exec_line="$CF_BIN tunnel --no-autoupdate${proto_arg} --edge-ip-version auto run --token $CF_TUNNEL_TOKEN"
  fi

  warn_if_cf_edge_unreachable
  write_service_definition "$CF_SERVICE_NAME" "CFProxy cloudflared tunnel service" "$exec_line"
  [ "$SERVICE_BACKEND" = "process" ] && : > "$(service_log_file "$CF_SERVICE_NAME")"
  start_service "$CF_SERVICE_NAME"
  handle_cloudflared_online_result "$CF_SERVICE_NAME"
  if [ "$SERVICE_BACKEND" = "systemd" ]; then
    ok "${CF_SERVICE_NAME}.service 已启动并设置开机自启。"
  else
    ok "${CF_SERVICE_NAME} 已启动（进程守护模式，开机拉起：${BOOT_HOOK_BACKEND}）。"
  fi
}

filebrowser_enabled() {
  [ "${ENABLE_TEMP_FILEBROWSER}" = "on" ] || [ "${FB_ENABLED_STATE:-}" = "on" ]
}

effective_fb_root() {
  local desired candidates dir home_dir
  desired="${FB_ROOT_DIR:-$CONFIG_DIR}"
  home_dir="${HOME:-}"
  candidates="$desired $CONFIG_DIR"
  [ -n "$home_dir" ] && candidates="$candidates ${home_dir}/proxy-configs $home_dir"
  candidates="$candidates ${FB_ROOT_FALLBACKS:-/tmp /}"

  for dir in $candidates; do
    [ -n "$dir" ] || continue
    if mkdir -p "$dir" 2>/dev/null && [ -d "$dir" ] && [ -w "$dir" ]; then
      printf '%s\n' "$dir"
      return 0
    fi
  done

  printf '%s\n' "/tmp"
}

effective_fb_bind_addr() {
  if [ "${DIRECT_PUBLIC_STATE:-}" = "on" ] && [ "${ENABLE_FB_PUBLIC_ON_DIRECT}" = "on" ]; then
    printf '%s\n' "0.0.0.0"
  else
    printf '%s\n' "127.0.0.1"
  fi
}

ensure_filebrowser_password() {
  [[ "${FB_USER}" =~ ^[^[:space:]]+$ ]] || fail "FB_USER 不能为空且不能包含空白字符。"
  if [ -n "${FB_PASSWORD_EFFECTIVE:-}" ]; then
    return 0
  fi
  if [ -n "${FB_PASS:-}" ]; then
    FB_PASSWORD_EFFECTIVE="$FB_PASS"
  else
    FB_PASSWORD_EFFECTIVE="$(openssl rand -hex 8)"
  fi
  if [ "${#FB_PASSWORD_EFFECTIVE}" -lt 12 ]; then
    warn "FB_PASS 少于 12 位，FileBrowser 新版会拒绝；已自动生成随机密码。"
    FB_PASSWORD_EFFECTIVE="$(openssl rand -hex 8)"
  fi
}

install_filebrowser() {
  if [ -x "$FB_BIN" ]; then
    ok "FileBrowser 已存在：$($FB_BIN version 2>/dev/null | head -n1 || true)"
    return
  fi
  info "正在安装 FileBrowser"
  curl -fsSL https://raw.githubusercontent.com/filebrowser/get/master/get.sh | bash
  [ -x "$FB_BIN" ] || fail "FileBrowser 安装失败。"
  ok "FileBrowser 安装完成。"
}

filebrowser_ensure_user() {
  local output
  output="$(timeout 15 "$FB_BIN" users add "$FB_USER" "$FB_PASSWORD_EFFECTIVE" --perm.admin -d "$FB_DB" 2>&1)" && return 0
  if printf '%s\n' "$output" | grep -Eiq 'already exists|exists|UNIQUE|duplicate'; then
    timeout 15 "$FB_BIN" users update "$FB_USER" --password "$FB_PASSWORD_EFFECTIVE" --perm.admin -d "$FB_DB" >/dev/null 2>&1 && return 0
    warn "FileBrowser 用户 ${FB_USER} 已存在，但自动更新密码/权限失败；继续复用现有用户。"
    return 0
  fi
  warn "FileBrowser 用户创建失败：${output}"
  return 1
}

setup_filebrowser_db() {
  local root_dir bind_addr
  root_dir="$(effective_fb_root)"
  bind_addr="$(effective_fb_bind_addr)"
  mkdir -p "$root_dir" "$FB_WORK_DIR"
  chmod 700 "$FB_WORK_DIR" || true
  ensure_filebrowser_password

  if [ -n "${FB_SERVICE_NAME:-}" ] && service_is_active "$FB_SERVICE_NAME"; then
    stop_service_runtime "$FB_SERVICE_NAME" || true
  fi

  if [ ! -f "$FB_DB" ]; then
    timeout 15 "$FB_BIN" config init -d "$FB_DB" || { warn "FileBrowser DB 初始化超时/失败，重建数据库。"; rm -f "$FB_DB"; timeout 15 "$FB_BIN" config init -d "$FB_DB" || return 1; }
  fi
  timeout 15 "$FB_BIN" config set -a "$bind_addr" -p "$FB_LOCAL_PORT" -r "$root_dir" -d "$FB_DB" || {
    warn "FileBrowser 配置数据库超时/失败，尝试重建数据库。"
    rm -f "$FB_DB"
    timeout 15 "$FB_BIN" config init -d "$FB_DB" || return 1
    timeout 15 "$FB_BIN" config set -a "$bind_addr" -p "$FB_LOCAL_PORT" -r "$root_dir" -d "$FB_DB" || return 1
  }
  filebrowser_ensure_user || true
  if [ "$bind_addr" = "0.0.0.0" ] && [ -n "${DIRECT_PUBLIC_HOST_EFFECTIVE:-}" ]; then
    FB_PUBLIC_URL="http://${DIRECT_PUBLIC_HOST_EFFECTIVE}:${FB_LOCAL_PORT}"
  fi
  chmod 600 "$FB_DB" || true
}

capture_filebrowser_quick_url() {
  local deadline url="" log_text
  [ -n "${FB_CF_SERVICE_NAME:-}" ] || return 1
  deadline=$(( $(date +%s) + FB_QUICK_TUNNEL_TIMEOUT ))
  while [ "$(date +%s)" -lt "$deadline" ]; do
    log_text="$(service_recent_log "$FB_CF_SERVICE_NAME" 260)"
    url=$(printf '%s\n' "$log_text" | grep -Eo 'https://[-a-z0-9]+\.trycloudflare\.com' | tail -n1 || true)
    if [ -n "$url" ]; then
      FB_QUICK_URL="$url"
      ok "FileBrowser trycloudflare 链接已抓取（CF/Quick Tunnel，7844 不通时可能打不开）：${FB_QUICK_URL}"
      return 0
    fi
    sleep 1
  done
  warn "暂未抓取到 FileBrowser 临时链接。若日志出现 7844 超时，说明当前服务器无法连接 Cloudflare Tunnel Edge。"
  service_recent_log "$FB_CF_SERVICE_NAME" 80
  return 1
}

setup_temp_filebrowser() {
  local fb_exec cf_exec
  if [ ! -f "$STATE_FILE" ] && [ -z "${CURRENT_ALIAS:-}" ]; then
    ensure_local_proxy_for_fallback || return 0
  fi
  FB_ENABLED_STATE="on"
  if [ -z "${FB_LOCAL_PORT:-}" ]; then
    if [ "${FB_PORT:-0}" -gt 0 ] && ! port_in_use "$FB_PORT"; then
      FB_LOCAL_PORT="$FB_PORT"
    else
      FB_LOCAL_PORT="$(pick_random_port)"
    fi
  fi

  install_filebrowser
  setup_filebrowser_db || { warn "FileBrowser 数据库配置失败，跳过本次 FileBrowser 启动。"; return 0; }
  FB_SERVICE_NAME=$(pick_service_name "cfproxy-filebrowser" "CFPROXY-MANAGED")
  fb_exec="$FB_BIN -d $FB_DB"
  write_service_definition "$FB_SERVICE_NAME" "CFProxy temporary FileBrowser" "$fb_exec"
  start_service "$FB_SERVICE_NAME"

  if [ "${DIRECT_PUBLIC_STATE:-}" = "on" ] && [ "${ENABLE_FB_PUBLIC_ON_DIRECT}" = "on" ]; then
    ok "FileBrowser 公网直连链接：${FB_PUBLIC_URL:-未生成}"
    if ! cf_quick_tunnel_allowed; then
      warn "CF Tunnel 当前未确认在线，跳过 FileBrowser trycloudflare 链接抓取；请先测试公网直连链接。"
      save_state
      generate_info_file
      return 0
    fi
  fi

  if [ "${SETUP_FB_SKIP_QUICK:-0}" = "1" ]; then
    save_state
    generate_info_file
    return 0
  fi

  install_cloudflared
  FB_CF_SERVICE_NAME=$(pick_service_name "cfproxy-filebrowser-cloudflared" "CFPROXY-MANAGED")
  cf_exec="$CF_BIN tunnel --no-autoupdate --url http://127.0.0.1:${FB_LOCAL_PORT}"
  write_service_definition "$FB_CF_SERVICE_NAME" "CFProxy temporary FileBrowser quick tunnel" "$cf_exec"
  [ "$SERVICE_BACKEND" = "process" ] && : > "$(service_log_file "$FB_CF_SERVICE_NAME")"
  restart_service "$FB_CF_SERVICE_NAME"
  capture_filebrowser_quick_url || true
  save_state
  generate_info_file
}

show_filebrowser_info() {
  echo ""
  echo -e "${BLUE}========== FileBrowser 临时下载页 ==========${RESET}"
  echo "状态     : $(if [ "${FB_ENABLED_STATE:-}" = "on" ]; then echo 已启用; else echo 未启用; fi)"
  echo "根目录   : $(effective_fb_root)"
  echo "本地端口 : ${FB_LOCAL_PORT:-未分配}"
  echo "用户名   : ${FB_USER}"
  echo "密码     : ${FB_PASSWORD_EFFECTIVE:-未生成；启用后生成}"
  echo "公网链接 : ${FB_PUBLIC_URL:-未生成}"
  echo "CF/trycloudflare : ${FB_QUICK_URL:-尚未抓取}（依赖 CF Tunnel；7844 被封时常不可用）"
  echo "ngrok 入口       : ${NGROK_FB_URL:-未生成}（单入口复用时与代理入口相同；打开根路径进入 FB）"
  echo "说明            : ngrok 模式下优先使用 ngrok 入口；trycloudflare 仅在 Cloudflare Quick Tunnel 能连通时可用。"
  echo -e "${BLUE}============================================${RESET}"
}

enable_or_refresh_filebrowser_menu() {
  setup_temp_filebrowser
  if [ "${NGROK_ENABLED_STATE:-}" = "on" ] && [ "${NGROK_ENABLE_FILEBROWSER}" = "on" ]; then
    refresh_ngrok_filebrowser_tunnel || true
  fi
  show_filebrowser_info
}

install_ngrok() {
  local arch url tmpdir
  if [ -x "$NGROK_BIN" ]; then
    ok "ngrok 已存在：$($NGROK_BIN version 2>/dev/null | head -n1 || true)"
    return
  fi
  case "$(uname -m)" in
    x86_64|amd64) arch="amd64" ;;
    aarch64|arm64) arch="arm64" ;;
    armv7l) arch="arm" ;;
    *) fail "暂不支持当前架构安装 ngrok：$(uname -m)" ;;
  esac
  url="https://bin.equinox.io/c/bNyj1mQVY4c/ngrok-v3-stable-linux-${arch}.tgz"
  tmpdir=$(mktemp -d)
  info "正在安装 ngrok (${arch})"
  curl -fL --progress-bar "$url" -o "${tmpdir}/ngrok.tgz"
  tar -xzf "${tmpdir}/ngrok.tgz" -C "$tmpdir"
  install -m 755 "${tmpdir}/ngrok" "$NGROK_BIN"
  rm -rf "$tmpdir"
  ok "ngrok 安装完成。"
}

ngrok_tokens() {
  printf '%s\n' "${NGROK_AUTHTOKEN_POOL:-}" \
    | sed 's/\r$//' \
    | awk 'NF && $1 !~ /^#/ {print $1}'
}

ngrok_token_fingerprint() {
  local token="$1"
  if [ "${#token}" -le 12 ]; then
    printf '%s\n' "[set]"
  else
    printf '%s...%s\n' "${token:0:6}" "${token: -4}"
  fi
}

ngrok_region_arg() {
  if [ -n "${NGROK_REGION:-}" ]; then
    printf -- '--region %q' "$NGROK_REGION"
  fi
}

ngrok_http_url_regex() {
  printf '%s\n' 'https://[-a-z0-9.]+(\.ngrok-free\.(app|dev)|\.ngrok\.app|\.ngrok\.io)'
}

ngrok_tcp_url_regex() {
  printf '%s\n' 'tcp://[^[:space:]]+'
}

ngrok_failure_hint_from_log() {
  local logfile="$1"
  [ -f "$logfile" ] || return 0
  if grep -q 'ERR_NGROK_334' "$logfile" 2>/dev/null; then
    warn "ngrok 返回 ERR_NGROK_334：该 token 的默认 endpoint 已经在线。不是‘3 个名额都满’；需要在 ngrok Dashboard/API 停掉旧 endpoint/agent，或换一个真正空闲的账号。" >&2
    warn "不建议直接开 pooling：它会把同一个 URL 负载均衡到多台服务器，代理配置会串流量。" >&2
  elif grep -q 'ERR_NGROK_313' "$logfile" 2>/dev/null; then
    warn "ngrok 返回 ERR_NGROK_313：免费计划不能临时指定自定义子域名；不能靠脚本随便换一个 ngrok-free.dev 域名避让。" >&2
  elif grep -q 'ERR_NGROK_206' "$logfile" 2>/dev/null; then
    warn "ngrok 返回 ERR_NGROK_206：把 authtoken 当 API key 使用了。远程列出/清理 endpoint 需要单独的 ngrok API key。" >&2
  fi
}

wait_ngrok_url_from_log() {
  local logfile="$1" regex="$2" deadline url
  deadline=$(( $(date +%s) + NGROK_TRY_TIMEOUT ))
  while [ "$(date +%s)" -lt "$deadline" ]; do
    url=$(grep -Ei 'started tunnel|url=' "$logfile" 2>/dev/null | grep -Eo "$regex" | tail -n1 || true)
    if [ -n "$url" ] && [[ "$url" != *ngrok.com/docs/errors/* ]]; then
      printf '%s\n' "$url"
      return 0
    fi
    if grep -Eiq 'ERR_NGROK|ngrok.com/docs/errors|authentication failed|authtoken|limit|too many|exceed|session closing|failed to start tunnel' "$logfile" 2>/dev/null; then
      break
    fi
    sleep 1
  done
  return 1
}

start_ngrok_tunnel_with_pool() {
  local service_name="$1" tunnel_kind="$2" local_target="$3" regex="$4"
  local token qtoken qlog region_arg exec_line logfile url
  install_ngrok >&2
  mkdir -p "$RUN_DIR"
  region_arg="$(ngrok_region_arg)"

  # 每次重新申请 ngrok 前，先清掉本机旧的同名托管进程。
  # 这只能释放本机残留的 agent/session；如果是其它服务器或 dashboard 上的旧会话占额，
  # 仍需要等 ngrok 侧超时、换 token，或手动/API 清理。
  stop_service_runtime "$service_name" >/dev/null 2>&1 || true

  if [ -z "$(ngrok_tokens)" ]; then
    warn "NGROK_AUTHTOKEN_POOL 为空，无法启用 ngrok 兜底。"
    return 1
  fi

  while read -r token; do
    [ -n "$token" ] || continue
    logfile="$(service_log_file "$service_name")"
    : > "$logfile"
    chmod 600 "$logfile" || true
    qtoken=$(printf '%q' "$token")
    qlog=$(printf '%q' "$logfile")
    case "$tunnel_kind" in
      tcp)
        exec_line="$NGROK_BIN tcp --authtoken $qtoken --log=$qlog ${region_arg} $local_target"
        ;;
      http)
        exec_line="$NGROK_BIN http --authtoken $qtoken --log=$qlog ${region_arg} $local_target"
        ;;
      *)
        fail "未知 ngrok tunnel 类型：$tunnel_kind"
        ;;
    esac

    info "尝试 ngrok token：$(ngrok_token_fingerprint "$token")（${tunnel_kind} -> ${local_target}）" >&2
    write_service_definition "$service_name" "CFProxy ngrok ${tunnel_kind} fallback" "$exec_line"
    restart_service "$service_name" || true
    if url="$(wait_ngrok_url_from_log "$logfile" "$regex")"; then
      NGROK_AUTHTOKEN_FINGERPRINT="$(ngrok_token_fingerprint "$token")"
      printf '%s\n' "$url"
      return 0
    fi

    warn "该 ngrok token 未拿到可用 URL，尝试下一个。最近日志：" >&2
    ngrok_failure_hint_from_log "$logfile"
    tail -n 40 "$logfile" 2>/dev/null >&2 || true
    stop_disable_remove_service "$service_name" || true
  done < <(ngrok_tokens)

  warn "ngrok token 池全部尝试失败。"
  return 1
}

schedule_ngrok_fb_autostop() {
  local mins="${NGROK_FB_AUTO_STOP_MINUTES:-0}" name="$NGROK_FB_SERVICE_NAME" pidfile
  [ "$mins" -gt 0 ] 2>/dev/null || return 0
  [ -n "$name" ] || return 0
  pidfile="$(service_pid_file "$name")"
  if [ "$SERVICE_BACKEND" = "systemd" ]; then
    nohup bash -c 'set +u; sleep "$1"; systemctl stop "$2" >/dev/null 2>&1 || true; [ -f "$3" ] && sed -i "s|^NGROK_FB_URL=.*|NGROK_FB_URL='\'''\''|" "$3" 2>/dev/null || true' _ "$((mins * 60))" "$name" "$STATE_FILE" >/dev/null 2>&1 &
  else
    nohup bash -c 'set +u; sleep "$1"; pidfile="$2"; state="$3"; name="$4"; launcher="$5"; marker="cfproxy-${name}"; if [ -s "$pidfile" ]; then p=$(cat "$pidfile" 2>/dev/null || true); [ -n "$p" ] && kill "$p" 2>/dev/null || true; sleep 1; [ -n "$p" ] && kill -9 "$p" 2>/dev/null || true; rm -f "$pidfile"; fi; ps -eo pid=,args= 2>/dev/null | while read -r c rest; do case "$rest" in *"$marker"*|*"$launcher"*) [ "$c" != "$$" ] && kill "$c" 2>/dev/null || true ;; esac; done; [ -f "$state" ] && sed -i "s|^NGROK_FB_URL=.*|NGROK_FB_URL='\'''\''|" "$state" 2>/dev/null || true' _ "$((mins * 60))" "$pidfile" "$STATE_FILE" "$name" "$(service_launcher_file "$name")" >/dev/null 2>&1 &
  fi
  ok "FileBrowser 的 ngrok 隧道已设置 ${mins} 分钟后自动停止；可在面板重新生成。"
}

install_caddy() {
  local arch tag ver url tmpdir
  if [ -x "$CADDY_BIN" ]; then
    ok "Caddy 已存在：$($CADDY_BIN version 2>/dev/null | head -n1 || true)"
    return 0
  fi
  case "$(uname -m)" in
    x86_64|amd64) arch="amd64" ;;
    aarch64|arm64) arch="arm64" ;;
    armv7l) arch="armv7" ;;
    *) warn "暂不支持当前架构安装 Caddy：$(uname -m)"; return 1 ;;
  esac
  tag="$(get_latest_release_tag "caddyserver/caddy" 2>/dev/null || true)"
  [ -n "$tag" ] || { warn "获取 Caddy 最新版本失败，ngrok 单入口复用将降级。"; return 1; }
  ver="${tag#v}"
  url="https://github.com/caddyserver/caddy/releases/download/${tag}/caddy_${ver}_linux_${arch}.tar.gz"
  tmpdir=$(mktemp -d)
  info "正在安装 Caddy ${tag} (${arch})，用于 ngrok 单入口复用代理+FileBrowser"
  if ! curl -fL --progress-bar "$url" -o "${tmpdir}/caddy.tgz"; then
    warn "Caddy 下载失败，ngrok 单入口复用将降级。"
    rm -rf "$tmpdir"
    return 1
  fi
  if ! tar -xzf "${tmpdir}/caddy.tgz" -C "$tmpdir" caddy; then
    warn "Caddy 解压失败，ngrok 单入口复用将降级。"
    rm -rf "$tmpdir"
    return 1
  fi
  install -m 755 "${tmpdir}/caddy" "$CADDY_BIN" || { warn "Caddy 安装失败，ngrok 单入口复用将降级。"; rm -rf "$tmpdir"; return 1; }
  rm -rf "$tmpdir"
  ok "Caddy 安装完成。"
}

ngrok_mux_active() {
  [ "${NGROK_MUX_STATE:-}" = "on" ] && [ -n "${NGROK_MUX_SERVICE_NAME:-}" ] && service_is_active "$NGROK_MUX_SERVICE_NAME"
}

setup_ngrok_mux_service() {
  local caddy_exec
  [ "${NGROK_MUX_FILEBROWSER:-on}" = "on" ] || return 1
  [ "${NGROK_ENABLE_FILEBROWSER:-on}" = "on" ] || return 1
  [ -n "${PROXY_PORT:-}" ] || return 1

  if [ -z "${FB_LOCAL_PORT:-}" ] || [ -z "${FB_SERVICE_NAME:-}" ] || ! service_is_active "$FB_SERVICE_NAME"; then
    SETUP_FB_SKIP_QUICK=1 setup_temp_filebrowser || true
  fi
  if [ -z "${FB_LOCAL_PORT:-}" ] || [ -z "${FB_SERVICE_NAME:-}" ] || ! service_is_active "$FB_SERVICE_NAME"; then
    warn "FileBrowser 本地服务不可用，ngrok 单入口复用降级为仅代理。"
    return 1
  fi

  if [ -z "${NGROK_MUX_PORT:-}" ]; then
    NGROK_MUX_PORT="$(pick_random_port)"
  elif port_in_use "$NGROK_MUX_PORT" && { [ -z "${NGROK_MUX_SERVICE_NAME:-}" ] || ! service_is_active "$NGROK_MUX_SERVICE_NAME"; }; then
    warn "ngrok 单入口复用端口 ${NGROK_MUX_PORT} 已被占用，自动换随机端口。"
    NGROK_MUX_PORT="$(pick_random_port)"
  fi

  install_caddy || return 1
  mkdir -p "$CADDY_WORK_DIR"
  cat > "$NGROK_MUX_CADDYFILE" <<EOF_CADDY
{
  auto_https off
  admin off
}

:${NGROK_MUX_PORT} {
  @proxy path ${WS_PATH} ${WS_PATH}/*
  reverse_proxy @proxy 127.0.0.1:${PROXY_PORT}
  reverse_proxy 127.0.0.1:${FB_LOCAL_PORT}
}
EOF_CADDY
  chmod 600 "$NGROK_MUX_CADDYFILE" || true

  NGROK_MUX_SERVICE_NAME=$(pick_service_name "cfproxy-ngrok-mux" "CFPROXY-MANAGED")
  caddy_exec="$CADDY_BIN run --config $NGROK_MUX_CADDYFILE --adapter caddyfile"
  write_service_definition "$NGROK_MUX_SERVICE_NAME" "CFProxy ngrok single endpoint mux" "$caddy_exec"
  restart_service "$NGROK_MUX_SERVICE_NAME"
  NGROK_MUX_STATE="on"
  ok "ngrok 单入口复用已启动：/:FileBrowser，${WS_PATH}:代理（本地端口 ${NGROK_MUX_PORT}）。"
  return 0
}

refresh_ngrok_filebrowser_tunnel() {
  local url
  [ "${NGROK_ENABLE_FILEBROWSER}" = "on" ] || return 1
  if [ "$(ngrok_proxy_kind_current 2>/dev/null || true)" = "http_ws_mux" ] && [ -n "${NGROK_PROXY_URL:-}" ]; then
    NGROK_FB_URL="$NGROK_PROXY_URL"
    ok "ngrok FileBrowser 已复用代理入口：${NGROK_FB_URL}"
    save_state
    generate_info_file
    return 0
  fi
  if [ -z "${FB_LOCAL_PORT:-}" ] || [ -z "${FB_SERVICE_NAME:-}" ] || ! service_is_active "$FB_SERVICE_NAME"; then
    SETUP_FB_SKIP_QUICK=1 setup_temp_filebrowser || true
  fi
  if [ -z "${FB_LOCAL_PORT:-}" ]; then
    warn "FileBrowser 本地端口未分配，跳过 ngrok FileBrowser。"
    return 1
  fi

  NGROK_FB_SERVICE_NAME=$(pick_service_name "cfproxy-ngrok-filebrowser" "CFPROXY-MANAGED")
  NGROK_FB_URL=""
  if url="$(start_ngrok_tunnel_with_pool "$NGROK_FB_SERVICE_NAME" "http" "http://127.0.0.1:${FB_LOCAL_PORT}" "$(ngrok_http_url_regex)")"; then
    NGROK_FB_URL="$url"
    ok "ngrok FileBrowser 临时入口：${NGROK_FB_URL}"
    schedule_ngrok_fb_autostop
    save_state
    generate_info_file
    return 0
  fi

  warn "ngrok FileBrowser 入口启用失败。ngrok FB 才是 ngrok 情况下的真实下载页；失败时可稍后重试、换 token，或看是否有公网/trycloudflare 入口。"
  save_state
  generate_info_file
  return 1
}

enable_ngrok_fallback() {
  local url mode modes m http_target mux_used
  ensure_local_proxy_for_fallback || return 0
  NGROK_ENABLED_STATE="on"

  # 优先使用 ngrok HTTP -> WebSocket：客户端走 443/WSS，通常比随机 TCP 端口更容易被 Clash / 运营商放行。
  # 若启用单入口复用，HTTP endpoint 同时承载代理 WS_PATH 与 FileBrowser 根路径。
  # 若 HTTP endpoint 满额或失败，auto 模式再退回传统 TCP。
  mode="${NGROK_PROXY_MODE:-auto}"
  case "$mode" in
    http_ws) modes="http_ws" ;;
    tcp) modes="tcp" ;;
    auto|"") modes="http_ws tcp" ;;
    *) warn "未知 NGROK_PROXY_MODE=$mode，已按 auto 处理。"; modes="http_ws tcp" ;;
  esac

  NGROK_PROXY_SERVICE_NAME=$(pick_service_name "cfproxy-ngrok-proxy" "CFPROXY-MANAGED")
  NGROK_PROXY_URL=""
  NGROK_PROXY_KIND=""
  for m in $modes; do
    case "$m" in
      http_ws)
        http_target="http://127.0.0.1:${PROXY_PORT}"
        mux_used=0
        if [ "${NGROK_MUX_FILEBROWSER:-on}" = "on" ] && [ "${NGROK_ENABLE_FILEBROWSER:-on}" = "on" ]; then
          if setup_ngrok_mux_service; then
            http_target="http://127.0.0.1:${NGROK_MUX_PORT}"
            mux_used=1
          fi
        fi
        if url="$(start_ngrok_tunnel_with_pool "$NGROK_PROXY_SERVICE_NAME" "http" "$http_target" "$(ngrok_http_url_regex)")"; then
          NGROK_PROXY_URL="$url"
          if [ "$mux_used" -eq 1 ]; then
            NGROK_PROXY_KIND="http_ws_mux"
            NGROK_FB_URL="$url"
            NGROK_FB_SERVICE_NAME=""
            ok "ngrok 单入口临时入口（代理+FileBrowser 共用）：${NGROK_PROXY_URL}"
          else
            NGROK_PROXY_KIND="http_ws"
            ok "ngrok 代理临时入口（HTTP/WSS 443）：${NGROK_PROXY_URL}"
          fi
          break
        fi
        ;;
      tcp)
        if url="$(start_ngrok_tunnel_with_pool "$NGROK_PROXY_SERVICE_NAME" "tcp" "127.0.0.1:${PROXY_PORT}" "$(ngrok_tcp_url_regex)")"; then
          NGROK_PROXY_URL="$url"
          NGROK_PROXY_KIND="tcp"
          ok "ngrok 代理临时入口（TCP）：${NGROK_PROXY_URL}"
          break
        fi
        ;;
    esac
  done

  if [ -n "${NGROK_PROXY_URL:-}" ]; then
    generate_ngrok_client_files
  else
    warn "ngrok 代理入口启用失败。"
  fi

  if [ "${NGROK_ENABLE_FILEBROWSER}" = "on" ]; then
    if [ "$(ngrok_proxy_kind_current 2>/dev/null || true)" = "http_ws_mux" ] && [ -n "${NGROK_PROXY_URL:-}" ]; then
      NGROK_FB_URL="$NGROK_PROXY_URL"
      ok "FileBrowser 已复用 ngrok 代理入口：打开根路径进入 FB；客户端代理仍走 ${WS_PATH}。"
    else
      # 非单入口复用时保留旧行为：先刷新 trycloudflare，再额外申请 ngrok FB。
      setup_temp_filebrowser || true
      refresh_ngrok_filebrowser_tunnel || true
    fi
  fi

  save_state
  generate_info_file
  show_links_brief
}

build_vmess_link() {
  local ps="$1" add="$2" port="$3"
  local payload
  payload=$(cat <<EOF_JSON
{"v":"2","ps":"${ps}","add":"${add}","port":"${port}","id":"${PROXY_UUID}","aid":"0","scy":"auto","net":"ws","type":"none","host":"${TUNNEL_DOMAIN}","path":"${WS_PATH}","tls":"tls","sni":"${TUNNEL_DOMAIN}","fp":"chrome"}
EOF_JSON
)
  printf 'vmess://%s' "$(printf '%s' "$payload" | b64)"
}

build_vless_link() {
  local name="$1" add="$2" port="$3" path_enc
  path_enc=$(urlencode_path "$WS_PATH")
  printf 'vless://%s@%s:%s?encryption=none&security=tls&sni=%s&type=ws&host=%s&path=%s&fp=chrome#%s' \
    "$PROXY_UUID" "$add" "$port" "$TUNNEL_DOMAIN" "$TUNNEL_DOMAIN" "$path_enc" "$name"
}

recommended_link() {
  local name="${CURRENT_ALIAS}-${PROXY_PROTOCOL}-cf"
  if [ "$PROXY_PROTOCOL" = "vmess" ]; then
    build_vmess_link "$name" "$CLIENT_SERVER" "$CLIENT_PORT"
  else
    build_vless_link "$name" "$CLIENT_SERVER" "$CLIENT_PORT"
  fi
}

direct_link() {
  local name="${CURRENT_ALIAS}-${PROXY_PROTOCOL}-direct"
  if [ "$PROXY_PROTOCOL" = "vmess" ]; then
    build_vmess_link "$name" "$TUNNEL_DOMAIN" "$DIRECT_PORT"
  else
    build_vless_link "$name" "$TUNNEL_DOMAIN" "$DIRECT_PORT"
  fi
}

build_plain_ws_vmess_link() {
  local ps="$1" add="$2" port="$3" payload
  payload=$(cat <<EOF_JSON
{"v":"2","ps":"${ps}","add":"${add}","port":"${port}","id":"${PROXY_UUID}","aid":"0","scy":"auto","net":"ws","type":"none","host":"${add}","path":"${WS_PATH}","tls":"","sni":"","fp":"chrome"}
EOF_JSON
)
  printf 'vmess://%s' "$(printf '%s' "$payload" | b64)"
}

build_plain_ws_vless_link() {
  local name="$1" add="$2" port="$3" path_enc
  path_enc=$(urlencode_path "$WS_PATH")
  printf 'vless://%s@%s:%s?encryption=none&security=none&type=ws&host=%s&path=%s#%s' \
    "$PROXY_UUID" "$add" "$port" "$add" "$path_enc" "$name"
}

build_plain_ws_link() {
  local name="$1" add="$2" port="$3"
  if [ "$PROXY_PROTOCOL" = "vmess" ]; then
    build_plain_ws_vmess_link "$name" "$add" "$port"
  else
    build_plain_ws_vless_link "$name" "$add" "$port"
  fi
}

build_tls_ws_vmess_link() {
  local ps="$1" add="$2" port="$3" host="$4" payload
  payload=$(cat <<EOF_JSON
{"v":"2","ps":"${ps}","add":"${add}","port":"${port}","id":"${PROXY_UUID}","aid":"0","scy":"auto","net":"ws","type":"none","host":"${host}","path":"${WS_PATH}","tls":"tls","sni":"${host}","fp":"chrome"}
EOF_JSON
)
  printf 'vmess://%s' "$(printf '%s' "$payload" | b64)"
}

build_tls_ws_vless_link() {
  local name="$1" add="$2" port="$3" host="$4" path_enc
  path_enc=$(urlencode_path "$WS_PATH")
  printf 'vless://%s@%s:%s?encryption=none&security=tls&sni=%s&type=ws&host=%s&path=%s&fp=chrome#%s' \
    "$PROXY_UUID" "$add" "$port" "$host" "$host" "$path_enc" "$name"
}

build_tls_ws_link() {
  local name="$1" add="$2" port="$3" host="${4:-$2}"
  if [ "$PROXY_PROTOCOL" = "vmess" ]; then
    build_tls_ws_vmess_link "$name" "$add" "$port" "$host"
  else
    build_tls_ws_vless_link "$name" "$add" "$port" "$host"
  fi
}

public_direct_link() {
  [ -n "${DIRECT_PUBLIC_HOST_EFFECTIVE:-}" ] || return 0
  build_plain_ws_link "${CURRENT_ALIAS}-${PROXY_PROTOCOL}-public-direct" "$DIRECT_PUBLIC_HOST_EFFECTIVE" "$PROXY_PORT"
}

ngrok_proxy_host_port() {
  local url="${NGROK_PROXY_URL}" host port
  if [[ "$url" == https://* ]]; then
    host="${url#https://}"
    host="${host%%/*}"
    port=443
  else
    url="${url#tcp://}"
    host="${url%:*}"
    port="${url##*:}"
  fi
  [ -n "$host" ] && [ -n "$port" ] || return 1
  printf '%s %s\n' "$host" "$port"
}

ngrok_proxy_kind_current() {
  if [ -z "${NGROK_PROXY_KIND:-}" ] && [ -z "${NGROK_PROXY_URL:-}" ]; then
    printf '%s\n' "未生成"
  elif [ -n "${NGROK_PROXY_KIND:-}" ]; then
    printf '%s\n' "$NGROK_PROXY_KIND"
  elif [[ "${NGROK_PROXY_URL:-}" == https://* ]]; then
    printf '%s\n' "http_ws"
  else
    printf '%s\n' "tcp"
  fi
}

wait_current_ngrok_proxy_url() {
  local logfile="$1" kind url
  kind="$(ngrok_proxy_kind_current)"
  if [ "$kind" = "http_ws" ] || [ "$kind" = "http_ws_mux" ]; then
    wait_ngrok_url_from_log "$logfile" "$(ngrok_http_url_regex)"
    return $?
  fi
  if [ "$kind" = "tcp" ] && [[ "${NGROK_PROXY_URL:-}" == tcp://* ]]; then
    wait_ngrok_url_from_log "$logfile" "$(ngrok_tcp_url_regex)"
    return $?
  fi
  if url="$(wait_ngrok_url_from_log "$logfile" "$(ngrok_http_url_regex)")"; then
    NGROK_PROXY_KIND="http_ws"
    printf '%s\n' "$url"
    return 0
  fi
  if url="$(wait_ngrok_url_from_log "$logfile" "$(ngrok_tcp_url_regex)")"; then
    NGROK_PROXY_KIND="tcp"
    printf '%s\n' "$url"
    return 0
  fi
  return 1
}

ngrok_proxy_link() {
  local hp host port kind
  [ -n "${NGROK_PROXY_URL:-}" ] || return 0
  hp="$(ngrok_proxy_host_port)" || return 0
  host="${hp% *}"
  port="${hp##* }"
  kind="$(ngrok_proxy_kind_current)"
  if [ "$kind" = "http_ws" ] || [ "$kind" = "http_ws_mux" ]; then
    build_tls_ws_link "${CURRENT_ALIAS}-${PROXY_PROTOCOL}-ngrok-${kind}" "$host" "$port" "$host"
  else
    build_plain_ws_link "${CURRENT_ALIAS}-${PROXY_PROTOCOL}-ngrok-tcp" "$host" "$port"
  fi
}

primary_fallback_link() {
  if [ "${NGROK_ENABLED_STATE:-}" = "on" ] && [ -n "${NGROK_PROXY_URL:-}" ]; then
    ngrok_proxy_link
    return 0
  fi
  if [ "${DIRECT_PUBLIC_STATE:-}" = "on" ] && [ -n "${DIRECT_PUBLIC_HOST_EFFECTIVE:-}" ]; then
    public_direct_link
    return 0
  fi
  return 0
}

direct_node_enabled() {
  [ "${EXPORT_DIRECT_NODE}" = "on" ]
}

generate_plain_ws_client_pair() {
  local host="$1" port="$2" name="$3" clash_file="$4" singbox_file="$5"
  if [ -z "$host" ] || [ -z "$port" ]; then
    return 0
  fi

  if [ "$PROXY_PROTOCOL" = "vmess" ]; then
    cat > "$clash_file" <<EOF_YAML
mixed-port: 7890
allow-lan: true
mode: rule
log-level: info

proxies:
  - name: "${name}"
    type: vmess
    server: ${host}
    port: ${port}
    uuid: ${PROXY_UUID}
    alterId: 0
    cipher: auto
    udp: true
    tls: false
    network: ws
    ws-opts:
      path: "${WS_PATH}"
      headers:
        Host: "${host}"

proxy-groups:
  - name: "🚀 节点选择"
    type: select
    proxies:
      - "${name}"
      - DIRECT

rules:
  - GEOIP,CN,DIRECT
  - MATCH,🚀 节点选择
EOF_YAML

    cat > "$singbox_file" <<EOF_JSON
{
  "log": { "level": "info", "timestamp": true },
  "outbounds": [
    {
      "type": "selector",
      "tag": "select",
      "default": "${name}",
      "outbounds": ["${name}", "direct"]
    },
    {
      "type": "vmess",
      "tag": "${name}",
      "server": "${host}",
      "server_port": ${port},
      "uuid": "${PROXY_UUID}",
      "security": "auto",
      "packet_encoding": "packetaddr",
      "transport": {
        "type": "ws",
        "path": "${WS_PATH}",
        "headers": { "Host": "${host}" }
      }
    },
    { "type": "direct", "tag": "direct" }
  ],
  "route": { "final": "select" }
}
EOF_JSON
  else
    cat > "$clash_file" <<EOF_YAML
mixed-port: 7890
allow-lan: true
mode: rule
log-level: info

proxies:
  - name: "${name}"
    type: vless
    server: ${host}
    port: ${port}
    uuid: ${PROXY_UUID}
    udp: true
    tls: false
    network: ws
    ws-opts:
      path: "${WS_PATH}"
      headers:
        Host: "${host}"

proxy-groups:
  - name: "🚀 节点选择"
    type: select
    proxies:
      - "${name}"
      - DIRECT

rules:
  - GEOIP,CN,DIRECT
  - MATCH,🚀 节点选择
EOF_YAML

    cat > "$singbox_file" <<EOF_JSON
{
  "log": { "level": "info", "timestamp": true },
  "outbounds": [
    {
      "type": "selector",
      "tag": "select",
      "default": "${name}",
      "outbounds": ["${name}", "direct"]
    },
    {
      "type": "vless",
      "tag": "${name}",
      "server": "${host}",
      "server_port": ${port},
      "uuid": "${PROXY_UUID}",
      "transport": {
        "type": "ws",
        "path": "${WS_PATH}",
        "headers": { "Host": "${host}" }
      }
    },
    { "type": "direct", "tag": "direct" }
  ],
  "route": { "final": "select" }
}
EOF_JSON
  fi
}

generate_tls_ws_client_pair() {
  local host="$1" port="$2" name="$3" clash_file="$4" singbox_file="$5"
  if [ -z "$host" ] || [ -z "$port" ]; then
    return 0
  fi

  if [ "$PROXY_PROTOCOL" = "vmess" ]; then
    cat > "$clash_file" <<EOF_YAML
mixed-port: 7890
allow-lan: true
mode: rule
log-level: info

proxies:
  - name: "${name}"
    type: vmess
    server: ${host}
    port: ${port}
    uuid: ${PROXY_UUID}
    alterId: 0
    cipher: auto
    udp: true
    tls: true
    servername: ${host}
    client-fingerprint: chrome
    network: ws
    ws-opts:
      path: "${WS_PATH}"
      headers:
        Host: "${host}"
        ngrok-skip-browser-warning: "true"

proxy-groups:
  - name: "🚀 节点选择"
    type: select
    proxies:
      - "${name}"
      - DIRECT

rules:
  - GEOIP,CN,DIRECT
  - MATCH,🚀 节点选择
EOF_YAML

    cat > "$singbox_file" <<EOF_JSON
{
  "log": { "level": "info", "timestamp": true },
  "outbounds": [
    {
      "type": "selector",
      "tag": "select",
      "default": "${name}",
      "outbounds": ["${name}", "direct"]
    },
    {
      "type": "vmess",
      "tag": "${name}",
      "server": "${host}",
      "server_port": ${port},
      "uuid": "${PROXY_UUID}",
      "security": "auto",
      "packet_encoding": "packetaddr",
      "tls": { "enabled": true, "server_name": "${host}", "utls": { "enabled": true, "fingerprint": "chrome" } },
      "transport": {
        "type": "ws",
        "path": "${WS_PATH}",
        "headers": { "Host": "${host}", "ngrok-skip-browser-warning": "true" }
      }
    },
    { "type": "direct", "tag": "direct" }
  ],
  "route": { "final": "select" }
}
EOF_JSON
  else
    cat > "$clash_file" <<EOF_YAML
mixed-port: 7890
allow-lan: true
mode: rule
log-level: info

proxies:
  - name: "${name}"
    type: vless
    server: ${host}
    port: ${port}
    uuid: ${PROXY_UUID}
    udp: true
    tls: true
    servername: ${host}
    client-fingerprint: chrome
    network: ws
    ws-opts:
      path: "${WS_PATH}"
      headers:
        Host: "${host}"
        ngrok-skip-browser-warning: "true"

proxy-groups:
  - name: "🚀 节点选择"
    type: select
    proxies:
      - "${name}"
      - DIRECT

rules:
  - GEOIP,CN,DIRECT
  - MATCH,🚀 节点选择
EOF_YAML

    cat > "$singbox_file" <<EOF_JSON
{
  "log": { "level": "info", "timestamp": true },
  "outbounds": [
    {
      "type": "selector",
      "tag": "select",
      "default": "${name}",
      "outbounds": ["${name}", "direct"]
    },
    {
      "type": "vless",
      "tag": "${name}",
      "server": "${host}",
      "server_port": ${port},
      "uuid": "${PROXY_UUID}",
      "tls": { "enabled": true, "server_name": "${host}", "utls": { "enabled": true, "fingerprint": "chrome" } },
      "transport": {
        "type": "ws",
        "path": "${WS_PATH}",
        "headers": { "Host": "${host}", "ngrok-skip-browser-warning": "true" }
      }
    },
    { "type": "direct", "tag": "direct" }
  ],
  "route": { "final": "select" }
}
EOF_JSON
  fi
}

generate_direct_public_client_files() {
  [ "${DIRECT_PUBLIC_STATE:-}" = "on" ] || return 0
  [ -n "${DIRECT_PUBLIC_HOST_EFFECTIVE:-}" ] || return 0
  generate_plain_ws_client_pair "$DIRECT_PUBLIC_HOST_EFFECTIVE" "$PROXY_PORT" \
    "${CURRENT_ALIAS}-${PROXY_PROTOCOL}-public-direct" "$DIRECT_CLASH_FILE" "$DIRECT_SINGBOX_CLIENT_FILE"
}

generate_ngrok_client_files() {
  local hp host port kind
  [ "${NGROK_ENABLED_STATE:-}" = "on" ] || return 0
  [ -n "${NGROK_PROXY_URL:-}" ] || return 0
  hp="$(ngrok_proxy_host_port)" || return 0
  host="${hp% *}"
  port="${hp##* }"
  kind="$(ngrok_proxy_kind_current)"
  if [ "$kind" = "http_ws" ] || [ "$kind" = "http_ws_mux" ]; then
    generate_tls_ws_client_pair "$host" "$port" \
      "${CURRENT_ALIAS}-${PROXY_PROTOCOL}-ngrok-${kind}" "$NGROK_CLASH_FILE" "$NGROK_SINGBOX_CLIENT_FILE"
  else
    generate_plain_ws_client_pair "$host" "$port" \
      "${CURRENT_ALIAS}-${PROXY_PROTOCOL}-ngrok-tcp" "$NGROK_CLASH_FILE" "$NGROK_SINGBOX_CLIENT_FILE"
  fi
}

latest_url_from_service_log() {
  local name="$1" regex="$2" log_text url
  [ -n "$name" ] || return 1
  log_text="$(service_recent_log "$name" 260)"
  url=$(printf '%s\n' "$log_text" | grep -Eo "$regex" | grep -v 'ngrok\.com/docs/errors' | tail -n1 || true)
  [ -n "$url" ] || return 1
  printf '%s\n' "$url"
}

ensure_filebrowser_quick_for_status() {
  filebrowser_enabled || return 0
  [ -f "$STATE_FILE" ] || return 0
  has_deployment || return 0

  # “查看链接 / 状态”也应尽量给出 FileBrowser 的 CF Quick Tunnel 下载入口。
  # 但不要在已知 CF Edge 不通时强行等待 FB_QUICK_TUNNEL_TIMEOUT，避免 sb 状态页变慢。
  if [ -n "${FB_CF_SERVICE_NAME:-}" ] && service_is_active "$FB_CF_SERVICE_NAME"; then
    if [ -z "${FB_QUICK_URL:-}" ] && cf_quick_tunnel_allowed; then
      capture_filebrowser_quick_url || true
    fi
    return 0
  fi

  if cf_quick_tunnel_allowed; then
    info "正在确保 FileBrowser 的 CF/trycloudflare 临时下载隧道可用..."
    setup_temp_filebrowser || true
    return 0
  fi

  return 0
}

refresh_dynamic_urls() {
  local changed=0 url
  [ -n "${CURRENT_ALIAS:-}" ] || return 0
  refresh_output_paths

  if [ "${DIRECT_PUBLIC_STATE:-}" = "on" ]; then
    if [ -z "${DIRECT_PUBLIC_LINK:-}" ] && [ -n "${DIRECT_PUBLIC_HOST_EFFECTIVE:-}" ]; then
      DIRECT_PUBLIC_LINK="$(public_direct_link)"
      changed=1
    fi
    if [ "${ENABLE_FB_PUBLIC_ON_DIRECT}" = "on" ] && [ -n "${FB_LOCAL_PORT:-}" ] && [ -n "${DIRECT_PUBLIC_HOST_EFFECTIVE:-}" ]; then
      url="http://${DIRECT_PUBLIC_HOST_EFFECTIVE}:${FB_LOCAL_PORT}"
      if [ "${FB_PUBLIC_URL:-}" != "$url" ]; then
        FB_PUBLIC_URL="$url"
        changed=1
      fi
    fi
  fi

  if [ -n "${FB_CF_SERVICE_NAME:-}" ] && service_is_active "$FB_CF_SERVICE_NAME"; then
    if url="$(latest_url_from_service_log "$FB_CF_SERVICE_NAME" 'https://[-a-z0-9]+\.trycloudflare\.com')"; then
      if [ "${FB_QUICK_URL:-}" != "$url" ]; then
        FB_QUICK_URL="$url"
        changed=1
      fi
    fi
  fi

  if [ -n "${NGROK_PROXY_SERVICE_NAME:-}" ] && service_is_active "$NGROK_PROXY_SERVICE_NAME"; then
    if url="$(latest_url_from_service_log "$NGROK_PROXY_SERVICE_NAME" "$(ngrok_http_url_regex)")"; then
      if [ "${NGROK_PROXY_URL:-}" != "$url" ] || [ "${NGROK_PROXY_KIND:-}" != "http_ws" ]; then
        NGROK_ENABLED_STATE="on"
        NGROK_PROXY_URL="$url"
        if ngrok_mux_active; then NGROK_PROXY_KIND="http_ws_mux"; NGROK_FB_URL="$url"; else NGROK_PROXY_KIND="http_ws"; fi
        generate_ngrok_client_files
        changed=1
      fi
    elif url="$(latest_url_from_service_log "$NGROK_PROXY_SERVICE_NAME" "$(ngrok_tcp_url_regex)")"; then
      if [ "${NGROK_PROXY_URL:-}" != "$url" ]; then
        NGROK_ENABLED_STATE="on"
        NGROK_PROXY_URL="$url"
        NGROK_PROXY_KIND="tcp"
        generate_ngrok_client_files
        changed=1
      fi
    fi
  elif [ -n "${NGROK_PROXY_URL:-}" ] && [ -n "${NGROK_PROXY_SERVICE_NAME:-}" ]; then
    warn "ngrok 代理服务未运行，已清空过期代理入口：${NGROK_PROXY_URL}"
    NGROK_PROXY_URL=""
    NGROK_PROXY_KIND=""
    changed=1
  fi

  if [ -n "${NGROK_FB_SERVICE_NAME:-}" ] && service_is_active "$NGROK_FB_SERVICE_NAME"; then
    if url="$(latest_url_from_service_log "$NGROK_FB_SERVICE_NAME" "$(ngrok_http_url_regex)")"; then
      if [ "${NGROK_FB_URL:-}" != "$url" ]; then
        NGROK_ENABLED_STATE="on"
        NGROK_FB_URL="$url"
        changed=1
      fi
    fi
  elif [ -n "${NGROK_FB_URL:-}" ] && [ -n "${NGROK_FB_SERVICE_NAME:-}" ]; then
    warn "ngrok FileBrowser 服务未运行，已清空过期下载入口：${NGROK_FB_URL}"
    NGROK_FB_URL=""
    changed=1
  fi

  if [ "$changed" -eq 1 ]; then
    generate_info_file
    save_state
  fi
}

generate_clash_file() {
  local rec_name="${CURRENT_ALIAS}-${PROXY_PROTOCOL}-cf"
  local dir_name="${CURRENT_ALIAS}-${PROXY_PROTOCOL}-direct"

  if [ "$PROXY_PROTOCOL" = "vmess" ]; then
    if direct_node_enabled; then
      cat > "$CLASH_FILE" <<EOF_YAML
mixed-port: 7890
allow-lan: true
mode: rule
log-level: info

proxies:
  - name: "${rec_name}"
    type: vmess
    server: ${CLIENT_SERVER}
    port: ${CLIENT_PORT}
    uuid: ${PROXY_UUID}
    alterId: 0
    cipher: auto
    udp: true
    tls: true
    servername: ${TUNNEL_DOMAIN}
    client-fingerprint: chrome
    network: ws
    ws-opts:
      path: "${WS_PATH}"
      headers:
        Host: "${TUNNEL_DOMAIN}"

  - name: "${dir_name}"
    type: vmess
    server: ${TUNNEL_DOMAIN}
    port: ${DIRECT_PORT}
    uuid: ${PROXY_UUID}
    alterId: 0
    cipher: auto
    udp: true
    tls: true
    servername: ${TUNNEL_DOMAIN}
    client-fingerprint: chrome
    network: ws
    ws-opts:
      path: "${WS_PATH}"
      headers:
        Host: "${TUNNEL_DOMAIN}"

proxy-groups:
  - name: "🚀 节点选择"
    type: select
    proxies:
      - "${rec_name}"
      - "${dir_name}"
      - DIRECT

rules:
  - GEOIP,CN,DIRECT
  - MATCH,🚀 节点选择
EOF_YAML
    else
      cat > "$CLASH_FILE" <<EOF_YAML
mixed-port: 7890
allow-lan: true
mode: rule
log-level: info

proxies:
  - name: "${rec_name}"
    type: vmess
    server: ${CLIENT_SERVER}
    port: ${CLIENT_PORT}
    uuid: ${PROXY_UUID}
    alterId: 0
    cipher: auto
    udp: true
    tls: true
    servername: ${TUNNEL_DOMAIN}
    client-fingerprint: chrome
    network: ws
    ws-opts:
      path: "${WS_PATH}"
      headers:
        Host: "${TUNNEL_DOMAIN}"

proxy-groups:
  - name: "🚀 节点选择"
    type: select
    proxies:
      - "${rec_name}"
      - DIRECT

rules:
  - GEOIP,CN,DIRECT
  - MATCH,🚀 节点选择
EOF_YAML
    fi
  else
    if direct_node_enabled; then
      cat > "$CLASH_FILE" <<EOF_YAML
mixed-port: 7890
allow-lan: true
mode: rule
log-level: info

proxies:
  - name: "${rec_name}"
    type: vless
    server: ${CLIENT_SERVER}
    port: ${CLIENT_PORT}
    uuid: ${PROXY_UUID}
    udp: true
    tls: true
    servername: ${TUNNEL_DOMAIN}
    client-fingerprint: chrome
    network: ws
    ws-opts:
      path: "${WS_PATH}"
      headers:
        Host: "${TUNNEL_DOMAIN}"

  - name: "${dir_name}"
    type: vless
    server: ${TUNNEL_DOMAIN}
    port: ${DIRECT_PORT}
    uuid: ${PROXY_UUID}
    udp: true
    tls: true
    servername: ${TUNNEL_DOMAIN}
    client-fingerprint: chrome
    network: ws
    ws-opts:
      path: "${WS_PATH}"
      headers:
        Host: "${TUNNEL_DOMAIN}"

proxy-groups:
  - name: "🚀 节点选择"
    type: select
    proxies:
      - "${rec_name}"
      - "${dir_name}"
      - DIRECT

rules:
  - GEOIP,CN,DIRECT
  - MATCH,🚀 节点选择
EOF_YAML
    else
      cat > "$CLASH_FILE" <<EOF_YAML
mixed-port: 7890
allow-lan: true
mode: rule
log-level: info

proxies:
  - name: "${rec_name}"
    type: vless
    server: ${CLIENT_SERVER}
    port: ${CLIENT_PORT}
    uuid: ${PROXY_UUID}
    udp: true
    tls: true
    servername: ${TUNNEL_DOMAIN}
    client-fingerprint: chrome
    network: ws
    ws-opts:
      path: "${WS_PATH}"
      headers:
        Host: "${TUNNEL_DOMAIN}"

proxy-groups:
  - name: "🚀 节点选择"
    type: select
    proxies:
      - "${rec_name}"
      - DIRECT

rules:
  - GEOIP,CN,DIRECT
  - MATCH,🚀 节点选择
EOF_YAML
    fi
  fi
}

generate_singbox_client_file() {
  local rec_tag="${CURRENT_ALIAS}-${PROXY_PROTOCOL}-cf"
  local dir_tag="${CURRENT_ALIAS}-${PROXY_PROTOCOL}-direct"

  if [ "$PROXY_PROTOCOL" = "vmess" ]; then
    if direct_node_enabled; then
      cat > "$SINGBOX_CLIENT_FILE" <<EOF_JSON
{
  "log": { "level": "info", "timestamp": true },
  "dns": {
    "servers": [
      { "tag": "cf", "address": "tls://1.1.1.1" },
      { "tag": "google", "address": "tls://8.8.8.8" }
    ],
    "strategy": "prefer_ipv4"
  },
  "outbounds": [
    {
      "type": "selector",
      "tag": "select",
      "default": "${rec_tag}",
      "outbounds": ["${rec_tag}", "${dir_tag}", "direct"]
    },
    {
      "type": "vmess",
      "tag": "${rec_tag}",
      "server": "${CLIENT_SERVER}",
      "server_port": ${CLIENT_PORT},
      "uuid": "${PROXY_UUID}",
      "security": "auto",
      "packet_encoding": "packetaddr",
      "tls": {
        "enabled": true,
        "server_name": "${TUNNEL_DOMAIN}",
        "utls": { "enabled": true, "fingerprint": "chrome" }
      },
      "transport": {
        "type": "ws",
        "path": "${WS_PATH}",
        "headers": { "Host": "${TUNNEL_DOMAIN}" },
        "max_early_data": 2048,
        "early_data_header_name": "Sec-WebSocket-Protocol"
      }
    },
    {
      "type": "vmess",
      "tag": "${dir_tag}",
      "server": "${TUNNEL_DOMAIN}",
      "server_port": ${DIRECT_PORT},
      "uuid": "${PROXY_UUID}",
      "security": "auto",
      "packet_encoding": "packetaddr",
      "tls": {
        "enabled": true,
        "server_name": "${TUNNEL_DOMAIN}",
        "utls": { "enabled": true, "fingerprint": "chrome" }
      },
      "transport": {
        "type": "ws",
        "path": "${WS_PATH}",
        "headers": { "Host": "${TUNNEL_DOMAIN}" },
        "max_early_data": 2048,
        "early_data_header_name": "Sec-WebSocket-Protocol"
      }
    },
    { "type": "direct", "tag": "direct" }
  ],
  "route": {
    "auto_detect_interface": true,
    "final": "select"
  }
}
EOF_JSON
    else
      cat > "$SINGBOX_CLIENT_FILE" <<EOF_JSON
{
  "log": { "level": "info", "timestamp": true },
  "dns": {
    "servers": [
      { "tag": "cf", "address": "tls://1.1.1.1" },
      { "tag": "google", "address": "tls://8.8.8.8" }
    ],
    "strategy": "prefer_ipv4"
  },
  "outbounds": [
    {
      "type": "selector",
      "tag": "select",
      "default": "${rec_tag}",
      "outbounds": ["${rec_tag}", "direct"]
    },
    {
      "type": "vmess",
      "tag": "${rec_tag}",
      "server": "${CLIENT_SERVER}",
      "server_port": ${CLIENT_PORT},
      "uuid": "${PROXY_UUID}",
      "security": "auto",
      "packet_encoding": "packetaddr",
      "tls": {
        "enabled": true,
        "server_name": "${TUNNEL_DOMAIN}",
        "utls": { "enabled": true, "fingerprint": "chrome" }
      },
      "transport": {
        "type": "ws",
        "path": "${WS_PATH}",
        "headers": { "Host": "${TUNNEL_DOMAIN}" },
        "max_early_data": 2048,
        "early_data_header_name": "Sec-WebSocket-Protocol"
      }
    },
    { "type": "direct", "tag": "direct" }
  ],
  "route": {
    "auto_detect_interface": true,
    "final": "select"
  }
}
EOF_JSON
    fi
  else
    if direct_node_enabled; then
      cat > "$SINGBOX_CLIENT_FILE" <<EOF_JSON
{
  "log": { "level": "info", "timestamp": true },
  "dns": {
    "servers": [
      { "tag": "cf", "address": "tls://1.1.1.1" },
      { "tag": "google", "address": "tls://8.8.8.8" }
    ],
    "strategy": "prefer_ipv4"
  },
  "outbounds": [
    {
      "type": "selector",
      "tag": "select",
      "default": "${rec_tag}",
      "outbounds": ["${rec_tag}", "${dir_tag}", "direct"]
    },
    {
      "type": "vless",
      "tag": "${rec_tag}",
      "server": "${CLIENT_SERVER}",
      "server_port": ${CLIENT_PORT},
      "uuid": "${PROXY_UUID}",
      "tls": {
        "enabled": true,
        "server_name": "${TUNNEL_DOMAIN}",
        "utls": { "enabled": true, "fingerprint": "chrome" }
      },
      "transport": {
        "type": "ws",
        "path": "${WS_PATH}",
        "headers": { "Host": "${TUNNEL_DOMAIN}" },
        "max_early_data": 2048,
        "early_data_header_name": "Sec-WebSocket-Protocol"
      }
    },
    {
      "type": "vless",
      "tag": "${dir_tag}",
      "server": "${TUNNEL_DOMAIN}",
      "server_port": ${DIRECT_PORT},
      "uuid": "${PROXY_UUID}",
      "tls": {
        "enabled": true,
        "server_name": "${TUNNEL_DOMAIN}",
        "utls": { "enabled": true, "fingerprint": "chrome" }
      },
      "transport": {
        "type": "ws",
        "path": "${WS_PATH}",
        "headers": { "Host": "${TUNNEL_DOMAIN}" },
        "max_early_data": 2048,
        "early_data_header_name": "Sec-WebSocket-Protocol"
      }
    },
    { "type": "direct", "tag": "direct" }
  ],
  "route": {
    "auto_detect_interface": true,
    "final": "select"
  }
}
EOF_JSON
    else
      cat > "$SINGBOX_CLIENT_FILE" <<EOF_JSON
{
  "log": { "level": "info", "timestamp": true },
  "dns": {
    "servers": [
      { "tag": "cf", "address": "tls://1.1.1.1" },
      { "tag": "google", "address": "tls://8.8.8.8" }
    ],
    "strategy": "prefer_ipv4"
  },
  "outbounds": [
    {
      "type": "selector",
      "tag": "select",
      "default": "${rec_tag}",
      "outbounds": ["${rec_tag}", "direct"]
    },
    {
      "type": "vless",
      "tag": "${rec_tag}",
      "server": "${CLIENT_SERVER}",
      "server_port": ${CLIENT_PORT},
      "uuid": "${PROXY_UUID}",
      "tls": {
        "enabled": true,
        "server_name": "${TUNNEL_DOMAIN}",
        "utls": { "enabled": true, "fingerprint": "chrome" }
      },
      "transport": {
        "type": "ws",
        "path": "${WS_PATH}",
        "headers": { "Host": "${TUNNEL_DOMAIN}" },
        "max_early_data": 2048,
        "early_data_header_name": "Sec-WebSocket-Protocol"
      }
    },
    { "type": "direct", "tag": "direct" }
  ],
  "route": {
    "auto_detect_interface": true,
    "final": "select"
  }
}
EOF_JSON
    fi
  fi
}

generate_info_file() {
  local rec_link dir_link direct_public_link ngrok_link fallback_link
  rec_link=$(recommended_link)
  dir_link=$(direct_link)
  direct_public_link="${DIRECT_PUBLIC_LINK:-$(public_direct_link)}"
  ngrok_link="$(ngrok_proxy_link)"
  fallback_link="$(primary_fallback_link)"

  cat > "$INFO_FILE" <<EOF_TXT
==========================================
CF Proxy 自动部署信息
==========================================
脚本版本        : ${SCRIPT_VERSION}
服务器别名      : ${CURRENT_ALIAS}
代理协议        : ${PROXY_PROTOCOL}-ws
本地监听端口    : ${PROXY_PORT}
WS 路径         : ${WS_PATH}
节点 UUID       : ${PROXY_UUID}
------------------------------------------
Cloudflare 模式 : $(current_auth_mode) -> 实际运行 ${CF_RUN_MODE}
隧道名称        : ${TUNNEL_NAME}
隧道域名        : ${TUNNEL_DOMAIN}
隧道 UUID       : ${TUNNEL_UUID_CF}
服务后端        : ${SERVICE_BACKEND}
开机拉起        : ${BOOT_HOOK_BACKEND}
sing-box 服务   : ${SB_SERVICE_NAME}
cloudflared服务 : ${CF_SERVICE_NAME}
隧道健康状态    : ${CF_LAST_HEALTH}
------------------------------------------
【推荐用法｜甬哥风格优先入口】
连接地址        : ${CLIENT_SERVER}
连接端口        : ${CLIENT_PORT}
Host / SNI      : ${TUNNEL_DOMAIN}
TLS             : 开启
备注            : 如果你所在地直连隧道域名速度一般，优先用这一组

推荐分享链接：
${rec_link}
------------------------------------------
【备用直连｜仍走 Cloudflare 域名】
连接地址        : ${TUNNEL_DOMAIN}
连接端口        : ${DIRECT_PORT}
Host / SNI      : ${TUNNEL_DOMAIN}
TLS             : 开启

备用分享链接：
${dir_link}
------------------------------------------
【公网直连兜底｜不依赖 CF/ngrok】
状态            : $(if [ "${DIRECT_PUBLIC_STATE:-}" = "on" ]; then echo 已启用; else echo 未启用; fi)
公网地址        : ${DIRECT_PUBLIC_HOST_EFFECTIVE:-未探测 / 未设置}
sing-box 监听   : ${SB_LISTEN_ADDR}:${PROXY_PORT}
TLS             : 关闭（明文 WS，仅建议临时使用）
分享链接        : ${direct_public_link:-未生成}
Clash 配置      : $(if [ -f "${DIRECT_CLASH_FILE:-}" ]; then echo "${DIRECT_CLASH_FILE}"; else echo 未生成; fi)
sing-box 配置   : $(if [ -f "${DIRECT_SINGBOX_CLIENT_FILE:-}" ]; then echo "${DIRECT_SINGBOX_CLIENT_FILE}"; else echo 未生成; fi)
说明            : 只有服务器公网入站和该端口可达时才可用；如果打不开，就进面板启用 ngrok 临时模式。
------------------------------------------
【ngrok 临时兜底｜无公网入站时手动启用】
状态            : $(if [ "${NGROK_ENABLED_STATE:-}" = "on" ]; then echo 已启用; else echo 未启用; fi)
代理模式        : $(ngrok_proxy_kind_current 2>/dev/null || echo 未生成)
代理入口        : ${NGROK_PROXY_URL:-未生成}
代理分享链接    : ${ngrok_link:-未生成}
Clash 配置      : $(if [ -f "${NGROK_CLASH_FILE:-}" ]; then echo "${NGROK_CLASH_FILE}"; else echo 未生成; fi)
sing-box 配置   : $(if [ -f "${NGROK_SINGBOX_CLIENT_FILE:-}" ]; then echo "${NGROK_SINGBOX_CLIENT_FILE}"; else echo 未生成; fi)
FileBrowser ngrok : ${NGROK_FB_URL:-未生成}（单入口复用时与代理入口相同；根路径打开）
Token 指纹      : ${NGROK_AUTHTOKEN_FINGERPRINT:-未记录}
说明            : auto 优先 ngrok HTTP/WSS(443)，失败才退 TCP；http_ws_mux=代理+FB 单入口复用，FB 不再额外占 ngrok endpoint。
------------------------------------------
【临时 FileBrowser 下载页】
状态            : $(if [ "${FB_ENABLED_STATE:-}" = "on" ]; then echo 已启用; else echo 未启用; fi)
根目录          : $(effective_fb_root)
本地地址        : $(if [ -n "${FB_LOCAL_PORT:-}" ]; then echo "http://127.0.0.1:${FB_LOCAL_PORT}"; else echo 未分配; fi)
公网直连链接    : ${FB_PUBLIC_URL:-未生成 / 未启用}
trycloudflare   : ${FB_QUICK_URL:-未抓取 / 未启用}（依赖 CF Tunnel；7844 被封时常不可用）
ngrok 入口      : ${NGROK_FB_URL:-未生成 / 未启用}（单入口复用时与代理入口相同；提示页点 Visit Site）
用户名          : ${FB_USER}
密码            : ${FB_PASSWORD_EFFECTIVE:-未生成}
说明            : 默认根目录就是 ${CONFIG_DIR}，方便直接下载 Clash / sing-box 客户端配置。
------------------------------------------
生成文件：
1. ${INFO_FILE}
2. ${CLASH_FILE}
3. ${SINGBOX_CLIENT_FILE}
4. $(if [ -f "${DIRECT_CLASH_FILE:-}" ]; then echo "${DIRECT_CLASH_FILE}"; else echo "公网直连 Clash：未生成"; fi)
5. $(if [ -f "${DIRECT_SINGBOX_CLIENT_FILE:-}" ]; then echo "${DIRECT_SINGBOX_CLIENT_FILE}"; else echo "公网直连 sing-box：未生成"; fi)
6. $(if [ -f "${NGROK_CLASH_FILE:-}" ]; then echo "${NGROK_CLASH_FILE}"; else echo "ngrok Clash：未生成"; fi)
7. $(if [ -f "${NGROK_SINGBOX_CLIENT_FILE:-}" ]; then echo "${NGROK_SINGBOX_CLIENT_FILE}"; else echo "ngrok sing-box：未生成"; fi)
客户端直连节点  : $(if direct_node_enabled; then echo 已输出; else echo 已隐藏（如需输出可把 EXPORT_DIRECT_NODE 改成 on）; fi)
面板本体路径    : ${INSTALLED_SCRIPT}
面板保底唤起    : bash ${INSTALLED_SCRIPT}
快捷命令        : $(if quick_cmd_installed; then echo "${QUICK_CMD}"; else echo "未安装"; fi)
------------------------------------------
【末尾汇总｜方便复制】
首选可用兜底链接：
${fallback_link:-未生成；可在面板 4 里生成公网或 ngrok}

推荐节点链接：
${rec_link}

备用直连链接：
${dir_link}

公网直连链接：
${direct_public_link:-未生成}

ngrok 代理链接：
${ngrok_link:-未生成}

Clash 配置文件：
${CLASH_FILE}

sing-box 客户端配置：
${SINGBOX_CLIENT_FILE}

公网直连 Clash 配置：
$(if [ -f "${DIRECT_CLASH_FILE:-}" ]; then echo "${DIRECT_CLASH_FILE}"; else echo 未生成; fi)

公网直连 sing-box 配置：
$(if [ -f "${DIRECT_SINGBOX_CLIENT_FILE:-}" ]; then echo "${DIRECT_SINGBOX_CLIENT_FILE}"; else echo 未生成; fi)

ngrok Clash 配置：
$(if [ -f "${NGROK_CLASH_FILE:-}" ]; then echo "${NGROK_CLASH_FILE}"; else echo 未生成; fi)

ngrok sing-box 配置：
$(if [ -f "${NGROK_SINGBOX_CLIENT_FILE:-}" ]; then echo "${NGROK_SINGBOX_CLIENT_FILE}"; else echo 未生成; fi)

FileBrowser 公网直连：
${FB_PUBLIC_URL:-未生成}

FileBrowser trycloudflare（依赖 CF Tunnel；7844 被封时常不可用）：
${FB_QUICK_URL:-未启用或未抓取}

FileBrowser ngrok 入口（单入口复用时与代理入口相同；打开后点 Visit Site）：
${NGROK_FB_URL:-未生成}
==========================================
EOF_TXT
}

generate_client_files() {
  mkdir -p "$CONFIG_DIR"
  refresh_output_paths
  if [ "${CF_RUN_MODE:-}" != "skipped" ] && [ "${TUNNEL_UUID_CF:-}" != "skipped" ]; then
    generate_clash_file
    generate_singbox_client_file
  else
    : > "$CLASH_FILE"
    : > "$SINGBOX_CLIENT_FILE"
  fi
  generate_direct_public_client_files
  generate_ngrok_client_files
  generate_info_file
  ok "客户端配置已生成：${CONFIG_DIR}"
}

show_links_brief() {
  local direct_public_link ngrok_link fallback_link
  direct_public_link="${DIRECT_PUBLIC_LINK:-$(public_direct_link)}"
  ngrok_link="$(ngrok_proxy_link)"
  fallback_link="$(primary_fallback_link)"

  echo ""
  echo -e "${BLUE}========== 链接汇总（方便复制） ==========${RESET}"
  echo "[首选兜底] ${fallback_link:-未生成，请在面板 4 生成公网或 ngrok}"
  if [ "${CF_RUN_MODE:-}" != "skipped" ] && [ "${TUNNEL_UUID_CF:-}" != "skipped" ]; then
    echo ""
    echo "[推荐] $(recommended_link)"
    echo ""
    echo "[备用直连] $(direct_link)"
    echo ""
    echo "[Clash配置] ${CLASH_FILE}"
    echo "[sing-box配置] ${SINGBOX_CLIENT_FILE}"
  fi

  if [ "${DIRECT_PUBLIC_STATE:-}" = "on" ]; then
    echo ""
    echo "[公网直连] ${direct_public_link:-未生成}"
    echo "[公网直连 Clash配置] ${DIRECT_CLASH_FILE:-未生成}"
    echo "[公网直连 sing-box配置] ${DIRECT_SINGBOX_CLIENT_FILE:-未生成}"
    if [ "${FB_ENABLED_STATE:-}" = "on" ] && [ -n "${FB_PUBLIC_URL:-}" ]; then
      echo "[FileBrowser 公网] ${FB_PUBLIC_URL}"
    fi
  fi

  if [ "${NGROK_ENABLED_STATE:-}" = "on" ]; then
    echo ""
    echo "[ngrok 代理 $(ngrok_proxy_kind_current 2>/dev/null || echo 未知)] ${ngrok_link:-${NGROK_PROXY_URL:-未生成}}"
    echo "[ngrok Clash配置] ${NGROK_CLASH_FILE:-未生成}"
    echo "[ngrok sing-box配置] ${NGROK_SINGBOX_CLIENT_FILE:-未生成}"
    echo "[ngrok FileBrowser 入口｜单入口复用时与代理入口相同，打开后点 Visit Site] ${NGROK_FB_URL:-未生成}"
  fi

  if [ "${FB_ENABLED_STATE:-}" = "on" ]; then
    echo ""
    echo "[FileBrowser trycloudflare｜依赖 CF Tunnel，7844 被封时常不可用] ${FB_QUICK_URL:-尚未抓取，请在面板选择 FileBrowser 功能刷新}"
  fi
  if ! direct_node_enabled; then
    echo ""
    warn "当前 Clash / sing-box 客户端配置默认只写入推荐节点；备用直连链接仅展示在信息文件里，避免重复节点。"
  fi
  echo -e "${BLUE}=========================================${RESET}"
}

quick_cmd_path() {
  echo "/usr/local/bin/${QUICK_CMD}"
}

quick_cmd_installed() {
  [ -x "$(quick_cmd_path)" ]
}

manager_entry_hint() {
  local src="${BASH_SOURCE[0]}"
  if [ -f "$INSTALLED_SCRIPT" ]; then
    echo "bash $INSTALLED_SCRIPT"
  elif quick_cmd_installed; then
    echo "${QUICK_CMD}"
  elif [[ "$src" != /dev/fd/* ]] && [ -f "$src" ]; then
    echo "bash $src"
  else
    echo "$(bootstrap_install_command)"
  fi
}

show_entry_commands() {
  local quick_path
  quick_path=$(quick_cmd_path)
  echo ""
  echo -e "${BLUE}========== 面板入口 ==========${RESET}"
  if [ -f "$INSTALLED_SCRIPT" ]; then
    echo "本体路径   : $INSTALLED_SCRIPT"
    echo "保底唤起   : bash $INSTALLED_SCRIPT"
  else
    echo "本体路径   : 尚未写入固定路径"
  fi

  if quick_cmd_installed; then
    echo "快捷命令   : ${QUICK_CMD}"
    echo "快捷路径   : ${quick_path}"
  else
    echo "快捷命令   : 尚未安装"
  fi

  echo ""
  if bootstrap_cert_ready; then
    echo "当前状态   : 已检测到本地一次性管理凭证文件：${BOOTSTRAP_CERT_FILE}"
  elif [ -s "$CF_DIR/cert.pem" ]; then
    echo "当前状态   : 已检测到运行中的管理凭证文件：${CF_DIR}/cert.pem"
  else
    echo "当前状态   : 未检测到本地管理凭证文件"
  fi
  echo ""
  echo "普通用户提示：若当前账号具备 sudo，也可直接执行上述入口，脚本会自动尝试提权。"
  echo ""
  echo "说明："
  echo "- 日常唤起优先直接执行 ${QUICK_CMD}；保底可执行 bash ${INSTALLED_SCRIPT}。"
  echo "- 首条安装命令不在状态页展开，避免每次查看链接时刷屏；需要时看总笔记的安装章节。"
  echo "- 如果只是暂时不想部署，又已下载了本地管理凭证，可直接选 6 -> 2 做彻底删除。"
  echo -e "${BLUE}==============================${RESET}"
}

show_status() {
  echo ""
  echo -e "${BLUE}========== 当前状态 ==========${RESET}"
  if [ -f "$STATE_FILE" ]; then
    refresh_dynamic_urls
    ensure_filebrowser_quick_for_status
    refresh_dynamic_urls
    echo "别名             : ${CURRENT_ALIAS}"
    echo "隧道名称         : ${TUNNEL_NAME}"
    echo "隧道域名         : ${TUNNEL_DOMAIN}"
    echo "认证模式         : $(current_auth_mode)"
    echo "协议             : ${PROXY_PROTOCOL}-ws"
    echo "本地端口         : ${PROXY_PORT}"
    echo "WS 路径          : ${WS_PATH}"
    echo "sing-box 服务    : ${SB_SERVICE_NAME:-未记录}"
    echo "cloudflared 服务 : ${CF_SERVICE_NAME:-未记录}"
    echo "隧道健康         : ${CF_LAST_HEALTH:-未检测}"
    echo "公网直连         : $(if [ "${DIRECT_PUBLIC_STATE:-}" = "on" ]; then echo "已启用（${DIRECT_PUBLIC_HOST_EFFECTIVE:-未知}:${PROXY_PORT}）"; else echo 未启用; fi)"
    echo "ngrok            : $(if [ "${NGROK_ENABLED_STATE:-}" = "on" ]; then echo "已启用（$(ngrok_proxy_kind_current 2>/dev/null || echo 未知)，${NGROK_PROXY_URL:-未抓取入口}）"; else echo 未启用; fi)"
    echo "FileBrowser      : $(if [ "${FB_ENABLED_STATE:-}" = "on" ]; then echo "已启用（ngrok真实:${NGROK_FB_URL:-未生成} trycloudflare:${FB_QUICK_URL:-未抓取} 公网:${FB_PUBLIC_URL:-未生成}）"; else echo 未启用; fi)"
    echo "本地管理凭证     : $(if local_mgmt_cred_exists; then echo 已检测到，建议首次 cert 建隧道后自动销毁，或选 6 -> 2 删除; else echo 未检测到; fi)"
    echo "服务后端         : ${SERVICE_BACKEND}"
    if [ "$SERVICE_BACKEND" = "process" ]; then
      echo "开机拉起         : ${BOOT_HOOK_BACKEND}"
    fi
    echo ""

    printf 'sing-box   : '
    if [ -n "${SB_SERVICE_NAME:-}" ] && service_is_active "$SB_SERVICE_NAME"; then
      echo -e "${GREEN}运行中${RESET}"
    else
      echo -e "${RED}未运行${RESET}"
    fi

    printf 'cloudflared: '
    if [ -n "${CF_SERVICE_NAME:-}" ] && service_is_active "$CF_SERVICE_NAME"; then
      echo -e "${GREEN}运行中${RESET}"
    else
      echo -e "${RED}未运行${RESET}"
    fi

    if [ "${FB_ENABLED_STATE:-}" = "on" ]; then
      printf 'filebrowser: '
      if [ -n "${FB_SERVICE_NAME:-}" ] && service_is_active "$FB_SERVICE_NAME"; then
        echo -e "${GREEN}运行中${RESET}"
      else
        echo -e "${RED}未运行${RESET}"
      fi
      printf 'fb tunnel  : '
      if [ -n "${FB_CF_SERVICE_NAME:-}" ] && service_is_active "$FB_CF_SERVICE_NAME"; then
        echo -e "${GREEN}运行中${RESET}"
      else
        echo -e "${RED}未运行${RESET}"
      fi
    fi

    if [ "${NGROK_ENABLED_STATE:-}" = "on" ]; then
      if [ -n "${NGROK_MUX_SERVICE_NAME:-}" ]; then
        printf 'ngrok mux  : '
        if service_is_active "$NGROK_MUX_SERVICE_NAME"; then
          echo -e "${GREEN}运行中${RESET}"
        else
          echo -e "${RED}未运行${RESET}"
        fi
      fi
      printf 'ngrok proxy: '
      if [ -n "${NGROK_PROXY_SERVICE_NAME:-}" ] && service_is_active "$NGROK_PROXY_SERVICE_NAME"; then
        echo -e "${GREEN}运行中${RESET}"
      else
        echo -e "${RED}未运行${RESET}"
      fi
      printf 'ngrok fb   : '
      if [ -n "${NGROK_FB_SERVICE_NAME:-}" ] && service_is_active "$NGROK_FB_SERVICE_NAME"; then
        echo -e "${GREEN}运行中${RESET}"
      else
        echo -e "${RED}未运行${RESET}"
      fi
    fi

    echo ""
    [ -f "$INFO_FILE" ] && sed -n '1,220p' "$INFO_FILE"
    show_links_brief
    show_entry_commands
  else
    warn "当前没有部署记录。"
    show_entry_commands
  fi
}

restart_services() {
  require_deployment || return 0

  if [ -n "${SB_SERVICE_NAME:-}" ]; then
    restart_service "$SB_SERVICE_NAME"
    ok "已重启 ${SB_SERVICE_NAME}"
  fi

  if [ -n "${CF_SERVICE_NAME:-}" ]; then
    restart_service "$CF_SERVICE_NAME"
    ok "已重启 ${CF_SERVICE_NAME}"
  fi

  if [ "${FB_ENABLED_STATE:-}" = "on" ]; then
    [ -n "${FB_SERVICE_NAME:-}" ] && restart_service "$FB_SERVICE_NAME" && ok "已重启 ${FB_SERVICE_NAME}"
    [ -n "${FB_CF_SERVICE_NAME:-}" ] && [ "$SERVICE_BACKEND" = "process" ] && : > "$(service_log_file "$FB_CF_SERVICE_NAME")"
    [ -n "${FB_CF_SERVICE_NAME:-}" ] && restart_service "$FB_CF_SERVICE_NAME" && ok "已重启 ${FB_CF_SERVICE_NAME}"
    capture_filebrowser_quick_url || true
    save_state
    generate_info_file
  fi

  if [ "${NGROK_ENABLED_STATE:-}" = "on" ]; then
    if [ -n "${NGROK_MUX_SERVICE_NAME:-}" ]; then
      restart_service "$NGROK_MUX_SERVICE_NAME"
      ok "已重启 ${NGROK_MUX_SERVICE_NAME}"
    fi
    if [ -n "${NGROK_PROXY_SERVICE_NAME:-}" ]; then
      : > "$(service_log_file "$NGROK_PROXY_SERVICE_NAME")"
      restart_service "$NGROK_PROXY_SERVICE_NAME"
      NGROK_PROXY_URL="$(wait_current_ngrok_proxy_url "$(service_log_file "$NGROK_PROXY_SERVICE_NAME")" || true)"
      [ -n "${NGROK_PROXY_URL:-}" ] && generate_ngrok_client_files
      ok "已重启 ${NGROK_PROXY_SERVICE_NAME}"
    fi
    if [ -n "${NGROK_FB_SERVICE_NAME:-}" ]; then
      : > "$(service_log_file "$NGROK_FB_SERVICE_NAME")"
      restart_service "$NGROK_FB_SERVICE_NAME"
      NGROK_FB_URL="$(wait_ngrok_url_from_log "$(service_log_file "$NGROK_FB_SERVICE_NAME")" "$(ngrok_http_url_regex)" || true)"
      schedule_ngrok_fb_autostop
      ok "已重启 ${NGROK_FB_SERVICE_NAME}"
    fi
    save_state
    generate_info_file
  fi
}

ensure_services() {
  require_deployment || return 0

  if [ -n "${SB_SERVICE_NAME:-}" ] && ! service_is_active "$SB_SERVICE_NAME"; then
    ensure_service_running "$SB_SERVICE_NAME"
    ok "已补启动 ${SB_SERVICE_NAME}"
  fi

  if [ -n "${CF_SERVICE_NAME:-}" ] && ! service_is_active "$CF_SERVICE_NAME"; then
    ensure_service_running "$CF_SERVICE_NAME"
    ok "已补启动 ${CF_SERVICE_NAME}"
  fi

  if [ "${FB_ENABLED_STATE:-}" = "on" ]; then
    [ -n "${FB_SERVICE_NAME:-}" ] && ! service_is_active "$FB_SERVICE_NAME" && ensure_service_running "$FB_SERVICE_NAME" && ok "已补启动 ${FB_SERVICE_NAME}"
    [ -n "${FB_CF_SERVICE_NAME:-}" ] && ! service_is_active "$FB_CF_SERVICE_NAME" && ensure_service_running "$FB_CF_SERVICE_NAME" && ok "已补启动 ${FB_CF_SERVICE_NAME}"
    capture_filebrowser_quick_url || true
    save_state
    generate_info_file
  fi

  if [ "${NGROK_ENABLED_STATE:-}" = "on" ]; then
    if [ -n "${NGROK_MUX_SERVICE_NAME:-}" ] && ! service_is_active "$NGROK_MUX_SERVICE_NAME"; then
      ensure_service_running "$NGROK_MUX_SERVICE_NAME"
      ok "已补启动 ${NGROK_MUX_SERVICE_NAME}"
    fi
    if [ -n "${NGROK_PROXY_SERVICE_NAME:-}" ] && ! service_is_active "$NGROK_PROXY_SERVICE_NAME"; then
      : > "$(service_log_file "$NGROK_PROXY_SERVICE_NAME")"
      ensure_service_running "$NGROK_PROXY_SERVICE_NAME"
      NGROK_PROXY_URL="$(wait_current_ngrok_proxy_url "$(service_log_file "$NGROK_PROXY_SERVICE_NAME")" || true)"
      [ -n "${NGROK_PROXY_URL:-}" ] && generate_ngrok_client_files
      ok "已补启动 ${NGROK_PROXY_SERVICE_NAME}"
    fi
    if [ -n "${NGROK_FB_SERVICE_NAME:-}" ] && ! service_is_active "$NGROK_FB_SERVICE_NAME"; then
      : > "$(service_log_file "$NGROK_FB_SERVICE_NAME")"
      ensure_service_running "$NGROK_FB_SERVICE_NAME"
      NGROK_FB_URL="$(wait_ngrok_url_from_log "$(service_log_file "$NGROK_FB_SERVICE_NAME")" "$(ngrok_http_url_regex)" || true)"
      schedule_ngrok_fb_autostop
      ok "已补启动 ${NGROK_FB_SERVICE_NAME}"
    fi
    save_state
    generate_info_file
  fi
}

remove_proxy_side() {
  if [ -n "${NGROK_FB_SERVICE_NAME:-}" ]; then
    stop_disable_remove_service "$NGROK_FB_SERVICE_NAME"
    ok "已移除 ${NGROK_FB_SERVICE_NAME}"
  fi

  if [ -n "${NGROK_PROXY_SERVICE_NAME:-}" ]; then
    stop_disable_remove_service "$NGROK_PROXY_SERVICE_NAME"
    ok "已移除 ${NGROK_PROXY_SERVICE_NAME}"
  fi

  if [ -n "${NGROK_MUX_SERVICE_NAME:-}" ]; then
    stop_disable_remove_service "$NGROK_MUX_SERVICE_NAME"
    ok "已移除 ${NGROK_MUX_SERVICE_NAME}"
  fi

  if [ -n "${FB_CF_SERVICE_NAME:-}" ]; then
    stop_disable_remove_service "$FB_CF_SERVICE_NAME"
    ok "已移除 ${FB_CF_SERVICE_NAME}"
  fi

  if [ -n "${FB_SERVICE_NAME:-}" ]; then
    stop_disable_remove_service "$FB_SERVICE_NAME"
    ok "已移除 ${FB_SERVICE_NAME}"
  fi

  if [ -n "${SB_SERVICE_NAME:-}" ]; then
    stop_disable_remove_service "$SB_SERVICE_NAME"
    ok "已移除 ${SB_SERVICE_NAME}"
  fi

  rm -rf "$SB_DIR"
  rm -rf "$FB_WORK_DIR"
  rm -f "$STATE_FILE"
  [ -n "${INFO_FILE:-}" ] && rm -f "$INFO_FILE"
  [ -n "${CLASH_FILE:-}" ] && rm -f "$CLASH_FILE"
  [ -n "${SINGBOX_CLIENT_FILE:-}" ] && rm -f "$SINGBOX_CLIENT_FILE"
  [ -n "${DIRECT_CLASH_FILE:-}" ] && rm -f "$DIRECT_CLASH_FILE"
  [ -n "${DIRECT_SINGBOX_CLIENT_FILE:-}" ] && rm -f "$DIRECT_SINGBOX_CLIENT_FILE"
  [ -n "${NGROK_CLASH_FILE:-}" ] && rm -f "$NGROK_CLASH_FILE"
  [ -n "${NGROK_SINGBOX_CLIENT_FILE:-}" ] && rm -f "$NGROK_SINGBOX_CLIENT_FILE"
  rm -f "$BOOTSTRAP_CERT_FILE"
  rm -f "/usr/local/bin/${QUICK_CMD}"
  rm -f "$INSTALLED_SCRIPT"
}

remove_cf_side() {
  if [ -n "${CF_SERVICE_NAME:-}" ]; then
    local service_file launcher_file
    service_file=$(service_file_path "$CF_SERVICE_NAME")
    launcher_file=$(service_launcher_file "$CF_SERVICE_NAME")
    if { [ -f "$service_file" ] && grep -q "CFPROXY-MANAGED" "$service_file"; } \
      || { [ -f "$launcher_file" ] && grep -q "CFPROXY-MANAGED" "$launcher_file"; }; then
      stop_disable_remove_service "$CF_SERVICE_NAME"
      ok "已移除 ${CF_SERVICE_NAME}"
    else
      warn "${CF_SERVICE_NAME} 不是本脚本接管的服务，已跳过删除。"
    fi
  fi

  if [ "$(current_auth_mode)" = "cert" ] && [ -n "${TUNNEL_NAME:-}" ] && [ "$TUNNEL_UUID_CF" != "token-mode" ]; then
    "$CF_BIN" tunnel route dns delete "$TUNNEL_DOMAIN" >/dev/null 2>&1 || true
    "$CF_BIN" tunnel delete "$TUNNEL_NAME" >/dev/null 2>&1 || true
    ok "已尝试删除 Cloudflare 后台隧道：${TUNNEL_NAME}"
  else
    warn "当前不是 cert 全自动模式，或无隧道 UUID；脚本不会强删后台隧道。"
  fi

  rm -f "$CF_CONFIG"
}

deploy_new_proxy() {
  local deploy_mode="${1:-cert}"
  if [ -f "$STATE_FILE" ]; then
    warn "检测到当前机器已经有部署记录。若要重装，请先走卸载。"
    return
  fi

  prompt_alias
  case "$deploy_mode" in
    cert)
      set_current_auth_mode "cert"
      require_cert
      ;;
    token)
      set_current_auth_mode "token"
      prompt_token_value
      ;;
    *)
      fail "未知部署模式：$deploy_mode"
      ;;
  esac
  prompt_protocol

  TUNNEL_NAME="${CURRENT_ALIAS}-${DOMAIN_SUFFIX}"
  TUNNEL_DOMAIN="${CURRENT_ALIAS}-${DOMAIN_SUFFIX}.${MAIN_DOMAIN}"
  if [ "$deploy_mode" = "token" ]; then
    prompt_token_hostname
  fi
  PROXY_UUID=$(rand_uuid)
  PROXY_PORT=$(pick_port)
  WS_PATH="/${PROXY_UUID%%-*}-${PROXY_PROTOCOL}"

  echo ""
  echo -e "${BLUE}========== 即将部署 ==========${RESET}"
  echo "认证模式    : ${deploy_mode}"
  echo "别名        : ${CURRENT_ALIAS}"
  echo "隧道名称    : ${TUNNEL_NAME}"
  echo "隧道域名    : ${TUNNEL_DOMAIN}"
  echo "协议        : ${PROXY_PROTOCOL}-ws"
  echo "本地端口    : ${PROXY_PORT}"
  echo "推荐入口    : ${CLIENT_SERVER}:${CLIENT_PORT}"
  echo "直连入口    : ${TUNNEL_DOMAIN}:${DIRECT_PORT}"
  echo -e "${BLUE}==============================${RESET}"
  read -r -p "回车立即开始部署，输入 n 取消：" confirm
  [[ "${confirm:-}" =~ ^[Nn]$ ]] && { destroy_cert >/dev/null 2>&1 || true; warn "已取消。"; return; }

  info "[1/6] 安装 sing-box"
  install_singbox

  info "[2/6] 写入 sing-box 配置"
  build_singbox_config

  info "[3/6] 启动 sing-box 服务"
  setup_singbox_service

  info "[4/6] 安装 cloudflared"
  install_cloudflared

  info "[5/6] 配置/复用 Cloudflare 隧道"
  if setup_cf_tunnel; then
    setup_cloudflared_service
  else
    CF_LAST_HEALTH="CF 固定隧道配置失败：已保留 sing-box，可走公网直连 / ngrok"
    CF_SERVICE_NAME=""
    CF_RUN_MODE="${CF_RUN_MODE:-failed}"
    TUNNEL_UUID_CF="${TUNNEL_UUID_CF:-not-ready}"
    warn "CF 固定隧道配置未成功，但不会中断部署；后续可在面板 4 里生成公网配置或启用 ngrok。"
  fi
  setup_public_direct_fallback
  destroy_cert

  info "[6/6] 生成客户端配置文件"
  generate_client_files
  save_state
  if [ "${ENABLE_TEMP_FILEBROWSER}" = "on" ]; then
    info "[附加] 启动临时 FileBrowser 下载页（根目录：$(effective_fb_root)）"
    setup_temp_filebrowser
  fi
  if [ "${ENABLE_NGROK_FALLBACK}" = "on" ] && [[ "${CF_LAST_HEALTH:-}" != 已连接* ]]; then
    info "[附加] CF 未唤醒，自动尝试 ngrok 兜底"
    enable_ngrok_fallback
  fi
  register_quick_cmd
  show_links_brief

  echo ""
  if [[ "${CF_LAST_HEALTH:-}" == 已连接* ]]; then
    ok "全部完成，隧道已在线。"
  else
    warn "部署流程已完成，但隧道当前健康状态为：${CF_LAST_HEALTH:-未检测}。请不要只看 CF 后台“已创建”，要以是否出现 Registered tunnel connection 为准。"
    warn "下一步建议：回到面板选择 4，先做公网 IP 入站探测；如果公网不可达，再切 ngrok 临时模式。"
  fi
  echo "文件如下："
  echo "- ${INFO_FILE}"
  echo "- ${CLASH_FILE}"
  echo "- ${SINGBOX_CLIENT_FILE}"
  [ -f "${DIRECT_CLASH_FILE:-}" ] && echo "- 公网直连 Clash：${DIRECT_CLASH_FILE}"
  [ -f "${DIRECT_SINGBOX_CLIENT_FILE:-}" ] && echo "- 公网直连 sing-box：${DIRECT_SINGBOX_CLIENT_FILE}"
  [ -f "${NGROK_CLASH_FILE:-}" ] && echo "- ngrok Clash：${NGROK_CLASH_FILE}"
  [ -f "${NGROK_SINGBOX_CLIENT_FILE:-}" ] && echo "- ngrok sing-box：${NGROK_SINGBOX_CLIENT_FILE}"
  if [ "${FB_ENABLED_STATE:-}" = "on" ]; then
    echo "- FileBrowser 公网：${FB_PUBLIC_URL:-未生成}"
    echo "- FileBrowser trycloudflare（依赖 CF Tunnel）：${FB_QUICK_URL:-未抓取到临时链接}"
    echo "- FileBrowser ngrok 入口（单入口复用时与代理入口相同，点 Visit Site）：${NGROK_FB_URL:-未生成}"
  fi
  if [ "${ENABLE_QUICK_CMD}" = "on" ]; then
    echo "- 快捷命令：${QUICK_CMD}"
  else
    echo "- 启动方式：$(manager_entry_hint)"
  fi
  show_entry_commands
  echo ""
  warn "DNS 初次生效通常需要 1~3 分钟；若直连域名速度一般，优先用推荐入口（cloudflare-ech.com:8443 + Host/SNI=你的隧道域名）。"
}

do_new_proxy() {
  deploy_new_proxy "cert"
}

do_new_proxy_token() {
  deploy_new_proxy "token"
}

deploy_local_proxy_only() {
  if [ -f "$STATE_FILE" ]; then
    return 0
  fi

  load_state
  if [ -f "$STATE_FILE" ]; then
    return 0
  fi

  warn "当前没有部署记录，将创建本地 sing-box 基础代理，不创建 CF 固定隧道。"
  prompt_alias
  set_current_auth_mode "local"
  DEPLOY_AUTH_MODE="local"
  CF_RUN_MODE="skipped"
  CF_LAST_HEALTH="已跳过 CF：当前使用公网直连 / ngrok 兜底"
  TUNNEL_NAME="${CURRENT_ALIAS}-${DOMAIN_SUFFIX}"
  TUNNEL_DOMAIN="${CURRENT_ALIAS}-${DOMAIN_SUFFIX}.${MAIN_DOMAIN}"
  TUNNEL_UUID_CF="skipped"
  prompt_protocol
  PROXY_UUID=$(rand_uuid)
  PROXY_PORT=$(pick_port)
  WS_PATH="/${PROXY_UUID%%-*}-${PROXY_PROTOCOL}"

  echo ""
  echo -e "${BLUE}========== 即将创建本地代理 ==========${RESET}"
  echo "别名        : ${CURRENT_ALIAS}"
  echo "协议        : ${PROXY_PROTOCOL}-ws"
  echo "本地端口    : ${PROXY_PORT}"
  echo "用途        : 公网直连 / ngrok 兜底"
  echo -e "${BLUE}======================================${RESET}"
  read -r -p "回车立即创建，输入 n 取消：" confirm
  [[ "${confirm:-}" =~ ^[Nn]$ ]] && { warn "已取消。"; return 1; }

  install_singbox
  build_singbox_config
  setup_singbox_service
  generate_client_files
  save_state
  [ "${ENABLE_TEMP_FILEBROWSER}" = "on" ] && setup_temp_filebrowser
  ok "本地代理基础服务已创建。现在可生成公网直连配置或启用 ngrok。"
}

ensure_local_proxy_for_fallback() {
  if has_deployment; then
    return 0
  fi
  deploy_local_proxy_only
}

regen_client_files() {
  require_deployment || return 0
  generate_client_files
  show_links_brief
}

purge_local_mgmt_cred_menu() {
  echo ""
  read -r -p "确认彻底删除本地管理凭证痕迹（一次性密钥文件 + 当前 cert.pem）吗？回车确认 / n 取消：" c
  [[ "${c:-}" =~ ^[Nn]$ ]] && { warn "已取消。"; return; }
  purge_local_mgmt_cred
}

uninstall_all() {
  require_deployment || return 0

  echo ""
  echo "1. 只卸载脚本面板 + sing-box（保留 CF 隧道）"
  echo "2. 连 Cloudflare 隧道/服务一起清理"
  echo "0. 返回"
  read -r -p "请输入数字（默认 1）: " choice

  case "${choice:-1}" in
    0) return ;;
    1)
      read -r -p "确认只卸载 sing-box 和脚本吗？回车确认 / n 取消：" c1
      [[ "${c1:-}" =~ ^[Nn]$ ]] && { warn "已取消。"; return; }
      remove_proxy_side
      ok "已卸载脚本面板 + sing-box，Cloudflare 隧道已保留。"
      ;;
    2)
      read -r -p "确认连 Cloudflare 也一起卸载？回车确认 / n 取消：" c2
      [[ "${c2:-}" =~ ^[Nn]$ ]] && { warn "已取消。"; return; }
      if [ "$(current_auth_mode)" = "cert" ]; then
        require_cert
      fi
      remove_cf_side
      destroy_cert
      remove_proxy_side
      ok "已完成完整卸载。"
      ;;
    *)
      warn "无效输入。"
      ;;
  esac
}

generate_public_direct_without_probe_menu() {
  ensure_local_proxy_for_fallback || return 0
  setup_public_direct_fallback "force"
  show_links_brief
}

fallback_menu() {
  while true; do
    echo ""
    echo -e "${BLUE}========== 兜底 / 故障处理 ==========${RESET}"
    if has_deployment; then
      echo "CF 健康       : ${CF_LAST_HEALTH:-未检测}"
    else
      echo "CF 健康       : ${STARTUP_CF_EDGE_STATUS:-未检测}（未部署）"
    fi
    echo "公网直连      : $(if [ "${DIRECT_PUBLIC_STATE:-}" = "on" ]; then echo "已生成（${DIRECT_PUBLIC_HOST_EFFECTIVE:-未知}:${PROXY_PORT}）"; else echo 未生成; fi)"
    echo "ngrok         : $(if [ "${NGROK_ENABLED_STATE:-}" = "on" ]; then echo "已启用（$(ngrok_proxy_kind_current 2>/dev/null || echo 未知)，${NGROK_PROXY_URL:-未抓取入口}）"; else echo 未启用; fi)"
    echo "FileBrowser   : $(if [ "${FB_ENABLED_STATE:-}" = "on" ]; then echo "已启用"; else echo 未启用; fi)"
    echo "--------------------------------------"
    if [[ "${CF_LAST_HEALTH:-}" != 已连接* ]]; then
      warn "CF 隧道未确认在线：可先探测公网入站；若公网也不通，再切 ngrok。"
    fi
    echo "1. 探测公网 IP 入站，成功后生成公网直连配置"
    echo "2. 跳过探测，直接生成公网直连配置"
    echo "3. 启用 / 刷新 ngrok + FileBrowser 临时模式"
    echo "4. 启用 / 刷新 FileBrowser 下载链接"
    echo "5. 查看当前链接 / 状态"
    echo "0. 返回主菜单"
    echo "======================================"
    read -r -p "请输入数字（默认 1）: " choice
    case "${choice:-1}" in
      1) ensure_local_proxy_for_fallback && probe_public_ip_then_generate_direct ;;
      2) generate_public_direct_without_probe_menu ;;
      3) ensure_local_proxy_for_fallback && enable_ngrok_fallback ;;
      4) ensure_local_proxy_for_fallback && enable_or_refresh_filebrowser_menu ;;
      5) show_status ;;
      0) return 0 ;;
      *) warn "无效输入。" ;;
    esac
  done
}

service_manage_menu() {
  require_deployment || return 0
  while true; do
    echo ""
    echo -e "${BLUE}========== 服务管理 ==========${RESET}"
    echo "1. 重新生成客户端配置"
    echo "2. 重启服务"
    echo "3. 补启动服务（智能修复）"
    echo "4. 手动检查/安装基础组件 + CF 预检"
    echo "0. 返回主菜单"
    echo "================================"
    read -r -p "请输入数字（默认 1）: " choice
    case "${choice:-1}" in
      1) regen_client_files ;;
      2) restart_services ;;
      3) ensure_services ;;
      4) manual_check_install_runtime ;;
      0) return 0 ;;
      *) warn "无效输入。" ;;
    esac
  done
}

panel_security_menu() {
  while true; do
    echo ""
    echo -e "${BLUE}========== 面板 / 凭证 ==========${RESET}"
    echo "1. 显示面板安装 / 唤起命令"
    echo "2. 彻底删除本地管理凭证"
    echo "3. 查看 FileBrowser 信息"
    echo "0. 返回主菜单"
    echo "================================="
    read -r -p "请输入数字（默认 1）: " choice
    case "${choice:-1}" in
      1) show_entry_commands ;;
      2) purge_local_mgmt_cred_menu ;;
      3) show_filebrowser_info ;;
      0) return 0 ;;
      *) warn "无效输入。" ;;
    esac
  done
}

startup_prepare_runtime
startup_cf_edge_precheck
show_boot_log
load_state
register_quick_cmd

while true; do
  echo ""
  echo -e "${GREEN}========== CF Proxy 管理器 ==========${RESET}"
  if [ -f "$STATE_FILE" ]; then
    echo "状态：已部署  |  别名：${CURRENT_ALIAS}  |  域名：${TUNNEL_DOMAIN}"
    echo "CF  ：${CF_LAST_HEALTH:-未检测}"
    if [[ "${CF_LAST_HEALTH:-}" != 已连接* ]]; then
      echo -e "${YELLOW}提示：CF 未确认在线，可选 4 进入兜底：公网探测 / 直接公网配置 / ngrok。${RESET}"
    fi
  else
    echo "状态：未部署"
  fi
  echo "CF预检：${STARTUP_CF_EDGE_STATUS}"
  if quick_cmd_installed; then
    echo "快捷：${QUICK_CMD}"
  elif [ "${ENABLE_QUICK_CMD}" = "on" ]; then
    echo "快捷：${QUICK_CMD}（待注册）"
  fi
  echo "===================================="
  echo "1. 新建代理节点（cert 模式）"
  echo "2. 新建代理节点（token 模式 / 已有隧道）"
  echo "3. 查看链接 / 状态"
  echo "4. 兜底 / 故障处理"
  echo "5. 服务管理"
  echo "6. 面板 / 凭证"
  echo "7. 卸载"
  echo "8. 手动检查/安装基础组件 + CF 预检"
  echo "0. 退出"
  echo "===================================="
  read -r -p "请输入数字（默认 3）: " menu

  case "${menu:-3}" in
    1) do_new_proxy ;;
    2) do_new_proxy_token ;;
    3) show_status ;;
    4) fallback_menu ;;
    5) service_manage_menu ;;
    6) panel_security_menu ;;
    7) uninstall_all ;;
    8) manual_check_install_runtime ;;
    0) echo "退出。"; exit 0 ;;
    *) warn "无效输入。" ;;
  esac
done
