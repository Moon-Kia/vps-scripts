# 迁移说明

当前目录是从 `fenghuixianyu` 私有 gist 备份并整理出的待迁移仓库内容。

## 已完成

- 已备份原 gist 到 `migration/fenghuixianyu-gist-backup/`。
- 已从原 `fenghuixianyu` gist 删除本次新增的：
  - `vpnmux-xray-dual.sh`
  - `README-vpnmux-xray-dual.md`
- 已在本地待迁移目录中加入泛化后的：
  - `vpnmux-xray-dual.sh`
  - `README.md`
- 已修补旧脚本的 systemd 误判问题：
  - `install-proxy.sh`
  - `cf-manager.sh`
  - `fbpanel-ngrok.sh`
  - `ngrok-ssh-pool.sh`
  - `tailscale-install.sh`

## 当前阻塞

本地 `【密钥】g8562006-GitHub for the AI.txt` 里的 token 认证出来仍是：

```text
fenghuixianyu
```

且 GitHub API 查询 `g8562006` 返回 404。当前凭证无法把仓库创建到 `g8562006` 名下。

请提供真正属于 `g8562006` 的 GitHub token，或先确认账号名是否拼写正确。

## 准备推送的仓库名建议

```text
vps-scripts
```

推送后 README 里的 raw URL 会指向：

```text
https://raw.githubusercontent.com/Moon-Kia/vps-scripts/main/vpnmux-xray-dual.sh
```


## 2026-05-21 更新

按要求，已从 fenghuixianyu 备份脚本恢复内置 ngrok / UptimeRobot / FileBrowser / SSH 默认值，并重新应用容器 systemd 误判修补。未在本文记录任何密钥明文。
