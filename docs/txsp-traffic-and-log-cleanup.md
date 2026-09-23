# txsp：出网流量归因分析与日志清理

> 执行时间：2026-09-19 深夜（服务器本地时间 CST，文中未标注时区的时间均为 UTC）。
> 关联文档：[`online-reverse-proxy-topology.md`](online-reverse-proxy-topology.md)、[`txsp-caddy-waf-migration.md`](txsp-caddy-waf-migration.md)

## 一句话结论

`txsp` 的流量**不是来路不明的入站流量**，而是它自己作为公网入口在**回源转发**：
`Cloudflare → txsp:80(Caddy) → gate 110.40.167.56:3001~3010 → app3` 的响应体，
其中 **约 91% 是 `fuxipan.com` 的 `/doc/<id>` 页面**（平均 ~70 KB/页，未压缩）。
出方向（TX）57 天累计 **1.70 TB**，折合 **≈908 GB/月**，正好落在 1 TB 套餐的 ~90%。

## 一、实例与方向

| 项 | 值 |
|---|---|
| 公网 IP | 43.134.116.41（ap-singapore-2） |
| 实例名 | `lh-1258489738-lhins-llvcnkj1`（轻量应用服务器 Lighthouse；DMI 显示 CVM） |
| 内网 | `ens5` `10.3.4.17/22`，网关 `10.3.4.1` |
| 抓取时刻开机时长 | 57 天 |

`/proc/net/dev` 累计（自 2026-07-24 开机）：

```text
ens5  RX  1,792.7 GB   平均 31.4 GB/天
ens5  TX  1,702.2 GB   平均 29.9 GB/天
```

实测瞬时速率在 **310~600 KiB/s 每方向**之间波动，即 **27~50 GB/天**，与上述均值一致。

**方向判断要点**：这是一台反向代理，同一个字节会在两个方向各出现一次——
用户请求/上传是 RX，发回用户的响应体是 TX；同时「向 gate 取数据」是 RX 的另一个大头。
因此 **RX ≈ TX，两者都很大**。腾讯云轻量/CVM 的流量包按**公网出流量**抵扣，
1.70 TB ÷ 57 天 × 30.4 ≈ **908 GB/月 ≈ 1 TB 的 91%**，与「已用 90%」吻合；
建议在控制台「流量监控」里再确认一次计费方向（出/入）。

## 二、归因证据（三种方法互相印证）

### 1) `ss` 每连接字节数采样

60~120 秒窗口内按 socket 的 `bytes_sent/bytes_received` 做差：

```text
local:80      out= 230 KiB/s   in= 69 KiB/s     # 与 Cloudflare 172.x/162.158.x/104.2x 通信
ephemeral    in = 120+ KiB/s                    # 与 gate 110.40.167.56:3001~3010 通信
local:443/3344                                  # v2ray（m15.xwd.pw /tim），约 1 KiB/s 量级
```

### 2) `tcpdump` 抓包 20000 包（14 秒）

```text
proto: tcp 19980 / ICMP 18 / UDP 2
local:80    out 3.33 MB   in 1.15 MB      # 唯一的大头
其他        gate:3006/3010 回程约 2.8 MB
```

抓包覆盖的字节数 ≈ 接口计数，**没有发现 80/443 之外的隐藏大流量**
（UDP 几乎为 0；WARP/usque 仅用于 x.ai 分流，量级 10 KiB/s）。

### 3) Caddy 日志聚合（保留期内）

| 站点 | 响应字节 | 说明 |
|---|---:|---|
| fuxipan | 55.0 GB | 其中 `GET /doc/<id>` 占 **91.5%**，403,850 个不同页面，平均 70.6 KB |
| lzpanx / panso.me | 11.5 GB | `GET /doc/<id>` 50% |
| qkpanso | 0.79 GB | 大量 403（60 万） |
| reman / hunhepan / v2fd / alipanx | < 0.4 GB | hunhepan 有 26 万次 429 |

> 站点日志受 `roll_keep 10 / roll_keep_for 240h` 限制，只保留约 1~2 天，
> 因此上表覆盖 2026-09-04 ~ 09-19 中实际留存的部分，量级用于比较而非全量统计。

### 4) 个人代理（v2ray）不是原因

`m15.xwd.pw / m15.panso.me` 的 `/tim` → `127.0.0.1:3344`（vmess+ws），
`caddy.log`(JSON) 全量统计：**累计仅 6.8 GB（2026-08-05 起，约 0.1 GB/天）**，
唯一客户端 `43.161.227.45`（也是我们 SSH 的来源 IP），
出站 `x.ai / grok.com` 走本机 `usque`（WARP）`127.0.0.1:1080`。
**它不在 1 TB 消耗里占任何显著份额。**

### 5) 单 IP 抓取大户（fuxipan 保留期日志）

| IP | 归属 | 字节 | 请求数 |
|---|---|---:|---:|
| 112.98.87.93 | 哈尔滨电信 | 8.93 GB | 161,081 |
| 112.98.82.112 | 哈尔滨电信 | 2.80 GB | 49,744 |
| 161.153.113.113 | Oracle 云（美西） | 0.72 GB | 10,591 |
| 43.134.106.91 | 腾讯云新加坡 | 0.30 GB | 4,249 |
| 66.249.92.x | Google（Mediapartners-Google） | ~0.7 GB | ~10,000 |

前两个 IP 合计约占总量的 21%，且路径几乎全是 `/doc/<id>`，属典型批量抓取。

## 三、为什么这么大：回源 HTML 没有压缩

线上实测（`fuxipan.com` 一个 `/doc/` 页面）：

```text
raw                 76,037 B
raw (Accept-Encoding: gzip) 76,037 B   ← Caddyfile 里没有 encode 指令
gzip -9              6,597 B           ← 可省 91%
```

Caddyfile 中**没有 `encode` 指令**：Cloudflare 对回源请求会带 `Accept-Encoding: gzip, br`，
但源站不压缩就直接把 76 KB 明文发给 Cloudflare（CF 只对「用户↔CF」那一段压缩，
**CF↔源站那一段是明文未压缩**）。`/doc/` 页占全部出流量 91.5%，
所以这是最大的一个可优化项。

## 四、已执行的日志清理

清理前 `/` 使用 23 G，`/var/log` 20 G，其中 `syslog` 系列 14.3 G、`journal` 4.1 G。
原因：Caddy/caddy-waf 的 WARN 日志（`REQUEST BLOCKED BY WAF`、
`Request blocked in phase evaluation`、`aborting with incomplete response`）经
journald → `/dev/log` 进入 `/var/log/syslog`，速率约 **700 MB/天**，
近 50 万行里 99.8% 是 caddy。另有 `/var/log/v2ray/error.log` 24 MB、
`/var/log/btmp.1` 66 MB（SSH 撞库记录，端口 4895 暴露在公网）。

### 删除/截断（不可恢复）

| 目标 | 动作 |
|---|---|
| `/var/log/syslog` | 保留最后 2 MB 后截断 |
| `/var/log/syslog.1`（8.0 G）、`syslog.2.gz`（151 M） | 删除 |
| `/var/log/journal/**` | `journalctl --vacuum-size=500M`，释放 3.5 G |
| `/var/log/v2ray/error.log` | 截断 |
| `/var/log/btmp.1` | 截断 |
| `/var/log/caddy/waf.json-*.gz` | 只保留最近 3 天 |

结果：`/` 23 G → **4.2 G（10%）**，`/var/log` 20 G → **1.4 G**。

### 新增配置（防复发）

1. `/etc/rsyslog.d/10-caddy-filter.conf`
   ```rsyslog
   if ($programname == 'caddy') then stop
   ```
   caddy 的业务日志仍完整保留在 `/var/log/caddy/*.log`、`/var/log/caddy/waf.json`
   与 journald（`journalctl -u caddy`）中，只是不再重复写入 `/var/log/syslog`。
   验证：重启后 30 秒内 syslog 增长 **0 B**（此前约 8 KB/s）。

2. `/etc/systemd/journald.conf.d/99-size-limit.conf`
   ```ini
   [Journal]
   SystemMaxUse=500M
   SystemKeepFree=1G
   MaxRetentionSec=14day
   ```

**回滚**：删除上述两个文件后 `systemctl restart rsyslog systemd-journald` 即可。

## 四点五、WAF 黑名单封禁抓取大户（2026-09-20 00:07 执行）

### 封禁名单（5 个 IP，均为保留期日志里请求数/流量最大的抓取源）

| IP | 归属 | 保留期请求数 | 保留期字节 | 行为特征 |
|---|---|---:|---:|---|
| 112.98.87.93 | 哈尔滨电信 | 214,286 | 10.50 GB | 8 种 UA 轮换，`/search` 就打了 62,908 次 |
| 112.98.82.112 | 哈尔滨电信 | 49,744 | 2.80 GB | 8 种 UA 轮换，`/search` 15,624 次 |
| 161.153.113.113 | Oracle 云 (us-phoenix-1) | 10,637 | 0.72 GB | 单一固定 UA，批量拉 `/doc/*` |
| 43.134.106.91 | 腾讯云新加坡 | 4,282 | 0.30 GB | 跨 fuxipan/lzpanx/qkpanso 批量抓取 |
| 120.229.5.86 | 中国移动广东 | 4,392 | 0.13 GB | lzpanx 上 83% 请求为 `/search` |

未封禁（如需要可再加）：`66.249.92.x` 为 Google Mediapartners / Googlebot（影响 SEO 与广告），
`47.79.13.220` 为抓 sitemap 的 SEO 爬虫（230 次请求 105 MB，量小）。

### 写入位置（两处都写，原因见下）

| 主机 | 文件 | 生效范围 |
|---|---|---|
| `gate` | `/etc/caddy/waf/ip_blacklist.txt` | `:3001`(hunhepan)、`:3006`(lzpan)、`:3010`(fuxipan) |
| `txsp` | `/etc/caddy/waf/ip_blacklist.txt` | hunhepan、reman、v2fd |

> **关键细节**：`txsp` 上 `fuxipan` / `lzpanx` 站点**没有** `import waf`，所以只写 `txsp` 的黑名单对这两个站无效。
> 真正拦得住它们的是 `gate` 的 `:3010` / `:3006`（已 `import waf`）。两处都写是为了覆盖完整。

### 为什么能拦到真实客户端 IP

请求链路是 `客户端 → Cloudflare → txsp → gate`，`gate` 看到的直连对端是 `txsp`（43.134.116.41）。
caddy-waf 的 IP 黑名单**除了直连对端，还会检查所有 `X-Forwarded-For` 值**，而 Cloudflare 会把真实客户端 IP
写入 XFF（`txsp` 的 `cfproxy` 片段用 `header_up X-Forwarded-For {header.X-Forwarded-For}` 原样透传），
因此黑名单能命中真实客户端。客户端伪造 XFF 只会把自己写进去，无法绕过。

### 生效方式与验证

黑名单文件热加载，**无需 reload/restart**：

```bash
# 变更前备份
mkdir -p /root/waf-blacklist-backup-20260920 && cp -a /etc/caddy/waf/ip_blacklist.txt /root/waf-blacklist-backup-20260920/
printf '%s\n' <ip>... >> /etc/caddy/waf/ip_blacklist.txt
```

验证结果：

```text
gate  :3010(fuxipan) / :3006(lzpanx)  → 5 个 IP 全部 403，对照 IP(8.8.8.8) 非 403
txsp  :80 hunhepan / reman            → 5 个 IP 全部 403
gate  /var/log/caddy/waf.json         → reason=ip_blacklist 持续记录（direct peer = 43.134.116.41）
txsp  fuxipan.log                     → 112.98.87.93 命中 135 次 403、161.153.113.113 命中 6 次 403
```

**回滚**：`cp -a /root/waf-blacklist-backup-20260920/ip_blacklist.txt /etc/caddy/waf/ip_blacklist.txt`（同样热加载）。

### 局限

- 这是**反应式**封禁：`112.98.87.93` / `112.98.82.112` 同属哈尔滨电信同一段且 UA 轮换，换 IP 即可绕过；
  若复发应考虑在 Cloudflare 上对 `/search` 做 Rate Limiting 或直接封该段，而不是继续加单 IP。
- 封禁点在 `gate`，请求仍会走完 `CF → txsp → gate`（几百字节），但 70 KB 的 `/doc/` 响应体被 `403`（44 字节）替代，
  出流量节省约 99%。

## 五、后续建议（按性价比排序）

1. **给 Caddy 加响应压缩**（预计直接砍掉出流量 70%~90%）
   在各站点或公共片段中加入 `encode zstd gzip`，用 `systemctl reload caddy` 生效。
   注意：`/doc/` 页 76 KB → 6.6 KB；CPU 当前余量充足（caddy ~14%）。
2. **Cloudflare 侧对 `/doc/*` 开启 Cache Rule（Cache Everything + Edge TTL）**，
   把回源次数降下来，这是把「每访问一次都回源」变成「每个页面只回源一次」的关键。
3. **限流/封禁抓取 IP**（112.98.87.93、112.98.82.112、161.153.113.113、43.134.106.91），
   或在 CF 上启用 Bot Fight Mode / Rate Limiting；WAF 的 403/429 已在拦，但仍产生请求流量。
4. **`/doc/` 页瘦身**：76 KB HTML 里若是内嵌 JSON 首屏数据，可考虑分页/懒加载。
5. **安全项（与本主题无关但同期发现）**：
   - `/etc/caddy/Caddyfile` 权限为 `644`，其中 DNS Provider 的 Cloudflare API Token 是明文，
     本机任何用户可读。建议改为环境变量或受限权限的凭据文件，并**轮换该 Token**。
   - SSH `4895` 端口持续被撞库（`btmp` 66 MB）。建议仅允许固定来源 IP 或在安全组收敛。

## 六、同期发现的线上异常（非本次变更导致，待确认）

排查过程中发现 `app3` 上 **`go-fuxipan` 于 2026-09-19 23:55:11 收到 shutdown 信号后停止，未再启动**，
`gate:3010` 因此对所有请求返回 `502`（`app3:6655` 无监听）；`go-reman`(4678)、`go-v2fd`(8484) 同样是 `stopped` 状态。

```text
pm2 list (app3):  go-fuxipan  stopped  ↺0     # ↺0 + stopped 说明是显式 pm2 stop，不是崩溃退出
                  go-reman    stopped  ↺0
                  go-v2fd     stopped  ↺173   # 早前已崩溃重试到上限
                  go-alipanx  stopped  ↺196
```

时间线上临近的其它动作：`go-qkpanso` 22:34:54 重启、`go-forge` 23:42:47 启动（↺4），
看起来当晚 `app3` 上有其它人/流程在做发布，因此**未擅自重启**，待确认后再处理。
若需恢复：`cd /root/app/go-fuxipan && ./rs.sh <binary>` 或（补上 nvm PATH 后）`pm2 restart go-fuxipan`。
