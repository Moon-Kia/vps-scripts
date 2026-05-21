#!/usr/bin/env bash
set -Eeuo pipefail

# ============================================================
# SSH + ngrok TCP 单独链接一键脚本（token 池版）
# 用途：给没有公网入站/SFTP 的容器临时开 SSH 入口
# ============================================================

SSH_PASSWORD="${SSH_PASSWORD:-}"                         # 留空运行时输入 root 密码
SSH_PORT=22                              # 本机 SSH 端口
QUICK_CMD="ng"                         # 快捷命令
INSTALL_DIR="/usr/local/lib/ngrok-ssh"
INSTALLED_SCRIPT="${INSTALL_DIR}/ngrok-ssh-pool.sh"
WORK_DIR="/etc/ngrok-ssh"
RUN_DIR="${WORK_DIR}/run"
INFO_FILE="/root/ngrok_ssh_info.txt"
NGROK_BIN="/usr/local/bin/ngrok"
SERVICE_NAME="ngrok-ssh"
SERVICE_BACKEND=""
NGROK_URL=""
NGROK_TOKEN_FINGERPRINT=""
NGROK_REGION=""
NGROK_TRY_TIMEOUT=30
SCRIPT_VERSION="2026.05.07-ngs-r4"

NGROK_AUTHTOKEN_POOL="${NGROK_AUTHTOKEN_POOL:-}"
GREEN="\033[32m"; YELLOW="\033[33m"; RED="\033[31m"; BLUE="\033[34m"; RESET="\033[0m"
ok(){ echo -e "${GREEN}✔ $*${RESET}"; }
warn(){ echo -e "${YELLOW}⚠ $*${RESET}"; }
info(){ echo -e "${BLUE}➜ $*${RESET}"; }
fail(){ echo -e "${RED}✘ $*${RESET}" >&2; exit 1; }
trap 'echo -e "${RED}脚本执行失败（第 $LINENO 行）。${RESET}" >&2' ERR

need_root(){ [ "$(id -u)" -eq 0 ] || { command -v sudo >/dev/null 2>&1 && exec sudo bash "$0" "$@"; fail "请用 root 运行。"; }; }
service_file(){ echo "/etc/systemd/system/${SERVICE_NAME}.service"; }
launcher_file(){ echo "${RUN_DIR}/${SERVICE_NAME}.sh"; }
pid_file(){ echo "${RUN_DIR}/${SERVICE_NAME}.pid"; }
log_file(){ echo "${RUN_DIR}/${SERVICE_NAME}.log"; }

detect_backend(){
  # Do not trust systemctl binary alone in containers; PID1 may be dumb-init/supervisord.
  if command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ] && systemctl is-system-running >/dev/null 2>&1; then
    SERVICE_BACKEND=systemd
  else
    SERVICE_BACKEND=process
  fi
}

register_quick(){
  mkdir -p "$INSTALL_DIR" /usr/local/bin "$WORK_DIR" "$RUN_DIR"
  local src="${BASH_SOURCE[0]}"
  if [[ "$src" != /dev/fd/* ]] && [ -f "$src" ] && [ "$src" != "$INSTALLED_SCRIPT" ]; then install -m 755 "$src" "$INSTALLED_SCRIPT" || true; fi
  [ -f "$INSTALLED_SCRIPT" ] || return 0
  cat > "/usr/local/bin/${QUICK_CMD}" <<EOF_Q
#!/usr/bin/env bash
if [ "\$(id -u)" -ne 0 ] && command -v sudo >/dev/null 2>&1; then exec sudo bash "$INSTALLED_SCRIPT" "\$@"; fi
exec bash "$INSTALLED_SCRIPT" "\$@"
EOF_Q
  chmod 755 "/usr/local/bin/${QUICK_CMD}"
}

arch_pkg(){ case "$(uname -m)" in x86_64|amd64) echo amd64;; aarch64|arm64) echo arm64;; armv7l) echo arm;; *) fail "不支持架构：$(uname -m)";; esac; }
install_ngrok(){
  if [ -x "$NGROK_BIN" ]; then ok "ngrok 已存在：$($NGROK_BIN version 2>/dev/null | head -n1 || true)"; return; fi
  local arch tmp; arch=$(arch_pkg); tmp=$(mktemp -d)
  info "正在安装 ngrok (${arch})"
  curl -fL --progress-bar "https://bin.equinox.io/c/bNyj1mQVY4c/ngrok-v3-stable-linux-${arch}.tgz" -o "${tmp}/ngrok.tgz"
  tar -xzf "${tmp}/ngrok.tgz" -C "$tmp"
  install -m 755 "${tmp}/ngrok" "$NGROK_BIN"; rm -rf "$tmp"
}

install_ssh(){
  if command -v apt-get >/dev/null 2>&1; then
    apt-get update -y >/dev/null 2>&1 || true
    apt-get install -y openssh-server curl tar >/dev/null 2>&1 || true
  elif command -v apk >/dev/null 2>&1; then
    apk add --no-cache openssh curl tar >/dev/null 2>&1 || true
  fi
  command -v sshd >/dev/null 2>&1 || fail "未检测到 sshd，且自动安装失败。"
  mkdir -p /run/sshd /var/run/sshd
  sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin yes/g' /etc/ssh/sshd_config 2>/dev/null || true
  sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication yes/g' /etc/ssh/sshd_config 2>/dev/null || true
  if [ -z "$SSH_PASSWORD" ]; then read -r -s -p "请输入 root SSH 密码: " SSH_PASSWORD; echo; fi
  [ -n "$SSH_PASSWORD" ] || fail "SSH_PASSWORD 不能为空。"
  echo "root:${SSH_PASSWORD}" | chpasswd
  if [ "${SERVICE_BACKEND:-}" = "systemd" ]; then
    systemctl enable ssh >/dev/null 2>&1 || systemctl enable sshd >/dev/null 2>&1 || true
    systemctl restart ssh >/dev/null 2>&1 || systemctl restart sshd >/dev/null 2>&1 || true
  else
    pkill sshd 2>/dev/null || true
    /usr/sbin/sshd -p "$SSH_PORT" || /usr/sbin/sshd || true
  fi
  ok "SSH 已配置，端口 ${SSH_PORT}。"
}

ngrok_tokens(){ printf '%s\n' "$NGROK_AUTHTOKEN_POOL" | sed 's/\r$//' | awk 'NF && $1 !~ /^#/ {print $1}'; }
fingerprint(){ local t="$1"; [ "${#t}" -le 12 ] && echo set || printf '%s...%s\n' "${t:0:6}" "${t: -4}"; }
region_arg(){ [ -n "$NGROK_REGION" ] && printf -- '--region %q' "$NGROK_REGION" || true; }

grok_log_hint(){
  local f="$1"
  grep -q 'ERR_NGROK_334' "$f" 2>/dev/null && warn "334：该 token 的 endpoint 已在线；等旧 agent 断开会自动释放。"
}

wait_tcp_url(){
  local f="$1" pid="${2:-}" deadline url
  deadline=$(( $(date +%s) + NGROK_TRY_TIMEOUT ))
  while [ "$(date +%s)" -lt "$deadline" ]; do
    grep -Eq 'ERR_NGROK_|failed to start tunnel|authentication failed|authtoken|limit|too many|exceed' "$f" 2>/dev/null && return 1
    url=$(grep -Eo 'tcp://[^[:space:]]+' "$f" 2>/dev/null | grep -v 'ngrok.com/docs/errors' | tail -n1 || true)
    [ -n "$url" ] && { [ -n "$pid" ] && ! kill -0 "$pid" 2>/dev/null && return 1; echo "$url"; return 0; }
    [ -n "$pid" ] && ! kill -0 "$pid" 2>/dev/null && return 1
    sleep 1
  done
  return 1
}

write_service(){
  local token="$1" qtoken exec_line
  qtoken=$(printf '%q' "$token")
  exec_line="$NGROK_BIN tcp --authtoken $qtoken --log=$(printf '%q' "$(log_file)") --log-format=logfmt $(region_arg) ${SSH_PORT}"
  if [ "$SERVICE_BACKEND" = "systemd" ]; then
    cat > "$(service_file)" <<EOF_S
[Unit]
Description=ngrok SSH tunnel
After=network-online.target ssh.service sshd.service
Wants=network-online.target

[Service]
ExecStart=${exec_line}
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF_S
    systemctl daemon-reload; systemctl enable "$SERVICE_NAME" >/dev/null 2>&1 || true
  else
    cat > "$(launcher_file)" <<EOF_L
#!/usr/bin/env bash
while true; do ${exec_line}; sleep 5; done
EOF_L
    chmod 700 "$(launcher_file)"
  fi
}

stop_service(){
  if [ "$SERVICE_BACKEND" = "systemd" ]; then systemctl stop "$SERVICE_NAME" >/dev/null 2>&1 || true; else [ -s "$(pid_file)" ] && kill "$(cat "$(pid_file)")" 2>/dev/null || true; pkill -f "ngrok tcp.*${SSH_PORT}" 2>/dev/null || true; fi
}
start_service(){
  : > "$(log_file)"
  if [ "$SERVICE_BACKEND" = "systemd" ]; then systemctl restart "$SERVICE_NAME"; else nohup bash "$(launcher_file)" >> "$(log_file)" 2>&1 & echo $! > "$(pid_file)"; fi
}

start_ngrok_pool(){
  install_ngrok
  local token tmp pid url
  [ -n "$(ngrok_tokens)" ] || fail "NGROK_AUTHTOKEN_POOL 为空。"
  stop_service
  while read -r token; do
    [ -n "$token" ] || continue
    tmp=$(mktemp)
    info "尝试 token：$(fingerprint "$token")（tcp -> ${SSH_PORT}）"
    "$NGROK_BIN" tcp --authtoken "$token" --log="$tmp" --log-format=logfmt $(region_arg) "$SSH_PORT" >/dev/null 2>&1 & pid=$!
    if url=$(wait_tcp_url "$tmp" "$pid"); then
      kill "$pid" 2>/dev/null || true; sleep 1
      write_service "$token"; start_service
      NGROK_URL=$(wait_tcp_url "$(log_file)" || echo "$url")
      NGROK_TOKEN_FINGERPRINT=$(fingerprint "$token")
      rm -f "$tmp"; return 0
    fi
    grok_log_hint "$tmp"; tail -n 20 "$tmp" 2>/dev/null || true
    kill "$pid" 2>/dev/null || true; rm -f "$tmp"; sleep 1
  done < <(ngrok_tokens)
  fail "token 池全部失败。"
}

write_info(){
  local host port
  host="${NGROK_URL#tcp://}"; port="${host##*:}"; host="${host%:*}"
  cat > "$INFO_FILE" <<EOF_I
=========================================
ngrok SSH 连接信息
ngrok URL : ${NGROK_URL}
Host      : ${host}
Port      : ${port}
User      : root
Password  : ${SSH_PASSWORD}
Token     : ${NGROK_TOKEN_FINGERPRINT}
快捷命令  : ${QUICK_CMD}
状态命令  : systemctl status ${SERVICE_NAME} 或 ${QUICK_CMD}
=========================================
EOF_I
  chmod 600 "$INFO_FILE" || true
}

show_info(){ [ -f "$INFO_FILE" ] && cat "$INFO_FILE" || warn "尚未生成信息文件。"; }
local_ngrok_status(){
  local saved_url
  saved_url="$(sed -n 's/^ngrok URL[[:space:]]*:[[:space:]]*//p' "$INFO_FILE" 2>/dev/null | head -n1 || true)"
  echo ""
  echo -e "${BLUE}========== 本机 ngrok 状态 ==========${RESET}"
  echo "脚本版本 : ${SCRIPT_VERSION}"
  echo "服务后端 : ${SERVICE_BACKEND:-未检测}"
  echo "ngrok URL: ${NGROK_URL:-${saved_url:-未生成}}"
  echo "日志文件 : $(log_file)"
  if [ "$SERVICE_BACKEND" = "systemd" ]; then
    systemctl is-active --quiet "$SERVICE_NAME" && echo "服务状态 : 运行中" || echo "服务状态 : 未运行"
    journalctl -u "$SERVICE_NAME" -n 60 --no-pager -o cat 2>/dev/null || true
  else
    if [ -s "$(pid_file)" ] && kill -0 "$(cat "$(pid_file)")" 2>/dev/null; then echo "服务状态 : 运行中"; else echo "服务状态 : 未运行"; fi
    tail -n 60 "$(log_file)" 2>/dev/null || true
  fi
  echo -e "${BLUE}=====================================${RESET}"
}
menu(){
  while true; do
    echo ""
    echo -e "${GREEN}========== ngrok SSH 管理器 ==========${RESET}"
    echo "1. 安装/刷新 SSH ngrok 链接（默认）"
    echo "2. 查看连接信息"
    echo "3. 查看本机 ngrok 状态/日志"
    echo "0. 退出"
    read -r -p "请输入数字（默认 1）: " c
    case "${c:-1}" in
      1) install_ssh; start_ngrok_pool; write_info; show_info ;;
      2) show_info ;;
      3) local_ngrok_status ;;
      0) exit 0 ;;
      *) warn "无效输入。" ;;
    esac
  done
}

need_root "$@"
detect_backend
register_quick
mkdir -p "$WORK_DIR" "$RUN_DIR"
menu
