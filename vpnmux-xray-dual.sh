#!/usr/bin/env bash
set -Eeuo pipefail

# VPNMux + Xray dual-node installer
# - Reuses one public SSH TCP port for SSH + VMess-WS + VLESS-REALITY.
# - Designed for Zcomputer/FRP/free containers where SSH public entry is raw TCP.
# - Does NOT require TUN/CAP_NET_ADMIN/systemd.
#
# Usage:
#   bash vpnmux-xray-dual.sh deploy
#   PUBLIC_HOST=ts6.zocomputer.io PUBLIC_PORT=10946 bash vpnmux-xray-dual.sh deploy
#   bash vpnmux-xray-dual.sh status
#   bash vpnmux-xray-dual.sh restore

ACTION="${1:-deploy}"
WORK="${WORK:-/etc/vpnmux}"
OUT="${OUT:-/root/vpnmux/out}"
CONF="${SUPERVISOR_CONF:-/etc/zo/supervisord-user.conf}"
PUBLIC_HOST="${PUBLIC_HOST:-}"
PUBLIC_PORT="${PUBLIC_PORT:-}"
# PUBLIC_IP is the resolved/public entry IP for PUBLIC_HOST when detectable.
# OUTBOUND_IP is the container/server egress IP as seen by public IP echo services.
PUBLIC_IP="${PUBLIC_IP:-}"
OUTBOUND_IP="${OUTBOUND_IP:-}"
MUX_PORT="${MUX_PORT:-}"
SSH_INNER_PORT="${SSH_INNER_PORT:-2223}"
VMESS_PORT="${VMESS_PORT:-2224}"
REALITY_PORT="${REALITY_PORT:-2225}"
REALITY_SERVER_NAME="${REALITY_SERVER_NAME:-www.cloudflare.com}"
REALITY_DEST="${REALITY_DEST:-www.cloudflare.com:443}"
QUICK_CMD="${QUICK_CMD:-vpnmux}"
AUTO_INSTALL_SSH="${AUTO_INSTALL_SSH:-on}"
AUTO_CONFIGURE_SSH="${AUTO_CONFIGURE_SSH:-on}"
AUTO_BOOTSTRAP_SSH="${AUTO_BOOTSTRAP_SSH:-on}"
WAIT_HANDOFF="${WAIT_HANDOFF:-on}"
AUTO_PUBLIC_FROM_OUTBOUND="${AUTO_PUBLIC_FROM_OUTBOUND:-auto}"
ALLOW_PRIVATE_PUBLIC_HOST="${ALLOW_PRIVATE_PUBLIC_HOST:-off}"
SSH_PASSWORD="${SSH_PASSWORD:-}"
SSHD_BIN="${SSHD_BIN:-/usr/sbin/sshd}"
SSHD_EXTRA_OPTS="${SSHD_EXTRA_OPTS:--o PermitRootLogin=yes -o PasswordAuthentication=yes -o PubkeyAuthentication=yes -o UsePAM=no}"

log(){ printf '\033[36m[%s] %s\033[0m\n' "$(date -Is)" "$*"; }
ok(){ printf '\033[32m✔ %s\033[0m\n' "$*"; }
warn(){ printf '\033[33m⚠ %s\033[0m\n' "$*"; }
fail(){ printf '\033[31m✘ %s\033[0m\n' "$*" >&2; exit 1; }
have(){ command -v "$1" >/dev/null 2>&1; }

need_root(){ [ "$(id -u)" -eq 0 ] || fail "请用 root 运行。"; }
rand_uuid(){ python3 - <<'PY'
import uuid
print(uuid.uuid4())
PY
}

parse_frpc_value(){
  local key="$1" file val
  for file in /__substrate/frpc*.toml /etc/*frpc*.toml; do
    [ -f "$file" ] || continue
    val=$(awk -F= -v k="$key" '$1 ~ "^[[:space:]]*"k"[[:space:]]*$" {gsub(/[ \t\"\r]/,"",$2); print $2; exit}' "$file" 2>/dev/null || true)
    [ -n "$val" ] && { printf '%s\n' "$val"; return 0; }
  done
  return 1
}

resolve_host_ip(){
  local host="$1" ip=""
  [ -n "$host" ] || return 1
  if have getent; then
    ip=$(getent ahostsv4 "$host" 2>/dev/null | awk '{print $1; exit}')
    [ -n "$ip" ] || ip=$(getent hosts "$host" 2>/dev/null | awk '/^[0-9.]+[[:space:]]/ {print $1; exit}')
  fi
  if [ -z "$ip" ] && have dig; then
    ip=$(dig +short A "$host" 2>/dev/null | awk '/^[0-9.]+$/ {print; exit}')
  fi
  [ -n "$ip" ] && printf '%s\n' "$ip"
}

is_ipv4(){
  local ip="$1" IFS=. a b c d extra
  [[ "$ip" =~ ^[0-9]+(\.[0-9]+){3}$ ]] || return 1
  read -r a b c d extra <<<"$ip"
  [ -z "${extra:-}" ] || return 1
  for n in "$a" "$b" "$c" "$d"; do
    [ "$n" -ge 0 ] 2>/dev/null && [ "$n" -le 255 ] 2>/dev/null || return 1
  done
}

is_private_ipv4(){
  local ip="$1" IFS=. a b c d
  is_ipv4 "$ip" || return 1
  read -r a b c d <<<"$ip"
  case "$a" in
    0|10|127) return 0 ;;
    169) [ "$b" -eq 254 ] 2>/dev/null && return 0 ;;
    172) [ "$b" -ge 16 ] 2>/dev/null && [ "$b" -le 31 ] 2>/dev/null && return 0 ;;
    192) [ "$b" -eq 168 ] 2>/dev/null && return 0 ;;
    100) [ "$b" -ge 64 ] 2>/dev/null && [ "$b" -le 127 ] 2>/dev/null && return 0 ;;
    198) [ "$b" -ge 18 ] 2>/dev/null && [ "$b" -le 19 ] 2>/dev/null && return 0 ;;
  esac
  [ "$a" -ge 224 ] 2>/dev/null && return 0
  return 1
}

modal_like_runtime(){
  local hn
  hn="$(hostname 2>/dev/null || true)"
  case "${hn,,}" in modal|modal-*|*.modal) return 0 ;; esac
  env 2>/dev/null | grep -Eq '^(MODAL_|MODAL=|ZC_|ZO_|ZOCOMPUTER_)' && return 0
  return 1
}

host_is_probably_public(){
  local host="$1" lower ip
  [ "$ALLOW_PRIVATE_PUBLIC_HOST" = "on" ] && [ -n "$host" ] && return 0
  host="${host#[}"
  host="${host%]}"
  host="${host%.}"
  lower="${host,,}"
  [ -n "$lower" ] || return 1
  case "$lower" in
    localhost|localhost.*|modal|modal-*|*.local|*.internal|*.localhost) return 1 ;;
  esac
  if is_ipv4 "$host"; then
    is_private_ipv4 "$host" && return 1
    return 0
  fi
  # Short names such as "modal" or "workspace" only work inside the container/LAN,
  # not from a phone or an external client.
  [[ "$host" == *.* ]] || return 1
  ip="$(resolve_host_ip "$host" || true)"
  if [ -n "$ip" ] && is_private_ipv4 "$ip"; then return 1; fi
  return 0
}

env_var(){
  local name="$1"
  eval 'printf "%s\n" "${'"$name"':-}"'
}

detect_endpoint_from_env(){
  local h p v var parsed
  for var in VPNMUX_PUBLIC_HOST PUBLIC_HOST SSH_PUBLIC_HOST SSH_HOST ZC_SSH_HOST ZO_SSH_HOST ZOCOMPUTER_SSH_HOST; do
    v="$(env_var "$var")"
    [ -n "$v" ] && { h="$v"; break; }
  done
  for var in VPNMUX_PUBLIC_PORT PUBLIC_PORT SSH_PUBLIC_PORT SSH_PORT ZC_SSH_PORT ZO_SSH_PORT ZOCOMPUTER_SSH_PORT; do
    v="$(env_var "$var")"
    [ -n "$v" ] && { p="$v"; break; }
  done
  if [ -n "${h:-}" ] && [ -n "${p:-}" ]; then
    printf '%s %s\n' "$h" "$p"
    return 0
  fi
  for var in SSH_URL SSH_COMMAND ZC_SSH_URL ZO_SSH_URL ZOCOMPUTER_SSH_URL; do
    v="$(env_var "$var")"
    [ -n "$v" ] || continue
    parsed="$(python3 - "$v" <<'PY' 2>/dev/null || true
import re, sys
s=sys.argv[1]
patterns=[
    r'ssh\s+-p\s+(\d+)\s+\S+@([A-Za-z0-9._-]+)',
    r'ssh://(?:[^@/\s]+@)?([A-Za-z0-9._-]+):(\d+)',
    r'([A-Za-z0-9._-]+):(\d+)',
]
for pat in patterns:
    m=re.search(pat, s)
    if not m: continue
    if pat.startswith('ssh\\s'):
        print(m.group(2), m.group(1))
    else:
        print(m.group(1), m.group(2))
    break
PY
)"
    [ -n "$parsed" ] && { printf '%s\n' "$parsed"; return 0; }
  done
  return 1
}

detect_outbound_ip(){
  local url ip
  have curl || return 1
  for url in \
    https://api.ipify.org \
    https://ifconfig.me/ip \
    https://icanhazip.com \
    https://checkip.amazonaws.com; do
    ip=$(curl -fsSL --connect-timeout 4 --max-time 8 "$url" 2>/dev/null | tr -d '[:space:]' | sed -n 's/^\([0-9][0-9.]*\)$/\1/p' | head -n1 || true)
    [ -n "$ip" ] && { printf '%s\n' "$ip"; return 0; }
  done
  return 1
}

autodetect_public(){
  local env_ep env_host env_port frp_host frp_port frp_local
  env_ep="$(detect_endpoint_from_env || true)"
  if [ -n "$env_ep" ]; then
    read -r env_host env_port <<<"$env_ep"
    PUBLIC_HOST="${PUBLIC_HOST:-$env_host}"
    PUBLIC_PORT="${PUBLIC_PORT:-$env_port}"
  fi
  frp_host="$(parse_frpc_value serverAddr || true)"
  frp_port="$(parse_frpc_value remotePort || true)"
  frp_local="$(parse_frpc_value localPort || true)"
  PUBLIC_HOST="${PUBLIC_HOST:-$frp_host}"
  PUBLIC_PORT="${PUBLIC_PORT:-$frp_port}"
  MUX_PORT="${MUX_PORT:-$(parse_frpc_value localPort || true)}"
  MUX_PORT="${MUX_PORT:-$frp_local}"
  MUX_PORT="${MUX_PORT:-2222}"
  [ -n "$PUBLIC_PORT" ] || PUBLIC_PORT="$MUX_PORT"
  [ -n "$OUTBOUND_IP" ] || OUTBOUND_IP="$(detect_outbound_ip || true)"
  # On a normal VPS, the egress IP is often also the public ingress IP. On
  # Modal/Zo-style web workspaces it is usually only NAT egress, so do not use it
  # automatically there.
  if [ -z "$PUBLIC_HOST" ] && [ -n "$OUTBOUND_IP" ] && ! modal_like_runtime; then
    if [ "$AUTO_PUBLIC_FROM_OUTBOUND" = "on" ] || [ "$AUTO_PUBLIC_FROM_OUTBOUND" = "auto" ]; then
      PUBLIC_HOST="$OUTBOUND_IP"
    fi
  fi
  if [ -n "$PUBLIC_HOST" ] && ! host_is_probably_public "$PUBLIC_HOST"; then
    warn "探测到的 PUBLIC_HOST=${PUBLIC_HOST} 不是可外部访问的公网名/IP，已忽略。"
    PUBLIC_HOST=""
    PUBLIC_IP=""
  fi
  [ -n "$PUBLIC_HOST" ] && [ -n "$PUBLIC_IP" ] || PUBLIC_IP="$(resolve_host_ip "$PUBLIC_HOST" || true)"
}

require_public_endpoint(){
  if [ -z "${PUBLIC_HOST:-}" ] || [ -z "${PUBLIC_PORT:-}" ]; then
    cat >&2 <<EOF

没有找到真实公网入口，已停止生成客户端配置，避免产生“看起来成功但外网不可用”的节点。

当前容器内能打开的 ${MUX_PORT} 只是本地监听；截图里的 modal:2222 / 127.0.0.1 属于容器内部地址，不是手机可连接的公网入口。

解决办法二选一：
1. 先在平台面板开启 SSH/TCP 端口映射，再重跑脚本；
2. 直接把平台给出的 SSH 命令拆成 PUBLIC_HOST/PUBLIC_PORT，例如：

   PUBLIC_HOST=ts6.zocomputer.io PUBLIC_PORT=10946 bash <(curl -fsSL https://raw.githubusercontent.com/Moon-Kia/vps-scripts/main/vpnmux-xray-dual.sh) deploy

如果你确认公网入口就是出口 IP，可强制：

   AUTO_PUBLIC_FROM_OUTBOUND=on PUBLIC_PORT=${MUX_PORT} bash <(curl -fsSL https://raw.githubusercontent.com/Moon-Kia/vps-scripts/main/vpnmux-xray-dual.sh) deploy

EOF
    exit 1
  fi
}

arch_asset(){
  case "$(uname -m)" in
    x86_64|amd64) echo Xray-linux-64.zip ;;
    aarch64|arm64) echo Xray-linux-arm64-v8a.zip ;;
    armv7l|armv7*) echo Xray-linux-arm32-v7a.zip ;;
    *) fail "不支持架构：$(uname -m)" ;;
  esac
}

find_sshd_bin(){
  local p
  for p in "${SSHD_BIN:-}" "$(command -v sshd 2>/dev/null || true)" /usr/sbin/sshd /usr/local/sbin/sshd /usr/bin/sshd; do
    [ -n "$p" ] || continue
    [ -x "$p" ] && { printf '%s\n' "$p"; return 0; }
  done
  return 1
}

install_ssh_package(){
  [ "$AUTO_INSTALL_SSH" = "on" ] || fail "缺少 sshd，且 AUTO_INSTALL_SSH!=on，无法自动安装 OpenSSH Server。"
  log "缺少 sshd，尝试自动安装 OpenSSH Server"
  if have apt-get; then
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -y
    apt-get install -y --no-install-recommends openssh-server openssh-client ca-certificates
  elif have apk; then
    apk add --no-cache openssh-server openssh-client ca-certificates
  elif have dnf; then
    dnf install -y openssh-server openssh-clients ca-certificates
  elif have yum; then
    yum install -y openssh-server openssh-clients ca-certificates
  elif have pacman; then
    pacman -Sy --noconfirm openssh ca-certificates
  elif have zypper; then
    zypper --non-interactive install openssh ca-certificates
  else
    fail "缺少 sshd，且未识别可用包管理器；请先安装 openssh-server。"
  fi
}

configure_sshd_auth(){
  [ "$AUTO_CONFIGURE_SSH" = "on" ] || return 0
  [ -d /etc/ssh ] || return 0
  mkdir -p /etc/ssh/sshd_config.d 2>/dev/null || true
  if [ -d /etc/ssh/sshd_config.d ]; then
    cat > /etc/ssh/sshd_config.d/99-vpnmux.conf <<'EOF'
# Managed by vpnmux-xray-dual.sh
PermitRootLogin yes
PasswordAuthentication yes
PubkeyAuthentication yes
UsePAM no
EOF
    chmod 600 /etc/ssh/sshd_config.d/99-vpnmux.conf 2>/dev/null || true
  fi
}

set_root_password_if_requested(){
  [ -n "$SSH_PASSWORD" ] || return 0
  if have chpasswd; then
    printf 'root:%s\n' "$SSH_PASSWORD" | chpasswd
    ok "已按 SSH_PASSWORD 设置 root SSH 密码。"
  else
    warn "已提供 SSH_PASSWORD，但系统缺少 chpasswd，未能自动设置 root 密码。"
  fi
}

ensure_ssh_server(){
  log "检查 SSH/端口前置条件"
  if ! SSHD_BIN="$(find_sshd_bin)"; then
    install_ssh_package
    SSHD_BIN="$(find_sshd_bin)" || fail "OpenSSH Server 安装后仍找不到 sshd。"
  fi
  mkdir -p /run/sshd /var/run/sshd "$WORK/run"
  chmod 755 /run/sshd /var/run/sshd 2>/dev/null || true
  if have ssh-keygen; then
    ssh-keygen -A >/dev/null 2>&1 || true
  fi
  configure_sshd_auth
  set_root_password_if_requested
  if ! "$SSHD_BIN" -t $SSHD_EXTRA_OPTS >/tmp/vpnmux-sshd-test.out 2>/tmp/vpnmux-sshd-test.err; then
    warn "sshd 配置自检未通过，稍后仍会尝试用命令行参数启动；详情：/tmp/vpnmux-sshd-test.err"
  fi
  ok "SSH 服务端就绪：$SSHD_BIN"
}

port_has_listener(){
  local port="$1"
  if have ss; then
    ss -lnt 2>/dev/null | awk -v p=":$port" '$4 ~ p"$" {found=1} END{exit found?0:1}'
  elif have netstat; then
    netstat -lnt 2>/dev/null | awk -v p=":$port" '$4 ~ p"$" {found=1} END{exit found?0:1}'
  elif have lsof; then
    lsof -iTCP:"$port" -sTCP:LISTEN >/dev/null 2>&1
  else
    return 1
  fi
}

probe_ssh_banner(){
  local port="$1"
  if have ssh-keyscan && have timeout; then
    timeout 8 ssh-keyscan -p "$port" -T 5 127.0.0.1 >/tmp/vpnmux-keyscan-"$port".out 2>/tmp/vpnmux-keyscan-"$port".err \
      && [ -s /tmp/vpnmux-keyscan-"$port".out ]
    return $?
  fi
  python3 - "$port" <<'PY' >/tmp/vpnmux-ssh-probe.out 2>/tmp/vpnmux-ssh-probe.err
import socket, sys
port=int(sys.argv[1])
s=socket.create_connection(("127.0.0.1", port), 5)
s.settimeout(5)
data=s.recv(64)
s.close()
sys.exit(0 if data.startswith(b"SSH-") else 1)
PY
}

start_bootstrap_sshd_on_mux(){
  [ "$AUTO_BOOTSTRAP_SSH" = "on" ] || return 1
  mkdir -p "$WORK/run" /run/sshd /var/run/sshd
  if [ -s "$WORK/run/bootstrap-sshd.pid" ]; then
    kill "$(cat "$WORK/run/bootstrap-sshd.pid")" 2>/dev/null || true
    rm -f "$WORK/run/bootstrap-sshd.pid"
  fi
  log "本地 ${MUX_PORT} 没有 SSH banner，先自动拉起 bootstrap sshd 占位；稍后会切换为 VPNMux。"
  nohup "$SSHD_BIN" -D -e $SSHD_EXTRA_OPTS -p "$MUX_PORT" >>/dev/shm/vpnmux-bootstrap-sshd.log 2>&1 &
  echo $! > "$WORK/run/bootstrap-sshd.pid"
  sleep 2
  probe_ssh_banner "$MUX_PORT"
}

ensure_mux_ssh_entry(){
  if probe_ssh_banner "$MUX_PORT"; then
    ok "本地端口 ${MUX_PORT} 已有 SSH banner，可作为复用入口。"
    return 0
  fi

  if port_has_listener "$MUX_PORT"; then
    warn "本地端口 ${MUX_PORT} 已被非 SSH 服务占用；后台切换时会尝试接管该端口。"
    return 0
  fi

  if start_bootstrap_sshd_on_mux; then
    ok "已自动打开本地 SSH 入口端口 ${MUX_PORT}。"
  else
    warn "无法自动打开本地 SSH 入口端口 ${MUX_PORT}；如果平台没有公网映射，生成的节点可能无法连通。"
  fi
}

install_xray(){
  if have xray; then
    xray version | head -n1 || true
    return 0
  fi
  have curl || fail "缺少 curl"
  have unzip || { if have apt-get; then apt-get update -y && apt-get install -y unzip; else fail "缺少 unzip"; fi; }
  local tmp rel asset url
  tmp=$(mktemp -d)
  rel="$tmp/release.json"
  asset="$(arch_asset)"
  curl -fsSL --retry 3 https://api.github.com/repos/XTLS/Xray-core/releases/latest -o "$rel"
  url=$(python3 - <<PY "$rel" "$asset"
import json,sys
j=json.load(open(sys.argv[1])); asset=sys.argv[2]
for a in j.get('assets',[]):
    if a.get('name') == asset:
        print(a.get('browser_download_url')); break
PY
)
  [ -n "$url" ] || fail "没有找到 Xray 发行包：$asset"
  log "下载 Xray：$asset"
  curl -fL --retry 3 --progress-bar "$url" -o "$tmp/xray.zip"
  unzip -q "$tmp/xray.zip" -d "$tmp/xray"
  install -m 755 "$tmp/xray/xray" /usr/local/bin/xray
  rm -rf "$tmp"
  xray version | head -n1 || true
}

x25519_keys(){
  local out priv pub
  out=$(xray x25519 2>/dev/null)
  priv=$(printf '%s\n' "$out" | awk -F': ' '/PrivateKey|Private key/{print $2; exit}')
  pub=$(printf '%s\n' "$out" | awk -F': ' '/PublicKey|Public key|Password \(PublicKey\)/{print $2; exit}')
  [ -n "$priv" ] && [ -n "$pub" ] || fail "生成 REALITY x25519 密钥失败"
  printf '%s %s\n' "$priv" "$pub"
}

write_state(){
  local detected_sshd_bin="$SSHD_BIN" detected_sshd_opts="$SSHD_EXTRA_OPTS"
  mkdir -p "$WORK" "$OUT" "$WORK/bootstrap"
  chmod 700 "$WORK" "$WORK/bootstrap" 2>/dev/null || true
  if [ -f "$WORK/state.env" ]; then . "$WORK/state.env" || true; fi
  SSHD_BIN="$detected_sshd_bin"
  SSHD_EXTRA_OPTS="$detected_sshd_opts"
  UUID="${UUID:-$(rand_uuid)}"
  WS_PATH="${WS_PATH:-/$(openssl rand -hex 12)-vmess}"
  REALITY_UUID="${REALITY_UUID:-$(rand_uuid)}"
  if [ -z "${REALITY_PRIVATE_KEY:-}" ] || [ -z "${REALITY_PUBLIC_KEY:-}" ]; then
    read -r REALITY_PRIVATE_KEY REALITY_PUBLIC_KEY < <(x25519_keys)
  fi
  REALITY_SHORT_ID="${REALITY_SHORT_ID:-$(openssl rand -hex 8)}"
  {
  cat <<STATE
PUBLIC_HOST=${PUBLIC_HOST}
PUBLIC_PORT=${PUBLIC_PORT}
PUBLIC_IP=${PUBLIC_IP}
OUTBOUND_IP=${OUTBOUND_IP}
MUX_PORT=${MUX_PORT}
SSH_INNER_PORT=${SSH_INNER_PORT}
VMESS_PORT=${VMESS_PORT}
XRAY_PORT=${VMESS_PORT}
REALITY_PORT=${REALITY_PORT}
UUID=${UUID}
WS_PATH=${WS_PATH}
REALITY_UUID=${REALITY_UUID}
REALITY_SERVER_NAME=${REALITY_SERVER_NAME}
REALITY_DEST=${REALITY_DEST}
REALITY_PRIVATE_KEY=${REALITY_PRIVATE_KEY}
REALITY_PUBLIC_KEY=${REALITY_PUBLIC_KEY}
REALITY_SHORT_ID=${REALITY_SHORT_ID}
STATE
  printf 'SSHD_BIN=%q\n' "$SSHD_BIN"
  printf 'SSHD_EXTRA_OPTS=%q\n' "$SSHD_EXTRA_OPTS"
  } > "$WORK/state.env"
  chmod 600 "$WORK/state.env"
}

write_mux(){
  cat > "$WORK/mux.py" <<'PY'
#!/usr/bin/env python3
import argparse, socket, threading, time, sys
BUF = 65536
HTTP_PREFIXES = (b'GET ', b'POST ', b'HEAD ', b'PUT ', b'DELETE ', b'OPTIONS ', b'PATCH ', b'CONNECT ')
def log(msg):
    sys.stderr.write(time.strftime('%Y-%m-%dT%H:%M:%S%z ') + msg + '\n'); sys.stderr.flush()
def close_sock(s):
    try: s.shutdown(socket.SHUT_RDWR)
    except Exception: pass
    try: s.close()
    except Exception: pass
def pump(src, dst):
    try:
        while True:
            data = src.recv(BUF)
            if not data: break
            dst.sendall(data)
    except Exception: pass
    finally:
        close_sock(src); close_sock(dst)
def classify(first):
    if first == b'SSH-timeout-assume' or first.startswith(b'SSH-'): return 'ssh'
    if len(first) >= 3 and first[0] == 0x16 and first[1] == 0x03: return 'reality'
    if first.startswith(HTTP_PREFIXES): return 'ws'
    return 'ws'
def handle(client, addr, targets, peek_timeout):
    upstream = None
    try:
        client.settimeout(peek_timeout)
        try: first = client.recv(4096, socket.MSG_PEEK)
        except socket.timeout: first = b'SSH-timeout-assume'
        if not first: return
        target = targets[classify(first)]
        upstream = socket.create_connection(target, timeout=12)
        client.settimeout(None); upstream.settimeout(None)
        threading.Thread(target=pump, args=(client, upstream), daemon=True).start()
        threading.Thread(target=pump, args=(upstream, client), daemon=True).start()
    except Exception as e:
        log(f'{addr} dispatch error: {e!r}')
        close_sock(client)
        if upstream: close_sock(upstream)
def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--listen', default='0.0.0.0')
    ap.add_argument('--port', type=int, required=True)
    ap.add_argument('--ssh-port', type=int, required=True)
    ap.add_argument('--ws-port', type=int, required=True)
    ap.add_argument('--reality-port', type=int, required=True)
    ap.add_argument('--peek-timeout', type=float, default=1.0)
    args = ap.parse_args()
    targets = {'ssh':('127.0.0.1',args.ssh_port), 'ws':('127.0.0.1',args.ws_port), 'reality':('127.0.0.1',args.reality_port)}
    srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM); srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    srv.bind((args.listen, args.port)); srv.listen(512)
    log(f'vpnmux listen={args.listen}:{args.port} targets={targets}')
    while True:
        c,a = srv.accept(); threading.Thread(target=handle, args=(c,a,targets,args.peek_timeout), daemon=True).start()
if __name__ == '__main__': main()
PY
  chmod 755 "$WORK/mux.py"
}

write_xray_configs(){
  cat > "$WORK/xray-vmess-server.json" <<JSON
{
  "log": { "loglevel": "warning" },
  "inbounds": [{
    "listen": "127.0.0.1", "port": ${VMESS_PORT}, "protocol": "vmess",
    "settings": { "clients": [{ "id": "${UUID}", "alterId": 0 }] },
    "streamSettings": { "network": "ws", "wsSettings": { "path": "${WS_PATH}" } }
  }],
  "outbounds": [{ "protocol": "freedom", "tag": "direct" }]
}
JSON
  cat > "$WORK/xray-reality-server.json" <<JSON
{
  "log": { "loglevel": "warning" },
  "inbounds": [{
    "listen": "127.0.0.1", "port": ${REALITY_PORT}, "protocol": "vless",
    "settings": { "clients": [{ "id": "${REALITY_UUID}" }], "decryption": "none" },
    "streamSettings": { "network": "tcp", "security": "reality", "realitySettings": {
      "show": false, "dest": "${REALITY_DEST}", "xver": 0,
      "serverNames": ["${REALITY_SERVER_NAME}"],
      "privateKey": "${REALITY_PRIVATE_KEY}", "shortIds": ["${REALITY_SHORT_ID}"]
    }}
  }],
  "outbounds": [{ "protocol": "freedom", "tag": "direct" }]
}
JSON
  xray run -test -config "$WORK/xray-vmess-server.json" >/tmp/vpnmux-vmess-test.log 2>&1 || { cat /tmp/vpnmux-vmess-test.log >&2; fail "VMess 配置校验失败"; }
  xray run -test -config "$WORK/xray-reality-server.json" >/tmp/vpnmux-reality-test.log 2>&1 || { cat /tmp/vpnmux-reality-test.log >&2; fail "REALITY 配置校验失败"; }
}

write_client_configs(){
  cat > "$OUT/endpoint-info.txt" <<INFO
PUBLIC_HOST=${PUBLIC_HOST}
PUBLIC_PORT=${PUBLIC_PORT}
PUBLIC_IP=${PUBLIC_IP:-unknown}
OUTBOUND_IP=${OUTBOUND_IP:-unknown}
MUX_PORT=${MUX_PORT}

说明：
- PUBLIC_HOST/PUBLIC_PORT 是客户端应连接的公网入口。
- PUBLIC_IP 是 PUBLIC_HOST 当前解析到的 IPv4，便于排查 DNS/入口变化。
- OUTBOUND_IP 是容器访问公网时暴露的出口 IPv4，可能与入口 IP 不同。
INFO
  cat > "$OUT/IMPORT_THIS_CLASH_META_COMBINED.yaml" <<YAML
# public-host: ${PUBLIC_HOST}
# public-port: ${PUBLIC_PORT}
# public-ip: ${PUBLIC_IP:-unknown}
# outbound-ip: ${OUTBOUND_IP:-unknown}
mixed-port: 7890
allow-lan: false
mode: rule
log-level: info
ipv6: true

dns:
  enable: true
  enhanced-mode: redir-host
  nameserver:
    - 1.1.1.1
    - 8.8.8.8

proxies:
  - name: "vpnmux-reality"
    type: vless
    server: "${PUBLIC_HOST}"
    port: ${PUBLIC_PORT}
    uuid: "${REALITY_UUID}"
    udp: true
    tls: true
    network: tcp
    servername: "${REALITY_SERVER_NAME}"
    client-fingerprint: chrome
    reality-opts:
      public-key: "${REALITY_PUBLIC_KEY}"
      short-id: "${REALITY_SHORT_ID}"
  - name: "vpnmux-vmess-ws"
    type: vmess
    server: "${PUBLIC_HOST}"
    port: ${PUBLIC_PORT}
    uuid: "${UUID}"
    alterId: 0
    cipher: auto
    udp: true
    tls: false
    network: ws
    ws-opts:
      path: "${WS_PATH}"
      headers:
        Host: "${PUBLIC_HOST}"

proxy-groups:
  - name: "PROXY"
    type: select
    proxies:
      - "vpnmux-reality"
      - "vpnmux-vmess-ws"
      - DIRECT

rules:
  - MATCH,PROXY
YAML
  python3 - <<PY > "$OUT/vmess-uri.txt"
import base64,json
cfg={"v":"2","ps":"vpnmux-vmess-ws","add":"$PUBLIC_HOST","port":"$PUBLIC_PORT","id":"$UUID","aid":"0","scy":"auto","net":"ws","type":"none","host":"$PUBLIC_HOST","path":"$WS_PATH","tls":""}
print('vmess://' + base64.b64encode(json.dumps(cfg,separators=(',',':')).encode()).decode())
PY
  python3 - <<PY > "$OUT/vless-reality-uri.txt"
from urllib.parse import quote
q='encryption=none&security=reality&sni={sni}&fp=chrome&pbk={pbk}&sid={sid}&type=tcp'.format(sni=quote('$REALITY_SERVER_NAME'),pbk=quote('$REALITY_PUBLIC_KEY'),sid=quote('$REALITY_SHORT_ID'))
print('vless://$REALITY_UUID@$PUBLIC_HOST:$PUBLIC_PORT?'+q+'#vpnmux-reality')
PY
  chmod 600 "$OUT"/* 2>/dev/null || true
}

write_restore(){
  cat > "$WORK/restore-ssh.sh" <<'EOS'
#!/usr/bin/env bash
set +e
WORK=/etc/vpnmux
CONF=${SUPERVISOR_CONF:-/etc/zo/supervisord-user.conf}
SUP="supervisorctl -c $CONF"
[ -f "$WORK/state.env" ] && . "$WORK/state.env"
MUX_PORT="${MUX_PORT:-2222}"
SSH_INNER_PORT="${SSH_INNER_PORT:-2223}"
SSHD_BIN="${SSHD_BIN:-/usr/sbin/sshd}"
SSHD_EXTRA_OPTS="${SSHD_EXTRA_OPTS:-}"
LOG=/dev/shm/vpnmux-restore.log
exec >>"$LOG" 2>&1
echo "[$(date -Is)] restore start"
$SUP stop vpnmux-mux vpnmux-xray-vmess vpnmux-xray-reality ssh || true
pkill -f '/etc/vpnmux/mux.py' || true
pkill -f 'xray run -config /etc/vpnmux/xray-vmess-server.json' || true
pkill -f 'xray run -config /etc/vpnmux/xray-reality-server.json' || true
pkill -f "sshd .*ListenAddress=127.0.0.1 .*${SSH_INNER_PORT}" || true
if [ -f "$WORK/supervisord-user.conf.orig" ]; then cp -f "$WORK/supervisord-user.conf.orig" "$CONF"; fi
$SUP reread || true
$SUP update || true
$SUP start ssh || true
sleep 1
mkdir -p /run/sshd /var/run/sshd
if ! timeout 2 bash -c "</dev/tcp/127.0.0.1/${MUX_PORT}" >/dev/null 2>&1; then
  nohup "$SSHD_BIN" -D -e $SSHD_EXTRA_OPTS -p "$MUX_PORT" >>/dev/shm/vpnmux-fallback-sshd.log 2>&1 &
fi
echo "[$(date -Is)] restore done"
EOS
  chmod 755 "$WORK/restore-ssh.sh"
}

write_quick_cmd(){
  [ -w /usr/local/bin ] || return 0
  cat > "/usr/local/bin/${QUICK_CMD}" <<EOFQ
#!/usr/bin/env bash
exec bash "$WORK/vpnmux-xray-dual.sh" "\$@"
EOFQ
  chmod 755 "/usr/local/bin/${QUICK_CMD}"
}

pretest(){
  log "本地预检：SSH / VMess-WS / VLESS-REALITY"
  local TS=2293 TV=2294 TR=2295 TM=2299
  mkdir -p /run/sshd /var/run/sshd
  for f in /tmp/vpnmux_pre_*.pid; do [ -f "$f" ] && kill "$(cat "$f")" 2>/dev/null || true; done
  rm -f /tmp/vpnmux_pre_*.pid
  nohup "$SSHD_BIN" -D -e $SSHD_EXTRA_OPTS -o ListenAddress=127.0.0.1 -p "$TS" >/dev/shm/vpnmux-pre-sshd.log 2>&1 & echo $! >/tmp/vpnmux_pre_sshd.pid
  sed "s/\"port\": ${VMESS_PORT}/\"port\": ${TV}/" "$WORK/xray-vmess-server.json" > /tmp/vpnmux-pre-vmess.json
  sed "s/\"port\": ${REALITY_PORT}/\"port\": ${TR}/" "$WORK/xray-reality-server.json" > /tmp/vpnmux-pre-reality.json
  nohup xray run -config /tmp/vpnmux-pre-vmess.json >/dev/shm/vpnmux-pre-vmess.log 2>&1 & echo $! >/tmp/vpnmux_pre_vmess.pid
  nohup xray run -config /tmp/vpnmux-pre-reality.json >/dev/shm/vpnmux-pre-reality.log 2>&1 & echo $! >/tmp/vpnmux_pre_reality.pid
  sleep 2
  nohup python3 "$WORK/mux.py" --listen 127.0.0.1 --port "$TM" --ssh-port "$TS" --ws-port "$TV" --reality-port "$TR" >/dev/shm/vpnmux-pre-mux.log 2>&1 & echo $! >/tmp/vpnmux_pre_mux.pid
  sleep 1
  timeout 8 ssh-keyscan -p "$TM" -T 5 127.0.0.1 >/tmp/vpnmux-pre-keyscan.out 2>/tmp/vpnmux-pre-keyscan.err || fail "预检 SSH 分流失败"
  [ -s /tmp/vpnmux-pre-keyscan.out ] || fail "预检 SSH 无 banner"
  python3 - <<PY >/tmp/vpnmux-pre-ws.out
import socket,sys
s=socket.create_connection(('127.0.0.1',$TM),5)
s.sendall(("GET $WS_PATH HTTP/1.1\r\nHost: $PUBLIC_HOST\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\nSec-WebSocket-Version: 13\r\n\r\n").encode())
r=s.recv(256); print(r.decode('latin1','replace')); s.close(); sys.exit(0 if b'101' in r.split(b'\r\n',1)[0] else 1)
PY
  cat > /tmp/vpnmux-pre-reality-client.json <<JSON
{"log":{"loglevel":"warning"},"inbounds":[{"listen":"127.0.0.1","port":10819,"protocol":"socks","settings":{"auth":"noauth","udp":false}}],"outbounds":[{"protocol":"vless","settings":{"vnext":[{"address":"127.0.0.1","port":${TM},"users":[{"id":"${REALITY_UUID}","encryption":"none"}]}]},"streamSettings":{"network":"tcp","security":"reality","realitySettings":{"serverName":"${REALITY_SERVER_NAME}","fingerprint":"chrome","publicKey":"${REALITY_PUBLIC_KEY}","shortId":"${REALITY_SHORT_ID}"}}}]}
JSON
  nohup xray run -config /tmp/vpnmux-pre-reality-client.json >/dev/shm/vpnmux-pre-reality-client.log 2>&1 & echo $! >/tmp/vpnmux_pre_reality_client.pid
  sleep 2
  curl -fsS --connect-timeout 8 --max-time 20 --socks5-hostname 127.0.0.1:10819 https://www.cloudflare.com/cdn-cgi/trace >/tmp/vpnmux-pre-reality-curl.out 2>/tmp/vpnmux-pre-reality-curl.err || fail "预检 REALITY 出口失败"
  for f in /tmp/vpnmux_pre_*.pid; do [ -f "$f" ] && kill "$(cat "$f")" 2>/dev/null || true; done
  rm -f /tmp/vpnmux_pre_*.pid /tmp/vpnmux-pre-*.json
  ok "预检通过"
}

patch_supervisor(){
  have supervisorctl || fail "当前脚本主要支持 supervisorctl 环境；没有 supervisorctl 时请手动改为 nohup/process 守护。"
  [ -f "$CONF" ] || fail "找不到 supervisor 配置：$CONF"
  [ -f "$WORK/supervisord-user.conf.orig" ] || cp -a "$CONF" "$WORK/supervisord-user.conf.orig"
  cp -a "$CONF" "$CONF.bak.vpnmux.$(date -u +%Y%m%d-%H%M%S)"
  python3 - <<PY "$CONF" "$WORK" "$MUX_PORT" "$SSH_INNER_PORT" "$VMESS_PORT" "$REALITY_PORT" "$SSHD_BIN" "$SSHD_EXTRA_OPTS"
from pathlib import Path
import sys
conf=Path(sys.argv[1]); work=sys.argv[2]; mux,ssh,vm,re=sys.argv[3:7]; sshd_bin=sys.argv[7]; sshd_opts=sys.argv[8]
sshd_cmd=' '.join(x for x in [sshd_bin, '-D -e', sshd_opts, f'-o ListenAddress=127.0.0.1 -p {ssh}'] if x)
text=conf.read_text(); lines=text.splitlines(); out=[]; skip=False
remove={'[program:vpnmux-xray-vmess]','[program:vpnmux-xray-reality]','[program:vpnmux-mux]','[program:vpnmux-xray]','[program:vpnmux-singbox]'}
for line in lines:
    st=line.strip()
    if st.startswith('[program:'):
        skip = st in remove
    if not skip: out.append(line)
lines=out; out=[]; section=None
for line in lines:
    st=line.strip()
    if st.startswith('[') and st.endswith(']'): section=st
    if section == '[program:ssh]' and line.startswith('command='):
        line=f'command={sshd_cmd}'
    elif section == '[program:ssh]' and line.startswith('environment='):
        line=f'environment=PORT="{ssh}"'
    out.append(line)
base='\n'.join(out).rstrip()+"\n"
if '[program:ssh]' not in {l.strip() for l in lines}:
    base += f'''
[program:ssh]
command={sshd_cmd}
autostart=true
autorestart=true
startretries=20
startsecs=2
stdout_logfile=/dev/shm/vpnmux-sshd-inner.log
stderr_logfile=/dev/shm/vpnmux-sshd-inner_err.log
stdout_logfile_maxbytes=10MB
stdout_logfile_backups=3
stderr_logfile_maxbytes=10MB
stderr_logfile_backups=3
'''
append=f'''
[program:vpnmux-xray-vmess]
command=/usr/local/bin/xray run -config {work}/xray-vmess-server.json
directory={work}
autostart=true
autorestart=true
stopsignal=TERM
stopasgroup=true
killasgroup=true
startretries=20
startsecs=2
stdout_logfile=/dev/shm/vpnmux-xray-vmess.log
stderr_logfile=/dev/shm/vpnmux-xray-vmess_err.log
stdout_logfile_maxbytes=10MB
stdout_logfile_backups=3
stderr_logfile_maxbytes=10MB
stderr_logfile_backups=3

[program:vpnmux-xray-reality]
command=/usr/local/bin/xray run -config {work}/xray-reality-server.json
directory={work}
autostart=true
autorestart=true
stopsignal=TERM
stopasgroup=true
killasgroup=true
startretries=20
startsecs=2
stdout_logfile=/dev/shm/vpnmux-xray-reality.log
stderr_logfile=/dev/shm/vpnmux-xray-reality_err.log
stdout_logfile_maxbytes=10MB
stdout_logfile_backups=3
stderr_logfile_maxbytes=10MB
stderr_logfile_backups=3

[program:vpnmux-mux]
command=/usr/bin/python3 {work}/mux.py --listen 0.0.0.0 --port {mux} --ssh-port {ssh} --ws-port {vm} --reality-port {re}
directory={work}
autostart=true
autorestart=true
stopsignal=TERM
stopasgroup=true
killasgroup=true
startretries=20
startsecs=2
stdout_logfile=/dev/shm/vpnmux-mux.log
stderr_logfile=/dev/shm/vpnmux-mux_err.log
stdout_logfile_maxbytes=10MB
stdout_logfile_backups=3
stderr_logfile_maxbytes=10MB
stderr_logfile_backups=3
'''
conf.write_text(base+append)
PY
}

write_handoff(){
  cat > "$WORK/bootstrap/handoff.sh" <<'EOS'
#!/usr/bin/env bash
set +e
WORK=/etc/vpnmux
CONF=${SUPERVISOR_CONF:-/etc/zo/supervisord-user.conf}
SUP="supervisorctl -c $CONF"
. "$WORK/state.env"
LOG=/dev/shm/vpnmux-handoff.log
exec >>"$LOG" 2>&1
echo "[$(date -Is)] handoff start"
listener_pids(){
  local port="$1"
  if command -v ss >/dev/null 2>&1; then
    ss -lntp 2>/dev/null | awk -v p=":$port" '$4 ~ p"$" {print $0}' | sed -n 's/.*pid=\([0-9][0-9]*\).*/\1/p' | sort -u
  elif command -v lsof >/dev/null 2>&1; then
    lsof -tiTCP:"$port" -sTCP:LISTEN 2>/dev/null | sort -u
  fi
}
$SUP reread
$SUP stop vpnmux-mux || true
$SUP stop ssh || true
for pid in $(listener_pids "$MUX_PORT"); do
  echo "[$(date -Is)] stopping old listener pid=$pid port=$MUX_PORT"
  kill "$pid" 2>/dev/null || true
  sleep 1
  kill -9 "$pid" 2>/dev/null || true
done
$SUP update
$SUP start ssh vpnmux-xray-vmess vpnmux-xray-reality vpnmux-mux || true
sleep 6
$SUP status || true
ssh_ok=0; ws_ok=0
if timeout 8 ssh-keyscan -p "$MUX_PORT" -T 5 127.0.0.1 >/tmp/vpnmux-live-keyscan.out 2>/tmp/vpnmux-live-keyscan.err && [ -s /tmp/vpnmux-live-keyscan.out ]; then ssh_ok=1; fi
python3 - <<PY >/tmp/vpnmux-live-ws.out 2>/tmp/vpnmux-live-ws.err
import socket,sys
s=socket.create_connection(('127.0.0.1', int('$MUX_PORT')),5)
s.sendall(("GET $WS_PATH HTTP/1.1\r\nHost: $PUBLIC_HOST\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\nSec-WebSocket-Version: 13\r\n\r\n").encode())
r=s.recv(256); print(r.decode('latin1','replace')); s.close(); sys.exit(0 if b'101' in r.split(b'\r\n',1)[0] else 1)
PY
[ $? -eq 0 ] && ws_ok=1
if [ "$ssh_ok" != 1 ] || [ "$ws_ok" != 1 ]; then
  echo "[$(date -Is)] critical self-test failed; restoring"
  bash "$WORK/restore-ssh.sh"
  exit 1
fi
echo "[$(date -Is)] handoff OK ssh=$ssh_ok ws=$ws_ok"
EOS
  chmod 755 "$WORK/bootstrap/handoff.sh"
}


supervisor_usable(){
  have supervisorctl && [ -f "$CONF" ] && supervisorctl -c "$CONF" status >/dev/null 2>&1
}

write_process_handoff(){
  cat > "$WORK/bootstrap/process-handoff.sh" <<'EOS_PROCESS_HANDOFF'
#!/usr/bin/env bash
set +e
WORK=/etc/vpnmux
. "$WORK/state.env"
RUN="$WORK/run"
mkdir -p "$RUN" /run/sshd /var/run/sshd
LOG=/dev/shm/vpnmux-process-handoff.log
exec >>"$LOG" 2>&1
echo "[$(date -Is)] process handoff start"
stop_pid(){ [ -s "$1" ] && kill "$(cat "$1")" 2>/dev/null || true; rm -f "$1"; }
listener_pids(){
  local port="$1"
  if command -v ss >/dev/null 2>&1; then
    ss -lntp 2>/dev/null | awk -v p=":$port" '$4 ~ p"$" {print $0}' | sed -n 's/.*pid=\([0-9][0-9]*\).*/\1/p' | sort -u
  elif command -v lsof >/dev/null 2>&1; then
    lsof -tiTCP:"$port" -sTCP:LISTEN 2>/dev/null | sort -u
  fi
}
start_one(){
  local name="$1" cmd="$2" log="$3" pidfile="$RUN/$name.pid"
  stop_pid "$pidfile"
  nohup bash -lc "$cmd" >>"$log" 2>&1 & echo $! > "$pidfile"
}
start_one sshd-inner "\"$SSHD_BIN\" -D -e $SSHD_EXTRA_OPTS -o ListenAddress=127.0.0.1 -p $SSH_INNER_PORT" /dev/shm/vpnmux-sshd-inner.log
start_one xray-vmess "xray run -config $WORK/xray-vmess-server.json" /dev/shm/vpnmux-xray-vmess.log
start_one xray-reality "xray run -config $WORK/xray-reality-server.json" /dev/shm/vpnmux-xray-reality.log
sleep 3
for pid in $(listener_pids "$MUX_PORT"); do
  echo "[$(date -Is)] stopping old listener pid=$pid port=$MUX_PORT"
  kill "$pid" 2>/dev/null || true
  sleep 1
  kill -9 "$pid" 2>/dev/null || true
done
start_one vpnmux "python3 $WORK/mux.py --listen 0.0.0.0 --port $MUX_PORT --ssh-port $SSH_INNER_PORT --ws-port $VMESS_PORT --reality-port $REALITY_PORT" /dev/shm/vpnmux-mux.log
sleep 3
ssh_ok=0; ws_ok=0
if timeout 8 ssh-keyscan -p "$MUX_PORT" -T 5 127.0.0.1 >/tmp/vpnmux-process-keyscan.out 2>/tmp/vpnmux-process-keyscan.err && [ -s /tmp/vpnmux-process-keyscan.out ]; then ssh_ok=1; fi
python3 - <<PY_PROCESS_WS >/tmp/vpnmux-process-ws.out 2>/tmp/vpnmux-process-ws.err
import socket,sys
s=socket.create_connection(('127.0.0.1', int('$MUX_PORT')),5)
s.sendall(("GET $WS_PATH HTTP/1.1\r\nHost: $PUBLIC_HOST\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\nSec-WebSocket-Version: 13\r\n\r\n").encode())
r=s.recv(256); print(r.decode('latin1','replace')); s.close(); sys.exit(0 if b'101' in r.split(b'\r\n',1)[0] else 1)
PY_PROCESS_WS
[ $? -eq 0 ] && ws_ok=1
if [ "$ssh_ok" != 1 ] || [ "$ws_ok" != 1 ]; then
  echo "[$(date -Is)] process self-test failed; fallback to direct sshd on $MUX_PORT"
  stop_pid "$RUN/vpnmux.pid"
  nohup "$SSHD_BIN" -D -e $SSHD_EXTRA_OPTS -p "$MUX_PORT" >>/dev/shm/vpnmux-fallback-sshd.log 2>&1 & echo $! > "$RUN/fallback-sshd.pid"
  exit 1
fi
echo "[$(date -Is)] process handoff OK ssh=$ssh_ok ws=$ws_ok"
EOS_PROCESS_HANDOFF
  chmod 755 "$WORK/bootstrap/process-handoff.sh"
}

probe_ws_upgrade(){
  local port="$1"
  python3 - "$port" "$WS_PATH" "$PUBLIC_HOST" <<'PY' >/tmp/vpnmux-ws-probe.out 2>/tmp/vpnmux-ws-probe.err
import socket, sys
port=int(sys.argv[1]); path=sys.argv[2]; host=sys.argv[3]
s=socket.create_connection(("127.0.0.1", port), 5)
s.sendall((f"GET {path} HTTP/1.1\r\nHost: {host}\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\nSec-WebSocket-Version: 13\r\n\r\n").encode())
r=s.recv(256)
s.close()
sys.exit(0 if b"101" in r.split(b"\r\n",1)[0] else 1)
PY
}

probe_public_tcp(){
  [ -n "$PUBLIC_HOST" ] && [ -n "$PUBLIC_PORT" ] || return 1
  host_is_probably_public "$PUBLIC_HOST" || return 1
  if have timeout; then
    timeout 8 bash -c "</dev/tcp/${PUBLIC_HOST}/${PUBLIC_PORT}" >/tmp/vpnmux-public-tcp.out 2>/tmp/vpnmux-public-tcp.err
  else
    python3 - "$PUBLIC_HOST" "$PUBLIC_PORT" <<'PY' >/tmp/vpnmux-public-tcp.out 2>/tmp/vpnmux-public-tcp.err
import socket, sys
s=socket.create_connection((sys.argv[1], int(sys.argv[2])), 8)
s.close()
PY
  fi
}

wait_for_handoff(){
  [ "$WAIT_HANDOFF" = "on" ] || return 0
  log "等待后台切换完成并做本地连通性验证"
  local i
  for i in $(seq 1 35); do
    if probe_ssh_banner "$MUX_PORT" && probe_ws_upgrade "$MUX_PORT"; then
      ok "本地验证通过：${MUX_PORT} 同时可分流 SSH 与 VMess-WS。"
      if probe_public_tcp; then
        ok "公网入口 TCP 可连接：${PUBLIC_HOST}:${PUBLIC_PORT}"
      else
        warn "未能从本机回连公网入口 ${PUBLIC_HOST}:${PUBLIC_PORT}。这可能是平台不支持回环检测；若客户端仍无速度，请优先确认面板/FRP/防火墙是否真的放行该公网端口。"
      fi
      return 0
    fi
    sleep 1
  done
  warn "等待 35 秒后本地验证仍未通过。请执行 ${QUICK_CMD} status，并查看 /dev/shm/vpnmux-handoff.log 或 /dev/shm/vpnmux-process-handoff.log。"
}

deploy(){
  need_root
  autodetect_public
  require_public_endpoint
  log "PUBLIC=${PUBLIC_HOST}:${PUBLIC_PORT} PUBLIC_IP=${PUBLIC_IP:-unknown} OUTBOUND_IP=${OUTBOUND_IP:-unknown} MUX_PORT=${MUX_PORT}"
  mkdir -p "$WORK" "$OUT"
  ensure_ssh_server
  ensure_mux_ssh_entry
  install_xray
  write_state
  write_mux
  write_xray_configs
  write_client_configs
  write_restore
  cp -f "$0" "$WORK/vpnmux-xray-dual.sh" 2>/dev/null || true
  chmod 755 "$WORK/vpnmux-xray-dual.sh" 2>/dev/null || true
  write_quick_cmd
  pretest
  if supervisor_usable; then
    patch_supervisor
    write_handoff
    handoff="$WORK/bootstrap/handoff.sh"
    log "检测到 supervisor，使用 supervisor 托管。"
  else
    warn "未检测到可用 supervisor，降级为 process/nohup 托管；当前 SSH 可能会短暂断开。"
    write_process_handoff
    handoff="$WORK/bootstrap/process-handoff.sh"
  fi
  log "开始后台切换。当前 SSH 可能短暂断开。"
  nohup bash "$handoff" >/dev/shm/vpnmux-handoff-launch.log 2>&1 &
  wait_for_handoff
  ok "已准备完成。客户端配置：$OUT/IMPORT_THIS_CLASH_META_COMBINED.yaml"
  echo "入口信息    : $OUT/endpoint-info.txt"
  echo "VMess URI   : $OUT/vmess-uri.txt"
  echo "VLESS URI   : $OUT/vless-reality-uri.txt"
  echo "状态命令    : ${QUICK_CMD} status 或 bash $WORK/vpnmux-xray-dual.sh status"
  echo "恢复 SSH    : bash $WORK/restore-ssh.sh"
}

status(){
  echo "========== VPNMux status =========="
  [ -f "$WORK/state.env" ] && . "$WORK/state.env" || true
  [ -f "$WORK/state.env" ] && awk -F= '$1 !~ /PRIVATE|SSHD_EXTRA_OPTS/ {print}' "$WORK/state.env" || true
  echo "--- supervisor ---"
  if have supervisorctl && [ -f "$CONF" ]; then supervisorctl -c "$CONF" status | grep -E 'ssh|vpnmux' || true; fi
  echo "--- process pid files ---"
  find "$WORK/run" -maxdepth 1 -type f -name '*.pid' -print -exec cat {} \; 2>/dev/null || true
  echo "--- listeners ---"
  local ports="${MUX_PORT:-2222}|${SSH_INNER_PORT:-2223}|${VMESS_PORT:-2224}|${REALITY_PORT:-2225}"
  ss -lntup 2>/dev/null | grep -E ":(${ports})\\b" || true
  echo "--- local probes ---"
  if probe_ssh_banner "${MUX_PORT:-2222}"; then echo "SSH banner on mux port: OK"; else echo "SSH banner on mux port: FAIL"; fi
  if [ -n "${WS_PATH:-}" ] && [ -n "${PUBLIC_HOST:-}" ] && probe_ws_upgrade "${MUX_PORT:-2222}"; then echo "VMess-WS upgrade on mux port: OK"; else echo "VMess-WS upgrade on mux port: FAIL"; fi
  if probe_public_tcp; then echo "public TCP ${PUBLIC_HOST}:${PUBLIC_PORT}: OK"; else echo "public TCP ${PUBLIC_HOST:-unknown}:${PUBLIC_PORT:-unknown}: unchecked/fail"; fi
  echo "--- files ---"
  ls -l "$OUT" 2>/dev/null || true
}

restore(){
  need_root
  if [ -x "$WORK/restore-ssh.sh" ]; then bash "$WORK/restore-ssh.sh"; else fail "找不到 $WORK/restore-ssh.sh"; fi
  ok "恢复流程已执行。"
}

case "$ACTION" in
  deploy|install) deploy ;;
  status) status ;;
  restore|uninstall) restore ;;
  *) echo "Usage: bash $0 {deploy|status|restore}"; exit 2 ;;
esac
