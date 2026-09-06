# txsp：Caddy / WAF 升级记录

> 完成时间：2026-09-06

## 结果

- Caddy：`v2.10.2` → `v2.11.4`
- WAF：`github.com/Xwudao/caddy-waf v0.0.5` → `github.com/fabriziosalmi/caddy-waf v0.4.14`
- 服务：`caddy.service`，当前为 `active`
- 验证：向 `api.hunhepan.com` 的本机 HTTP 入口发送 SQL 注入测试载荷，返回 `403 Forbidden`。

## 保留与迁移内容

新二进制保留并升级了原有模块：

- Cloudflare DNS provider
- dynamic DNS
- transform encoder

旧 WAF 的规则和名单已迁移：

```text
/etc/caddy/waf/rules.json          # 新项目内置规则
/etc/caddy/waf/legacy-rules.json   # 旧 args / POST / UA 规则转换结果
/etc/caddy/waf/ip_blacklist.txt    # 旧 IP 黑名单
/etc/caddy/waf/ip_whitelist.txt    # 旧 IP 白名单
/var/log/caddy/waf.json            # 新 WAF JSON 日志
```

WAF 仍只在原先启用 WAF 的 hunhepan、reman、v2fd 三个站点生效。

## 备份与本地二进制

服务器切换前的完整备份：

```text
/root/caddy-waf-migration-backup-20260906-124931
```

本地二进制备份：

```text
~/Backups/caddy-txsp-v2.11.4-fabriziosalmi-waf-v0.4.14-linux-amd64
```

SHA-256：

```text
54270a8ad23175a535e3f4b53d56b90ba6bd70001de0e020f26fd30d94329020
```

## 注意事项

- Caddy systemd 服务以 `caddy` 用户运行，所以 `/etc/caddy/Caddyfile` 必须可读（当前权限为 `644`）。
- WAF 日志文件权限为 `caddy:caddy`、`640`；若文件不存在可执行：

  ```bash
  install -m 640 -o caddy -g caddy /dev/null /var/log/caddy/waf.json
  ```

- 已将 WAF 日志级别调整为 `warn`，避免 `info` 级别记录每个正常请求。
- 已配置 `/etc/logrotate.d/caddy-waf`：每天轮转、达到 50 MiB 提前轮转、保留 14 份并压缩；使用 `copytruncate`，无需重启 Caddy。

- 修改 WAF 规则或 IP 黑白名单时，文件监听会自动热加载。
- 修改 Caddyfile 时使用 `systemctl reload caddy`。
- 更换二进制或 Go 模块实现时必须 `systemctl restart caddy`，不能只 reload。
- `hunhepan` 会同时经过 txsp 和 gate 的新版 WAF；如出现误拦截，应同时检查两台服务器的 `/var/log/caddy/waf.json`。
