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
  PUBLIC_HOST="${PUBLIC_HOST:-$(parse_frpc_value serverAddr || true)}"
  PUBLIC_PORT="${PUBLIC_PORT:-$(parse_frpc_value remotePort || true)}"
  MUX_PORT="${MUX_PORT:-$(parse_frpc_value localPort || true)}"
  MUX_PORT="${MUX_PORT:-2222}"
  [ -n "$PUBLIC_HOST" ] || PUBLIC_HOST="$(hostname -f 2>/dev/null || hostname)"
  [ -n "$PUBLIC_PORT" ] || PUBLIC_PORT="$MUX_PORT"
  [ -n "$PUBLIC_IP" ] || PUBLIC_IP="$(resolve_host_ip "$PUBLIC_HOST" || true)"
  [ -n "$OUTBOUND_IP" ] || OUTBOUND_IP="$(detect_outbound_ip || true)"
}

arch_asset(){
  case "$(uname -m)" in
    x86_64|amd64) echo Xray-linux-64.zip ;;
    aarch64|arm64) echo Xray-linux-arm64-v8a.zip ;;
    armv7l|armv7*) echo Xray-linux-arm32-v7a.zip ;;
    *) fail "不支持架构：$(uname -m)" ;;
  esac
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
  mkdir -p "$WORK" "$OUT" "$WORK/bootstrap"
  chmod 700 "$WORK" "$WORK/bootstrap" 2>/dev/null || true
  if [ -f "$WORK/state.env" ]; then . "$WORK/state.env" || true; fi
  UUID="${UUID:-$(rand_uuid)}"
  WS_PATH="${WS_PATH:-/$(openssl rand -hex 12)-vmess}"
  REALITY_UUID="${REALITY_UUID:-$(rand_uuid)}"
  if [ -z "${REALITY_PRIVATE_KEY:-}" ] || [ -z "${REALITY_PUBLIC_KEY:-}" ]; then
    read -r REALITY_PRIVATE_KEY REALITY_PUBLIC_KEY < <(x25519_keys)
  fi
  REALITY_SHORT_ID="${REALITY_SHORT_ID:-$(openssl rand -hex 8)}"
  cat > "$WORK/state.env" <<STATE
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
LOG=/dev/shm/vpnmux-restore.log
exec >>"$LOG" 2>&1
echo "[$(date -Is)] restore start"
$SUP stop vpnmux-mux vpnmux-xray-vmess vpnmux-xray-reality ssh || true
pkill -f '/etc/vpnmux/mux.py' || true
pkill -f 'xray run -config /etc/vpnmux/xray-vmess-server.json' || true
pkill -f 'xray run -config /etc/vpnmux/xray-reality-server.json' || true
pkill -f 'sshd .*ListenAddress=127.0.0.1 .*2223' || true
if [ -f "$WORK/supervisord-user.conf.orig" ]; then cp -f "$WORK/supervisord-user.conf.orig" "$CONF"; fi
$SUP reread || true
$SUP update || true
$SUP start ssh || true
sleep 1
if ! timeout 2 bash -c '</dev/tcp/127.0.0.1/2222' >/dev/null 2>&1; then
  nohup /usr/sbin/sshd -D -e -p 2222 >>/dev/shm/vpnmux-fallback-sshd.log 2>&1 &
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
  nohup /usr/sbin/sshd -D -e -o ListenAddress=127.0.0.1 -p "$TS" >/dev/shm/vpnmux-pre-sshd.log 2>&1 & echo $! >/tmp/vpnmux_pre_sshd.pid
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
  python3 - <<PY "$CONF" "$WORK" "$MUX_PORT" "$SSH_INNER_PORT" "$VMESS_PORT" "$REALITY_PORT"
from pathlib import Path
import sys
conf=Path(sys.argv[1]); work=sys.argv[2]; mux,ssh,vm,re=sys.argv[3:]
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
        line=f'command=/usr/sbin/sshd -D -e -o ListenAddress=127.0.0.1 -p {ssh}'
    elif section == '[program:ssh]' and line.startswith('environment='):
        line=f'environment=PORT="{ssh}"'
    out.append(line)
base='\n'.join(out).rstrip()+"\n"
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
$SUP reread
$SUP update
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
start_one sshd-inner "/usr/sbin/sshd -D -e -o ListenAddress=127.0.0.1 -p $SSH_INNER_PORT" /dev/shm/vpnmux-sshd-inner.log
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
  nohup /usr/sbin/sshd -D -e -p "$MUX_PORT" >>/dev/shm/vpnmux-fallback-sshd.log 2>&1 & echo $! > "$RUN/fallback-sshd.pid"
  exit 1
fi
echo "[$(date -Is)] process handoff OK ssh=$ssh_ok ws=$ws_ok"
EOS_PROCESS_HANDOFF
  chmod 755 "$WORK/bootstrap/process-handoff.sh"
}

deploy(){
  need_root
  autodetect_public
  log "PUBLIC=${PUBLIC_HOST}:${PUBLIC_PORT} PUBLIC_IP=${PUBLIC_IP:-unknown} OUTBOUND_IP=${OUTBOUND_IP:-unknown} MUX_PORT=${MUX_PORT}"
  mkdir -p "$WORK" "$OUT"
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
  ok "已准备完成。客户端配置：$OUT/IMPORT_THIS_CLASH_META_COMBINED.yaml"
  echo "入口信息    : $OUT/endpoint-info.txt"
  echo "VMess URI   : $OUT/vmess-uri.txt"
  echo "VLESS URI   : $OUT/vless-reality-uri.txt"
  echo "状态命令    : ${QUICK_CMD} status 或 bash $WORK/vpnmux-xray-dual.sh status"
  echo "恢复 SSH    : bash $WORK/restore-ssh.sh"
}

status(){
  echo "========== VPNMux status =========="
  [ -f "$WORK/state.env" ] && awk -F= '$1 !~ /PRIVATE/ {print}' "$WORK/state.env" || true
  echo "--- supervisor ---"
  if have supervisorctl && [ -f "$CONF" ]; then supervisorctl -c "$CONF" status | grep -E 'ssh|vpnmux' || true; fi
  echo "--- process pid files ---"
  find "$WORK/run" -maxdepth 1 -type f -name '*.pid' -print -exec cat {} \; 2>/dev/null || true
  echo "--- listeners ---"
  ss -lntup 2>/dev/null | grep -E ':(2222|2223|2224|2225)\b' || true
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
