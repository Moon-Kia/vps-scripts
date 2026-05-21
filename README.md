# VPS / 免费容器代理脚本集合

迁移自 `fenghuixianyu` 的私有 gist，并增加了 VPNMux + Xray 双节点脚本。

## VPNMux + Xray 双节点

适用于：

- SSH 公网入口是原始 TCP 转发；
- 容器没有 `TUN` / `CAP_NET_ADMIN`；
- 需要在同一个公网 SSH 端口上复用 SSH、VMess-WS、VLESS-REALITY。

一键安装：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/Moon-Kia/vps-scripts/main/vpnmux-xray-dual.sh) deploy
```

部署时会自动探测并保存：

- `PUBLIC_HOST` / `PUBLIC_PORT`：公网入口，优先从常见 `frpc` 配置读取；
- `PUBLIC_IP`：`PUBLIC_HOST` 当前解析到的入口 IPv4；
- `OUTBOUND_IP`：容器访问公网时暴露的出口 IPv4。
- SSH 前置条件：缺少 `sshd` 时自动安装 OpenSSH Server，自动生成 host key，创建 `/run/sshd`，必要时先在 `MUX_PORT` 拉起临时 SSH 占位，再切换成 VPNMux。
- 部署末尾会等待后台切换并做本地 SSH/VMess-WS 验证；若公网入口从容器内无法回连，会给出提示但不直接判死刑。
- 不再把 `modal`、`localhost`、`127.0.0.1`、内网 IP 或无点短主机名误当公网入口；如果平台没有开启 SSH/TCP 映射，会停止生成客户端配置并提示手动传入 `PUBLIC_HOST` / `PUBLIC_PORT`。
- 默认不启用 ngrok 兜底；脚本会先打开容器内 SSH，再等待并扫描环境变量、进程、`/__substrate`、`/etc/zo`、`/run`、`/tmp`、`/var/log` 等平台状态/日志里的 SSH 命令、`frpc` 配置和公网入口。需要 ngrok 兜底时手动加 `AUTO_NGROK_PUBLIC=on`。

如新容器没有 root 密码，但需要复用端口继续保留 SSH 登录能力，可显式传入：

```bash
SSH_PASSWORD='你的root密码' bash <(curl -fsSL https://raw.githubusercontent.com/Moon-Kia/vps-scripts/main/vpnmux-xray-dual.sh) deploy
```

如果自动识别公网入口失败，手动指定：

```bash
PUBLIC_HOST=你的公网域名 PUBLIC_PORT=你的公网端口 \
  bash <(curl -fsSL https://raw.githubusercontent.com/Moon-Kia/vps-scripts/main/vpnmux-xray-dual.sh) deploy
```

状态：

```bash
vpnmux status
```

恢复：

```bash
bash /etc/vpnmux/restore-ssh.sh
```

输出：

```text
/root/vpnmux/out/endpoint-info.txt
/root/vpnmux/out/IMPORT_THIS_CLASH_META_COMBINED.yaml
/root/vpnmux/out/vmess-uri.txt
/root/vpnmux/out/vless-reality-uri.txt
```

## 稳定性修补

本仓库版本对旧脚本做了以下稳定性修补：

- 不再只因为 `systemctl list-unit-files` 可用就误判为 systemd；必须同时满足 `/run/systemd/system` 存在且 `systemctl is-system-running` 可用。
- 对 `dumb-init`、`supervisord`、普通容器环境优先降级到 process/nohup 守护。
- VPNMux 脚本不绑定 Zcomputer，支持自动捕获公网入口/解析 IP/出口 IP，也支持通过 `PUBLIC_HOST` / `PUBLIC_PORT` / `MUX_PORT` 显式指定入口。
- VPNMux 会自动补齐 SSH 服务端前置条件；如果平台没有真正给容器做公网端口映射，脚本只能打开容器内监听并在状态页提示公网 TCP 检测失败，不能凭空创建平台外层 NAT/FRP 映射。
- 当平台外层映射不可控时，可手动打开 `AUTO_NGROK_PUBLIC=on` 使用 ngrok TCP 作为兜底公网入口；这属于用户态反向隧道，不依赖容器具备公网入站权限，但速度/稳定性取决于 ngrok 免费线路和 token 额度。
- Zo/Modal 这类 Web Terminal 环境里，容器 hostname 可能是 `modal` 且解析到 `127.0.0.1`；这只是容器内部地址，不能写进客户端配置。必须先开启平台 SSH/TCP 入口，或把平台显示的 `ssh -p 端口 user@host` 拆成 `PUBLIC_HOST=host PUBLIC_PORT=端口` 后部署。
