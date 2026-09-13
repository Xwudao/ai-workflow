# xwd.pw → panso.me：m14 / m15 入口域名并行迁移

> 执行时间：2026-09-13。目标：在 `xwd.pw` 到期前，让 `m14.xwd.pw` / `m15.xwd.pw` 的入口能力在 `panso.me` 上并行可用；过渡期内**两套域名同时生效**，`xwd.pw` 不删除。

## 背景

- `m14.xwd.pw` / `m15.xwd.pw` 是两台服务器的 TLS 入口（`/tim` WebSocket → 本机 `127.0.0.1:3344`），分别对应 SSH 别名 `txhk`、`txsp`。
- `xwd.pw` 后续会过期弃用，需要把入口域名平移到账户内已有的 `panso.me`。
- 迁移原则：先加新域名（不删旧域名），验证通过后再择期下线旧域名。

## 拓扑

| 入口域名 | 服务器（SSH 别名） | 公网 IP | Caddy 站点 | 上游 |
|---|---|---|---|---|
| `m14.xwd.pw` / `m14.panso.me` | `txhk`（hostname `ubuntu`） | `43.161.227.45` | `/etc/caddy/Caddyfile` | `@websockets path /tim` → `127.0.0.1:3344` |
| `m15.xwd.pw` / `m15.panso.me` | `txsp` | `43.134.116.41` | `/etc/caddy/Caddyfile` | 同上 |

- DNS 全部为 **DNS only（灰云）**，因为入口做的是源站 TLS 终止 + WebSocket，不能走 Cloudflare 代理。
- 证书：Caddy 自动 ACME（Let's Encrypt），新域名通过 `tls-alpn-01` / `http-01` 签发。

## 变更内容

### 1. DNS（Cloudflare，zone `panso.me`）

在 `panso.me` zone 新增两条与 `xwd.pw` 完全一致的 A 记录（`proxied=false`、`ttl=1` 自动）：

| 名称 | 类型 | 值 | Record ID |
|---|---|---|---|
| `m14.panso.me` | A | `43.161.227.45` | `a4225065997a720106b45262a378a403` |
| `m15.panso.me` | A | `43.134.116.41` | `fadc424387b0598b842a15949e22d7f3` |

对应的旧记录（保留不动）：

| 名称 | 类型 | 值 | Record ID | zone |
|---|---|---|---|---|
| `m14.xwd.pw` | A | `43.161.227.45` | `509e0fb730dfcae19d1aea20f27f3c4c` | `29db4e5b0cac8a2cb6c3b0655bb08d3c` |
| `m15.xwd.pw` | A | `43.134.116.41` | `38d8daed48283f864440ec191796a5ae` | 同上 |

> 凭证：Cloudflare DNS 凭证位于 `txsp:/etc/caddy/Caddyfile` 的 `(cfdns)` 片段（仅记录位置，不落盘明文）。`panso.me` zone id 为 `9382dd2e9474f7af79fe09f7b610a912`。

### 2. Caddyfile（多站点共用同一配置块）

只改站点标签行，配置体完全复用，两个域名各自独立签发证书：

```diff
- m14.xwd.pw {
+ m14.xwd.pw, m14.panso.me {
```

```diff
- m15.xwd.pw {
+ m15.xwd.pw, m15.panso.me {
```

变更前均先备份（同目录 Caddyfile 副本）：

- `txhk:/root/caddyfile-m14panso-backup-20260913-074137`
- `txsp:/root/caddyfile-m15panso-backup-20260913-154136`

生效方式：`caddy validate --config /etc/caddy/Caddyfile` 通过后 `systemctl reload caddy`（仅改配置，无需 restart）。

### 3. 客户端出站引用同步切换

`xwd.pw` 过期会直接打断这些出站，故同步改为 `panso.me`（服务端 Caddy 站点仍同时保留两套域名，回退只影响客户端）：

| 位置 | 文件 | 改动 | 备份 |
|---|---|---|---|
| `txhk`（v2ray 客户端出站） | `/usr/local/etc/v2ray/config.json` | `outbounds[proxy].vnext[0].address` 与 `tlsSettings.serverName`：`m15.xwd.pw` → `m15.panso.me` | `/root/v2ray-config-backup-20260913-074528.json` |
| `app3`（sing-box 出站） | `/etc/sing-box/config.json` | `proxy`（→ `m14.xwd.pw`）与 `vmess-2`（→ `m15.xwd.pw`）的 `server` / `tls.server_name` 全部改为 `*.panso.me` | `/root/singbox-config-backup-20260913-155037.json` |

切换前均在服务器上用**临时实例**（独立 socks 入站 + 同一出站）做端到端验证，确认 vmess/ws/tls 隧道可达后再动生产配置：

- `txhk`：临时 `v2ray run` 实例 socks `10810/10811`，`curl -x socks5h://… https://www.gstatic.com/generate_204` → `204`。
- `app3`：`sing-box check` 通过后 `systemctl reload sing-box`；`socks-in:38080`（→ `m14.panso.me`）与 `socks-in-2:38081`（→ `m15.panso.me`）各测一次 → 均 `204`，journal 无报错。
- `txhk` 用 `install` 保留原属主/权限后 `systemctl restart v2ray`（配置生效后确认监听 `127.0.0.1:3344` 正常）。

## 验证结果

| 检查项 | 结果 |
|---|---|
| `dig`（DoH）解析 | `m14.panso.me → 43.161.227.45`、`m15.panso.me → 43.134.116.41` |
| 证书 | CN 分别为 `m14.panso.me` / `m15.panso.me`，Let's Encrypt（`YE2`），有效期至 2026-12-12 |
| 站内自测（`--resolve …:443:127.0.0.1`） | 新老域名 `GET /` 与 `GET /tim` 均 `200`，行为一致 |
| 公网自测（真实 IP + SNI） | `https://m14.panso.me/`、`https://m15.panso.me/` 均 `200` |
| 旧域名回归 | `m14.xwd.pw` / `m15.xwd.pw` 证书与响应不变 |
| Caddy | 两机 `systemctl is-active caddy` = `active`，reload 期间无中断 |

> 首次 reload 时 `m15.panso.me` 因新记录尚未传播出现一次 ACME NXDOMAIN，Caddy 60s 后自动重试成功；属预期现象，无需人工干预。

## 回滚

1. 还原 Caddyfile：`cp -a <对应备份> /etc/caddy/Caddyfile && caddy validate --config /etc/caddy/Caddyfile && systemctl reload caddy`。
2. 删除新增 DNS 记录（可选，不影响旧域名）：

```bash
curl -X DELETE -H "Authorization: Bearer $CF_TOKEN" \
  "https://api.cloudflare.com/client/v4/zones/9382dd2e9474f7af79fe09f7b610a912/dns_records/a4225065997a720106b45262a378a403"
curl -X DELETE -H "Authorization: Bearer $CF_TOKEN" \
  "https://api.cloudflare.com/client/v4/zones/9382dd2e9474f7af79fe09f7b610a912/dns_records/fadc424387b0598b842a15949e22d7f3"
```

3. 回滚不会影响 `xwd.pw` 记录与其证书。
4. 客户端回滚：还原上表备份文件（`txhk` 重启 `v2ray`、`app3` `systemctl reload sing-box`）。

## 现状与后续待办

已全量切换（`txhk` / `txsp` / `app3` 扫描 `/etc`、`/usr/local/etc`、`/opt`、`/root` 后，除下列项外无 `m14/m15.xwd.pw` 残留引用）：

- `m14.xwd.pw` / `m15.xwd.pw` 仅作为 Caddy 站点的**兼容入口**保留，与 `panso.me` 并存。
- `reman.xwd.pw`（`txsp:/etc/caddy/Caddyfile`）及其在 `app3` 各业务 `config.yml` / sitemap 中的引用**未动**，需在 `xwd.pw` 过期前单独迁移。

`xwd.pw` 到期前需要做：

1. 确认所有客户端（SSH、代理客户端）已改用 `m14/m15.panso.me`。
2. 迁移 `reman.xwd.pw` 到 `panso.me` 等效子域，并同步 `app3` 业务配置与 sitemap。
3. 从 `txhk` / `txsp` 的 Caddyfile 中移除 `m14.xwd.pw` / `m15.xwd.pw` 站点标签，并删除 `xwd.pw` zone 记录。
