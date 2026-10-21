# 业务链路与迁移目标（txhk → alhk）

文档日期：2026-10-21。本文是 `txhk-service-inventory.md` 的上层拓扑说明，
不记录任何 Token / 私钥 / UUID。

## 一、主机与角色

| 别名 | 公网 IP | 云 / 位置 | 系统 | 角色 |
|---|---|---|---|---|
| `alhk` | 47.242.228.248 | 阿里云 HK | Ubuntu 24.04.5 | **新入口机**（本次迁移目标），2C/1.8G/40G，ssh 9844 |
| `txhk` | 43.161.227.45 | 腾讯云 HK | Ubuntu 22.04.5 | 旧入口机（本次下线），2C/961M/40G，ssh 2323 |
| `txsp2` | 43.160.224.101 | 腾讯云 SG | Ubuntu 22.04.5 | :80 源站 + m15 v2ray 落地，ssh 9844 |
| `gate` | 110.40.167.56 | 腾讯云 | Ubuntu 24.04.3 | 应用网关，Caddy 监听 3001–3017 + 443，ssh 4958 |
| `app3` | 118.89.110.51 | 腾讯云 | Ubuntu 24.04.3 | 业务应用（Go 程序），ssh 4344 |
| `db2` | 1.15.13.221 | 腾讯云 | Ubuntu 24.04.3 | MySQL 3306 / PostgreSQL 5432，ssh 5634 |
| `dev` | 本地 Mac | - | - | 开发机，经 `wg-dev`（10.77.43.2）连 txsp2 |

## 二、请求链路（两条独立业务线）

### A. 站点线（lzpanx / hunhepan / fuxipan / qkpanso）

```
用户 → Cloudflare(橙色云) → 源站 :80
                               ├─ 现状 1：txsp2 Caddy :80 ──→ 110.40.167.56:300x（gate 公网）
                               └─ 现状 2：txhk   Caddy :80 ──→ 10.77.42.2:300x（gate 经 WG）
                                        ↓
                                    gate Caddy(3001–3017) → app3 的 Go 应用 → db2
```

- `gate` 的端口映射（txsp2 Caddyfile 中的现状）：
  `3001`=hunhepan、`3006`=lzpanx、`3007`=qkpanso、`3009`=reman.xwd.pw、`3010`=fuxipan
- `app3` 后端：`go-hunhepan:3765`、`go-ai-api:5384`、`go-forge:7687`、`go-taokeapi:2045`、`go-fuxipan:6655`，另有 sing-box（127.0.0.1:8080/38080/38081）
- `txhk` 上的 lzpanx/hunhepan 站点与 `txsp2` **内容重复**（同一批域名、同一后端，只是路径不同：WG 内网 vs 公网）。
  DNS 目前全部指 `txsp2`，所以 **txhk 那两组站点此刻是空转的**。

### B. 代理线（m14 / m15）

```
客户端 → m14.panso.me:443 (WSS /tim) → txhk Caddy → 127.0.0.1:3344 v2ray(入口, vmess+ws)
        → v2ray 出站 vmess → m15.panso.me:443 (txsp2 的 v2ray :3344)
        → txsp2 v2ray 出站（direct / xai-proxy socks）
```

- `m14.panso.me` → 43.161.227.45（txhk，DNS-only）
- `m15.panso.me` → 43.160.224.101（txsp2，DNS-only）
- 路由：`geoip:private` → block；54 个 AI/Google 域名 → proxy（→ m15）；其余 → direct
- `warp-out`（socks 127.0.0.1:1080 / usque）**已决定废弃**，迁移时一并清掉

### C. 其它站点（都在 txhk 上）

| 站点 | 上游 | 备注 |
|---|---|---|
| `jujuso.com`、`v4.jujuso.com`、`www.jujuso.com` | 139.155.21.35:3007 | DNS-only 直指 txhk 43.161.227.45，需一起迁 |
| `panso.me`（apex） | 10.77.42.2:3006（gate 经 WG）+ WAF | Cloudflare 代理，源站 txhk |
| `my.misiai.com` | 10.77.43.2:8080（dev） | 在 **txsp2**，不涉及本次 |
| `ai-api.misiai.com` | 127.0.0.1:5384 | 在 **app3**，不涉及本次 |

## 三、WireGuard 拓扑（txhk 是当前枢纽）

```
        wg-sghk (10.77.41.0/32 点对点)          wg-hksh
txsp2 10.77.41.2  ←———————————————→  txhk 10.77.41.1 / 10.77.42.1  ←————————————→  gate 10.77.42.2
                                        （UDP 32471）        （UDP 32472）
```

- txhk 自身**不做 NAT、不做上网转发**，只做两点之间的 `FORWARD` 放行：
  `10.77.41.2 ↔ 10.77.42.2` 双向 ACCEPT，其余 `-i wg-* -j DROP`。
- 对端配置：
  - `gate` 的 `wg-hksh` peer 公钥 = txhk 的 `wg-hksh` 公钥（`5eB0…sU8=`），allowed ips `10.77.42.1/32, 10.77.41.2/32`
  - `txsp2` 的 `wg-sghk` peer 公钥 = txhk 的 `wg-sghk` 公钥（`Cb36…hzw=`），allowed ips `10.77.41.1/32, 10.77.42.2/32`
- **因此迁移方式**：把 txhk 的 `/etc/wireguard/wg-{hksh,sghk}.{conf,key,pub}` 原样复制到 alhk，
  `gate`/`txsp2` 两侧**不需要改配置**（公钥不变；WireGuard 会随握手自动更新 endpoint IP）。
  代价是同名同密钥不能两端同时在线（会抢同一隧道地址），所以必须**先停 txhk 的 wg，再起 alhk 的 wg**。

## 四、DNS 现状（cloudctl 查询结果）

| 域名 | 当前记录 | 代理 | 迁移动作 |
|---|---|---|---|
| `m14.panso.me` | A 43.161.227.45 | 否 | 改 alhk |
| `m15.panso.me` | A 43.160.224.101 | 否 | **不动**（txsp2 落地） |
| `jujuso.com` / `v4.jujuso.com` / `www.jujuso.com` | A 43.161.227.45 | 否 | 改 alhk |
| `panso.me`（apex） | A 43.161.227.45 | 是 | 改 alhk，保持代理 |
| `lzpanx.com` / `www.lzpanx.com` | A 43.160.224.101 | 是 | 改 alhk，保持代理（用户要求） |
| `hunhepan.com` / `www.hunhepan.com` / `api.hunhepan.com` | A 43.160.224.101 | 是 | 改 alhk，保持代理（用户要求） |
| `fuxipan.com` / `qkpanso.com` 等 | 见 txsp2 | 是 | 本次不动 |
| `*.panso.me`（lz/hhp/qk/r2/ujs/yjs/www） | CNAME → `*.eo.dnse4.com` | 否 | 不动（腾讯 EdgeOne） |
| `m14.xwd.pw` | A 162.4.84.247（parklogic） | 否 | **域名已过期，删除站点配置，不再迁移** |
| `www.jujuso.co` | 无记录 | - | 写错了，实际是 `.com`，忽略（`www.jujuso.com` 已在列表内） |

Zone 均在 Cloudflare，改动用 `cloudctl dns ensure`。

## 五、迁移依赖与顺序（结合你的排序）

你的顺序：v2ray → caddy → wg → pm2（pm2/magnet 先不动）。实际依赖关系：

1. **v2ray**（alhk）：装二进制 + 搬 `config.json`，监听 127.0.0.1:3344。
   - 清掉 `warp-out`（usque 不要了）及指向它的路由；
   - 出站仍指 `m15.panso.me:443`（txsp2），**txsp2 侧零改动**；
   - 此时无公网入口，不影响线上（txhk 仍对外服务）。
2. **Caddy**（alhk）：可以从 **txhk 或 txsp2 直接复制 `/usr/local/sbin/caddy`**（两者是同一个构建，
   `h1:XKxkMTgNSizEvKG6QHue6cAsFOteU2qA61w2tKkCWi0=`，含 `caddy-waf@v0.4.14` + `dns.providers.cloudflare`）。
   搬 `Caddyfile` + `/etc/caddy/waf/` + `/var/lib/caddy`（证书），删掉 `m14.xwd.pw` 站点。
   - `lzpanx`/`hunhepan` 两块的上游是 `10.77.42.2`（WG 内网），**必须等 wg 起来后才能切这两个域名的 DNS**；
   - 不依赖 WG 的可以先切：`m14.panso.me`（需 v2ray 已就绪）、`jujuso.com`/`v4`/`www.jujuso.com`、`panso.me`（上游也是 10.77.42.2，也要等 wg）。
3. **WireGuard**（alhk）：先停 txhk 的两个接口 → 复制 conf/key 到 alhk → `systemctl enable --now wg-quick@wg-hksh wg-quick@wg-sghk`
   → 在 alhk 上验证 `ping 10.77.42.2`、`curl 10.77.42.2:3006`。
   - 注意 alhk 与 txhk 不能同时在线（同密钥同地址）。
4. **DNS 切换**（cloudctl）：
   - 批 1（不依赖 WG）：`m14.panso.me`、`jujuso.com`、`v4.jujuso.com`、`www.jujuso.com`
   - 批 2（依赖 WG）：`panso.me`、`lzpanx.com`、`www.lzpanx.com`、`hunhepan.com`、`www.hunhepan.com`、`api.hunhepan.com`
   - 建议把 TTL 降到 60s 先观察，稳定后恢复。
5. **pm2 / magnet**：按你的意见**本次不动**（继续留在 txhk，等它彻底下线前再迁）。
   - 但注意：magnet 的 `magnet-harvester` 会持续调 `hunhepan.com` API，域名切换后仍能工作（走 CF）。

## 六、alhk 需要放行的安全组端口

| 端口 | 用途 | 状态 |
|---|---|---|
| 9844/tcp | SSH | 已放行 |
| 80/tcp、443/tcp、443/udp | Caddy（站点 + HTTP/3） | **待放行** |
| 32471/udp | wg-sghk（txsp2 过来） | **待放行** |
| 32472/udp | wg-hksh（gate 过来） | **待放行** |
| 34631/tcp+udp、58241/udp | magnet（本次不迁） | 暂不需要 |

## 七、回滚

- 每一步都可回滚：alhk 上的 Caddy/v2ray 先只监听本地，DNS 未切前线上无感。
- DNS 回滚：`cloudctl dns ensure --content <旧 IP>` 改回 `43.161.227.45` / `43.160.224.101`。
- WG 回滚：alhk `systemctl disable --now wg-quick@wg-hksh wg-quick@wg-sghk`，再在 txhk 上重新 `up` 两个接口（配置未动）。
- txhk 在全部验证通过前**不卸载任何服务**，仅 `disable` 不 `remove`。

---

# 迁移执行记录（2026-10-21，v2ray / caddy / wg 已完成）

## 执行结果

| 项目 | 状态 | 说明 |
|---|---|---|
| v2ray | ✅ 完成 | alhk `/usr/local/bin/v2ray` 5.49.0，监听 127.0.0.1:3344；已移除 `warp-out`（usque 废弃）；出站仍 → `m15.panso.me:443`（txsp2），**txsp2 侧零改动** |
| Caddy | ✅ 完成 | 从 txhk 直传二进制（`v2.11.4 h1:XKxk…Wi0=`，与 txsp2 同一构建）+ `Caddyfile` + `/etc/caddy/waf/` + `/var/lib/caddy`（证书） |
| WireGuard | ✅ 完成 | txhk 的两个接口整体搬到 alhk，对端 endpoint 已改指 alhk |
| DNS | ✅ 完成 | 10 条 A 记录改指 `47.242.228.248`，CF 代理保持原状 |
| pm2 / magnet | ⏸ 未迁 | 按用户意见留在 txhk |
| `www.jujuso.com` 证书 | ⏳ 待签 | 撞 LE "failed authorizations (5)/1h" 限流，Caddy 自动重试（约 2026-10-21 03:55 UTC 后） |

## 关键实现细节

### v2ray
- 二进制/geo 数据/systemd unit/config 从 txhk 经 **txhk→alhk 直连 SSH**（HK↔HK，约 350KB/s）打包 gzip 传输，21s 完成。
- 传输通道：alhk 侧生成专用密钥 `/root/.ssh/id_transfer`，公钥追加进 txhk 的 `authorized_keys`（txhk sshd 是 2323）。
- 缺失 `/var/log/v2ray` 导致首启失败，按 txhk 的权限补建（`nobody:nogroup` 0700）。
- 验证方式：临时加 socks 入站 127.0.0.1:1081 → `api.openai.com` 401、`google.com` 200（走 proxy→m15）、`example.com` 200（direct），验证后删除临时配置。

### Caddy
- `caddy` 用户：alhk 上 998/999 已被系统占用，改用 `useradd --system`（实际 uid 999/gid 988），`/var/lib/caddy` 改为 `caddy:caddy` 0700。
- ⚠️ **`caddy validate` 以 root 执行会创建 root:root 0600 的 `/var/log/caddy/*.log`**，导致正式启动报 `permission denied`；已 `chown caddy:caddy` 修复。
- Caddyfile 改动：`m14.xwd.pw, m14.panso.me` → 只留 `m14.panso.me`（xwd.pw 已过期）；`www.jujuso.co` → `www.jujuso.com`（原为笔误）。
- 上游最终形态：`lzpanx/panso.me/hunhepan` 走 **WG 内网 `10.77.42.2:3001/:3006`**（按用户要求保持原架构，公网 `110.40.167.56` 方案已验证可用但未采用）。
- 站点验证（公网）：`jujuso.com` 200、`v4.jujuso.com` 200、`m14.panso.me` WSS **101**、`www.lzpanx.com` 200、`hunhepan.com` 200、`api.hunhepan.com` 200、`panso.me` 200；`lzpanx.com` 301 → `www`。
- WAF 生效验证：`?id=1' OR 1=1--` → 403，`UA: sqlmap/1.7` → 403，正常请求 200。

### WireGuard（关键坑）
- **gate 和 txsp2 都是主动方**，两侧配置均为 `Endpoint = 43.161.227.45:3247x` + `PersistentKeepalive = 25`；hub（txhk/alhk）是纯被动端。
  所以切换必须**同时改对端 endpoint**，否则对端会一直往旧 IP 打握手：
  - `gate:/etc/wireguard/wg-hksh.conf` → `Endpoint = 47.242.228.248:32472`（备份 `wg-hksh.conf.bak.20261021114654`）
  - `txsp2:/etc/wireguard/wg-sghk.conf` → `Endpoint = 47.242.228.248:32471`（备份 `wg-sghk.conf.bak.20261021034657`）
- 切换顺序：txhk `disable --now` 两个接口 → alhk `start` 两个接口 → 两侧改 endpoint 并 `restart wg-quick@` → 等 25s keepalive。
- ⚠️ **alhk 默认 `net.ipv4.ip_forward = 0`**，而 txhk 有 `/etc/sysctl.d/97-wg-hk-relay.conf`。
  不补会表现为「握手成功但 txsp2↔gate 互 ping 不通、`curl 10.77.42.2:3006` 超时」。
  已新增 `/etc/sysctl.d/97-wg-relay.conf`（`net.ipv4.ip_forward = 1`）。
- 切换后实测：alhk→gate 44.8ms 0% 丢包、alhk→txsp2 37.8ms 0% 丢包、`txsp2→10.77.42.2:3006` 200、
  `gate→10.77.41.2` 可达；alhk 上两条 FORWARD 放行 + `-i wg-* -j DROP` 规则由 wg-quick PostUp 自动恢复。
- 安全组：UDP 32471/32472 已放行（用 `nc -u -l` + 对端发送实测确认，非只信配置）。

## DNS 变更明细（cloudctl）

| 域名 | 旧值 | 新值 | 代理 | TTL |
|---|---|---|---|---|
| `m14.panso.me` | 43.161.227.45 | 47.242.228.248 | 否 | 60 |
| `jujuso.com` / `v4.jujuso.com` / `www.jujuso.com` | 43.161.227.45 | 47.242.228.248 | 否 | 60 |
| `panso.me` | 43.161.227.45 | 47.242.228.248 | 是 | 自动 |
| `lzpanx.com` / `www.lzpanx.com` | 43.160.224.101 | 47.242.228.248 | 是 | 自动 |
| `hunhepan.com` / `www.hunhepan.com` / `api.hunhepan.com` | 43.160.224.101 | 47.242.228.248 | 是 | 自动 |

`m15.panso.me`（txsp2）**未改动**。DNS-only 记录 TTL 暂设 60s 便于回滚，稳定后可改回自动。

## 备份与回滚清单

| 位置 | 备份 |
|---|---|
| alhk | `/etc/caddy/Caddyfile.orig-*`（迁移前原始）、`/etc/caddy/Caddyfile.pre-public-*`（公网上游版本）、`/usr/local/etc/v2ray/config.json.bak-*`、`/etc/ssh/sshd_config.bak.20261021112118` |
| gate | `/etc/wireguard/wg-hksh.conf.bak.20261021114654` |
| txsp2 | `/etc/wireguard/wg-sghk.conf.bak.20261021034657` |
| txhk | 全部服务与配置**未删除**，仅 wg 两个接口被 `disable --now` |

回滚（WG）：alhk 停两个接口 → 两侧 endpoint 改回 `43.161.227.45` 并 restart → txhk `start` 两个接口。
回滚（DNS）：`cloudctl dns ensure --content <旧 IP>` 逐条改回。
回滚（Caddy/v2ray）：alhk `systemctl disable --now caddy v2ray`，DNS 改回 txhk，txhk 上服务一直都在。

## 遗留事项

1. `www.jujuso.com`：已按用户意见**放弃**。原因：DNS 记录虽然指向 txhk，但 txhk 的 Caddyfile 里写的是 `www.jujuso.co`（笔误），该子域实际一直是坏的；
   加上迁移后 Caddy 首次尝试签发就撞上 LE "failed authorizations (5)/1h" 限流，为避免污染其他域名的签发额度，
   已从 TLS 站点块中移除（备份 `Caddyfile.before-wwwjujuso-*`），DNS 记录保持指向 alhk 暂不处理。
   **`lzpanx.com` / `hunhepan.com` / `panso.me` 在 Cloudflare 上是 Flexible 模式**（CF→源站走 80 明文），
   所以 Caddy 里这些站点写成 `:80` 后缀是正确且必需的：不触发 ACME、不需要证书，TLS 由 CF 边缘终结。
2. alhk 1.8G 内存无 swap，建议后续加 1G swap。
3. txhk 仍跑 caddy + v2ray + pm2(magnet)：观察 3~7 天后再决定停用/下线；`magnet` 仍在 txhk 上跑，经 CF 调 `api.hunhepan.com` 正常（日志有业务层 `磁力链接入库已关闭` 提示，非网络问题）。
4. txhk 的 sshd 仍开着密码登录（2323），下线前一并收紧。
5. `/root/.ssh/id_transfer`（alhk→txhk 免密）在 txhk 下线后应删除，并从 txhk 的 `authorized_keys` 移除。

## 追加：lzpanx/hunhepan 改为源站 TLS（DNS-01，2026-10-21）

背景：CF 原本是 **Flexible**（CF→源站 80 明文），所以那几个站点在 Caddyfile 里写成 `xxx:80`。要改成源站 HTTPS 就必须让 Caddy 能拿证书，
而 CF 代理（橙色云）下 **HTTP-01 / TLS-ALPN-01 都不可用**（校验到不了源站，或 TLS 由 CF 终结），只能走 DNS-01。

- alhk 的 caddy 二进制本来就编进了 `dns.providers.cloudflare`（与 txsp2 同一构建），**无需重编**。
- Token 存放：`/etc/caddy/cf.env`（`0600 caddy:caddy`），systemd drop-in
  `/etc/systemd/system/caddy.service.d/10-cf-env.conf` 里 `EnvironmentFile=-/etc/caddy/cf.env`，
  Caddyfile 只用占位符 `{env.CF_API_TOKEN}`，**token 不进 Caddyfile、不进文档**。
- 过渡期做法（零中断）：同一后端同时提供两套站点块
  - `http://lzpanx.com, http://www.lzpanx.com, http://panso.me { … }`（给当前 Flexible 用）
  - `lzpanx.com, www.lzpanx.com, panso.me { tls { dns cloudflare {env.CF_API_TOKEN} } … }`（443）
  - `hunhepan` 三个域名同理。
- 结果：6 张 LE 证书（`lzpanx.com`、`www.lzpanx.com`、`hunhepan.com`、`www.hunhepan.com`、`api.hunhepan.com`、`panso.me`）
  全部由 DNS-01 签发成功，有效期至 2027-01-19；443 上 WAF 复验：注入 403、`sqlmap` UA 403、正常 200；80 仍照常 200（未中断）。
- 备份：`/etc/caddy/Caddyfile.before-dns01-*`。

**待用户操作**：CF 面板把 `lzpanx.com` / `hunhepan.com` / `panso.me` 三个 zone 的 SSL/TLS 模式改成 **Full (strict)**。
（当前 token 只有 DNS 权限，改 zone 设置会返回 `9109 Unauthorized`。）
改成 Full (strict) 并验证公网 443 正常后，删除上述 `http://` 站点块、最后关闭安全组 80 端口即可（后续续期走 DNS-01，不再需要 80）。

### 执行结果（80 关闭 + Full(strict) 验证）

- 用户将 `lzpanx.com` / `hunhepan.com` 两个 zone 切到 **Full (strict)** 后，Caddy 里已删除对应 `http://` 站点块：
  现在只监听 **443**（Caddyfile 全局的 `auto_https disable_redirects` 保证不会自动监听 80）。
- 源站侧证据：`journalctl -u caddy` 里可见 CF 边缘（如 `162.158.186.198`）以 **TLS1.3 + SNI** 直连 443，
  带 `Cf-Ray` / `Cf-Connecting-Ip` 头，即 CF→源站已加密。
- 外部验证（从 `txsp2`，无代理干扰）：`www.lzpanx.com`、`hunhepan.com`、`api.hunhepan.com`、`jujuso.com`、`m14.panso.me` 全 200；`lzpanx.com`/`www.hunhepan.com` 301 到 www。
- ⚠️ **`panso.me` zone 当时仍是 Flexible**，CF 回源 80 → 关掉 80 后 `https://panso.me` 变 **521**。
  已临时追加 `http://panso.me { … }`（同一后端 10.77.42.2:3006）恢复服务（200），
  **待用户把 panso.me 也切 Full(strict) 后再删除该块**。
- 已知噪声：`caddy-waf v0.4.14` 在客户端中断 HTTP/2 流时会打 `PANIC in ServeHTTP` / `net/http: abort Handler`
  日志（插件在反代 panic 时 recover 造成），不影响服务；txhk 上同一构建同样存在。

## 事故与最终归属（2026-10-21 12:20–12:50）

### 现象
把 `lzpanx`/`hunhepan`/`panso.me` 切到 alhk 并关闭 80 之后约 10 分钟，访问开始大面积超时，用户反馈「alhk 延迟变得特别大」。实测（都在 alhk 上跑的）：

| 指标 | 异常期 | 恢复后（重启 alhk 前后） |
|---|---|---|
| alhk → 1.1.1.1 | 0% 丢包 / 2.2ms | 0% |
| alhk → 110.40.167.56(gate 公网) | **75% 丢包**（RTT 稳定 30ms） | 10%（ICMP 限速，隧道内 0%） |
| alhk → 43.160.224.101(txsp2) | **70% 丢包**（RTT 稳定 37ms） | 0% |
| alhk → gate:3006 HTTP | **8.00s**（TCP RTO 退避） | 0.28–0.63s |
| TCP 传输 20MB（经 WG 到 gate） | **27 KB / 49 秒** | 正常 |
| TCP 握手成功率 | 100%（SYN/ACK 正常，大包卡住） | 100% |
| 累计 TCP 重传率 | **24.7%**（471872/1912798） | 重启后 1.3%（13/1002） |

- 1.1.1.1 正常、TCP 握手成功但大流量几乎不动、RTT 稳定而丢包极高 → **不是本地资源问题**（CPU steal 0、无 OOM、无 conntrack 满、网卡无 drops）。
- 结论：**跨境/国际段短时严重丢包**（HK→CN 与 HK→SG 同时出现），约 15 分钟后自行恢复，`kill -INT 1` 重启 alhk 后仍未复现。根因未确认（阿里云侧或国际出口），**非配置问题**。

### 决策（用户）：不回退 Flexible，改为让 txsp2 也做 DNS-01

为保证「站点不能断」，最终把 6 条记录切回 **txsp2 作为源站**，但保留 CF **Full (strict)**：

```
用户 → CF(Full strict) → txsp2:443 (LE 证书, DNS-01) → gate 公网 110.40.167.56:300x → app3 → db2
```

txsp2 侧改动（备份 `/etc/caddy/Caddyfile.before-dns01-*`）：

- `lzpanx.com:80 www.lzpanx.com:80 panso.me:80` → `lzpanx.com, www.lzpanx.com, panso.me` + `tls { dns cloudflare {env.CF_API_TOKEN} }`
- `api.hunhepan.com:80 www.hunhepan.com:80 hunhepan.com:80` → 同上
- CF token 复制到 txsp2：`/etc/caddy/cf.env`（0600 caddy:caddy）+ `/etc/systemd/system/caddy.service.d/10-cf-env.conf`（`EnvironmentFile`）
- `systemctl restart caddy` 后 6 个域名全部 DNS-01 签发成功（`panso.me`、`lzpanx.com`、`www.lzpanx.com`、`hunhepan.com`、`www.hunhepan.com`、`api.hunhepan.com`）
- 443 上 WAF 复验：注入 403 / `sqlmap` UA 403 / 正常 200

### 事故后的最终归属

| 域名 | 源站 | 链路 | 证书 |
|---|---|---|---|
| `lzpanx.com`、`www.lzpanx.com`、`panso.me` | **txsp2** | CF Full strict → txsp2:443 | DNS-01 (LE) |
| `hunhepan.com`、`www.hunhepan.com`、`api.hunhepan.com` | **txsp2** | 同上 | DNS-01 (LE) |
| `jujuso.com`、`v4.jujuso.com` | alhk | DNS-only → alhk:443 | 从 txhk 迁来的 LE 证书 |
| `m14.panso.me` | alhk | DNS-only → alhk:443 → v2ray:3344 → m15(txsp2) | 同上 |
| `www.jujuso.com` | alhk | 无站点（按用户意见放弃） | - |

alhk 现状：caddy + v2ray + 两个 wg 接口均 active，只监听 443；`lzpanx/hunhepan/panso.me` 的站点块仍保留（**当前无人使用，作为待命配置**）；
WG 两条隧道的流量已降到 keepalive 级别（30s 内 wg-hksh ≈5KB），因为 gate 相关流量全部回到 txsp2 → gate 公网直连。

### 遗留 TODO

1. alhk 的 `/etc/caddy/waf/ip_whitelist.txt` 在这次排查中加入了 **Cloudflare 全段**（`ips-v4`/`ips-v6`）。
   若 caddy-waf 的 whitelist 语义是「跳过 WAF 检查」，则等于对 CF 来源流量关闭 WAF，需要复核并清理
   （现网 jujuso/m14 是 DNS-only 直连，不经过 CF 代理，暂时影响有限）。备份 `ip_whitelist.txt.bak-*`。
2. alhk 上 `lzpanx/hunhepan/panso.me` 站点块保留还是删除，待决定。
3. alhk 的 wg 两个接口当前空转，考虑停用（若停用，gate/txsp2 的 endpoint keepalive 会一直失败但无害）或保留待命。
4. DNS-only 记录 `jujuso.com`/`v4.jujuso.com`/`m14.panso.me` 的 TTL 仍是 60s，稳定后可恢复自动。
5. CF token 目前同时存在 alhk 与 txsp2 的 `/etc/caddy/cf.env`（0600）；如需最小权限可只保留在用的一台。

## A/B 实测：alhk 是否适合做站点源站（2026-10-21 13:00–13:20）

### 动机
事故恢复后（6 个域名在 txsp2），单独把 `hunhepan.com` 切回 alhk 做对照实验，验证「阿里 HK 源站」到底能不能用。

### 关键发现：WG 隧道是比公网更差的路径
把 alhk 到 gate 的上游从 WG(`10.77.42.2:3001`) 改为公网(`110.40.167.56:3001`) 后，同一 URL 直连源站（绕过 CF，n=10 交错）：

| 源站 / 路径 | med | p90 | max | avg |
|---|---|---|---|---|
| alhk（上游走 **WG**） | 1.319s | 5.146s | 6.354s | 2.377s |
| alhk（上游走 **公网**，改后） | 0.563s | 1.737s | 2.727s | 0.874s |
| txsp2（公网） | **0.389s** | **0.402s** | **0.406s** | **0.375s** |

原因：WG 是 UDP 封装，跨境丢包时没有 SACK/流控，一个包丢了整条隧道队头阻塞。
alhk 日志中抓到过 `upstream 10.77.42.2:3001 duration: 24.16s` 的单请求（Googlebot 抓 `/search`）。

经 CF 用户视角（gate 发起，8 次交错）：alhk 出现 3.29s / 4.18s 尖峰，txsp2 全在 1.26–2.23s。

### 结论：不是「alhk 不能建站」，而是「跨境反代大陆后端」要看响应大小
- `jujuso.com`（同样 alhk 反代国内 `139.155.21.35:3007`，响应小）→ 0.16–0.44s，**稳定**，可保留在 alhk
- `hunhepan.com`（大页面 + `/v1/sse/stream` 长连接，多次往返）→ 被 HK→CN 的间歇丢包（ping 约 10%）放大成 2–6s 尖峰
- alhk 最适合：v2ray/WSS 入口（`m14.panso.me` 0.2s 很稳）、静态/小响应站点、反代**海外或本机**后端

### 处置
- `hunhepan.com` 已切回 **txsp2**（`43.160.224.101`, proxied），复核 1.05–2.23s、无尖峰
- alhk 上 hunhepan 站点块的上游**保留改为公网** `110.40.167.56:3001`（比 WG 好得多，作为待命配置直接可用）
  备份：`/etc/caddy/Caddyfile.before-hhp-public-<ts>`
- `jujuso.com` / `v4.jujuso.com` / `m14.panso.me` 继续留在 alhk
- 复核 6 个域名全部 200：`hunhepan.com`、`api.hunhepan.com`、`www.lzpanx.com`、`panso.me`、`jujuso.com`、`m14.panso.me`

## 更正：根因是「alhk ↔ 中国大陆」链路持续丢包（2026-10-21 13:30）

上一节把差异归因于「响应体大小 / 页面大小」，**结论错了**。补测（各 150 包并发、同一时间窗）后确认：

| 起点 → 目标 | ICMP 丢包 | RTT |
|---|---|---|
| alhk → 1.1.1.1 | 0% | 2.3ms |
| alhk → txsp2 (43.160.224.101, 新加坡) | 0% | 37ms |
| alhk → 139.155.21.35（重庆腾讯） | **14%** | — |
| alhk → 110.40.167.56（广州 gate） | **19.3%** | 30.7ms |
| gate → 139.155.21.35（大陆互访） | 0% | — |
| gate → txsp2 (SG) | 0.67% | 68ms |
| gate → alhk | **18.67%** | 31.5ms |

- **双向、对全部大陆目标都丢 14–19%，到香港本地/新加坡/全球是 0%**；alhk 网卡 errors/dropped 均为 0。
- 所以与「页面大小」无关：app3 上同一个 20KB 页面在 VPC 内 **8ms** 完成（0% 卡顿）；慢的原因是跨境这条腿。
- 只是**丢包概率随传输的数据包数放大**：8KB（约 6 段）和 20KB（约 15 段）差别被放大成 20% vs 45% 的慢请求率。

### 实测影响（各 40 次，同一时间窗）

| 方式 | avg | >0.3s | >1s |
|---|---|---|---|
| alhk 直连大陆后端（20KB 页面） | 1.024s | 47% | **35%** |
| alhk 绕道 txsp2（HK→SG 0% + SG→CN 0.67%） | 0.388s | 40% | **7%** |
| txsp2 直连大陆后端 | 0.823s | 30% | 24% |

### 结论修正

1. `jujuso.com` 并非「稳定」——它同样吃这 14% 丢包，只是 8KB 页面命中概率低一些（40 次里 20% 慢请求，含 1.14s 级卡顿）。
2. 判据不是「alhk 能不能建站」，而是 **alhk 与大陆之间现在有 14–19% 的固定丢包**，任何「alhk → 大陆后端」的站点都会受影响，与 Caddy/WAF/页面大小无关。
3. 若必须让 alhk 服务大陆后端，可行做法是**绕新加坡中转**（>1s 慢请求从 35% 降到 7%），代价是 +37ms RTT；但直接放 txsp2 仍然最优。
4. 该丢包率随时间波动（本 session 早期 alhk→gate 曾测得 0%，事故期间 70–75%），疑与阿里云香港侧跨境 QoS/限速有关，需持续观测。
