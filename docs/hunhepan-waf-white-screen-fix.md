# hunhepan.com WAF 白屏修复

> 处理时间：2026-09-06 23:48
> 结果：保留 txsp 与 gate 两层 WAF；首页恢复，攻击载荷仍被拦截。

## 现象

`https://hunhepan.com/` 返回 `HTTP 200` 但 body 长度为 0，浏览器表现为白屏。

链路为：`Cloudflare → txsp → gate:3001 → app3:3765 (go-hunhepan)`。

## 根因

问题不在 app3 后端，也不是正常 WAF 规则集整体不能使用。

1. **txsp 的 hunhepan 使用了 named route + `invoke hunhepan-waf-proxy` 的特殊 WAF 配置路径。**
   - 该路径下，现代 Chrome UA 访问首页得到 `200 / 0B`。
   - app3 直连、gate:3001（gate WAF 开启）和 txsp 的其它常规 `import waf` 站点均能正常返回完整响应体。
   - 因此是 txsp 上该 named route 的 WAF 执行路径吞掉了正常响应体，而非命中某条拦截规则。

2. `legacy-user-agent-1` 是迁移旧 WAF 时带入的宽泛 UA 黑名单，明确误伤。
   - pattern 包含 `Chrome/91.0.4472.124`、`python`、`Java`、`axios`、`ubuntu`、`Go-http-client`、`HttpClient` 等。
   - 实测 Chrome/91 被该规则 `403` 拦截。

`curl` 默认 UA 得到 `system overload` 是 go-hunhepan 对脚本 UA 的应用行为；使用真实浏览器 UA 时后端首页正常，不能将其误判为后端故障。

## 最终变更

### txsp：hunhepan 改为标准 WAF 路由

`/etc/caddy/Caddyfile` 的公网 hunhepan site 改为与 txsp 的正常 WAF 站点、gate:3001 一致的标准结构：

```caddyfile
api.hunhepan.com:80 www.hunhepan.com:80 hunhepan.com:80 {
    import waf-dashboard-local
    import logger hunhepan.log
    import cfproxy to 110.40.167.56:3001
    import waf
}
```

不再在公网 hunhepan site 使用 `invoke hunhepan-waf-proxy`。因此公网路径仍为：

```text
Cloudflare → txsp WAF → gate:3001 WAF → app3:3765
```

原 named route 仍只被本机 `127.0.0.1:13002` 的旧 Dashboard 路由使用，**其计数不再代表公网 hunhepan 流量**；公网 WAF 的 `/waf`、`/waf_metrics` 仍由 `waf-dashboard-local` 限制为本机来源。

### txsp 与 gate：删除误伤 UA 规则

已从两台服务器的以下文件中删除完整规则对象 `legacy-user-agent-1`：

```text
/etc/caddy/waf/legacy-rules.json
```

保留了 `rules.json` 中的 `block-scanners` 规则及其余 SQLi、XSS、路径穿越、RCE、SSRF 等规则。

## 安全验证

变更后：

| 验证项 | 结果 |
|---|---|
| txsp，Chrome/120 UA，`GET /` | `200`，21455 B |
| txsp，原被误伤的 Chrome/91 UA，`GET /` | `200`，21455 B |
| 公网，Chrome/120 UA，`https://hunhepan.com/` | `200`，21455 B |
| txsp，SQLi `/?q=' union select 1--` | `403 Request blocked by WAF` |
| txsp / gate `caddy validate` | 通过 |
| txsp / gate `caddy.service` | reload 后均为 `active` |

## 备份与回滚

最终修改前备份（两台服务器）：

```text
/root/hunhepan-waf-route-fix-backup-20260906-234824/
```

内容包括受影响的 `Caddyfile`、`legacy-rules.json` 与 `SHA256SUMS`。

若需要回滚，在对应服务器恢复备份文件后执行：

```bash
sudo systemctl reload caddy
```

此前用于临时关闭 hunhepan WAF 的备份位于：

```text
/root/caddy-hhp-waf-disable-backup-20260906-234210/
```

该临时关闭已撤销；当前 hunhepan 的两层 WAF 均为启用状态。

## 后续建议

- 不要恢复 `legacy-user-agent-1` 这种把大量 UA 合并为一条 block 规则的策略；如要屏蔽特定爬虫，应逐项、精准评估。
- 修改 `/etc/caddy/waf/legacy-rules.json` 后，检查 WAF 日志中的误拦截；修改 Caddyfile 后先 `caddy validate` 再 `systemctl reload caddy`。

## 后续整理：Dashboard 与精准 UA 规则（2026-09-06 23:56）

### 移除无用 named WAF 路由，保留生产 Dashboard

txsp 的 `hunhepan-waf-proxy` named route 已完全删除（不再有任何引用）。它是此前吞掉正常响应体的配置路径，公网 hunhepan 已不依赖它。

原本 `127.0.0.1:13002` 通过 named route 共享 Dashboard；现在改为一个仅回环监听的反代：

```caddyfile
http://127.0.0.1:13002 {
    bind 127.0.0.1
    reverse_proxy 127.0.0.1:80 {
        header_up Host hunhepan.com
    }
}
```

因此原 SSH 隧道/脚本仍可用：`ssh -N -L 127.0.0.1:13002:127.0.0.1:13002 txsp`。该入口会请求真正的生产 hunhepan WAF 实例的 `/waf`，不是独立/空的 WAF 计数器。验证 `http://127.0.0.1:13002/waf` 返回 `200`、3072 B。

### 精准 UA 拦截规则

在 **txsp 和 gate** 的 `/etc/caddy/waf/rules.json` 同步新增两条 `phase: 1`、`HEADERS:User-Agent`、`score: 10`、`action: block` 规则：

- `block-commercial-seo-crawlers`：AhrefsBot、SemrushBot、DotBot、MJ12bot、BLEXBot、DataForSeoBot、MegaIndex、serpstatbot、SEOkicks、Barkrowler、AwarioBot、CensysInspect、ZoominfoBot。
- `block-ai-training-crawlers`：GPTBot、ClaudeBot、ChatGPT-User、Google-Extended、CCBot、Bytespider、anthropic-ai、meta-externalagent。

规则只匹配明确 bot 名称；**不**匹配浏览器版本、`python`、`Java`、`axios`、`curl` 或通用 HTTP 客户端标识。现有 `block-scanners` 及 SQLi/XSS/RCE 等规则均保留。

验证：Chrome/120、此前被误杀的 Chrome/91 首页均为 `200 / 21455 B`；AhrefsBot、GPTBot 在 txsp 返回 `403`，AhrefsBot 在 gate:3001 同样返回 `403`。

### 本机配置归档

两台服务器的 Caddy 配置已保存到本机（目录与压缩包权限均为仅当前用户可读）：

```text
~/Backups/caddy-config-backup-20260906-235637/
├── txsp-caddy-config.tar.gz
├── gate-caddy-config.tar.gz
└── SHA256SUMS
```

每个压缩包已执行 `tar -tzf` 完整性校验；包含 `/etc/caddy`、Caddy systemd unit、WAF logrotate 配置。压缩包可能含服务凭据，应仅在受控本机保存，不得外传或提交到仓库。
