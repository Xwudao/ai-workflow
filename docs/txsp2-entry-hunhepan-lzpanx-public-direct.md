# hunhepan / lzpanx 公网入口回到 txsp2(SG)，后台改走 gate 公网直连（2026-10-16）

## 背景与动机

最近几天 `hunhepan` / `lzpanx` 的公网入口反复迁移（txsp2 → txhk → RainYun HK，见
[`txhk-entry-hunhepan-lzpanx-migration.md`](txhk-entry-hunhepan-lzpanx-migration.md)、
[`rainyun-hk-entry-hunhepan-lzpanx.md`](rainyun-hk-entry-hunhepan-lzpanx.md)）。
RainYun 临时机曾出现 `ssh.socket` 不监听、且为 1C/1G 单点，不适合长期承载；
txhk 经 WireGuard 中转到 gate（`SG → HK → SH` 两跳）延迟与稳定性也不理想。

本次把 `hunhepan.com` / `lzpanx.com` 两组域名的公网入口**切回 txsp2(SG)**，并**保持 CF 橙云
（proxied=true）**；同时把 txsp2 上这两组站点的上游由 WireGuard 内网地址 `10.77.42.2`
改为**直连 gate 的公网 IP:端口** `110.40.167.56`，绕开经 txhk 的 WG 中继。

> 核心变化：入口在 SG，上游不再走 `sg-hk` WG 隧道，而是 SG → SH 公网直连。

## 变更后的拓扑

```text
                 ┌── hunhepan.com / www / api ──┐
CF (橙云, proxied)┤                              ├─→ txsp2(SG) Caddy :80 + WAF
                 └── lzpanx.com / www          ─┘        │
                                                          │ HTTP 110.40.167.56:3001 / :3006
                                                          │ （公网直连，不走 WireGuard）
                                                          ▼
                                          gate(SH) Caddy :3001/:3006 → app3 Go 服务
```

- **CDN 回源**：Cloudflare 橙云回源到源站 **HTTP :80**（Flexible），源站 txsp2 上这些域名
  定义为 `*.example.com:80`，无需证书，属既有设计。
- **上游**：`lzpanx` 组 → `110.40.167.56:3006`；`hunhepan` 组 → `110.40.167.56:3001`。
  与 gate 走 `wg-hksh` 访问的 `10.77.42.2:3001/3006` 是同一台 gate 的同一端口。

## 具体改动

### 1. Cloudflare DNS（cloudctl）

5 条 A 记录由 `43.161.227.45`（txhk）改为 `43.160.224.101`（txsp2），**保持 proxied=true**：

| zone | name |
|---|---|
| lzpanx.com | `lzpanx.com`、`www.lzpanx.com` |
| hunhepan.com | `@`、`www.hunhepan.com`、`api.hunhepan.com` |

命令：`cloudctl dns ensure --zone <z> --type A --name <n> --content 43.160.224.101 --proxied --json`
（5 条均返回 `action: update`）。

**未改动**：`panso.me @` 仍指向 `43.161.227.45`（txhk）——本次只涉及用户指定的两个域名；
txhk 上同款 `panso.me` 站点块仍在，可正常服务。如需一并切到 txsp2，改这一条即可。

### 2. txsp2：Caddy 上游由 WG 改公网

文件 `/etc/caddy/Caddyfile`，仅改 2 行（`lzpanx` / `hunhepan` 站点块）：

```diff
- 	reverse_proxy 10.77.42.2:3006 {
+ 	reverse_proxy 110.40.167.56:3006 {
...
- 	import cfproxy to 10.77.42.2:3001
+ 	import cfproxy to 110.40.167.56:3001
```

> 被注释的旧行 `#import cfproxy to 110.40.167.56:3006` 印证：公网直连本来就是这两站点的
> 原始形态，本次只是把上游从 WG 内网地址改回它。

生效方式：`caddy validate` 通过后 `systemctl reload caddy`（**仅改配置，无需 restart**）。

### 3. 补充：qkpanso.com（同日追加）

`qkpanso.com` / `www.qkpanso.com` 在 txsp2 上原本也走 WG，同日一并进行同样的改动：

```diff
- 	import cfproxy to 10.77.42.2:3007
+ 	import cfproxy to 110.40.167.56:3007
```

- **DNS 未改**：这两条 A 记录本就指向 txsp2（`43.160.224.101`，橙云），本次只改上游。
- 备份：`/etc/caddy/Caddyfile.bak.20261016142910`。
- 验证：txsp2 本机反代 `200`（0.14–0.83 s）；本地经 CF `www.qkpanso.com` `200`、`qkpanso.com` `301`（CF 层重定向）。
- 运行时配置经 Caddy admin API (`localhost:2019/config/`) 确认：`110.40.167.56:3007` 出现 1 处、`10.77.42.2:3007` 出现 0 处。

## 验证结果

在 txsp2 本机以 `Host:` 头直测 Caddy（`curl -H "Host: <域名>" http://127.0.0.1/`）：

| 域名 | 改前（走 WG 10.77.42.2） | 改后（公网 110.40.167.56） |
|---|---|---|
| `lzpanx.com` | **502**（约 5 s） | `200`（0.07–0.76 s） |
| `hunhepan.com` | `200`，**约 28.9 s** | `200`（约 0.07 s） |
| `www.hunhepan.com` | — | `200` |
| `api.hunhepan.com` | — | `200` |
| `qkpanso.com` | （当时 ~0.28 s，正常） | `200`（0.14–0.83 s） |

- 公网直连后端口/HTTP 时延稳定在 **~0.2 s**（对比 WG 路径的 5 s / 28.9 s）。
- `caddy validate` = `Valid configuration`；`systemctl reload caddy` OK；`caddy` active，监听 `:80`/`:443`。
- 本地经 CF 访问：`lzpanx.com` / `hunhepan.com` 返回 `301`（CF 层 `http→https` 重定向，属正常）。

## 备份与回滚

| 主机 | 路径 | 内容 |
|---|---|---|
| txsp2 | `/etc/caddy/Caddyfile.bak.20261016142321` | lzpanx/hunhepan 改前 Caddyfile（上游为 `10.77.42.2`） |
| txsp2 | `/etc/caddy/Caddyfile.bak.20261016142910` | qkpanso 改前 Caddyfile（上游为 `10.77.42.2:3007`） |

回滚步骤：

1. **Caddy**：`sudo cp /etc/caddy/Caddyfile.bak.20261016142321 /etc/caddy/Caddyfile && sudo caddy validate --config /etc/caddy/Caddyfile && sudo systemctl reload caddy`。
2. **DNS**：把上表 5 条记录改回原入口（txhk `43.161.227.45` 或 RainYun `154.37.222.86`，视当时目标）：
   `cloudctl dns ensure --zone <z> --type A --name <n> --content <原IP> --proxied --json`。
   txhk / RainYun 上的站点块仍在，改回即可恢复对应链路。

## 坑与注意

1. **`caddy validate` 会以 root 身份创建日志文件**，导致服务 `User=caddy` 启动/写入失败。
   本次只做了 `validate`（未 restart），但如后续需 restart，先修正
   `/var/log/caddy/*.log` 属主为 `caddy:caddy`（`chmod 640`），或改用 `sudo -u caddy caddy validate`。
2. **本地 macOS 的 `ping`/`nc`/`dig` 不可信**（透明代理假 ACK/假 IP），连通性判断一律用远端
   vantage（txsp2 / gate / txhk）。
3. **WG 链路的 TCP 端口探测会「假通」**：`/dev/tcp/10.77.42.2/3006` 能连上，但实际 HTTP
   反代 502 / 28.9 s，说明只看端口连通不足以判断后端可用，必须做应用层（HTTP）验证。
4. **`systemctl reload caddy` 期间本地 SSH 会话被断开**（`Connection to 43.160.224.101 closed by
   remote host`），本次连续出现 2 次，与 [txhk 迁移文档](txhk-entry-hunhepan-lzpanx-migration.md)
   记录的「restart 期间 SSH 抖动」同类，属 SG 线路问题；reload 本身仍执行成功。
   由于输出会被截断，**变更是否生效应改用 Caddy admin API 确认**：
   `sudo curl -s localhost:2019/config/ -o /tmp/cc.json` 后 `grep` 上游地址（运行时配置），
   不要只看 reload 命令的退出码。
5. **WAF 日志里的 `remote_addr` 是直连对端（CF 边缘 IP），不是被拦截的 IP（易误判）**：
   橙云回源时对端就是 Cloudflare 节点（`172.71.x / 104.23.x / 162.158.x`），日志的 `remote_addr`
   只记录 TCP 对端；而 `ip_blacklist` 实际命中 `X-Forwarded-For` 里的**真实客户端 IP**。
   黑名单 318 条全是客户端 IP，**不含任何 CF 段**。实测（txsp2 本机，来源 127.0.0.1）：
   无 XFF / `XFF=8.8.8.8` → `200`；`XFF=66.103.211.214`（黑名单条目）→ `403`，且该条日志的
   `remote_addr` 记的是 `127.0.0.1`。因此这是**正常防护，无需删除任何「边缘 IP」**。

## 遗留风险

- **SG 线路**：文档 [`txhk-entry-hunhepan-lzpanx-migration.md`](txhk-entry-hunhepan-lzpanx-migration.md)
  记录 2026-10-15 SG→SH 直连丢包 26–35%；本次但求「本地 → txsp2 → gate 公网」这条链路的
  实际表现，从 txsp2 本机看 HTTP 后端 ~0.2 s 正常，但**未做跨时段/公网端到端压测**。
- **txsp2 仍是 fuxipan / reman / m15 等站点的入口**，且现在又加回两组域名，SG 线路劣化会同时影响它们。
- **双层 WAF**：请求经「txsp2 WAF + gate WAF」两层（既有设计）。
- **panso.me 与 lzpanx 组不一致**：`panso.me` 仍在 txhk，若业务上需与 `lzpanx.com` 同入口，
  需单独迁移并同步改 DNS。
