#!/usr/bin/env bash
set -Eeuo pipefail

# ============================================================
# Tailscale 受限容器一键部署脚本（systemd / 无 systemd 兼容）
# 目标：没有 /dev/net/tun、没有 systemctl 的临时容器也尽量能跑
# ============================================================

# --------------------------- 配置区 ---------------------------
TS_AUTHKEY='tskey-auth-k122gmTrxk11CNTRL-U77NrMbJt2DRYNGM6m8J3Dg1hygmSy99B' # 直接填 Tailscale Auth Key；留空则运行时询问/仅安装
HOSTNAME_PREFIX='Prod'                    # Tailscale 设备名前缀
SERVER_ALIAS=''                           # 服务器别名；留空运行时询问，可直接回车自动生成
SSH_PASSWORD='fenghuixianyu'              # root SSH 密码；留空运行时询问，仍留空则不改密码
SSH_PORT=22                               # Tailscale 内网访问 SSH 的端口
ENABLE_SSH_SETUP='on'                     # on=安装/启动 sshd 并允许 root 密码登录
TS_TUN_MODE='userspace-networking'         # 受限容器建议 userspace-networking
TS_PORT=41641                             # Tailscale UDP 端口；userspace 下也可保留
TS_ACCEPT_DNS='false'                     # false=不改 resolv.conf，受限容器更稳
TS_EXTRA_UP_ARGS=''                       # 额外 tailscale up 参数，例如 --advertise-tags=tag:xxx
QUICK_CMD='tsm'                           # 快捷状态/修复命令
ENABLE_QUICK_CMD='on'
# ------------------------------------------------------------

SCRIPT_VERSION="2026.05.07-ts-r3"
INSTALL_DIR="/usr/local/lib/tailscale-onekey"
INSTALLED_SCRIPT="${INSTALL_DIR}/tailscale-install.sh"
WORK_DIR="/etc/tailscale-onekey"
RUN_DIR="${WORK_DIR}/run"
STATE_FILE="${WORK_DIR}/state.env"
INFO_FILE="/root/tailscale_connect_info.txt"
BOOTSTRAP_SCRIPT="${WORK_DIR}/start-services.sh"
LOGIN_AUTOSTART_FILE="/etc/profile.d/tailscale-onekey-autostart.sh"
TAILSCALED_STATE="/var/lib/tailscale/tailscaled.state"
TAILSCALED_SOCKET="/var/run/tailscale/tailscaled.sock"
TAILSCALED_BIN="/usr/sbin/tailscaled"
TAILSCALE_BIN="/usr/bin/tailscale"
SSHD_BIN="/usr/sbin/sshd"
SERVICE_BACKEND=""
FINAL_HOSTNAME=""
TS_IP=""

GREEN="\033[32m"; YELLOW="\033[33m"; RED="\033[31m"; BLUE="\033[34m"; RESET="\033[0m"
ok(){ echo -e "${GREEN}✔ $*${RESET}"; }
warn(){ echo -e "${YELLOW}⚠ $*${RESET}"; }
info(){ echo -e "${BLUE}➜ $*${RESET}"; }
fail(){ echo -e "${RED}✘ $*${RESET}" >&2; exit 1; }
trap 'echo -e "${RED}脚本执行失败（第 $LINENO 行）。${RESET}" >&2' ERR

need_root(){
  if [ "$(id -u)" -ne 0 ]; then
    if command -v sudo >/dev/null 2>&1; then exec sudo -E bash "$0" "$@"; fi
    fail "请用 root 运行，或安装 sudo。"
  fi
}

is_tty(){ [ -t 0 ] && [ -t 1 ]; }
service_file(){ echo "/etc/systemd/system/$1.service"; }
launcher_file(){ echo "${RUN_DIR}/$1.sh"; }
pid_file(){ echo "${RUN_DIR}/$1.pid"; }
log_file(){ echo "${RUN_DIR}/$1.log"; }

save_state(){
  cat > "$STATE_FILE" <<EOF_STATE
FINAL_HOSTNAME=$(printf '%q' "$FINAL_HOSTNAME")
TS_IP=$(printf '%q' "$TS_IP")
SSH_PORT=$(printf '%q' "$SSH_PORT")
TS_TUN_MODE=$(printf '%q' "$TS_TUN_MODE")
SERVICE_BACKEND=$(printf '%q' "$SERVICE_BACKEND")
EOF_STATE
  chmod 600 "$STATE_FILE" || true
}
load_state(){ [ -f "$STATE_FILE" ] && source "$STATE_FILE" || true; }

detect_backend(){
  # Do not trust systemctl binary alone in containers; PID1 may be dumb-init/supervisord.
  if command -v systemctl >/dev/null 2>&1     && [ -d /run/systemd/system ]     && systemctl is-system-running >/dev/null 2>&1; then
    SERVICE_BACKEND="systemd"
  else
    SERVICE_BACKEND="process"
  fi
}

shell_join(){ local out=() a; for a in "$@"; do out+=("$(printf '%q' "$a")"); done; printf '%s ' "${out[@]}"; }

process_active(){
  local name="$1" pid
  if [ -s "$(pid_file "$name")" ]; then
    pid=$(cat "$(pid_file "$name")" 2>/dev/null || true)
    [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null && return 0
  fi
  return 1
}

install_process_bootstrap(){
  [ "$SERVICE_BACKEND" = "process" ] || return 0
  cat > "$BOOTSTRAP_SCRIPT" <<'EOF_BOOT'
#!/usr/bin/env bash
RUN_DIR="/etc/tailscale-onekey/run"
[ -d "$RUN_DIR" ] || exit 0
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
# TAILSCALE-ONEKEY-MANAGED
if [ -x "$BOOTSTRAP_SCRIPT" ]; then
  if [ "\$(id -u 2>/dev/null || echo 1)" -eq 0 ]; then
    bash "$BOOTSTRAP_SCRIPT" >/dev/null 2>&1 || true
  elif command -v sudo >/dev/null 2>&1 && sudo -n true >/dev/null 2>&1; then
    sudo -n bash "$BOOTSTRAP_SCRIPT" >/dev/null 2>&1 || true
  fi
fi
EOF_LOGIN
    chmod 644 "$LOGIN_AUTOSTART_FILE" || true
  fi
}

write_process_service(){
  local name="$1" desc="$2" exec_line="$3" launcher
  launcher=$(launcher_file "$name")
  cat > "$launcher" <<EOF_RUN
#!/usr/bin/env bash
# TAILSCALE-ONEKEY-MANAGED
# ${desc}
set +e
trap 'kill "\${child:-}" 2>/dev/null || true; exit 0' INT TERM
while true; do
  echo "[\$(date -Is)] starting ${name}: ${exec_line}"
  bash -lc ${exec_line@Q} &
  child=\$!
  wait "\$child"
  rc=\$?
  echo "[\$(date -Is)] ${name} exited with \$rc; restart in 5s"
  sleep 5
done
EOF_RUN
  chmod 700 "$launcher"
  install_process_bootstrap
}

start_process_service(){
  local name="$1" logfile pidfile
  logfile=$(log_file "$name"); pidfile=$(pid_file "$name")
  stop_process_service "$name" >/dev/null 2>&1 || true
  : > "$logfile"
  nohup bash "$(launcher_file "$name")" >> "$logfile" 2>&1 & echo $! > "$pidfile"
  sleep 1
  process_active "$name" || { tail -n 80 "$logfile" 2>/dev/null || true; return 1; }
}

stop_process_service(){
  local name="$1" pid
  if [ -s "$(pid_file "$name")" ]; then
    pid=$(cat "$(pid_file "$name")" 2>/dev/null || true)
    [ -n "$pid" ] && kill "$pid" 2>/dev/null || true
    rm -f "$(pid_file "$name")"
  fi
}

install_self_and_quick(){
  mkdir -p "$INSTALL_DIR" /usr/local/bin "$WORK_DIR" "$RUN_DIR"
  chmod 700 "$WORK_DIR" "$RUN_DIR" || true
  local src="${BASH_SOURCE[0]}"
  if [[ "$src" != /dev/fd/* ]] && [ -f "$src" ] && [ "$src" != "$INSTALLED_SCRIPT" ]; then
    install -m 755 "$src" "$INSTALLED_SCRIPT" || true
  fi
  if [ "$ENABLE_QUICK_CMD" = "on" ] && [ -f "$INSTALLED_SCRIPT" ]; then
    cat > "/usr/local/bin/${QUICK_CMD}" <<EOF_Q
#!/usr/bin/env bash
if [ "\$(id -u)" -ne 0 ] && command -v sudo >/dev/null 2>&1; then
  exec sudo -E bash "$INSTALLED_SCRIPT" "\$@"
fi
exec bash "$INSTALLED_SCRIPT" "\$@"
EOF_Q
    chmod 755 "/usr/local/bin/${QUICK_CMD}"
  fi
}

install_packages(){
  if command -v apt-get >/dev/null 2>&1; then
    DEBIAN_FRONTEND=noninteractive apt-get update -y >/dev/null 2>&1 || true
    DEBIAN_FRONTEND=noninteractive apt-get install -y curl ca-certificates openssh-server iproute2 procps >/dev/null 2>&1 || true
  elif command -v apk >/dev/null 2>&1; then
    apk add --no-cache curl ca-certificates openssh-server iproute2 procps >/dev/null 2>&1 || true
  elif command -v dnf >/dev/null 2>&1; then
    dnf install -y curl ca-certificates openssh-server iproute procps-ng >/dev/null 2>&1 || true
  elif command -v yum >/dev/null 2>&1; then
    yum install -y curl ca-certificates openssh-server iproute procps-ng >/dev/null 2>&1 || true
  fi
}

install_tailscale(){
  if command -v tailscale >/dev/null 2>&1 && command -v tailscaled >/dev/null 2>&1; then
    TAILSCALE_BIN=$(command -v tailscale); TAILSCALED_BIN=$(command -v tailscaled)
    ok "Tailscale 已存在：$($TAILSCALE_BIN version 2>/dev/null | head -n1 || true)"
    return 0
  fi
  info "正在安装 Tailscale"
  curl -fsSL https://tailscale.com/install.sh | sh
  command -v tailscale >/dev/null 2>&1 || fail "tailscale 安装失败。"
  command -v tailscaled >/dev/null 2>&1 || fail "tailscaled 安装失败。"
  TAILSCALE_BIN=$(command -v tailscale); TAILSCALED_BIN=$(command -v tailscaled)
  ok "Tailscale 安装完成：$($TAILSCALE_BIN version 2>/dev/null | head -n1 || true)"
}

set_sshd_option(){
  local key="$1" val="$2" file="/etc/ssh/sshd_config"
  [ -f "$file" ] || return 0
  if grep -Eq "^[#[:space:]]*${key}[[:space:]]+" "$file"; then
    sed -i "s|^[#[:space:]]*${key}[[:space:]].*|${key} ${val}|" "$file"
  else
    printf '\n%s %s\n' "$key" "$val" >> "$file"
  fi
}

configure_ssh(){
  [ "$ENABLE_SSH_SETUP" = "on" ] || { warn "已跳过 SSH 配置。"; return 0; }
  command -v sshd >/dev/null 2>&1 || install_packages
  command -v sshd >/dev/null 2>&1 || fail "未检测到 sshd，自动安装也失败。"
  SSHD_BIN=$(command -v sshd)
  mkdir -p /run/sshd /var/run/sshd /etc/ssh
  [ -f /etc/ssh/sshd_config ] && [ ! -f /etc/ssh/sshd_config.bak.tailscale-onekey ] && cp -a /etc/ssh/sshd_config /etc/ssh/sshd_config.bak.tailscale-onekey || true
  set_sshd_option Port "$SSH_PORT"
  set_sshd_option ListenAddress "0.0.0.0"
  set_sshd_option PermitRootLogin "yes"
  set_sshd_option PasswordAuthentication "yes"
  set_sshd_option UsePAM "yes"

  if [ -z "$SSH_PASSWORD" ] && is_tty; then
    read -r -s -p "请输入 root SSH 密码（回车=不修改）: " SSH_PASSWORD; echo
  fi
  if [ -n "$SSH_PASSWORD" ]; then
    echo "root:${SSH_PASSWORD}" | chpasswd
    ok "root SSH 密码已设置。"
  else
    warn "未设置 root 密码；如需密码登录，请填 SSH_PASSWORD 后重跑。"
  fi

  if [ "$SERVICE_BACKEND" = "systemd" ]; then
    systemctl enable ssh >/dev/null 2>&1 || systemctl enable sshd >/dev/null 2>&1 || true
    systemctl restart ssh >/dev/null 2>&1 || systemctl restart sshd >/dev/null 2>&1 || true
  else
    local exec_line
    exec_line=$(shell_join "$SSHD_BIN" -D -e -p "$SSH_PORT" -o "ListenAddress=0.0.0.0" -o "PermitRootLogin=yes" -o "PasswordAuthentication=yes")
    write_process_service "sshd" "managed sshd for Tailscale access" "$exec_line"
    start_process_service "sshd" || warn "托管 sshd 启动失败，可能端口 ${SSH_PORT} 已被占用；可改 SSH_PORT 后重跑。"
  fi
  ok "SSH 配置完成：端口 ${SSH_PORT}。"
}

start_tailscaled(){
  mkdir -p "$(dirname "$TAILSCALED_STATE")" "$(dirname "$TAILSCALED_SOCKET")" "$RUN_DIR"
  local exec_line
  exec_line=$(shell_join "$TAILSCALED_BIN" --state="$TAILSCALED_STATE" --socket="$TAILSCALED_SOCKET" --port="$TS_PORT" --tun="$TS_TUN_MODE")
  if [ "$SERVICE_BACKEND" = "systemd" ]; then
    mkdir -p /etc/systemd/system/tailscaled.service.d
    cat > /etc/systemd/system/tailscaled.service.d/99-tailscale-onekey.conf <<EOF_SYS
# TAILSCALE-ONEKEY-MANAGED
[Service]
ExecStart=
ExecStart=${exec_line}
Restart=always
RestartSec=5
EOF_SYS
    systemctl daemon-reload
    systemctl enable tailscaled >/dev/null 2>&1 || true
    systemctl restart tailscaled
  else
    pkill -x tailscaled 2>/dev/null || true
    write_process_service "tailscaled" "tailscaled userspace daemon" "$exec_line"
    start_process_service "tailscaled" || fail "tailscaled 进程守护启动失败。"
  fi

  local deadline=$(( $(date +%s) + 20 ))
  while [ "$(date +%s)" -lt "$deadline" ]; do
    [ -S "$TAILSCALED_SOCKET" ] && { ok "tailscaled 已启动（${SERVICE_BACKEND}，tun=${TS_TUN_MODE}）。"; return 0; }
    sleep 1
  done
  warn "没有等到 tailscaled socket：${TAILSCALED_SOCKET}"
  show_logs "tailscaled" 80
  return 1
}

sanitize_label(){
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | sed 's/[[:space:]_][[:space:]_]*/-/g; s/[^a-z0-9-]//g; s/--\+/-/g; s/^-//; s/-$//'
}

choose_hostname(){
  local raw label arch suffix
  arch=$(uname -m)
  case "$arch" in x86_64|amd64) arch="x86";; aarch64|arm64) arch="arm64";; esac
  raw="$SERVER_ALIAS"
  if [ -z "$raw" ] && is_tty; then
    read -r -p "请输入服务器名字（回车=自动生成）: " raw
  fi
  label=$(sanitize_label "$raw")
  suffix=$(printf "%04x" "$RANDOM")
  if [ -n "$label" ]; then FINAL_HOSTNAME="${HOSTNAME_PREFIX}-${label}-${arch}-${suffix}"; else FINAL_HOSTNAME="${HOSTNAME_PREFIX}-${arch}-${suffix}"; fi
  FINAL_HOSTNAME=$(printf '%s' "$FINAL_HOSTNAME" | cut -c1-63 | sed 's/-$//')
  ok "本次设备名：${FINAL_HOSTNAME}"
}

valid_authkey(){
  [ -n "$TS_AUTHKEY" ] && [[ "$TS_AUTHKEY" != *xxxxxxxx* ]] && [[ "$TS_AUTHKEY" == tskey-* ]]
}

ensure_authkey(){
  if ! valid_authkey && is_tty; then
    read -r -s -p "请输入 Tailscale Auth Key（回车=只安装不登录）: " TS_AUTHKEY; echo
  fi
  valid_authkey
}

tailscale_cli(){ "$TAILSCALE_BIN" --socket="$TAILSCALED_SOCKET" "$@"; }

tailscale_login(){
  if ! ensure_authkey; then
    warn "未提供有效 TS_AUTHKEY：已完成安装与 daemon 启动，但不会加入 tailnet。填好 TS_AUTHKEY 后重跑即可。"
    return 2
  fi
  info "正在注册设备到 Tailscale：${FINAL_HOSTNAME}"
  # shellcheck disable=SC2086
  tailscale_cli up --auth-key="$TS_AUTHKEY" --hostname="$FINAL_HOSTNAME" --accept-dns="$TS_ACCEPT_DNS" $TS_EXTRA_UP_ARGS
  sleep 2
  TS_IP=$(tailscale_cli ip -4 2>/dev/null | head -n1 || true)
  [ -n "$TS_IP" ] && ok "Tailscale IP：${TS_IP}" || warn "暂未获取到 Tailscale IP，请稍后用 ${QUICK_CMD} status 查看。"
}

show_logs(){
  local name="${1:-tailscaled}" lines="${2:-80}"
  if [ "$SERVICE_BACKEND" = "systemd" ] && command -v journalctl >/dev/null 2>&1; then
    journalctl -u "$name" -n "$lines" --no-pager -o cat 2>/dev/null || true
  else
    tail -n "$lines" "$(log_file "$name")" 2>/dev/null || true
  fi
}

write_info(){
  cat > "$INFO_FILE" <<EOF_INFO
=========================================
Tailscale 连接信息
脚本版本 : ${SCRIPT_VERSION}
服务后端 : ${SERVICE_BACKEND}
设备名   : ${FINAL_HOSTNAME:-未生成}
Tailscale IP: ${TS_IP:-未获取}
SSH      : ${TS_IP:-100.x.x.x}:${SSH_PORT}
用户     : root
密码     : ${SSH_PASSWORD:-未在脚本中记录/未设置}
快捷命令 : ${QUICK_CMD}
状态命令 : ${QUICK_CMD} status
日志命令 : ${QUICK_CMD} logs
说明     : userspace 模式会把 tailnet 入站同端口转发到 127.0.0.1 同端口。
=========================================
EOF_INFO
  chmod 600 "$INFO_FILE" || true
}

show_status(){
  load_state
  echo ""
  echo -e "${BLUE}========== Tailscale 状态 ==========${RESET}"
  echo "脚本版本 : ${SCRIPT_VERSION}"
  echo "服务后端 : ${SERVICE_BACKEND:-未检测}"
  echo "设备名   : ${FINAL_HOSTNAME:-未生成}"
  echo "信息文件 : ${INFO_FILE}"
  if [ -x "$TAILSCALE_BIN" ] && [ -S "$TAILSCALED_SOCKET" ]; then
    "$TAILSCALE_BIN" --socket="$TAILSCALED_SOCKET" status 2>&1 | head -n 80 || true
    echo "IP       : $($TAILSCALE_BIN --socket="$TAILSCALED_SOCKET" ip -4 2>/dev/null | head -n1 || true)"
  else
    warn "tailscale/tailscaled 尚未就绪。"
  fi
  echo -e "${BLUE}=====================================${RESET}"
}

restart_all(){
  detect_backend
  if [ "$SERVICE_BACKEND" = "systemd" ]; then
    systemctl restart tailscaled >/dev/null 2>&1 || true
    systemctl restart ssh >/dev/null 2>&1 || systemctl restart sshd >/dev/null 2>&1 || true
  else
    [ -x "$(launcher_file tailscaled)" ] && start_process_service tailscaled || true
    [ -x "$(launcher_file sshd)" ] && start_process_service sshd || true
  fi
  ok "已尝试重启。"
}

deploy(){
  mkdir -p "$WORK_DIR" "$RUN_DIR" "$INSTALL_DIR"
  load_state
  detect_backend
  install_self_and_quick
  install_packages
  install_tailscale
  choose_hostname
  configure_ssh
  start_tailscaled
  tailscale_login || true
  save_state
  write_info
  cat "$INFO_FILE"
  if [ "$SERVICE_BACKEND" = "process" ]; then
    warn "当前无 systemd：已使用进程守护 + login/cron 拉起。容器若彻底重建，需要重新运行脚本。"
  fi
}

main(){
  need_root "$@"
  mkdir -p "$WORK_DIR" "$RUN_DIR"
  detect_backend
  case "${1:-deploy}" in
    deploy|install|repair) deploy ;;
    status|info) show_status; [ -f "$INFO_FILE" ] && cat "$INFO_FILE" || true ;;
    logs|log) show_logs tailscaled 120 ;;
    restart) restart_all ;;
    *) echo "用法：$0 [deploy|status|logs|restart]" ;;
  esac
}

main "$@"
