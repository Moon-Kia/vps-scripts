#!/usr/bin/env bash
set -Eeuo pipefail

# ============================================================
# FileBrowser 一键安装 + 临时链接/固定隧道/ngrok 兜底管理脚本
# 默认回车：Cloudflare trycloudflare 临时链接
# 快捷命令：fb
# ============================================================

# --------------------------- 配置区 ---------------------------
MAIN_DOMAIN="214114.xyz"                 # cert 固定隧道主域名
SERVER_ALIAS=""                          # 留空运行时询问；固定隧道域名 fb-别名.主域名
HOST_PREFIX="fb"                         # 固定隧道 hostname/tunnel 前缀
FB_USER="${FB_USER:-admin}"                  # FileBrowser 用户名
FB_PASS="${FB_PASS:-}"                  # FileBrowser 密码；少于 12 位会提示重新输入
FB_PORT=8888                              # FileBrowser 本地端口；0=随机
FB_ADDR="127.0.0.1"                      # 建议本地监听；公网直连才改 0.0.0.0
FB_ROOT="/"                              # FileBrowser 根目录
DB_PATH="/etc/fbpanel/filebrowser.db"     # FileBrowser 数据库
INFO_FILE="/root/filebrowser_panel_info.txt"
QUICK_CMD="fb"                           # 面板快捷命令
DEFAULT_PANEL_CHOICE="1"                 # 1=临时链接；回车默认
AUTO_NGROK_ON_QUICK_FAIL="on"            # trycloudflare 抓不到时自动尝试 ngrok
ENABLE_QUICK_CMD="on"                    # on=注册快捷命令
CHECK_CF_EDGE_ON_START="first"           # first=首次启动自动测 CF 7844；cached=按缓存刷新；on=每次测；off=不测
CF_EDGE_PRECHECK_CACHE_SECONDS=86400      # cached 模式缓存秒数
DIRECT_PUBLIC_HOST=""                    # 公网直连地址；留空自动探测 IPv4
ENABLE_UPTIMEROBOT_PROBE="on"            # on=用 UptimeRobot 从外部探测 公网IP:端口
UPTIMEROBOT_API_KEY="${UPTIMEROBOT_API_KEY:-}" # Main API key；可留空改用文件/环境变量
UPTIMEROBOT_API_KEY_FILE="/etc/fbpanel/uptimerobot_api_key.txt"
UPTIMEROBOT_PROBE_WAIT_SECONDS=120
UPTIMEROBOT_PROBE_INTERVAL=300
UPTIMEROBOT_PROBE_TIMEOUT=10
UPTIMEROBOT_DELETE_AFTER_PROBE="on"

# Cloudflare 固定隧道可选
CF_TUNNEL_TOKEN=""                       # token 固定隧道；留空运行时输入
TOKEN_TUNNEL_DOMAIN=""                   # token 模式域名；留空运行时输入/默认
CERT_PEM_CONTENT=$(cat <<'CERT_EOF'

CERT_EOF
)
AUTO_DESTROY_CERT="on"                   # cert 操作完成后删除 cert.pem
DNS_CONFLICT_ACTION="auto_suffix"         # auto_suffix/fail
DNS_CONFLICT_SUFFIX="fix"
MAX_DNS_CONFLICT_TRIES=8
CF_EDGE_PROTOCOL="auto"                  # auto/quic/http2
QUICK_TUNNEL_TIMEOUT=45

# ngrok 兜底：一行一个 authtoken；脚本会自动轮询
NGROK_AUTHTOKEN_POOL="${NGROK_AUTHTOKEN_POOL:-}"
NGROK_REGION=""                          # 留空自动；可填 us/eu/ap/jp 等
NGROK_TRY_TIMEOUT=30
# ------------------------------------------------------------

SCRIPT_VERSION="2026.05.07-fb-r5"
WORK_DIR="/etc/fbpanel"
INSTALL_DIR="/usr/local/lib/fbpanel"
INSTALLED_SCRIPT="${INSTALL_DIR}/fbpanel.sh"
STATE_FILE="${WORK_DIR}/state.env"
RUN_DIR="${WORK_DIR}/run"
BOOTSTRAP_SCRIPT="${WORK_DIR}/start-services.sh"
LOGIN_AUTOSTART_FILE="/etc/profile.d/fbpanel-autostart.sh"
CF_DIR="/root/.cloudflared"
CF_CONFIG="${WORK_DIR}/cloudflared-config.yml"
CF_BIN="/usr/local/bin/cloudflared"
FB_BIN="/usr/local/bin/filebrowser"
NGROK_BIN="/usr/local/bin/ngrok"
FB_SERVICE_NAME="fbpanel-filebrowser"
CF_SERVICE_NAME="fbpanel-cloudflared"
NGROK_SERVICE_NAME="fbpanel-ngrok"
SERVICE_BACKEND=""
DEPLOY_MODE=""
CURRENT_ALIAS=""
TUNNEL_NAME=""
TUNNEL_DOMAIN=""
TUNNEL_UUID_CF=""
CF_RUNTIME_MODE=""
QUICK_URL=""
NGROK_URL=""
PUBLIC_URL=""
PUBLIC_HOST_EFFECTIVE=""
NGROK_TOKEN_FINGERPRINT=""
FB_PORT_EFFECTIVE=""
BOOT_HOOK_BACKEND="manual"
STARTUP_CF_EDGE_STATUS="未检测"

GREEN="\033[32m"; YELLOW="\033[33m"; RED="\033[31m"; BLUE="\033[34m"; RESET="\033[0m"

ok(){ echo -e "${GREEN}✔ $*${RESET}"; }
warn(){ echo -e "${YELLOW}⚠ $*${RESET}"; }
info(){ echo -e "${BLUE}➜ $*${RESET}"; }
fail(){ echo -e "${RED}✘ $*${RESET}" >&2; exit 1; }
trap 'echo -e "${RED}脚本执行失败（第 $LINENO 行）。${RESET}" >&2' ERR

need_root(){
  if [ "$(id -u)" -ne 0 ]; then
    if command -v sudo >/dev/null 2>&1; then exec sudo bash "$0" "$@"; fi
    fail "请用 root 运行，或安装 sudo。"
  fi
}

service_file_path(){ echo "/etc/systemd/system/$1.service"; }
service_launcher_file(){ echo "${RUN_DIR}/$1.sh"; }
service_pid_file(){ echo "${RUN_DIR}/$1.pid"; }
service_log_file(){ echo "${RUN_DIR}/$1.log"; }

service_recent_log(){
  local name="$1" lines="${2:-160}" logfile output
  if [ "$SERVICE_BACKEND" = "systemd" ] && command -v journalctl >/dev/null 2>&1; then
    output="$(journalctl -u "$name" -n "$lines" --no-pager -o cat 2>/dev/null || true)"
    [ -n "$output" ] && { printf '%s\n' "$output"; return 0; }
  fi
  logfile=$(service_log_file "$name")
  tail -n "$lines" "$logfile" 2>/dev/null || true
}

detect_service_backend(){
  # Do not trust systemctl binary alone in containers; PID1 may be dumb-init/supervisord.
  if command -v systemctl >/dev/null 2>&1     && [ -d /run/systemd/system ]     && systemctl is-system-running >/dev/null 2>&1; then
    SERVICE_BACKEND="systemd"
  else
    SERVICE_BACKEND="process"
  fi
}

port_in_use(){
  local port="$1"
  if command -v ss >/dev/null 2>&1; then ss -ltn 2>/dev/null | awk '{print $4}' | grep -Eq "[:.]${port}$"; return $?; fi
  if command -v netstat >/dev/null 2>&1; then netstat -ltn 2>/dev/null | awk '{print $4}' | grep -Eq "[:.]${port}$"; return $?; fi
  return 1
}

pick_random_port(){
  local p
  for _ in $(seq 1 200); do
    p=$((10000 + RANDOM % 50001))
    port_in_use "$p" || { echo "$p"; return; }
  done
  fail "找不到可用端口。"
}

process_is_active(){
  local name="$1" pidfile pid marker
  pidfile=$(service_pid_file "$name"); marker="fbpanel-${name}"
  if [ -s "$pidfile" ]; then pid=$(cat "$pidfile" 2>/dev/null || true); [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null && return 0; fi
  ps -eo args= 2>/dev/null | grep -F "fbpanel-${name}" | grep -vq grep
}

install_process_bootstrap(){
  [ "$SERVICE_BACKEND" = "process" ] || return 0
  cat > "$BOOTSTRAP_SCRIPT" <<'EOF_BOOT'
#!/usr/bin/env bash
RUN_DIR="/etc/fbpanel/run"
for launcher in "$RUN_DIR"/*.sh; do
  [ -x "$launcher" ] || continue
  name="$(basename "$launcher" .sh)"
  pidfile="$RUN_DIR/${name}.pid"
  logfile="$RUN_DIR/${name}.log"
  if [ -s "$pidfile" ]; then
    pid=$(cat "$pidfile" 2>/dev/null || true)
    [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null && continue
  fi
  nohup bash "$launcher" >> "$logfile" 2>&1 & echo $! > "$pidfile"
done
EOF_BOOT
  chmod 700 "$BOOTSTRAP_SCRIPT"
  if command -v crontab >/dev/null 2>&1; then
    (crontab -l 2>/dev/null | grep -Fv "$BOOTSTRAP_SCRIPT"; echo "@reboot bash $BOOTSTRAP_SCRIPT") | crontab - 2>/dev/null || true
  fi
  if [ -d /etc/profile.d ] && [ -w /etc/profile.d ]; then
    cat > "$LOGIN_AUTOSTART_FILE" <<EOF_LOGIN
# FBPANEL-MANAGED
[ "\$(id -u 2>/dev/null || echo 1)" -eq 0 ] && [ -x "$BOOTSTRAP_SCRIPT" ] && bash "$BOOTSTRAP_SCRIPT" >/dev/null 2>&1 || true
EOF_LOGIN
    chmod 644 "$LOGIN_AUTOSTART_FILE" || true
  fi
  BOOT_HOOK_BACKEND="cron+login"
}

write_process_service(){
  local name="$1" desc="$2" exec_line="$3" launcher
  launcher=$(service_launcher_file "$name")
  cat > "$launcher" <<EOF_RUN
#!/usr/bin/env bash
# FBPANEL-MANAGED
# ${desc}
while true; do
  echo "[\$(date -Is)] starting ${name}: ${exec_line}"
  bash -lc 'exec -a "fbpanel-${name}" ${exec_line}' &
  child=\$!
  wait "\$child"; rc=\$?
  echo "[\$(date -Is)] ${name} exited with \$rc; restart in 5s"
  sleep 5
done
EOF_RUN
  chmod 700 "$launcher"
  install_process_bootstrap
}

write_systemd_service(){
  local name="$1" desc="$2" exec_line="$3" file
  file=$(service_file_path "$name")
  cat > "$file" <<EOF_SERVICE
# FBPANEL-MANAGED
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
EOF_SERVICE
  systemctl daemon-reload
}

write_service_definition(){
  if [ "$SERVICE_BACKEND" = "systemd" ]; then write_systemd_service "$@"; else write_process_service "$@"; fi
}

start_service(){
  local name="$1" logfile pidfile launcher
  if [ "$SERVICE_BACKEND" = "systemd" ]; then
    systemctl enable "$name" >/dev/null 2>&1 || true
    systemctl restart "$name"
    sleep 2
    systemctl is-active --quiet "$name" || { service_recent_log "$name" 80; return 1; }
  else
    launcher=$(service_launcher_file "$name"); logfile=$(service_log_file "$name"); pidfile=$(service_pid_file "$name")
    stop_service "$name" >/dev/null 2>&1 || true
    : > "$logfile"
    nohup bash "$launcher" >> "$logfile" 2>&1 & echo $! > "$pidfile"
    sleep 2
    process_is_active "$name" || { tail -n 80 "$logfile" 2>/dev/null || true; return 1; }
  fi
}

stop_service(){
  local name="$1" pidfile pid
  if [ "$SERVICE_BACKEND" = "systemd" ]; then
    systemctl stop "$name" >/dev/null 2>&1 || true
  else
    pidfile=$(service_pid_file "$name")
    if [ -s "$pidfile" ]; then pid=$(cat "$pidfile" 2>/dev/null || true); [ -n "$pid" ] && kill "$pid" 2>/dev/null || true; rm -f "$pidfile"; fi
    pkill -f "fbpanel-${name}" 2>/dev/null || true
  fi
}

remove_service(){
  local name="$1"
  stop_service "$name" || true
  if [ "$SERVICE_BACKEND" = "systemd" ]; then
    systemctl disable "$name" >/dev/null 2>&1 || true
    rm -f "$(service_file_path "$name")"
    systemctl daemon-reload >/dev/null 2>&1 || true
  else
    rm -f "$(service_launcher_file "$name")" "$(service_pid_file "$name")" "$(service_log_file "$name")"
  fi
}

service_active(){ if [ "$SERVICE_BACKEND" = "systemd" ]; then systemctl is-active --quiet "$1"; else process_is_active "$1"; fi; }

install_self_and_quick(){
  mkdir -p "$INSTALL_DIR" /usr/local/bin "$WORK_DIR" "$RUN_DIR" "$CF_DIR" "$(dirname "$DB_PATH")"
  chmod 700 "$WORK_DIR" "$RUN_DIR" || true
  local src="${BASH_SOURCE[0]}"
  if [ "${ENABLE_QUICK_CMD}" = "on" ]; then
    if [[ "$src" != /dev/fd/* ]] && [ -f "$src" ] && [ "$src" != "$INSTALLED_SCRIPT" ]; then
      install -m 755 "$src" "$INSTALLED_SCRIPT" || true
    fi
    if [ -f "$INSTALLED_SCRIPT" ]; then
      cat > "/usr/local/bin/${QUICK_CMD}" <<EOF_Q
#!/usr/bin/env bash
if [ "\$(id -u)" -ne 0 ] && command -v sudo >/dev/null 2>&1; then
  exec sudo bash "$INSTALLED_SCRIPT" "\$@"
fi
exec bash "$INSTALLED_SCRIPT" "\$@"
EOF_Q
      chmod 755 "/usr/local/bin/${QUICK_CMD}"
    fi
  fi
}

save_state(){
  cat > "$STATE_FILE" <<EOF_STATE
DEPLOY_MODE=$(printf '%q' "$DEPLOY_MODE")
CURRENT_ALIAS=$(printf '%q' "$CURRENT_ALIAS")
TUNNEL_NAME=$(printf '%q' "$TUNNEL_NAME")
TUNNEL_DOMAIN=$(printf '%q' "$TUNNEL_DOMAIN")
TUNNEL_UUID_CF=$(printf '%q' "$TUNNEL_UUID_CF")
CF_RUNTIME_MODE=$(printf '%q' "$CF_RUNTIME_MODE")
QUICK_URL=$(printf '%q' "$QUICK_URL")
NGROK_URL=$(printf '%q' "$NGROK_URL")
PUBLIC_URL=$(printf '%q' "$PUBLIC_URL")
PUBLIC_HOST_EFFECTIVE=$(printf '%q' "$PUBLIC_HOST_EFFECTIVE")
NGROK_TOKEN_FINGERPRINT=$(printf '%q' "$NGROK_TOKEN_FINGERPRINT")
FB_PORT_EFFECTIVE=$(printf '%q' "$FB_PORT_EFFECTIVE")
FB_ROOT=$(printf '%q' "$FB_ROOT")
FB_USER=$(printf '%q' "$FB_USER")
FB_PASS=$(printf '%q' "$FB_PASS")
EOF_STATE
  chmod 600 "$STATE_FILE"
}
load_state(){ [ -f "$STATE_FILE" ] && source "$STATE_FILE" || true; }

arch_name(){ case "$(uname -m)" in x86_64|amd64) echo amd64;; aarch64|arm64) echo arm64;; armv7l) echo arm;; *) fail "不支持架构：$(uname -m)";; esac; }

install_filebrowser(){
  if [ -x "$FB_BIN" ]; then ok "FileBrowser 已存在：$($FB_BIN version 2>/dev/null | head -n1 || true)"; return; fi
  info "正在安装 FileBrowser"
  curl -fsSL https://raw.githubusercontent.com/filebrowser/get/master/get.sh | bash
  [ -x "$FB_BIN" ] || fail "FileBrowser 安装失败。"
}

install_cloudflared(){
  if [ -x "$CF_BIN" ]; then ok "cloudflared 已存在：$($CF_BIN version 2>/dev/null | head -n1 || true)"; return; fi
  local tmp arch; arch=$(arch_name); tmp=$(mktemp)
  info "正在安装 cloudflared (${arch})"
  curl -fL --progress-bar "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-${arch}" -o "$tmp"
  install -m 755 "$tmp" "$CF_BIN"; rm -f "$tmp"
}

install_ngrok(){
  if [ -x "$NGROK_BIN" ]; then ok "ngrok 已存在：$($NGROK_BIN version 2>/dev/null | head -n1 || true)"; return; fi
  local arch url tmpdir; case "$(uname -m)" in x86_64|amd64) arch=amd64;; aarch64|arm64) arch=arm64;; armv7l) arch=arm;; *) fail "不支持 ngrok 架构：$(uname -m)";; esac
  url="https://bin.equinox.io/c/bNyj1mQVY4c/ngrok-v3-stable-linux-${arch}.tgz"; tmpdir=$(mktemp -d)
  info "正在安装 ngrok (${arch})"
  curl -fL --progress-bar "$url" -o "${tmpdir}/ngrok.tgz"
  tar -xzf "${tmpdir}/ngrok.tgz" -C "$tmpdir"
  install -m 755 "${tmpdir}/ngrok" "$NGROK_BIN"; rm -rf "$tmpdir"
}

ensure_fb_password(){
  [[ "$FB_USER" =~ ^[^[:space:]]+$ ]] || fail "FB_USER 不能为空且不能包含空白。"
  if [ "${#FB_PASS}" -lt 12 ]; then
    warn "FileBrowser 新版要求密码至少 12 位。"
    read -r -s -p "请输入新的 FileBrowser 密码: " FB_PASS; echo
    [ "${#FB_PASS}" -ge 12 ] || fail "密码仍不足 12 位。"
  fi
}

setup_filebrowser(){
  install_filebrowser
  ensure_fb_password
  mkdir -p "$(dirname "$DB_PATH")" "$FB_ROOT"
  if [ -z "${FB_PORT_EFFECTIVE:-}" ]; then
    if [ "$FB_PORT" -gt 0 ] && ! port_in_use "$FB_PORT"; then FB_PORT_EFFECTIVE="$FB_PORT"; else FB_PORT_EFFECTIVE=$(pick_random_port); fi
  fi
  stop_service "$FB_SERVICE_NAME" >/dev/null 2>&1 || true
  local bind_addr="$FB_ADDR"
  [ "${DEPLOY_MODE:-}" = "public" ] && bind_addr="0.0.0.0"
  [ -f "$DB_PATH" ] || "$FB_BIN" config init -d "$DB_PATH" >/dev/null 2>&1 || { rm -f "$DB_PATH"; "$FB_BIN" config init -d "$DB_PATH"; }
  "$FB_BIN" config set -a "$bind_addr" -p "$FB_PORT_EFFECTIVE" -r "$FB_ROOT" -d "$DB_PATH" >/dev/null
  "$FB_BIN" users add "$FB_USER" "$FB_PASS" --perm.admin -d "$DB_PATH" >/dev/null 2>&1 \
    || "$FB_BIN" users update "$FB_USER" --password "$FB_PASS" --perm.admin -d "$DB_PATH" >/dev/null 2>&1 || true
  write_service_definition "$FB_SERVICE_NAME" "FileBrowser panel service" "$FB_BIN -d $DB_PATH"
  start_service "$FB_SERVICE_NAME" || fail "FileBrowser 服务启动失败。"
  ok "FileBrowser 已启动：http://${bind_addr}:${FB_PORT_EFFECTIVE}"
}

detect_public_host(){
  local ip url
  if [ -n "${DIRECT_PUBLIC_HOST:-}" ]; then echo "$DIRECT_PUBLIC_HOST"; return 0; fi
  for url in https://api.ipify.org https://ifconfig.me/ip https://ipv4.icanhazip.com; do
    ip="$(curl -4fsS --max-time 6 "$url" 2>/dev/null | tr -d '[:space:]' || true)"
    if [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then echo "$ip"; return 0; fi
  done
  return 1
}

cf_edge_cache_file(){ echo "${RUN_DIR}/cf-edge-precheck.cache"; }

cf_edge_tcp7844_probe(){
  local hosts host ip tried=0 resolved=0
  command -v timeout >/dev/null 2>&1 || return 2
  command -v getent >/dev/null 2>&1 || return 2
  hosts="region1.argotunnel.com region2.argotunnel.com"
  for host in $hosts; do
    while read -r ip; do
      [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || continue
      resolved=1
      tried=$((tried + 1))
      timeout 4 bash -lc "cat </dev/null >/dev/tcp/${ip}/7844" >/dev/null 2>&1 && return 0
      [ "$tried" -ge 4 ] && return 1
    done < <({ getent ahostsv4 "$host" 2>/dev/null || getent hosts "$host" 2>/dev/null; } | awk '{print $1}' | sort -u | head -n 6)
  done
  [ "$resolved" -eq 0 ] && return 2
  return 1
}

startup_cf_edge_precheck(){
  local force="${1:-0}" mode cache now ts status rc
  mode="${CHECK_CF_EDGE_ON_START:-first}"
  cache="$(cf_edge_cache_file)"
  mkdir -p "$RUN_DIR" 2>/dev/null || true

  if [ "$force" != "1" ]; then
    if [ "$mode" = "off" ]; then
      status=$(sed -n '2p' "$cache" 2>/dev/null || true)
      STARTUP_CF_EDGE_STATUS="${status:+${status}（上次记录）}"
      STARTUP_CF_EDGE_STATUS="${STARTUP_CF_EDGE_STATUS:-未检测（已关闭启动预检）}"
      return 0
    fi
    if [ -f "$cache" ]; then
      ts=$(sed -n '1p' "$cache" 2>/dev/null || echo 0)
      status=$(sed -n '2p' "$cache" 2>/dev/null || true)
      if [ -n "$status" ]; then
        if [ "$mode" = "first" ]; then
          STARTUP_CF_EDGE_STATUS="${status}（上次记录）"
          return 0
        fi
        if [ "$mode" = "cached" ]; then
          now=$(date +%s)
          if [ $((now - ts)) -lt "${CF_EDGE_PRECHECK_CACHE_SECONDS:-86400}" ] 2>/dev/null; then
            STARTUP_CF_EDGE_STATUS="${status}（缓存）"
            return 0
          fi
        fi
      fi
    fi
  fi

  info "启动预检：检查 Cloudflare Tunnel Edge 7844 连通性"
  if cf_edge_tcp7844_probe; then rc=0; else rc=$?; fi
  case "$rc" in
    0)
      status="可连通"
      ok "CF/trycloudflare 预检通过：Cloudflare Edge 7844 可连通。"
      ;;
    1)
      status="不可连通：疑似 7844 被拦截"
      warn "CF/trycloudflare 预检失败：当前服务器疑似无法连 Cloudflare Edge 7844。"
      warn "建议优先使用菜单 2 公网探测、3 公网直连、4 ngrok 兜底；固定隧道/trycloudflare 可能创建但打不开。"
      ;;
    *)
      status="未检测：缺少 timeout/getent 或解析失败"
      warn "暂无法完成 CF 预检；可先试菜单 1，失败后用 2/3/4 兜底。"
      ;;
  esac
  STARTUP_CF_EDGE_STATUS="$status"
  { printf '%s\n%s\n' "$(date +%s)" "$status" > "$cache"; chmod 600 "$cache" 2>/dev/null || true; } 2>/dev/null || true
}

cf_edge_known_unreachable(){ [[ "${STARTUP_CF_EDGE_STATUS:-}" == 不可连通* ]]; }

uptimerobot_key(){
  [ -n "${FBPANEL_UPTIMEROBOT_API_KEY:-}" ] && { echo "$FBPANEL_UPTIMEROBOT_API_KEY"; return 0; }
  [ -n "${UPTIMEROBOT_API_KEY:-}" ] && { echo "$UPTIMEROBOT_API_KEY"; return 0; }
  [ -s "${UPTIMEROBOT_API_KEY_FILE:-}" ] && { sed -n '1{s/[[:space:]]//g;p;q;}' "$UPTIMEROBOT_API_KEY_FILE"; return 0; }
  return 1
}

json_value(){ local key="$1"; sed -n "s/.*\"${key}\"[[:space:]]*:[[:space:]]*\"\{0,1\}\([^\",}]*\)\"\{0,1\}.*/\1/p" | head -n1; }
uptimerobot_post(){ local ep="$1" key="$2"; shift 2; curl -fsS --max-time 25 -X POST "https://api.uptimerobot.com/v2/${ep}" -H "Content-Type: application/x-www-form-urlencoded" --data-urlencode "api_key=${key}" --data "format=json" "$@"; }
uptimerobot_delete(){ local key="$1" id="$2"; [ -n "$id" ] || return 0; uptimerobot_post deleteMonitor "$key" --data "id=${id}" >/dev/null 2>&1 || true; }
uptimerobot_create(){
  local key="$1" host="$2" port="$3" resp id friendly
  friendly="fbpanel-${host}-${port}-$(date +%s)"; friendly="$(printf '%s' "$friendly" | tr -c 'A-Za-z0-9_.-' '-')"
  resp="$(uptimerobot_post newMonitor "$key" --data-urlencode "friendly_name=${friendly}" --data-urlencode "url=${host}" --data type=4 --data sub_type=99 --data "port=${port}" --data "interval=${UPTIMEROBOT_PROBE_INTERVAL}" --data "timeout=${UPTIMEROBOT_PROBE_TIMEOUT}" 2>&1)" || { warn "UptimeRobot 创建 monitor 失败：${resp}"; return 1; }
  printf '%s' "$resp" | grep -q '"stat"[[:space:]]*:[[:space:]]*"ok"' || { warn "UptimeRobot 返回失败：${resp}"; return 1; }
  id="$(printf '%s' "$resp" | sed -n 's/.*"id"[[:space:]]*:[[:space:]]*\([0-9][0-9]*\).*/\1/p' | head -1)"
  [ -n "$id" ] || return 1
  echo "$id"
}
uptimerobot_status(){ local key="$1" id="$2" resp; resp="$(uptimerobot_post getMonitors "$key" --data "monitors=${id}" 2>/dev/null || true)"; printf '%s' "$resp" | json_value status; }
probe_public_port(){
  local host="$1" port="$2" key id deadline status
  [ "$ENABLE_UPTIMEROBOT_PROBE" = "on" ] || { warn "公网探测已关闭。"; return 2; }
  key="$(uptimerobot_key 2>/dev/null || true)"; [ -n "$key" ] || { warn "未配置 UptimeRobot API key，无法外部探测。"; return 2; }
  info "UptimeRobot 探测公网入站：${host}:${port}"
  id="$(uptimerobot_create "$key" "$host" "$port")" || return 1
  deadline=$(( $(date +%s) + UPTIMEROBOT_PROBE_WAIT_SECONDS ))
  while [ "$(date +%s)" -lt "$deadline" ]; do
    status="$(uptimerobot_status "$key" "$id" || true)"
    case "$status" in
      2) ok "公网入站探测通过：${host}:${port}"; [ "$UPTIMEROBOT_DELETE_AFTER_PROBE" = "on" ] && uptimerobot_delete "$key" "$id"; return 0 ;;
      8|9) warn "公网入站探测失败：${host}:${port} DOWN"; [ "$UPTIMEROBOT_DELETE_AFTER_PROBE" = "on" ] && uptimerobot_delete "$key" "$id"; return 1 ;;
    esac
    sleep 10
  done
  warn "UptimeRobot 未在 ${UPTIMEROBOT_PROBE_WAIT_SECONDS}s 内给出明确结果。"
  [ "$UPTIMEROBOT_DELETE_AFTER_PROBE" = "on" ] && uptimerobot_delete "$key" "$id"
  return 2
}

ngrok_tokens(){ printf '%s\n' "$NGROK_AUTHTOKEN_POOL" | sed 's/\r$//' | awk 'NF && $1 !~ /^#/ {print $1}'; }
fingerprint(){ local t="$1"; [ "${#t}" -le 12 ] && echo set || printf '%s...%s\n' "${t:0:6}" "${t: -4}"; }
ngrok_region_arg(){ [ -n "$NGROK_REGION" ] && printf -- '--region %q' "$NGROK_REGION" || true; }
ngrok_http_regex(){ echo 'https://[-a-z0-9.]+(\.ngrok-free\.(app|dev)|\.ngrok\.app|\.ngrok\.io)'; }

wait_url_from_log(){
  local logfile="$1" regex="$2" pid="${3:-}" deadline url
  deadline=$(( $(date +%s) + NGROK_TRY_TIMEOUT ))
  while [ "$(date +%s)" -lt "$deadline" ]; do
    if grep -Eq 'ERR_NGROK_|failed to start tunnel|authentication failed|authtoken|limit|too many|exceed' "$logfile" 2>/dev/null; then return 1; fi
    url=$(grep -Eo "$regex" "$logfile" 2>/dev/null | grep -v 'ngrok.com/docs/errors' | tail -n1 || true)
    if [ -n "$url" ]; then
      [ -n "$pid" ] && ! kill -0 "$pid" 2>/dev/null && return 1
      printf '%s\n' "$url"; return 0
    fi
    [ -n "$pid" ] && ! kill -0 "$pid" 2>/dev/null && return 1
    sleep 1
  done
  return 1
}

ngrok_hint(){
  local logfile="$1"
  grep -q 'ERR_NGROK_334' "$logfile" 2>/dev/null && warn "ngrok 334：该账号默认 endpoint 已在其它服务器在线；等旧 agent 断开会自动释放，不主动清理其它服务器。"
  grep -q 'ERR_NGROK_313' "$logfile" 2>/dev/null && warn "ngrok 313：免费计划不能随意指定新子域名。"
}

start_ngrok_fb(){
  install_ngrok
  [ -n "$(ngrok_tokens)" ] || { warn "NGROK_AUTHTOKEN_POOL 为空。"; return 1; }
  local token log pid url qtoken exec_line region; region=$(ngrok_region_arg)
  remove_service "$NGROK_SERVICE_NAME" >/dev/null 2>&1 || true
  while read -r token; do
    [ -n "$token" ] || continue
    log=$(mktemp)
    info "尝试 ngrok token：$(fingerprint "$token")（http -> 127.0.0.1:${FB_PORT_EFFECTIVE}）"
    "$NGROK_BIN" http --authtoken "$token" --log="$log" --log-format=logfmt $region "http://127.0.0.1:${FB_PORT_EFFECTIVE}" >/dev/null 2>&1 & pid=$!
    if url=$(wait_url_from_log "$log" "$(ngrok_http_regex)" "$pid"); then
      kill "$pid" 2>/dev/null || true; sleep 1
      qtoken=$(printf '%q' "$token")
      exec_line="$NGROK_BIN http --authtoken $qtoken --log=$(printf '%q' "$(service_log_file "$NGROK_SERVICE_NAME")") --log-format=logfmt $region http://127.0.0.1:${FB_PORT_EFFECTIVE}"
      write_service_definition "$NGROK_SERVICE_NAME" "FileBrowser ngrok fallback" "$exec_line"
      : > "$(service_log_file "$NGROK_SERVICE_NAME")" 2>/dev/null || true
      start_service "$NGROK_SERVICE_NAME" || true
      NGROK_URL=$(wait_url_from_log "$(service_log_file "$NGROK_SERVICE_NAME")" "$(ngrok_http_regex)" || echo "$url")
      NGROK_TOKEN_FINGERPRINT=$(fingerprint "$token")
      ok "ngrok FileBrowser 入口：${NGROK_URL}（打开后点 Visit Site）"
      rm -f "$log"; return 0
    fi
    ngrok_hint "$log"; tail -n 25 "$log" 2>/dev/null || true
    kill "$pid" 2>/dev/null || true; rm -f "$log"; sleep 1
  done < <(ngrok_tokens)
  warn "ngrok token 池全部未拿到可用 URL。"
  return 1
}

capture_quick_url(){
  local deadline url
  deadline=$(( $(date +%s) + QUICK_TUNNEL_TIMEOUT ))
  while [ "$(date +%s)" -lt "$deadline" ]; do
    url=$(service_recent_log "$CF_SERVICE_NAME" 260 | grep -Eo 'https://[-a-z0-9]+\.trycloudflare\.com' | tail -n1 || true)
    [ -n "$url" ] && { QUICK_URL="$url"; ok "FileBrowser trycloudflare 临时链接：$QUICK_URL"; return 0; }
    sleep 1
  done
  warn "暂未抓取到 trycloudflare 临时链接。"
  service_recent_log "$CF_SERVICE_NAME" 80
  return 1
}

start_quick_tunnel(){
  if cf_edge_known_unreachable; then
    warn "当前 CF 预检为：${STARTUP_CF_EDGE_STATUS}。"
    warn "本次不再等待 trycloudflare；建议菜单 2/3 公网直连，或菜单 4 ngrok 兜底。"
    if [ "$AUTO_NGROK_ON_QUICK_FAIL" = "on" ]; then
      warn "AUTO_NGROK_ON_QUICK_FAIL=on，自动启用 ngrok 兜底。"
      DEPLOY_MODE="ngrok"
      start_ngrok_fb || true
    fi
    return 0
  fi
  install_cloudflared
  DEPLOY_MODE="quick"; CF_RUNTIME_MODE="quick"
  write_service_definition "$CF_SERVICE_NAME" "FileBrowser trycloudflare quick tunnel" "$CF_BIN tunnel --no-autoupdate --url http://127.0.0.1:${FB_PORT_EFFECTIVE}"
  : > "$(service_log_file "$CF_SERVICE_NAME")" 2>/dev/null || true
  start_service "$CF_SERVICE_NAME" || warn "cloudflared 服务启动异常，继续尝试读取日志。"
  if ! capture_quick_url && [ "$AUTO_NGROK_ON_QUICK_FAIL" = "on" ]; then
    warn "trycloudflare 不可用，自动启用 ngrok 兜底。"
    DEPLOY_MODE="ngrok"
    start_ngrok_fb || true
  fi
}

prepare_cert(){
  mkdir -p "$CF_DIR"; chmod 700 "$CF_DIR" || true
  if [ -n "$(printf '%s' "$CERT_PEM_CONTENT" | tr -d '[:space:]')" ]; then printf '%s\n' "$CERT_PEM_CONTENT" > "$CF_DIR/cert.pem"; chmod 600 "$CF_DIR/cert.pem"; return; fi
  if [ -s "$CF_DIR/cert.pem" ]; then return; fi
  echo "请粘贴 cert.pem 内容，单独一行输入 CERT_END 结束："
  : > "$CF_DIR/cert.pem"
  while IFS= read -r line; do [ "$line" = "CERT_END" ] && break; printf '%s\n' "$line" >> "$CF_DIR/cert.pem"; done
  chmod 600 "$CF_DIR/cert.pem"
}

destroy_cert(){ [ "$AUTO_DESTROY_CERT" = "on" ] && rm -f "$CF_DIR/cert.pem" || true; }
validate_alias(){ [[ "$1" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?$ ]]; }
ensure_alias(){
  local input
  [ -n "${CURRENT_ALIAS:-}" ] || CURRENT_ALIAS="$SERVER_ALIAS"
  while [ -z "$CURRENT_ALIAS" ]; do read -r -p "请输入服务器别名（英文/数字/-）: " input; validate_alias "$input" && CURRENT_ALIAS="$input" || warn "格式不对。"; done
  TUNNEL_NAME="${HOST_PREFIX}-${CURRENT_ALIAS}"; TUNNEL_DOMAIN="${HOST_PREFIX}-${CURRENT_ALIAS}.${MAIN_DOMAIN}"
}

find_tunnel_uuid(){ "$CF_BIN" tunnel list 2>/dev/null | awk -v n="$1" 'NR>1 && $2==n {print $1; exit}'; }
route_dns(){
  local out label candidate i
  if out=$("$CF_BIN" tunnel route dns "$TUNNEL_NAME" "$TUNNEL_DOMAIN" 2>&1); then return 0; fi
  echo "$out"
  echo "$out" | grep -q "record with that host already exists" || return 1
  [ "$DNS_CONFLICT_ACTION" = "auto_suffix" ] || return 1
  label="${TUNNEL_DOMAIN%.${MAIN_DOMAIN}}"
  for i in $(seq 1 "$MAX_DNS_CONFLICT_TRIES"); do
    [ "$i" -eq 1 ] && candidate="${label}-${DNS_CONFLICT_SUFFIX}.${MAIN_DOMAIN}" || candidate="${label}-${DNS_CONFLICT_SUFFIX}${i}.${MAIN_DOMAIN}"
    if "$CF_BIN" tunnel route dns "$TUNNEL_NAME" "$candidate" >/dev/null 2>&1; then TUNNEL_DOMAIN="$candidate"; return 0; fi
  done
  return 1
}

start_cert_tunnel(){
  install_cloudflared; ensure_alias; prepare_cert; DEPLOY_MODE="cert"
  TUNNEL_UUID_CF=$(find_tunnel_uuid "$TUNNEL_NAME" || true)
  if [ -z "$TUNNEL_UUID_CF" ]; then "$CF_BIN" tunnel create "$TUNNEL_NAME" || fail "创建 tunnel 失败。"; TUNNEL_UUID_CF=$(find_tunnel_uuid "$TUNNEL_NAME" || true); fi
  [ -n "$TUNNEL_UUID_CF" ] || fail "未解析到 tunnel UUID。"
  route_dns || fail "DNS 绑定失败。"
  cat > "$CF_CONFIG" <<EOF_CF
# FBPANEL-MANAGED
tunnel: ${TUNNEL_UUID_CF}
credentials-file: ${CF_DIR}/${TUNNEL_UUID_CF}.json
ingress:
  - hostname: ${TUNNEL_DOMAIN}
    service: http://127.0.0.1:${FB_PORT_EFFECTIVE}
  - service: http_status:404
EOF_CF
  CF_RUNTIME_MODE="config"
  write_service_definition "$CF_SERVICE_NAME" "FileBrowser fixed Cloudflare tunnel" "$CF_BIN tunnel --no-autoupdate --config $CF_CONFIG run"
  start_service "$CF_SERVICE_NAME" || warn "cloudflared 固定隧道未确认启动，请看日志。"
  destroy_cert
  ok "固定隧道入口：https://${TUNNEL_DOMAIN}"
}

start_token_tunnel(){
  install_cloudflared; ensure_alias; DEPLOY_MODE="token"; CF_RUNTIME_MODE="token"
  [ -n "$CF_TUNNEL_TOKEN" ] || { read -r -s -p "请输入 Cloudflare Tunnel Token: " CF_TUNNEL_TOKEN; echo; }
  [ -n "$TOKEN_TUNNEL_DOMAIN" ] && TUNNEL_DOMAIN="$TOKEN_TUNNEL_DOMAIN"
  read -r -p "请输入后台已配置的访问域名（默认 ${TUNNEL_DOMAIN}）: " x; TUNNEL_DOMAIN="${x:-$TUNNEL_DOMAIN}"
  write_service_definition "$CF_SERVICE_NAME" "FileBrowser token Cloudflare tunnel" "$CF_BIN tunnel --no-autoupdate run --token $(printf '%q' "$CF_TUNNEL_TOKEN")"
  start_service "$CF_SERVICE_NAME" || warn "token 隧道未确认启动，请看日志。"
  ok "token 固定隧道入口：https://${TUNNEL_DOMAIN}"
}

write_info(){
  cat > "$INFO_FILE" <<EOF_INFO
=========================================
FileBrowser 面板信息
脚本版本      : ${SCRIPT_VERSION}
模式          : ${DEPLOY_MODE:-未部署}
CF预检        : ${STARTUP_CF_EDGE_STATUS:-未检测}
本地地址      : http://${FB_ADDR}:${FB_PORT_EFFECTIVE:-未分配}
根目录        : ${FB_ROOT}
用户名        : ${FB_USER}
密码          : ${FB_PASS}
trycloudflare : ${QUICK_URL:-未生成}
ngrok         : ${NGROK_URL:-未生成}
公网直连      : ${PUBLIC_URL:-未生成}
固定域名      : $( [ -n "${TUNNEL_DOMAIN:-}" ] && echo "https://${TUNNEL_DOMAIN}" || echo 未生成 )
快捷命令      : ${QUICK_CMD}
信息文件      : ${INFO_FILE}
=========================================
EOF_INFO
  chmod 600 "$INFO_FILE" || true
}

show_status(){
  load_state
  echo ""
  echo -e "${BLUE}========== FileBrowser 状态 ==========${RESET}"
  echo "FileBrowser : $(service_active "$FB_SERVICE_NAME" && echo 运行中 || echo 未运行)"
  echo "cloudflared : $(service_active "$CF_SERVICE_NAME" && echo 运行中 || echo 未运行)"
  echo "ngrok       : $(service_active "$NGROK_SERVICE_NAME" && echo 运行中 || echo 未运行)"
  echo "CF预检      : ${STARTUP_CF_EDGE_STATUS:-未检测}"
  cf_edge_known_unreachable && echo -e "${YELLOW}建议        : CF/trycloudflare 可能不可用，优先试公网直连或 ngrok。${RESET}"
  if [ "${DEPLOY_MODE:-}" = "public" ]; then
    echo "本地        : http://0.0.0.0:${FB_PORT_EFFECTIVE:-未分配}"
  else
    echo "本地        : http://${FB_ADDR}:${FB_PORT_EFFECTIVE:-未分配}"
  fi
  echo "trycloudflare: ${QUICK_URL:-未生成}"
  echo "ngrok       : ${NGROK_URL:-未生成}（打开后点 Visit Site）"
  echo "公网直连    : ${PUBLIC_URL:-未生成}"
  [ -n "${TUNNEL_DOMAIN:-}" ] && echo "固定域名    : https://${TUNNEL_DOMAIN}"
  echo "用户名/密码 : ${FB_USER} / ${FB_PASS}"
  echo "信息文件    : ${INFO_FILE}"
  echo "快捷命令    : ${QUICK_CMD}"
  echo -e "${BLUE}=====================================${RESET}"
}

simple_config(){
  load_state
  read -r -p "FileBrowser 根目录（当前 ${FB_ROOT}，回车不改）: " x; [ -n "$x" ] && FB_ROOT="$x"
  read -r -p "FileBrowser 用户名（当前 ${FB_USER}，回车不改）: " x; [ -n "$x" ] && FB_USER="$x"
  read -r -s -p "FileBrowser 密码（回车不改）: " x; echo; [ -n "$x" ] && FB_PASS="$x"
  setup_filebrowser
  save_state; write_info; ok "配置已更新。"
}

ngrok_local_status(){
  echo "ngrok 服务 : $(service_active "$NGROK_SERVICE_NAME" && echo 运行中 || echo 未运行)"
  echo "ngrok URL  : ${NGROK_URL:-未生成}"
  echo "token 指纹 : ${NGROK_TOKEN_FINGERPRINT:-未记录}"
  echo "日志文件   : $(service_log_file "$NGROK_SERVICE_NAME")"
  service_recent_log "$NGROK_SERVICE_NAME" 40
}

ngrok_menu(){
  while true; do
    echo ""
    echo -e "${BLUE}========== ngrok 本机管理 ==========${RESET}"
    echo "1. 查看本机 ngrok 状态/日志"
    echo "2. 刷新 ngrok FileBrowser 链接"
    echo "0. 返回"
    read -r -p "请输入数字（默认 1）: " c
    case "${c:-1}" in
      1) ngrok_local_status ;;
      2) deploy_ngrok ;;
      0) return 0 ;;
      *) warn "无效输入。" ;;
    esac
  done
}


deploy_public_direct(){
  DEPLOY_MODE="public"
  FB_ADDR="0.0.0.0"
  setup_filebrowser
  PUBLIC_HOST_EFFECTIVE="$(detect_public_host 2>/dev/null || true)"
  [ -n "$PUBLIC_HOST_EFFECTIVE" ] || { warn "未能探测公网 IP。"; PUBLIC_HOST_EFFECTIVE="${DIRECT_PUBLIC_HOST:-}"; }
  if [ -n "$PUBLIC_HOST_EFFECTIVE" ]; then
    PUBLIC_URL="http://${PUBLIC_HOST_EFFECTIVE}:${FB_PORT_EFFECTIVE}"
    ok "公网直连链接：${PUBLIC_URL}"
  fi
  save_state; write_info; show_status
}

probe_then_public(){
  DEPLOY_MODE="public"
  FB_ADDR="0.0.0.0"
  setup_filebrowser
  PUBLIC_HOST_EFFECTIVE="$(detect_public_host 2>/dev/null || true)"
  [ -n "$PUBLIC_HOST_EFFECTIVE" ] || { warn "未能探测公网 IP。"; return 1; }
  if probe_public_port "$PUBLIC_HOST_EFFECTIVE" "$FB_PORT_EFFECTIVE"; then
    PUBLIC_URL="http://${PUBLIC_HOST_EFFECTIVE}:${FB_PORT_EFFECTIVE}"
    ok "公网直连链接：${PUBLIC_URL}"
  else
    warn "公网探测未通过；仍保留本地服务，可改用 trycloudflare/ngrok。"
    PUBLIC_URL="http://${PUBLIC_HOST_EFFECTIVE}:${FB_PORT_EFFECTIVE}"
  fi
  save_state; write_info; show_status
}

deploy_quick(){ DEPLOY_MODE="quick"; FB_ADDR="127.0.0.1"; setup_filebrowser; start_quick_tunnel; save_state; write_info; show_status; }
deploy_ngrok(){ DEPLOY_MODE="ngrok"; FB_ADDR="127.0.0.1"; setup_filebrowser; start_ngrok_fb || true; save_state; write_info; show_status; }
deploy_local(){ DEPLOY_MODE="local"; FB_ADDR="127.0.0.1"; setup_filebrowser; save_state; write_info; show_status; }
deploy_cert(){ DEPLOY_MODE="cert"; FB_ADDR="127.0.0.1"; setup_filebrowser; start_cert_tunnel; save_state; write_info; show_status; }
deploy_token(){ DEPLOY_MODE="token"; FB_ADDR="127.0.0.1"; setup_filebrowser; start_token_tunnel; save_state; write_info; show_status; }
restart_all(){
  [ -n "${FB_SERVICE_NAME:-}" ] && setup_filebrowser || true
  if [ -n "${CF_SERVICE_NAME:-}" ] && service_active "$CF_SERVICE_NAME"; then start_service "$CF_SERVICE_NAME" || true; fi
  if [ -n "${NGROK_SERVICE_NAME:-}" ] && service_active "$NGROK_SERVICE_NAME"; then start_service "$NGROK_SERVICE_NAME" || true; fi
  ok "已尝试重启。"
}

manual_cf_check(){
  startup_cf_edge_precheck 1
}

main_menu(){
  while true; do
    load_state
    echo ""
    echo -e "${GREEN}========== FileBrowser 管理器 ==========${RESET}"
    echo "CF预检：${STARTUP_CF_EDGE_STATUS:-未检测}"
    if cf_edge_known_unreachable; then
      echo -e "${YELLOW}提示：CF/trycloudflare 可能不可用，建议选 2 公网探测、3 公网直连或 4 ngrok。${RESET}"
    fi
    echo "----------------------------------------"
    echo "1. 部署/刷新 trycloudflare 临时链接（默认）"
    echo "2. 探测公网入站，成功后生成公网直连"
    echo "3. 跳过探测，直接生成公网直连"
    echo "4. 启用/刷新 ngrok 兜底链接"
    echo "5. 查看状态/链接"
    echo "6. 简单配置 FileBrowser"
    echo "7. 重启服务"
    echo "8. cert 固定隧道模式"
    echo "9. token 固定隧道模式"
    echo "10. 仅本地服务"
    echo "11. ngrok 本机状态/刷新"
    echo "12. 重新检测 CF/trycloudflare 连通性"
    echo "0. 退出"
    echo "========================================"
    read -r -p "请输入数字（默认 ${DEFAULT_PANEL_CHOICE}）: " c
    case "${c:-$DEFAULT_PANEL_CHOICE}" in
      1) deploy_quick ;;
      2) probe_then_public ;;
      3) deploy_public_direct ;;
      4) deploy_ngrok ;;
      5) show_status ;;
      6) simple_config ;;
      7) restart_all ;;
      8) deploy_cert ;;
      9) deploy_token ;;
      10) deploy_local ;;
      11) ngrok_menu ;;
      12) manual_cf_check ;;
      0) exit 0 ;;
      *) warn "无效输入。" ;;
    esac
  done
}

need_root "$@"
detect_service_backend
install_self_and_quick
mkdir -p "$WORK_DIR" "$RUN_DIR" "$(dirname "$DB_PATH")"
load_state
startup_cf_edge_precheck
main_menu
