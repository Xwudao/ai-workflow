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

## 内置 Dashboard（2026-09-06）

已为 hunhepan、reman、v2fd 三个 WAF 实例启用 caddy-waf 的只读 Dashboard 与 JSON metrics。Dashboard 显示请求/拦截量、规则命中、来源 IP/国家和近期拦截，不能修改任何 WAF 状态。

- 新二进制：Caddy `v2.11.4` + caddy-waf `v0.4.14`，以 `with_ui` 构建标签编译。
- 当前二进制 SHA-256：`a027867c3821d88ed8e5023ffa5804f13176a5ad672b31c1ac6cda69a972ae26`
- `/waf` 与 `/waf_metrics` 仅允许来源为 `127.0.0.1` / `::1` 的请求；公网端点不返回 Dashboard 或 metrics。
- hunhepan 的 Dashboard 使用 txsp 本机 `127.0.0.1:13002` 作为 SSH 隧道目标，其数据对应 hunhepan WAF 实例。Caddy 对该端口实际绑定为 `127.0.0.1:13002`（并非 `0.0.0.0`）；公共 hunhepan 路由和本地 Dashboard 通过同一个 Caddy named route 复用同一套 WAF 计数器。

本机运行下面的脚本后，访问 <http://127.0.0.1:13002/waf>。脚本以前台方式保持 SSH 隧道；按 `Ctrl-C` 或关闭终端会自动停止转发：

```bash
./scripts/open-txsp-waf-dashboard.sh
```

已验证：`caddy validate` 成功、`caddy.service` 使用 `restart` 重启后处于 `active`，服务器本机 `/waf` 和 `/waf_metrics` 均返回 `200`（metrics schema `2`）。

本次切换及回环绑定修复的服务器备份：

```text
/root/caddy-waf-ui-backup-20260906-145644
/root/caddy-waf-ui-bind-fix-20260906-150440
/root/caddy-waf-ui-bind-fix2-20260906-150523
```

该目录包含切换前的 `Caddyfile`、二进制和 `SHA256SUMS`。回滚时恢复这两个文件后执行：

```bash
sudo systemctl restart caddy
```
