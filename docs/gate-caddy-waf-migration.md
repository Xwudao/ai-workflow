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

## 规则评估（2026-09-06）

当前规则覆盖 SQLi、XSS、路径穿越、敏感文件、RCE、SSRF、NoSQL 注入、Log4Shell、Java 反序列化与常见扫描器，基础覆盖已足够。后续优先级应是调优与访问控制，而不是盲目增加大量正则。

- `legacy-user-agent-1` 是旧规则迁移而来，包含 `python`、`Java`、`axios`、若干旧 Chrome 版本及大量爬虫标识等宽泛匹配；启用后的约 27 分钟内已触发 132 次拦截。确认其不会误伤合法客户端前，不宜继续扩大该类 UA 黑名单。
- WAF 当前未启用速率限制。若要启用基于真实客户端 IP 的限流，gate 位于多层代理之后，必须先确认并严格配置 `trusted_proxies`，否则会按 txsp/CDN 节点限流，可能造成所有用户被连带阻断。
- WAF 仅部署在 `:3001`、`:3006`、`:3010`；其余公开 Caddy 路由未受新版 WAF 保护。建议逐站点以日志观察方式纳入，而非一次性全量启用。
- `max_request_body_size` 为 1 MiB；适合普通 API，但超过该大小的请求仅有前 1 MiB 被检查。上传型接口应结合业务允许的大小另行设限。

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

- 已将 WAF 日志级别调整为 `warn`，仅保留拦截与错误等重要事件；`info` 会记录大量正常请求。
- 已配置 `/etc/logrotate.d/caddy-waf`：每天轮转、单文件达到 50 MiB 时提前轮转、保留 14 份并压缩。因 WAF 直接追加写文件，规则使用 `copytruncate`，无需重启 Caddy 即可轮转。

- 回滚时恢复备份中的二进制和 `Caddyfile`，然后重启 Caddy。

## 内置 Dashboard（2026-09-06）

已为 `:3001`、`:3006`、`:3010` 上的 WAF 启用 caddy-waf 的只读 Dashboard 和 JSON metrics。Dashboard 显示请求/拦截量、规则命中、来源 IP/国家和近期拦截；不会修改规则或黑白名单。

- 新二进制：Caddy `v2.11.4` + caddy-waf `v0.4.14`，以 `with_ui` 构建标签编译。
- 当前二进制 SHA-256：`a027867c3821d88ed8e5023ffa5804f13176a5ad672b31c1ac6cda69a972ae26`
- 配置：每个 WAF 实例使用 `/waf` 和 `/waf_metrics`；三套实例的计数彼此独立。
- 访问控制：仅允许来自 `127.0.0.1`/`::1` 的请求访问这两个路径；公网实测均为 `404`。因此必须通过 SSH 隧道查看，避免暴露攻击来源、规则命中和流量统计。

本机运行 `scripts/open-gate-waf-dashboard.sh`，随后访问 <http://127.0.0.1:13001/waf>。脚本以前台方式保持 SSH 隧道；按 `Ctrl-C` 或关闭终端会自动停止转发。

```bash
./scripts/open-gate-waf-dashboard.sh
```

等效的手工命令：

```bash
ssh -N -L 127.0.0.1:13001:127.0.0.1:3001 gate
```

验证结果：`caddy validate` 通过，`caddy.service` 已使用 `restart` 重启并处于 `active`；隧道目标的 `/waf` 与 `/waf_metrics` 均返回 `200`，metrics schema 为 `2`。

本次切换备份位于服务器：

```text
/root/caddy-waf-ui-backup-20260906-145045
```

其中包含切换前的 `/etc/caddy/Caddyfile` 和 `/usr/local/sbin/caddy`，并有 `SHA256SUMS`。回滚时恢复这两个文件后执行：

```bash
sudo systemctl restart caddy
```
