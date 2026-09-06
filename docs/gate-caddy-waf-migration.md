# gate：Caddy WAF 迁移记录

> 完成时间：2026-09-06

## 目标

将 `gate` 上原有的 `github.com/Xwudao/caddy-waf v0.0.5` 替换为 `github.com/fabriziosalmi/caddy-waf v0.4.14`，同时保留既有的 Cloudflare DNS、dynamic DNS 和日志 transform 插件。

## 最终状态

- Caddy：`v2.11.4`
- WAF：`github.com/fabriziosalmi/caddy-waf v0.4.14`
- systemd 服务：`caddy.service`，状态 `active`
- WAF 覆盖范围：保留原先启用 WAF 的 `:3001`、`:3006`、`:3010`
- 规则总数：60
  - 项目内置规则：33
  - 从旧 WAF 迁移的参数、POST、User-Agent 规则：27
- IP 黑名单：127 条有效记录
- IP 白名单：2 条记录

已在服务器本机验证：请求 `/?q=' union select 1--` 至受保护的 `:3001` 返回 `403 Forbidden`。

## 备份

切换前已创建服务器备份：

```text
/root/caddy-waf-migration-backup-20260906-122948
```

备份包括：

- `/etc/caddy/`
- `/etc/systemd/system/caddy.service`
- 原 `/usr/local/sbin/caddy`
- `SHA256SUMS`

本地还保存了新二进制：

```text
~/Backups/caddy-gate-v2.11.4-fabriziosalmi-waf-v0.4.14-linux-amd64
```

SHA-256：

```text
54270a8ad23175a535e3f4b53d56b90ba6bd70001de0e020f26fd30d94329020
```

## 当前配置与文件

```text
/etc/caddy/Caddyfile
/etc/caddy/waf/rules.json
/etc/caddy/waf/legacy-rules.json
/etc/caddy/waf/ip_blacklist.txt
/etc/caddy/waf/ip_whitelist.txt
/var/log/caddy/waf.json
```

`Caddyfile` 全局使用了：

```caddyfile
order waf before reverse_proxy
```

以保证 WAF 始终在反向代理之前执行。

WAF 的关键参数：

```caddyfile
anomaly_threshold 10
max_request_body_size 1048576
log_json
log_path /var/log/caddy/waf.json
redact_sensitive_data
```

旧规则已转为 JSON 规则，保留其直接阻断行为（`action: "block"`）；原 IP 黑/白名单分别迁移到新 WAF 对应文本文件。

## 构建方式

由于服务器位于国内，二进制在本地 macOS 交叉编译后通过 `scp` 上传；Go 模块优先使用：

```bash
GOPROXY='https://goproxy.cn|direct'
```

构建时保留的模块：

```bash
xcaddy build v2.11.4 \
  --with github.com/fabriziosalmi/caddy-waf@v0.4.14 \
  --with github.com/caddy-dns/cloudflare@v0.2.4 \
  --with github.com/caddyserver/transform-encoder@v0.0.0-20260423033309-ba4124974830 \
  --with github.com/mholt/caddy-dynamicdns@v0.0.0-20260805195708-67d107a42c02
```

## 运维说明

- 修改 `/etc/caddy/waf/rules.json`、`legacy-rules.json`、IP 黑名单后，WAF 文件监听会热加载。
- 修改 `/etc/caddy/Caddyfile` 后执行：

  ```bash
  sudo systemctl reload caddy
  ```

- 若再次替换 **Caddy 二进制或 WAF 模块实现**，不能只 reload，必须：

  ```bash
  sudo systemctl restart caddy
  ```

  因为 reload 会把新配置交给当前运行中的旧二进制，无法替换已加载的 Go 模块代码。
- WAF 日志文件必须让 `caddy:caddy` 可写：

  ```bash
  sudo install -m 640 -o caddy -g caddy /dev/null /var/log/caddy/waf.json
  ```

- 回滚时恢复备份中的二进制和 `Caddyfile`，然后重启 Caddy。
