# Caddy 配置本地打包备份（gate / txsp2 / alhk）

脚本：`scripts/backup-caddy-configs.sh`，产物落在 `~/Backups/caddy-configs/<时间戳>/`。

## 用法

```bash
./scripts/backup-caddy-configs.sh              # 三台都备份
./scripts/backup-caddy-configs.sh gate         # 只备份 gate
CADDY_BACKUP_KEEP=10 ./scripts/backup-caddy-configs.sh   # 只留最近 10 份（默认 30）
CADDY_BACKUP_DIR=/tmp/x ./scripts/backup-caddy-configs.sh
```

产物结构：

```
~/Backups/caddy-configs/20261021-185844/
├── gate-etc-caddy.tar.gz          # 整个 /etc/caddy
├── gate-filelist.txt              # 打包了哪些文件（不含 *.env）
├── gate-caddy-version.txt         # caddy version，恢复时核对二进制版本
├── txsp2-…（同上）
├── alhk-…（同上）
└── SHA256SUMS
```

## 覆盖范围与排除项

- 打包**整个 `/etc/caddy`**：Caddyfile、`waf/`（rules.json / ip_blacklist.txt / ip_whitelist.txt）、`blocks/`（自动生成的封禁片段）、`rule/`，以及历史上留的 `Caddyfile.before-*` 备份文件。
- **排除 `*.env`**：txsp2 的 `/etc/caddy/cf.env` 里是 Cloudflare API Token（`{env.CF_API_TOKEN}` 给 DNS-01 签发用）。凭据不进备份、也不在文档里出现；恢复时需要单独重新放置。
- 排除 `*.tmp`（脚本写片段时的临时文件）。

## 恢复

```bash
# 在某台机器上
cd /tmp && tar -xzf gate-etc-caddy.tar.gz -C /tmp      # 解出 caddy/
sudo tar -xzf gate-etc-caddy.tar.gz -C /etc --strip-components=0   # 覆盖回 /etc/caddy
# 凭据文件需要单独恢复（txsp2: /etc/caddy/cf.env, 600 caddy:caddy）
sudo caddy validate --config /etc/caddy/Caddyfile       # 注：txsp2/alhk 因 {env.CF_API_TOKEN} 未设置会报错，改用 caddy adapt
sudo systemctl reload caddy
```

## 注意

1. 该脚本只是**配置**备份，不含二进制、证书（证书在 `/var/lib/caddy`）、也不含日志。
2. `banned.caddyfile` 是自动生成的运行时产物，恢复旧备份会把封禁列表一起回退 —— 下一次 timer 触发会自动重建（`state.json` 在 `/var/lib/gate-ipguard/`，不随备份恢复）。
3. 建议配合 cron 每天跑一次，例如：
   ```cron
   15 4 * * * /Users/tim/Codes/ai-workflow/scripts/backup-caddy-configs.sh >> ~/Backups/caddy-backup.log 2>&1
   ```
