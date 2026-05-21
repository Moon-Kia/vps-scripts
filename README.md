# VPS / 免费容器代理脚本集合

迁移自 `fenghuixianyu` 的私有 gist，并增加了 VPNMux + Xray 双节点脚本。

## VPNMux + Xray 双节点

适用于：

- SSH 公网入口是原始 TCP 转发；
- 容器没有 `TUN` / `CAP_NET_ADMIN`；
- 需要在同一个公网 SSH 端口上复用 SSH、VMess-WS、VLESS-REALITY。

一键安装：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/g8562006/vps-scripts/main/vpnmux-xray-dual.sh) deploy
```

如果自动识别公网入口失败，手动指定：

```bash
PUBLIC_HOST=你的公网域名 PUBLIC_PORT=你的公网端口 \
  bash <(curl -fsSL https://raw.githubusercontent.com/g8562006/vps-scripts/main/vpnmux-xray-dual.sh) deploy
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
/root/vpnmux/out/IMPORT_THIS_CLASH_META_COMBINED.yaml
/root/vpnmux/out/vmess-uri.txt
/root/vpnmux/out/vless-reality-uri.txt
```

## 稳定性修补

本仓库版本对旧脚本做了以下稳定性修补：

- 不再只因为 `systemctl list-unit-files` 可用就误判为 systemd；必须同时满足 `/run/systemd/system` 存在且 `systemctl is-system-running` 可用。
- 对 `dumb-init`、`supervisord`、普通容器环境优先降级到 process/nohup 守护。
- VPNMux 脚本不绑定 Zcomputer，支持通过 `PUBLIC_HOST` / `PUBLIC_PORT` / `MUX_PORT` 显式指定入口。
