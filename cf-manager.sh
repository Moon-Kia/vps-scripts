#!/usr/bin/env bash
set -Eeuo pipefail

# ============================================================
# CF 端口映射管理脚本
# 说明：
# 1. 默认推荐 cert 模式，可自动创建/复用 tunnel 并批量 route dns。
# 2. token 模式用于接入已有 tunnel，本地更新 ingress；Public Hostname 需你后台同步。
# 3. 支持本地一次性管理凭证文件检测，用完即毁。
# 4. 支持 systemd；无 systemctl 时自动降级到进程守护模式。
# ============================================================

# --------------------------- 配置区 ---------------------------
# 【常用设置】优先改这里
MAIN_DOMAIN="214114.xyz"                              # 主域名
DEFAULT_PORTS="80 443 8888"                                # 默认映射端口，空格分隔
TUNNEL_SUFFIX="node"                                  # 隧道名称：别名-后缀
CONFIG_DIR="/root/cfmanager-configs"                  # 用户可查看的信息输出目录
LOCAL_SERVICE_SCHEME="http"                           # 本地服务协议：http / https

# 面板 / 快捷命令
QUICK_CMD="cfm"                                       # 快捷命令，可自定义
ENABLE_QUICK_CMD="on"                                 # on=自动安装快捷命令；off=关闭
BOOTSTRAP_CERT_PATH="/etc/cfmanager/bootstrap/cloudfarecert.pem" # 一次性管理凭证本地路径
AUTO_DESTROY_CERT="on"                                # cert 模式管理操作完成后自动销毁 cert.pem

# 进阶设置
CF_EDGE_PROTOCOL="auto"                               # auto / quic / http2
DNS_CONFLICT_ACTION="auto_suffix"                     # fail / auto_suffix
DNS_CONFLICT_SUFFIX="fix"                             # hostname 冲突时自动追加的后缀
MAX_DNS_CONFLICT_TRIES=8                               # 自动避让最大次数
TUNNEL_TOKEN=""                                       # token 模式可留空，到时交互输入

# cert 模式可选：
# 1. 推荐留空，首次使用时走本地一次性密钥文件或交互粘贴
# 2. 如确有需要，也可直接把 cert.pem 内容粘到 EOF 中
CERT_PEM_CONTENT=$(cat <<'CERT_EOF'

CERT_EOF
)
# ------------------------------------------------------------

SCRIPT_VERSION="2026.04.18-r1"
WORK_DIR="/etc/cfmanager"
INSTALL_DIR="/usr/local/lib/cfmanager"
INSTALLED_SCRIPT="${INSTALL_DIR}/cfmanager.sh"
STATE_FILE="${WORK_DIR}/state.env"
CF_WORK_DIR="${WORK_DIR}/cloudflared"
CF_CONFIG="${CF_WORK_DIR}/config.yml"
TOKEN_FILE="${WORK_DIR}/tunnel.token"
RUN_DIR="${WORK_DIR}/run"
BOOTSTRAP_DIR="${WORK_DIR}/bootstrap"
BOOTSTRAP_SCRIPT="${BOOTSTRAP_DIR}/start-services.sh"
BOOTSTRAP_CERT_FILE="${BOOTSTRAP_CERT_PATH}"
BOOTSTRAP_CERT_DIR="$(dirname "$BOOTSTRAP_CERT_FILE")"
CF_DIR="/root/.cloudflared"
CF_BIN="/usr/local/bin/cloudflared"
RUNNER_SCRIPT="${RUN_DIR}/cloudflared-run.sh"

GREEN="\033[32m"
YELLOW="\033[33m"
RED="\033[31m"
BLUE="\033[34m"
CYAN="\033[36m"
RESET="\033[0m"

CURRENT_ALIAS=""
CURRENT_DOMAIN="${MAIN_DOMAIN}"
CURRENT_PORTS=""
TUNNEL_NAME=""
TUNNEL_UUID_CF=""
PORT_HOST_MAP=""
DEPLOY_AUTH_MODE=""
CF_RUN_MODE=""
CF_SERVICE_NAME=""
SERVICE_BACKEND=""
BOOT_HOOK_BACKEND=""
MGMT_CRED_TEMP_WRITTEN="0"
INFO_FILE=""
CONFIG_SNAPSHOT_FILE=""

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
    echo -e "${YELLOW}⚠ 检测到当前为普通用户，正在尝试通过 sudo -i 提权运行面板...${RESET}"
    case "${BASH_SOURCE[0]}" in
      /dev/fd/*|/proc/*/fd/*|/proc/self/fd/*|stdin|-)
        if [ -f "$INSTALLED_SCRIPT" ]; then
          exec sudo -i bash "$INSTALLED_SCRIPT" "$@"
        fi
        fail "当前脚本是临时流式执行，且尚未安装固定副本。请先切到 root，或改用首条安装命令。"
        ;;
      *)
        if [ -f "${BASH_SOURCE[0]}" ]; then
          exec sudo -i bash "${BASH_SOURCE[0]}" "$@"
        elif [ -f "$INSTALLED_SCRIPT" ]; then
          exec sudo -i bash "$INSTALLED_SCRIPT" "$@"
        fi
        ;;
    esac
  fi
  fail "请使用 root 运行此脚本，或为当前用户准备 sudo 后重试。"
fi

mkdir -p "$WORK_DIR" "$CF_WORK_DIR" "$CONFIG_DIR" "$CF_DIR" "$RUN_DIR" "$BOOTSTRAP_DIR" "$BOOTSTRAP_CERT_DIR" "$INSTALL_DIR"
chmod 700 "$WORK_DIR" "$CF_WORK_DIR" "$RUN_DIR" "$BOOTSTRAP_DIR" "$BOOTSTRAP_CERT_DIR" || true

refresh_output_paths() {
  INFO_FILE="${CONFIG_DIR}/mapping_info_${CURRENT_ALIAS}.txt"
  CONFIG_SNAPSHOT_FILE="${CONFIG_DIR}/cloudflared_${CURRENT_ALIAS}.yml"
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

lower() {
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]'
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || fail "缺少命令：$1"
}

ensure_base_tools() {
  local pkgs=()
  command -v curl >/dev/null 2>&1 || pkgs+=(curl)

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

detect_service_backend() {
  # Do not trust systemctl binary alone in containers; PID1 may be dumb-init/supervisord.
  if command -v systemctl >/dev/null 2>&1     && [ -d /run/systemd/system ]     && systemctl is-system-running >/dev/null 2>&1; then
    SERVICE_BACKEND="systemd"
  else
    SERVICE_BACKEND="process"
  fi
}

detect_boot_hook_backend() {
  if [ "$SERVICE_BACKEND" = "systemd" ]; then
    BOOT_HOOK_BACKEND="systemd"
    return
  fi

  if command -v crontab >/dev/null 2>&1 && crontab -l 2>/dev/null | grep -Fq "$BOOTSTRAP_SCRIPT"; then
    BOOT_HOOK_BACKEND="cron"
  elif [ -f /etc/rc.local ] && grep -Fq "$BOOTSTRAP_SCRIPT" /etc/rc.local 2>/dev/null; then
    BOOT_HOOK_BACKEND="rc.local"
  else
    BOOT_HOOK_BACKEND="manual"
  fi
}

detect_service_backend
detect_boot_hook_backend

if [ "$SERVICE_BACKEND" = "process" ]; then
  need_cmd nohup
  warn "检测到当前环境没有可用的 systemd，将自动改用进程守护模式。"
fi

save_state() {
  cat > "$STATE_FILE" <<STATE_EOF
CURRENT_ALIAS=$(printf '%q' "$CURRENT_ALIAS")
CURRENT_DOMAIN=$(printf '%q' "$CURRENT_DOMAIN")
CURRENT_PORTS=$(printf '%q' "$CURRENT_PORTS")
TUNNEL_NAME=$(printf '%q' "$TUNNEL_NAME")
TUNNEL_UUID_CF=$(printf '%q' "$TUNNEL_UUID_CF")
PORT_HOST_MAP=$(printf '%q' "$PORT_HOST_MAP")
DEPLOY_AUTH_MODE=$(printf '%q' "$DEPLOY_AUTH_MODE")
CF_RUN_MODE=$(printf '%q' "$CF_RUN_MODE")
CF_SERVICE_NAME=$(printf '%q' "$CF_SERVICE_NAME")
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
    printf '%s\n' "cert"
  fi
}

set_current_auth_mode() {
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
    | grep -Eo 'https?://[^ '\''\"()<>]+' \
    | awk '
        /cfmanager/ || /cfm/ || /gist\.githubusercontent/ || /raw\.githubusercontent/ || /\.sh(\?|$)/ { print; found=1; exit }
        { if (!first) first=$0 }
        END { if (!found && first) print first }
      ' \
    | head -n1
}

guess_script_install_url() {
  local parent grandparent cmdline url

  if [ -n "${CFM_SCRIPT_URL:-}" ]; then
    printf '%s\n' "$CFM_SCRIPT_URL"
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
  printf '%s\n' "${CFM_SCRIPT_URL:-你的Raw链接}"
}

bootstrap_cert_url() {
  printf '%s\n' "${CFM_CERT_URL:-你的cert链接}"
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

validate_alias() {
  local alias="$1"
  [[ "$alias" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?$ ]]
}

validate_port() {
  local port="$1"
  [[ "$port" =~ ^[0-9]+$ ]] || return 1
  [ "$port" -ge 1 ] && [ "$port" -le 65535 ]
}

normalize_ports_list() {
  local item out=()
  for item in $*; do
    item="$(printf '%s' "$item" | tr -cd '0-9')"
    [ -n "$item" ] || continue
    validate_port "$item" || fail "发现非法端口：$item"
    out+=("$item")
  done
  if [ ${#out[@]} -eq 0 ]; then
    return 0
  fi
  printf '%s\n' "${out[@]}" | sort -n -u | xargs
}

port_map_entries() {
  printf '%s' "${PORT_HOST_MAP:-}" | tr ';' '\n' | awk 'NF'
}

rebuild_current_ports_from_map() {
  local ports
  ports="$(port_map_entries | awk -F= 'NF>=2 {print $1}' | sort -n -u | xargs || true)"
  CURRENT_PORTS="${ports:-}"
}

port_map_get() {
  local port="$1" entry
  while IFS= read -r entry; do
    [ -n "$entry" ] || continue
    if [ "${entry%%=*}" = "$port" ]; then
      printf '%s\n' "${entry#*=}"
      return 0
    fi
  done < <(port_map_entries)
  return 1
}

port_map_set() {
  local port="$1" host="$2" entry new_entries=()
  while IFS= read -r entry; do
    [ -n "$entry" ] || continue
    if [ "${entry%%=*}" != "$port" ]; then
      new_entries+=("$entry")
    fi
  done < <(port_map_entries)
  new_entries+=("${port}=${host}")
  PORT_HOST_MAP="$(printf '%s\n' "${new_entries[@]}" | awk 'NF' | sort -t= -k1,1n | paste -sd';' -)"
  rebuild_current_ports_from_map
}

port_map_del() {
  local port="$1" entry new_entries=()
  while IFS= read -r entry; do
    [ -n "$entry" ] || continue
    if [ "${entry%%=*}" != "$port" ]; then
      new_entries+=("$entry")
    fi
  done < <(port_map_entries)
  if [ ${#new_entries[@]} -eq 0 ]; then
    PORT_HOST_MAP=""
  else
    PORT_HOST_MAP="$(printf '%s\n' "${new_entries[@]}" | awk 'NF' | sort -t= -k1,1n | paste -sd';' -)"
  fi
  rebuild_current_ports_from_map
}

save_token() {
  local token="$1"
  printf '%s\n' "$token" > "$TOKEN_FILE"
  chmod 600 "$TOKEN_FILE"
}

load_token() {
  [ -s "$TOKEN_FILE" ] || return 1
  cat "$TOKEN_FILE"
}

clear_token() {
  rm -f "$TOKEN_FILE"
}

quick_cmd_path() {
  echo "/usr/local/bin/${QUICK_CMD}"
}

quick_cmd_installed() {
  [ -x "$(quick_cmd_path)" ]
}

install_manager_copy() {
  local src="${BASH_SOURCE[0]}" tmp url
  [ "${ENABLE_QUICK_CMD}" = "on" ] || return 0

  if [ "$src" = "$INSTALLED_SCRIPT" ] && [ -f "$INSTALLED_SCRIPT" ]; then
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
      warn "当前脚本是临时流式执行，无法直接复制自身。"
      warn "建议改用“首条安装命令”先把脚本完整落盘到 $INSTALLED_SCRIPT，再启动面板。"
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
  [ "${ENABLE_QUICK_CMD}" = "on" ] || return 0
  local dst tmp
  dst="$(quick_cmd_path)"
  if ! install_manager_copy; then
    return 0
  fi
  tmp=$(mktemp)
  cat > "$tmp" <<WRAP_EOF
#!/usr/bin/env bash
if [ "\$(id -u)" -ne 0 ]; then
  if command -v sudo >/dev/null 2>&1; then
    exec sudo -i bash "$INSTALLED_SCRIPT" "\$@"
  fi
  echo "当前不是 root，且未检测到 sudo。请先切到 root 后再运行 ${QUICK_CMD}。" >&2
  exit 1
fi
exec bash "$INSTALLED_SCRIPT" "\$@"
WRAP_EOF
  chmod 755 "$tmp"
  mv -f "$tmp" "$dst"
  ok "快捷命令已更新：${QUICK_CMD}"
}

lookup_cname() {
  local host="$1"
  if command -v dig >/dev/null 2>&1; then
    dig +short CNAME "$host" 2>/dev/null | sed 's/\.$//' | head -n1
    return 0
  fi
  curl -fsSL -H 'accept: application/dns-json' "https://1.1.1.1/dns-query?name=${host}&type=CNAME" 2>/dev/null \
    | sed -n 's/.*"data":"\([^"]*\)".*/\1/p' | sed 's/\.$//' | head -n1
}

host_already_points_to_current_tunnel() {
  local host="$1" target
  [ -n "${TUNNEL_UUID_CF:-}" ] || return 1
  target="$(lookup_cname "$host" 2>/dev/null || true)"
  [ -n "$target" ] || return 1
  [ "$target" = "${TUNNEL_UUID_CF}.cfargotunnel.com" ]
}

install_cloudflared() {
  local arch url tmpbin
  if [ -x "$CF_BIN" ]; then
    ok "cloudflared 已存在：$($CF_BIN --version 2>/dev/null | head -n1)"
    return
  fi

  case "$(uname -m)" in
    x86_64|amd64) arch="amd64" ;;
    aarch64|arm64) arch="arm64" ;;
    armv7l) arch="arm" ;;
    *) fail "暂不支持当前架构：$(uname -m)" ;;
  esac

  url="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-${arch}"
  tmpbin=$(mktemp)
  info "正在安装 cloudflared (${arch})"
  curl -fL --progress-bar "$url" -o "$tmpbin"
  install -m 755 "$tmpbin" "$CF_BIN"
  rm -f "$tmpbin"
  ok "cloudflared 安装完成。"
}

prompt_alias() {
  local input
  while true; do
    read -r -p "请输入服务器别名（仅支持英文/数字/中间-，例如 hk-1）: " input
    input="$(lower "$input")"
    if validate_alias "$input"; then
      CURRENT_ALIAS="$input"
      refresh_output_paths
      return
    fi
    echo -e "${RED}格式不正确，请重新输入。${RESET}"
  done
}

prompt_ports_for_create() {
  local base extra merged
  base="$(normalize_ports_list "$DEFAULT_PORTS")"
  echo "默认端口：${base:-无}"
  read -r -p "请输入额外需要映射的端口（空格分隔，直接回车则不追加）: " extra
  merged="$(normalize_ports_list "$base $extra")"
  [ -n "$merged" ] || fail "至少需要一个有效端口。"
  CURRENT_PORTS="$merged"
}

prompt_token_value() {
  local val="${TUNNEL_TOKEN:-}"
  if [ -n "$val" ]; then
    read -r -s -p "检测到配置区已填写 token，回车直接使用，或重新输入新的 token：" input_token
    echo ""
    if [ -n "${input_token:-}" ]; then
      val="$input_token"
    fi
  else
    read -r -s -p "请输入 Cloudflare Tunnel Token：" val
    echo ""
  fi
  [ -n "$val" ] || fail "你选择了 token 模式，但没有输入 tunnel token。"
  save_token "$val"
}

prompt_token_tunnel_name() {
  local default_name input
  default_name="${CURRENT_ALIAS}-${TUNNEL_SUFFIX}"
  read -r -p "请输入该 token 对应的 tunnel 名称（仅用于本地记录，默认 ${default_name}）: " input
  TUNNEL_NAME="${input:-$default_name}"
}

find_tunnel_uuid_by_name() {
  "$CF_BIN" tunnel list 2>/dev/null | awk -v name="$1" 'NR>1 && $2==name {print $1; exit}'
}

route_host_with_policy() {
  local desired="$1" output label candidate i

  if output=$("$CF_BIN" tunnel route dns "$TUNNEL_NAME" "$desired" 2>&1); then
    printf '%s\n' "$desired"
    return 0
  fi

  echo "$output"

  if echo "$output" | grep -Eq 'record with that host already exists|already exists'; then
    if host_already_points_to_current_tunnel "$desired"; then
      ok "检测到 ${desired} 已经指向当前 tunnel，直接复用。"
      printf '%s\n' "$desired"
      return 0
    fi

    if [ "$DNS_CONFLICT_ACTION" != "auto_suffix" ]; then
      fail "DNS 记录冲突：${desired} 已存在同名记录。请先删除旧记录，或换别名后重试。"
    fi

    label="${desired%.${CURRENT_DOMAIN}}"
    warn "检测到 hostname 冲突，开始自动避让。"
    for i in $(seq 1 "$MAX_DNS_CONFLICT_TRIES"); do
      if [ "$i" -eq 1 ]; then
        candidate="${label}-${DNS_CONFLICT_SUFFIX}.${CURRENT_DOMAIN}"
      else
        candidate="${label}-${DNS_CONFLICT_SUFFIX}${i}.${CURRENT_DOMAIN}"
      fi
      info "尝试备用域名：$candidate"
      if "$CF_BIN" tunnel route dns "$TUNNEL_NAME" "$candidate" >/dev/null 2>&1; then
        printf '%s\n' "$candidate"
        return 0
      fi
    done

    fail "DNS 冲突自动避让失败。请手动清理旧记录，或换别名后重试。"
  fi

  fail "绑定 DNS 失败：$desired"
}

cleanup_dns_host() {
  local host="$1"
  [ -n "$host" ] || return 0
  "$CF_BIN" tunnel route dns delete "$host" >/dev/null 2>&1 || true
}

cleanup_all_dns_from_state() {
  local entry host
  while IFS= read -r entry; do
    [ -n "$entry" ] || continue
    host="${entry#*=}"
    cleanup_dns_host "$host"
  done < <(port_map_entries)
}

prepare_tunnel_cert_mode() {
  local existing_uuid token_value

  existing_uuid="$(find_tunnel_uuid_by_name "$TUNNEL_NAME")"
  if [ -n "$existing_uuid" ]; then
    TUNNEL_UUID_CF="$existing_uuid"
    ok "发现远端已有同名隧道，直接复用：${TUNNEL_NAME} (${TUNNEL_UUID_CF})"
  else
    info "正在创建隧道：${TUNNEL_NAME}"
    "$CF_BIN" tunnel create "$TUNNEL_NAME" >/tmp/cfmanager_tunnel_create.log 2>&1 || {
      cat /tmp/cfmanager_tunnel_create.log || true
      fail "创建隧道失败，请检查 cert.pem 是否有效。"
    }
    TUNNEL_UUID_CF="$(find_tunnel_uuid_by_name "$TUNNEL_NAME")"
    [ -n "$TUNNEL_UUID_CF" ] || fail "隧道已创建，但未能解析出 UUID。"
    ok "隧道创建成功：${TUNNEL_UUID_CF}"
  fi

  if [ -f "$CF_DIR/${TUNNEL_UUID_CF}.json" ]; then
    CF_RUN_MODE="config"
    clear_token
  else
    warn "本地没有 ${TUNNEL_UUID_CF}.json，尝试自动拉取 tunnel token 运行。"
    token_value="$("$CF_BIN" tunnel token "$TUNNEL_NAME" 2>/dev/null | tr -d '\r' | tail -n1 || true)"
    if [ -n "$token_value" ] && [[ "$token_value" == ey* ]]; then
      save_token "$token_value"
      CF_RUN_MODE="token"
      ok "已切换为 token 运行模式，避免因缺少本地 json 凭证而报错。"
    else
      fail "复用同名隧道时本地缺少 json 凭证，且自动获取 token 失败。你可以删掉远端同名隧道后重试，或手动补上传对应 json。"
    fi
  fi
}

build_port_map_for_current_ports() {
  local port desired final_host
  PORT_HOST_MAP=""
  for port in $CURRENT_PORTS; do
    desired="${CURRENT_ALIAS}-${port}.${CURRENT_DOMAIN}"
    if [ "$(current_auth_mode)" = "cert" ]; then
      final_host="$(route_host_with_policy "$desired")"
    else
      final_host="$desired"
    fi
    port_map_set "$port" "$final_host"
  done
}

generate_cf_config() {
  local port host
  mkdir -p "$CF_WORK_DIR"
  {
    echo "# CFMANAGER-MANAGED"
    if [ "$CF_RUN_MODE" = "config" ]; then
      echo "tunnel: ${TUNNEL_UUID_CF}"
      echo "credentials-file: ${CF_DIR}/${TUNNEL_UUID_CF}.json"
    fi
    echo "ingress:"
    for port in $CURRENT_PORTS; do
      host="$(port_map_get "$port")"
      [ -n "$host" ] || continue
      echo "  - hostname: ${host}"
      echo "    service: ${LOCAL_SERVICE_SCHEME}://127.0.0.1:${port}"
    done
    echo "  - service: http_status:404"
  } > "$CF_CONFIG"

  if [ -n "${CONFIG_SNAPSHOT_FILE:-}" ]; then
    cp -f "$CF_CONFIG" "$CONFIG_SNAPSHOT_FILE"
  fi
}

write_runner_script() {
  cat > "$RUNNER_SCRIPT" <<RUN_EOF
#!/usr/bin/env bash
set -Eeuo pipefail
CF_BIN="${CF_BIN}"
CF_CONFIG="${CF_CONFIG}"
TOKEN_FILE="${TOKEN_FILE}"
RUN_MODE="${CF_RUN_MODE}"
PROTO="${CF_EDGE_PROTOCOL}"
args=(--no-autoupdate --config "\${CF_CONFIG}")
case "\${PROTO}" in
  quic|http2) args+=(--protocol "\${PROTO}") ;;
  *) ;;
esac
if [ "\${RUN_MODE}" = "token" ]; then
  [ -s "\${TOKEN_FILE}" ] || { echo "缺少 token 文件：\${TOKEN_FILE}" >&2; exit 1; }
  token="\$(cat "\${TOKEN_FILE}")"
  exec -a "cfmanager-cloudflared" "\${CF_BIN}" "\${args[@]}" tunnel run --token "\${token}"
fi
exec -a "cfmanager-cloudflared" "\${CF_BIN}" "\${args[@]}" tunnel run
RUN_EOF
  chmod 700 "$RUNNER_SCRIPT"
}

process_is_active() {
  local name="$1"
  local pidfile pid cmdline

  pidfile="$(service_pid_file "$name")"
  [ -s "$pidfile" ] || return 1
  pid=$(cat "$pidfile" 2>/dev/null || true)
  [ -n "$pid" ] || return 1
  kill -0 "$pid" 2>/dev/null || return 1
  cmdline=$(tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null || true)
  [[ "$cmdline" == *"cfmanager-${name}"* ]]
}

write_bootstrap_script() {
  cat > "$BOOTSTRAP_SCRIPT" <<EOF2
#!/usr/bin/env bash
set -e
RUN_DIR="${RUN_DIR}"
process_active() {
  local pidfile="\$1" pid cmdline name
  name="\$(basename "\$pidfile" .pid)"
  [ -s "\$pidfile" ] || return 1
  pid=\$(cat "\$pidfile" 2>/dev/null || true)
  [ -n "\$pid" ] || return 1
  kill -0 "\$pid" 2>/dev/null || return 1
  cmdline=\$(tr '\\0' ' ' < "/proc/\$pid/cmdline" 2>/dev/null || true)
  [[ "\$cmdline" == *"cfmanager-\${name}"* ]]
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
EOF2
  chmod 700 "$BOOTSTRAP_SCRIPT"
}

install_bootstrap_cron() {
  local tmp line
  line="@reboot bash $BOOTSTRAP_SCRIPT >/dev/null 2>&1"
  tmp=$(mktemp)
  crontab -l 2>/dev/null | grep -Fv "$BOOTSTRAP_SCRIPT" > "$tmp" || true
  printf '%s\n' "$line" >> "$tmp"
  crontab "$tmp"
  rm -f "$tmp"
  BOOT_HOOK_BACKEND="cron"
}

install_bootstrap_rc_local() {
  local file="/etc/rc.local" tmp
  if [ ! -f "$file" ]; then
    cat > "$file" <<'EOF3'
#!/usr/bin/env bash
exit 0
EOF3
    chmod 755 "$file"
  fi

  if grep -Fq "$BOOTSTRAP_SCRIPT" "$file" 2>/dev/null; then
    BOOT_HOOK_BACKEND="rc.local"
    return 0
  fi

  tmp=$(mktemp)
  awk -v cmd="bash $BOOTSTRAP_SCRIPT >/dev/null 2>&1" '
    BEGIN { inserted=0 }
    /^exit 0$/ && !inserted {
      print "# >>> CFMANAGER-BOOTSTRAP >>>"
      print cmd
      print "# <<< CFMANAGER-BOOTSTRAP <<<"
      inserted=1
    }
    { print }
    END {
      if (!inserted) {
        print "# >>> CFMANAGER-BOOTSTRAP >>>"
        print cmd
        print "# <<< CFMANAGER-BOOTSTRAP <<<"
        print "exit 0"
      }
    }
  ' "$file" > "$tmp"
  chmod 755 "$tmp"
  mv -f "$tmp" "$file"
  BOOT_HOOK_BACKEND="rc.local"
}

install_bootstrap_hook() {
  [ "$SERVICE_BACKEND" = "process" ] || return 0
  write_bootstrap_script
  if command -v crontab >/dev/null 2>&1; then
    if install_bootstrap_cron; then
      return 0
    fi
  fi
  if install_bootstrap_rc_local; then
    return 0
  fi
  BOOT_HOOK_BACKEND="manual"
  warn "当前环境没有可用的 systemd / crontab / rc.local，已仅保证当前会话可运行；重启后请手动执行：bash $BOOTSTRAP_SCRIPT"
}

remove_bootstrap_hook() {
  local tmp
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
      /# >>> CFMANAGER-BOOTSTRAP >>>/ { skip=1; next }
      /# <<< CFMANAGER-BOOTSTRAP <<</ { skip=0; next }
      !skip { print }
    ' /etc/rc.local > "$tmp"
    chmod 755 "$tmp"
    mv -f "$tmp" /etc/rc.local
  fi
  rm -f "$BOOTSTRAP_SCRIPT"
  BOOT_HOOK_BACKEND="manual"
}

pick_service_name() {
  local base="$1" marker="$2" file
  if [ "$SERVICE_BACKEND" = "systemd" ]; then
    file="$(service_file_path "$base")"
    if [ -f "$file" ]; then
      if grep -q "$marker" "$file"; then
        echo "$base"
      else
        echo "cfmanager-${base}"
      fi
    else
      echo "$base"
    fi
  else
    file="$(service_launcher_file "$base")"
    if [ -f "$file" ]; then
      if grep -q "$marker" "$file"; then
        echo "$base"
      else
        echo "cfmanager-${base}"
      fi
    else
      echo "$base"
    fi
  fi
}

write_process_service() {
  local name="$1" desc="$2" exec_line="$3" launcher
  launcher="$(service_launcher_file "$name")"
  cat > "$launcher" <<EOF4
#!/usr/bin/env bash
# CFMANAGER-MANAGED
# ${desc}
set -e
exec -a "cfmanager-${name}" ${exec_line}
EOF4
  chmod 700 "$launcher"
  install_bootstrap_hook
}

write_systemd_service() {
  local name="$1" desc="$2" exec_line="$3" file
  file="$(service_file_path "$name")"
  cat > "$file" <<EOF5
# CFMANAGER-MANAGED
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
EOF5
  systemctl daemon-reload
}

write_service_definition() {
  if [ "$SERVICE_BACKEND" = "systemd" ]; then
    write_systemd_service "$@"
  else
    write_process_service "$@"
  fi
}

start_process_service() {
  local name="$1" launcher logfile pidfile
  launcher="$(service_launcher_file "$name")"
  logfile="$(service_log_file "$name")"
  pidfile="$(service_pid_file "$name")"
  [ -x "$launcher" ] || fail "启动失败，缺少服务启动脚本：$launcher"
  if process_is_active "$name"; then
    stop_process_service "$name"
  fi
  nohup bash "$launcher" >> "$logfile" 2>&1 &
  echo $! > "$pidfile"
  sleep 2
  if ! process_is_active "$name"; then
    tail -n 50 "$logfile" 2>/dev/null || true
    fail "服务 ${name} 启动失败。"
  fi
}

stop_process_service() {
  local name="$1" pidfile pid
  pidfile="$(service_pid_file "$name")"
  if [ -s "$pidfile" ]; then
    pid=$(cat "$pidfile" 2>/dev/null || true)
    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
      kill "$pid" 2>/dev/null || true
      sleep 1
      kill -9 "$pid" 2>/dev/null || true
    fi
  fi
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

stop_disable_remove_service() {
  local name="$1" file launcher pidfile logfile
  if [ "$SERVICE_BACKEND" = "systemd" ]; then
    file="$(service_file_path "$name")"
    systemctl stop "$name" >/dev/null 2>&1 || true
    systemctl disable "$name" >/dev/null 2>&1 || true
    rm -f "$file"
    systemctl daemon-reload >/dev/null 2>&1 || true
  else
    launcher="$(service_launcher_file "$name")"
    pidfile="$(service_pid_file "$name")"
    logfile="$(service_log_file "$name")"
    stop_process_service "$name"
    rm -f "$launcher" "$pidfile" "$logfile"
    if ! has_process_services; then
      remove_bootstrap_hook
    else
      detect_boot_hook_backend
    fi
  fi
}

setup_cloudflared_service() {
  local exec_line
  write_runner_script
  CF_SERVICE_NAME="$(pick_service_name "cloudflared" "CFMANAGER-MANAGED")"
  if [ "$CF_SERVICE_NAME" != "cloudflared" ]; then
    warn "检测到现有 cloudflared.service 可能已服务于别的项目，已自动改用独立服务：${CF_SERVICE_NAME}.service"
  fi
  exec_line="bash $RUNNER_SCRIPT"
  write_service_definition "$CF_SERVICE_NAME" "CF Manager cloudflared tunnel service" "$exec_line"
  start_service "$CF_SERVICE_NAME"
  if [ "$SERVICE_BACKEND" = "systemd" ]; then
    ok "${CF_SERVICE_NAME}.service 已启动并设置开机自启。"
  else
    ok "${CF_SERVICE_NAME} 已启动（进程守护模式，开机拉起：${BOOT_HOOK_BACKEND}）。"
  fi
}

generate_info_file() {
  local port host manual_note
  if [ "$(current_auth_mode)" = "token" ]; then
    manual_note="token 模式说明：脚本已更新本地 ingress，但 Public Hostname / DNS 仍需你到 Zero Trust 后台手动同步。"
  else
    manual_note="cert 模式说明：脚本已自动创建 / 复用 tunnel，并自动绑定 DNS。"
  fi

  {
    echo "=========================================="
    echo "CF 端口映射管理脚本信息"
    echo "脚本版本: ${SCRIPT_VERSION}"
    echo "别名: ${CURRENT_ALIAS}"
    echo "主域名: ${CURRENT_DOMAIN}"
    echo "隧道名称: ${TUNNEL_NAME}"
    echo "隧道 UUID: ${TUNNEL_UUID_CF:-未记录}"
    echo "认证模式: $(current_auth_mode)"
    echo "运行模式: ${CF_RUN_MODE}"
    echo "本地服务协议: ${LOCAL_SERVICE_SCHEME}"
    echo "服务后端: ${SERVICE_BACKEND}"
    if [ "$SERVICE_BACKEND" = "process" ]; then
      echo "开机拉起: ${BOOT_HOOK_BACKEND}"
    fi
    echo "快捷命令: $(if quick_cmd_installed; then echo "$QUICK_CMD"; else echo "未安装"; fi)"
    echo "面板本体: ${INSTALLED_SCRIPT}"
    echo "保底唤起: bash ${INSTALLED_SCRIPT}"
    echo "------------------------------------------"
    echo "端口映射清单:"
    for port in $CURRENT_PORTS; do
      host="$(port_map_get "$port")"
      echo "- 本地 ${LOCAL_SERVICE_SCHEME}://127.0.0.1:${port}"
      echo "  => https://${host}"
    done
    echo "------------------------------------------"
    echo "$manual_note"
    echo "配置快照: ${CONFIG_SNAPSHOT_FILE}"
    echo "信息文件: ${INFO_FILE}"
    echo "=========================================="
  } > "$INFO_FILE"
}

generate_artifacts() {
  mkdir -p "$CONFIG_DIR"
  refresh_output_paths
  generate_cf_config
  generate_info_file
  ok "信息文件已生成：${CONFIG_DIR}"
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
  quick_path="$(quick_cmd_path)"
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
  echo "首条安装命令（不带密钥）："
  bootstrap_install_command
  echo ""
  echo "首条安装命令（带一次性密钥）："
  bootstrap_install_command_with_cert
  echo ""
  if bootstrap_cert_ready; then
    echo "当前状态   : 已检测到本地一次性管理凭证文件：${BOOTSTRAP_CERT_FILE}"
  elif [ -s "$CF_DIR/cert.pem" ]; then
    echo "当前状态   : 已检测到运行中的管理凭证文件：${CF_DIR}/cert.pem"
  else
    echo "当前状态   : 未检测到本地管理凭证文件"
  fi
  echo "普通用户提示：若当前账号具备 sudo，也可直接执行上述入口，脚本会自动尝试提权。"
  echo -e "${BLUE}==============================${RESET}"
}

show_boot_log() {
  echo ""
  echo -e "${BLUE}CF 端口映射管理器启动中${RESET}"
  echo "脚本版本 : ${SCRIPT_VERSION}"
  echo "服务后端 : ${SERVICE_BACKEND}"
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
    echo "临时凭证 : 已检测到本地管理凭证文件，建议尽快完成首次 cert 模式操作后自动销毁。"
  fi
  echo "脚本来源 : ${BASH_SOURCE[0]}"
}

require_deployment() {
  if [ ! -f "$STATE_FILE" ]; then
    warn "当前还没有部署记录，请先执行 1（cert）或 2（token）新建 / 接入隧道。"
    return 1
  fi
  return 0
}

deploy_new_tunnel() {
  local mode="$1"
  if [ -f "$STATE_FILE" ]; then
    warn "检测到当前机器已经有部署记录。若要重装，请先走卸载。"
    return
  fi

  prompt_alias
  prompt_ports_for_create
  CURRENT_DOMAIN="$MAIN_DOMAIN"

  case "$mode" in
    cert)
      set_current_auth_mode "cert"
      require_cert
      TUNNEL_NAME="${CURRENT_ALIAS}-${TUNNEL_SUFFIX}"
      ;;
    token)
      set_current_auth_mode "token"
      prompt_token_value
      prompt_token_tunnel_name
      TUNNEL_UUID_CF="token-mode"
      CF_RUN_MODE="token"
      ;;
    *)
      fail "未知模式：$mode"
      ;;
  esac

  echo ""
  echo -e "${BLUE}========== 即将部署 ==========${RESET}"
  echo "认证模式    : ${mode}"
  echo "别名        : ${CURRENT_ALIAS}"
  echo "主域名      : ${CURRENT_DOMAIN}"
  echo "隧道名称    : ${TUNNEL_NAME}"
  echo "默认端口    : ${CURRENT_PORTS}"
  echo -e "${BLUE}==============================${RESET}"
  read -r -p "回车立即开始部署，输入 n 取消：" confirm
  [[ "${confirm:-}" =~ ^[Nn]$ ]] && { destroy_cert >/dev/null 2>&1 || true; warn "已取消。"; return; }

  info "[1/4] 安装 cloudflared"
  install_cloudflared

  info "[2/4] 准备 tunnel"
  if [ "$mode" = "cert" ]; then
    prepare_tunnel_cert_mode
  fi

  info "[3/4] 生成映射配置"
  build_port_map_for_current_ports
  generate_artifacts

  info "[4/4] 启动 cloudflared 服务"
  setup_cloudflared_service
  save_state
  register_quick_cmd
  destroy_cert

  if [ "$mode" = "token" ]; then
    warn "token 模式不会替你自动创建 Public Hostname / DNS，请按信息文件中的域名到 Zero Trust 后台补上。"
  fi

  ok "全部完成。"
  echo "文件如下："
  echo "- ${INFO_FILE}"
  echo "- ${CONFIG_SNAPSHOT_FILE}"
  echo "- 面板入口：$(manager_entry_hint)"
  show_entry_commands
}

do_new_tunnel_cert() {
  deploy_new_tunnel cert
}

do_new_tunnel_token() {
  deploy_new_tunnel token
}

manage_ports() {
  local sub_choice add_ports del_ports port desired final_host old_host
  require_deployment || return 0

  echo ""
  echo -e "当前已映射端口: ${GREEN}[${CURRENT_PORTS:-无}]${RESET}"
  echo "1. 增加映射端口"
  echo "2. 关闭已有端口"
  echo "0. 返回"
  read -r -p "请选择（默认 1）: " sub_choice

  case "${sub_choice:-1}" in
    0) return ;;
    1)
      read -r -p "请输入要【增加】的端口（空格隔开）: " add_ports
      add_ports="$(normalize_ports_list "$add_ports")"
      [ -n "$add_ports" ] || { warn "没有输入任何有效端口。"; return; }
      if [ "$(current_auth_mode)" = "cert" ]; then
        require_cert
      fi
      for port in $add_ports; do
        if port_map_get "$port" >/dev/null 2>&1; then
          warn "端口 ${port} 已存在，已跳过。"
          continue
        fi
        desired="${CURRENT_ALIAS}-${port}.${CURRENT_DOMAIN}"
        if [ "$(current_auth_mode)" = "cert" ]; then
          final_host="$(route_host_with_policy "$desired")"
        else
          final_host="$desired"
        fi
        port_map_set "$port" "$final_host"
        ok "已加入映射：${port} -> ${final_host}"
      done
      ;;
    2)
      read -r -p "请输入要【关闭】的端口（空格隔开）: " del_ports
      del_ports="$(normalize_ports_list "$del_ports")"
      [ -n "$del_ports" ] || { warn "没有输入任何有效端口。"; return; }
      if [ "$(current_auth_mode)" = "cert" ]; then
        require_cert
      fi
      for port in $del_ports; do
        old_host="$(port_map_get "$port" 2>/dev/null || true)"
        if [ -z "$old_host" ]; then
          warn "端口 ${port} 不在当前映射内，已跳过。"
          continue
        fi
        if [ "$(current_auth_mode)" = "cert" ]; then
          cleanup_dns_host "$old_host"
        fi
        port_map_del "$port"
        ok "已移除映射：${port}"
      done
      ;;
    *)
      warn "无效输入。"
      return
      ;;
  esac

  if [ -z "${CURRENT_PORTS:-}" ]; then
    warn "当前已无任何端口映射，配置将只保留 404 回退。"
  fi
  generate_artifacts
  restart_service "$CF_SERVICE_NAME"
  save_state
  register_quick_cmd
  destroy_cert
  if [ "$(current_auth_mode)" = "token" ]; then
    warn "token 模式下请记得到 Zero Trust 后台同步新增/删除 Public Hostname。"
  fi
}

manage_info() {
  local sub_choice new_alias new_domain old_alias old_domain old_tunnel_name old_ports old_map port desired final_host
  require_deployment || return 0

  echo ""
  echo "1. 重命名服务器别名（当前: ${CURRENT_ALIAS}）"
  echo "2. 修改主域名（当前: ${CURRENT_DOMAIN}）"
  echo "0. 返回"
  read -r -p "请选择（默认 1）: " sub_choice

  case "${sub_choice:-1}" in
    0) return ;;
    1)
      read -r -p "请输入新的别名（仅支持英文数字与中间-）: " new_alias
      new_alias="$(lower "$new_alias")"
      validate_alias "$new_alias" || { warn "别名格式不合法。"; return; }
      [ "$new_alias" != "$CURRENT_ALIAS" ] || { warn "新别名与当前相同，无需修改。"; return; }
      ;;
    2)
      read -r -p "请输入新的主域名: " new_domain
      [ -n "${new_domain:-}" ] || { warn "主域名不能为空。"; return; }
      [ "$new_domain" != "$CURRENT_DOMAIN" ] || { warn "新主域名与当前相同，无需修改。"; return; }
      ;;
    *)
      warn "无效输入。"
      return
      ;;
  esac

  old_alias="$CURRENT_ALIAS"
  old_domain="$CURRENT_DOMAIN"
  old_tunnel_name="$TUNNEL_NAME"
  old_ports="$CURRENT_PORTS"
  old_map="$PORT_HOST_MAP"

  if [ "$(current_auth_mode)" = "cert" ]; then
    require_cert
    cleanup_all_dns_from_state
  fi

  if [ "${sub_choice:-1}" = "1" ]; then
    CURRENT_ALIAS="$new_alias"
    refresh_output_paths
    if [ "$(current_auth_mode)" = "cert" ]; then
      TUNNEL_NAME="${CURRENT_ALIAS}-${TUNNEL_SUFFIX}"
      if [ "$TUNNEL_NAME" != "$old_tunnel_name" ]; then
        "$CF_BIN" tunnel delete "$old_tunnel_name" >/dev/null 2>&1 || true
        prepare_tunnel_cert_mode
      fi
    fi
  else
    CURRENT_DOMAIN="$new_domain"
  fi

  if [ "$(current_auth_mode)" = "token" ]; then
    warn "token 模式不会自动修改远端 tunnel 名称或 Public Hostname，请稍后去后台同步。"
  fi

  CURRENT_PORTS="$old_ports"
  PORT_HOST_MAP=""
  for port in $CURRENT_PORTS; do
    desired="${CURRENT_ALIAS}-${port}.${CURRENT_DOMAIN}"
    if [ "$(current_auth_mode)" = "cert" ]; then
      final_host="$(route_host_with_policy "$desired")"
    else
      final_host="$desired"
    fi
    port_map_set "$port" "$final_host"
  done

  generate_artifacts
  restart_service "$CF_SERVICE_NAME"
  save_state
  destroy_cert
  ok "已更新基础信息。"
  if [ "$(current_auth_mode)" = "token" ]; then
    echo "旧别名/域名: ${old_alias} / ${old_domain}"
    echo "旧映射: ${old_map}"
    warn "请在 Zero Trust 后台按新的映射清单同步修改。"
  fi
}

show_status() {
  echo ""
  echo -e "${BLUE}========== 当前状态 ==========${RESET}"
  if [ -f "$STATE_FILE" ]; then
    echo "别名             : ${CURRENT_ALIAS}"
    echo "主域名           : ${CURRENT_DOMAIN}"
    echo "隧道名称         : ${TUNNEL_NAME}"
    echo "隧道 UUID         : ${TUNNEL_UUID_CF:-未记录}"
    echo "认证模式         : $(current_auth_mode)"
    echo "运行模式         : ${CF_RUN_MODE}"
    echo "本地服务协议     : ${LOCAL_SERVICE_SCHEME}"
    echo "端口列表         : ${CURRENT_PORTS:-无}"
    echo "cloudflared 服务 : ${CF_SERVICE_NAME:-未记录}"
    echo "本地管理凭证     : $(if local_mgmt_cred_exists; then echo 已检测到，建议 cert 操作完成后自动销毁，或选 9 删除; else echo 未检测到; fi)"
    echo "服务后端         : ${SERVICE_BACKEND}"
    if [ "$SERVICE_BACKEND" = "process" ]; then
      echo "开机拉起         : ${BOOT_HOOK_BACKEND}"
    fi
    echo ""
    printf 'cloudflared: '
    if [ -n "${CF_SERVICE_NAME:-}" ] && service_is_active "$CF_SERVICE_NAME"; then
      echo -e "${GREEN}运行中${RESET}"
    else
      echo -e "${RED}未运行${RESET}"
    fi
    echo ""
    if [ -f "$INFO_FILE" ]; then
      sed -n '1,220p' "$INFO_FILE"
    fi
    show_entry_commands
  else
    warn "当前没有部署记录。"
    show_entry_commands
  fi
}

restart_services() {
  require_deployment || return 0
  restart_service "$CF_SERVICE_NAME"
  ok "已重启 ${CF_SERVICE_NAME}"
}

ensure_services() {
  require_deployment || return 0
  if ! service_is_active "$CF_SERVICE_NAME"; then
    ensure_service_running "$CF_SERVICE_NAME"
    ok "已补启动 ${CF_SERVICE_NAME}"
  else
    ok "${CF_SERVICE_NAME} 当前运行正常。"
  fi
}

purge_local_mgmt_cred_menu() {
  echo ""
  read -r -p "确认彻底删除本地管理凭证痕迹（一次性密钥文件 + 当前 cert.pem）吗？回车确认 / n 取消：" c
  [[ "${c:-}" =~ ^[Nn]$ ]] && { warn "已取消。"; return; }
  purge_local_mgmt_cred
}

remove_local_side() {
  if [ -n "${CF_SERVICE_NAME:-}" ]; then
    stop_disable_remove_service "$CF_SERVICE_NAME"
    ok "已移除 ${CF_SERVICE_NAME}"
  fi
  clear_token
  rm -rf "$CF_WORK_DIR"
  rm -f "$RUNNER_SCRIPT"
  rm -f "$STATE_FILE"
  rm -f "$INFO_FILE" "$CONFIG_SNAPSHOT_FILE"
  rm -f "$BOOTSTRAP_CERT_FILE" "$CF_DIR/cert.pem"
  rm -f "$(quick_cmd_path)"
  rm -f "$INSTALLED_SCRIPT"
}

remove_remote_side() {
  if [ "$(current_auth_mode)" = "cert" ] && [ -n "${TUNNEL_NAME:-}" ] && [ "${TUNNEL_UUID_CF:-}" != "token-mode" ]; then
    cleanup_all_dns_from_state
    "$CF_BIN" tunnel delete "$TUNNEL_NAME" >/dev/null 2>&1 || true
    ok "已尝试删除 Cloudflare 后台隧道：${TUNNEL_NAME}"
  else
    warn "当前不是 cert 全自动模式，脚本不会强删后台隧道。"
  fi
}

uninstall_all() {
  require_deployment || return 0
  echo ""
  echo "1. 只卸载本机脚本 / cloudflared 服务（保留 CF 后台隧道）"
  echo "2. 连 Cloudflare 隧道 / DNS 一起清理（仅 cert 模式建议）"
  echo "0. 返回"
  read -r -p "请输入数字（默认 1）: " choice
  case "${choice:-1}" in
    0) return ;;
    1)
      read -r -p "确认只卸载本机侧内容吗？回车确认 / n 取消：" c1
      [[ "${c1:-}" =~ ^[Nn]$ ]] && { warn "已取消。"; return; }
      remove_local_side
      ok "已卸载本机脚本 / cloudflared 服务，远端 tunnel 已保留。"
      ;;
    2)
      read -r -p "确认连 Cloudflare 后台也一起清理？回车确认 / n 取消：" c2
      [[ "${c2:-}" =~ ^[Nn]$ ]] && { warn "已取消。"; return; }
      if [ "$(current_auth_mode)" = "cert" ]; then
        require_cert
      fi
      remove_remote_side
      destroy_cert
      remove_local_side
      ok "已完成完整卸载。"
      ;;
    *)
      warn "无效输入。"
      ;;
  esac
}

load_state
show_boot_log
register_quick_cmd

while true; do
  echo ""
  echo -e "${GREEN}========== CF 端口映射管理器 ========== 端口域名格式:服务器别名-端口数字.主域名 ==========${RESET}"
  if [ -f "$STATE_FILE" ]; then
    echo "状态：已部署  |  别名：${CURRENT_ALIAS}  |  隧道：${TUNNEL_NAME}"
  else
    echo "状态：未部署"
  fi
  echo "脚本版本：${SCRIPT_VERSION}"
  if quick_cmd_installed; then
    echo "快捷命令：${QUICK_CMD}（已安装）"
  elif [ "${ENABLE_QUICK_CMD}" = "on" ]; then
    echo "快捷命令：${QUICK_CMD}（自动注册开启）"
  else
    echo "快捷命令：已关闭自动注册"
  fi
  echo "管理凭证：$(if local_mgmt_cred_exists; then echo 已检测到本地一次性密钥/运行中 cert; else echo 未检测到; fi)"
  echo "========================================"
  echo "1. 新建 / 接管隧道（cert 模式，全自动）"
  echo "2. 接入已有隧道（token 模式，半自动）"
  echo "3. 管理端口映射"
  echo "4. 管理其他信息（别名 / 主域名）"
  echo "5. 查看状态 / 映射信息"
  echo "6. 重启服务"
  echo "7. 补启动服务（智能修复）"
  echo "8. 显示安装 / 唤起命令"
  echo "9. 彻底删除本地管理凭证"
  echo "10. 卸载"
  echo "0. 退出"
  echo "========================================"
  read -r -p "请输入数字（默认 5）: " menu

  case "${menu:-5}" in
    1) do_new_tunnel_cert ;;
    2) do_new_tunnel_token ;;
    3) manage_ports ;;
    4) manage_info ;;
    5) show_status ;;
    6) restart_services ;;
    7) ensure_services ;;
    8) show_entry_commands ;;
    9) purge_local_mgmt_cred_menu ;;
    10) uninstall_all ;;
    0) echo "退出。"; exit 0 ;;
    *) warn "无效输入。" ;;
  esac
done
