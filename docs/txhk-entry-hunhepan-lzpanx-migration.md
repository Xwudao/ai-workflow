# hunhepan / lzpanx 公网入口从 txsp2(SG) 迁到 txhk(HK)（2026-10-15）

## 背景与动机

原链路：`CF → txsp2(SG) → WireGuard → txhk(HK 转发) → gate(SH) → app3`。

问题：**SG 段线路严重劣化**，实测（2026-10-15）：

| 路径 | 结果 |
|---|---|
| SG(txsp2) → SH(gate) 直连 ICMP | 100 包 **26–35% 丢包**，RTT ≈ 103 ms |
| SG(txsp2) → HK(txhk) ICMP | 一轮 0%、另一轮 30%，RTT ≈ 34.8 ms，波动大 |
| HK(txhk) → SH(gate) ICMP | **0% 丢包**，RTT ≈ 30.8 ms |
| 本地 → `ssh txsp2` | 建连 5 s，且出现过整次超时 |
| 本地 → `ssh gate` | 建连 1.1 s |

而香港本来就承担全部 WG 转发流量，把入口放到香港可以**直接砍掉 SG 那一跳**。
本次只迁移 **hunhepan 与 lzpanx 两组域名**，其余（fuxipan、reman、m15 等）仍留在 txsp2。

## 变更后的拓扑

```text
                 ┌── hunhepan.com / www / api  ──┐
CF (proxied) ────┤                               ├──→ txhk(HK) Caddy :80 + WAF
                 └── lzpanx.com / www / panso.me ─┘        │
                                                            │ wg-hksh (UDP 32472)
                                                            ▼
                                            gate(SH) Caddy :3001/:3006 → app3 Go 服务

fuxipan / reman / m15.xwd.pw 等 ──→ txsp2(SG) Caddy（未改动，仍走原链路）
```

- **CDN 回源模式**：Cloudflare → 源站 **HTTP :80**（Flexible）。源站不需要证书，
  Caddy 站点因此定义为 `*.example.com:80`；txsp2 与 txhk 上这些域名都**没有 LE 证书**，
  这是既有设计，不是故障。
- `hunhepan` 现在**只有一层 WAF**（txhk）；gate 的 `:3001` WAF 仍然保留，属既有配置，未改动。

## 具体改动

### 1. txhk：换用 txsp2 的 Caddy 二进制

- 原：`/usr/local/sbin/caddy` = v2.9.1（2026-06-04，42 MB，带 `http.handlers.waf` 但未启用）
- 新：txsp2 的 v2.11.4 + `fabriziosalmi/caddy-waf v0.4.14`（76 MB，md5 `d5cc6b754901959ba7d418cae789bf1c`）
- 传输方式：本地中转流（`ssh txsp2 'tar czf - ...' | ssh txhk 'tar xzf -'`），约 5 分钟；
  **txhk/txsp2/gate 之间没有互信 key（`ssh` 只认本地公钥），无法主机直传**。
- 校验：源、目标二进制与 4 个 WAF 规则文件 md5 全部一致。
- 生效方式：**`systemctl restart caddy`**（换了二进制/模块，不能用 reload）。

### 2. txhk：WAF 规则与站点配置

- 新增 `/etc/caddy/waf/`：`rules.json`、`legacy-rules.json`、`ip_blacklist.txt`、`ip_whitelist.txt`
  （与 txsp2 逐字节一致）。
- `/etc/caddy/Caddyfile`：保留原有两个站点块（`m14.xwd.pw`/`m14.panso.me`、`v4.jujuso.com` 等），
  追加 `(logger)` / `(waf)` / `(waf-dashboard-local)` / `(cfproxy)` 片段与两个迁入站点块
  （`lzpanx.com:80 www.lzpanx.com:80 panso.me:80` → `10.77.42.2:3006`；
  `api.hunhepan.com:80 www.hunhepan.com:80 hunhepan.com:80` → `10.77.42.2:3001`）。
- 迁移前用暂存二进制执行 `caddy validate --config /etc/caddy/Caddyfile.new` 通过后才切换。

### 3. Cloudflare DNS（cloudctl）

6 条 A 记录由 `43.160.224.101` 改为 `43.161.227.45`，**保持 proxied=true**（未使用 `provider_error` 之外的重试需求；其中 hunhepan 根域首次调用超时，重试后成功）：

| zone | name |
|---|---|
| lzpanx.com | `lzpanx.com`、`www.lzpanx.com` |
| panso.me | `@` |
| hunhepan.com | `@`、`api.hunhepan.com`、`www.hunhepan.com` |

未改动：`m15.panso.me`（非 proxied，仍在 txsp2）、fuxipan / reman 相关记录。

## 验证结果

| 检查项 | 结果 |
|---|---|
| `systemctl is-active caddy`（txhk） | active，监听 `:80` `:443` |
| txhk 本机 `curl -H Host: lzpanx.com http://127.0.0.1/` | `200`（约 0.04–0.11 s） |
| txhk 本机 `api.hunhepan.com` | `500`（**迁移前在 txsp2 也是 500，属既有应用问题**，非本次引入） |
| 经 CF 端到端（从 gate 发起 https） | `www.lzpanx.com` / `panso.me` `200`；`hunhepan` 系列 `500`（同前） |
| txhk `/var/log/caddy/lzpanx.log` | 有流量、且记录的是**真实客户端 IP**（CF 透传 XFF，logger 取 `X-Forwarded-For[0]`） |
| WAF 探针 `?q=<script>alert(1)</script>` | `403`，WAF 在 HK 生效 |
| 原有站点 `m14.xwd.pw` / `jujuso.com` / `v4.jujuso.com`（从 gate 拨测 :443） | 全部 `200`，未受影响 |
| 回滚可用性 | txsp2 的 Caddyfile **未改动**，两个站点块仍在，DNS 翻回即回滚 |

## 备份与回滚

备份位置（内容含业务配置，不在文档中展开）：

| 主机 | 路径 | 内容 |
|---|---|---|
| txhk | `/root/mig-hhp-lzpanx/backup/caddy.pre` | 原 v2.9.1 二进制 |
| txhk | `/root/mig-hhp-lzpanx/backup/Caddyfile.pre` | 迁移前 Caddyfile |
| txhk | `/root/mig-hhp-lzpanx/backup/Caddyfile.pre-mig` | 切换瞬间的同一版本（冗余） |
| txhk | `/root/mig-hhp-lzpanx/backup/prestate.tgz` | `/etc/caddy` + `/var/lib/caddy` 打包 |
| txhk | `/root/mig-hhp-lzpanx/stage/` | 从 txsp2 拿到的二进制与 WAF 规则 |

回滚步骤：

1. DNS：用 `cloudctl dns ensure --zone <z> --type A --name <n> --content 43.160.224.101 --proxied` 把上表 6 条记录改回。
   （txsp2 的对应站点块仍在，改回即恢复原链路。）
2. txhk：如需连二进制一起回退，`cp /root/mig-hhp-lzpanx/backup/caddy.pre /usr/local/sbin/caddy`，
   恢复 `Caddyfile.pre`，然后 `systemctl restart caddy`；注意删掉/改属主 `/var/log/caddy/{hunhepan,lzpanx}.log`（见下文坑）。
3. 只回退部分域名时，可只删 txhk 上对应站点块并 reload，DNS 单条翻回。

## 本次踩到的坑（重要）

1. **`caddy validate` 会以 root 身份创建日志文件**：以 root 执行 validate 后，
   `/var/log/caddy/lzpanx.log`、`hunhepan.log`、`waf.json` 属主变成 `root:root 0600`，
   而服务以 `User=caddy` 运行 → 启动时 `opening log writer ... permission denied`，
   **`systemctl restart caddy` 直接失败，443 服务整体中断**（本次约 1 分钟）。
   处理：`chown caddy:caddy /var/log/caddy/*.log && chmod 640 ...` 后再启动。
   **以后在 caddy 机器上执行 validate，应在切换前就修正这些文件属主，或改用 `sudo -u caddy` 验证。**
2. `systemctl restart caddy` 期间 SSH 会话可能被断开（本机直连 txhk 时出现
   `Connection closed by remote host`），这只是**中国→香港 SSH 链路抖动**，
   不代表机器宕机：可用 `ssh -J gate txhk`（gate 跳板，SH↔HK 0% 丢包）稳定操作。
3. 本地 macOS 直连的 `ping`/`nc` 结果不可信（透明代理会对任意端口假 ACK、
   假 IP 段 `198.18.0.0/15`），判断连通性要用远端 vantage（gate/txsp2）。

## 遗留风险

- **txsp2 仍是 fuxipan、reman、m15 等站点的入口**，SG 线路劣化会持续影响这些站点
  （实测 `fuxipan.com` 从 gate 直连 txsp2 源站 TTFB 达 25 s）。建议后续同样迁往 txhk。
- **txhk 单点**：现在香港既做入口又做中转，HK 故障会同时影响新旧全部 WG 站点。
- txhk 为 2C/1G Lighthouse，迁入后需观察 CPU/内存与**月流量包额度**
  （迁移前 ens5 16 天已约 1.2 TB，超额按量计费）。
- `alipanx`（gate `:3003` → app3 `4677`）与 `xlpanso`（`:3002` → `4680`）上游未监听，
  一直是 502，属既有问题。
- 本次未做长时间压测与跨时段监控，也未验证真实业务功能（`hunhepan` 迁移前后均 500）。
