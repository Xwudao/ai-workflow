# gate 按阈值自动封禁（IP 白名单 + 超阈值拉黑）

2026-10-21 实施，同日 18:57 切到 **enforce**（已生效），截至 20:44 共封禁 56 个 IP（永久 48 + 临时 8）。

## 为什么不能按"来源 IP"封

gate 看到的 IP 有两种，`tcpdump` + 日志实测：

| 流量路径 | socket 对端（`remote`） | 真实客户端 |
|---|---|---|
| EdgeOne → gate | EdgeOne 边缘节点（国内各省 IP，免费版查不到回源 IP 段） | `EO-Connecting-IP`（EO **覆盖**客户端伪造值） |
| Cloudflare → txsp2/alhk → gate | 43.160.224.101 / 47.242.228.248（自己的入口机） | `CF-Connecting-IP`（CF 覆盖） |
| 直连 `110.40.167.56:30NN` | 攻击者自己 | 同左（但这类请求已被 `X-FR` 规则 403） |

所以：

- 按 socket 对端封 → 会封掉 EdgeOne 整个边缘节点，全站故障。
- 按 `X-Forwarded-For` 封 → EO 是**追加**不覆盖，客户端可随意伪造（`X-Forwarded-For: 1.2.3.4` 到源站变 `1.2.3.4,<真实IP>`）。
- 结论：**只能按 `EO-Connecting-IP` / `CF-Connecting-IP` 封**。

顺带说明为什么不复用 caddy-waf 的 `ip_blacklist_file`：实测 caddy-waf 只认 `X-Forwarded-For`（首段）和 `X-Real-IP`，伪造即可绕过；而且不是每个 300N 端口都挂了 waf。所以封禁用 gate 自己的 Caddyfile 片段实现。

## 组件

| 路径 | 作用 |
|---|---|
| `/usr/local/bin/gate-ipguard.py` | 守护脚本（源码 `scripts/gate/gate-ipguard.py`，部署用 `scripts/gate/install.sh`） |
| `/etc/gate-ipguard/ipguard.json` | 阈值与模式（当前 `"mode": "enforce"`） |
| `/etc/gate-ipguard/whitelist.txt` | 手工额外白名单（IP/CIDR，一行一个） |
| `/etc/gate-ipguard/whitelist.d/*.txt` | 追加白名单目录；`bot-allowlist.txt` 由 `refresh-bot-allowlist.sh` 生成 |
| `/etc/caddy/blocks/banned.caddyfile` | **生成**的封禁片段（enforce 模式才写） |
| `/etc/caddy/blocks/banned.caddyfile.dryrun` | dry-run 时的影子快照（不生效） |
| `/var/lib/gate-ipguard/state.json` | 增量读取位置 + 每分钟计数 + 封禁表 |
| `/var/log/gate-ipguard.log` | 处置流水 |
| `gate-ipguard.timer` | 每分钟跑一次（`oneshot`，约 0.2–1.5s） |

gate 侧接入：`(ipguard)` 片段被 17 个 `:30NN` 全部 `import`，内容只有一行 `import /etc/caddy/blocks/banned.caddyfile`；生成的片段形如

```caddyfile
@banned_eo header_regexp Eo-Connecting-Ip ^(203\.0\.113\.9|198\.51\.100\.7|…)$
respond @banned_eo "Forbidden" 403
@banned_cf header_regexp Cf-Connecting-Ip ^(203\.0\.113\.9|198\.51\.100\.7|…)$
respond @banned_cf "Forbidden" 403
```

为什么是 `header_regexp` 而不是 `header`：Caddy 的 `header` 匹配器**一个 matcher 只能带一个值**
（多值直接报 `malformed header matcher: expected field`），几千条 IP 不现实。`header_regexp` 走 RE2，
`ip1|ip2|...` 无回溯、无灾难性回溯，成本随条目数**线性**增长但斜率很小：当前 56 条实测与空 matcher
无差别（0.270ms vs 0.266ms），3000 条（`max_bans` 上限）约 +0.17ms，详见
[性能：条目数 vs 单请求耗时](#性能条目数-vs-单请求耗时2026-10-21-实测)。

> 也试过 `client_ip` 匹配器 + `servers { trusted_proxies static 0.0.0.0/0 ::/0; client_ip_headers Eo-Connecting-Ip Cf-Connecting-Ip }`：
> 功能上更优雅（CIDR 基数树、天然支持 IPv6），但 `trusted_proxies` 是**全局**设置，会让 `remote_ip` 匹配器
> 也改成看请求头 —— 直接破坏了 `(xfr)` 的内网豁免和 `(waf-dashboard-local)` 的仅本机限制（有人在 :443 上伪造
> `Eo-Connecting-Ip: 127.0.0.1` 就能访问 WAF 面板）。所以放弃，改用局部 regexp。

改动后由脚本自己 `caddy reload`（只在片段内容变化时 reload，秒级、不断连接）。

## 判定规则（当前配置）

```json
{
  "mode": "enforce",
  "rate_per_min": 60,
  "rate_minutes": 3,
  "daily_total": 2000,
  "ban_seconds": 1800,
  "ban_seconds_repeat": 0,
  "ban_seconds_long": 0,
  "strikes_for_long": 3,
  "max_bans": 3000
}
```

- **速率**：连续 3 个完整分钟，每分钟都 ≥ 60 次 → 首次封 30 分钟。
- **再次越线**（有过封禁记录、又触发阈值）→ **永久封禁**（`ban_seconds_repeat: 0` 表示永久）。
- **屡犯**：7 天内被处置 ≥ 3 次 → **永久封禁**（`ban_seconds_long: 0`）。
- 永久封禁在 `state.json` 里标记 `permanent: true` + `until=9999-12-31`，不会自动过期；解封只能手动：`gate-ipguard.py --unban <ip>`。
- 升级只看 `strikes`（7 天窗口内的处置次数），**不看旧封禁是否还在**：首次 30 分钟 → 第 2 次永久（`ban_seconds_repeat: 0`）→ 累计 3 次同样永久。
  实测（离线模拟同一 IP 连续越线 4 次）：`1799s / 永久 / 永久 / 永久`。
- 片段只在**封禁集合变化**时重写并 reload；没有变化的那一分钟完全不动 Caddy（日志里不会出现“快照更新”）。
- 计数只取「带合法 `X-FR`（CDN/入口机链路）且带 `eoip`/`cfip`」的请求 → 直连扫描器（已被 403）不参与计数，也不会误封 CDN 节点。
- 白名单内置：`127/8`、`::1`、`10/8`、`172.16/12`、`192.168/16`、`100.64/10`、`fd00::/8`、gate `110.40.167.56`、txsp2 `43.160.224.101`、alhk `47.242.228.248`。

## 手工放行记录

| 日期 | IP | 方式 | 说明 |
|---|---|---|---|
| 2026-10-22 | `1.14.49.179` | `/etc/gate-ipguard/whitelist.txt` | 曾因 `daily=3248` 被临时封 30 分钟（strikes=1）；放行时先加白名单，再 `--unban` 清掉封禁记录/strikes/日总量/分钟桶，旧文件备份在 gate 的 `/root/gate-whitelist-bak-20261022/`。仓库内 `scripts/gate/etc/whitelist.txt` 已同步。 |
| 2026-10-22 | 30 个普通 IP（批量） | 先 `--unban`，同日 17:51 对其中 29 个采集器重新封禁 | 复核 `daily=` 封禁，详见下文《日总量封禁 IP 复核与解封（2026-10-22）》。29 个实为住宅 IP 采集器，已重新封禁；仅 `2408:8207:c05:4b01:14be:3706:b118:ee18` 为真实用户，保持解封。 |
| 2026-10-22 | `175.152.177.9` | 仅 `--unban`（未加白名单） | 16:20 因 `daily=2011`（阈值 2000）被临时封 30 分钟（strikes=1）。是真实用户（Chrome/Windows+Mac+Android，`host=panso.pro`，登录态访问 admin 与 `/auth/v1/inbox/*`），非扫描器；每分钟轮询 `inbox/messages` + `inbox/summary` 各一次，全天累计超过日总量。解封后验证 200。**若继续这样用会再次触发日总量**，长期方案是 `X-Guard-Key` 或加白名单。 |

放行后验证：`in_whitelist()` 命中、`banned.caddyfile` 里 `grep -Fc '1\.14\.49\.179'` 为 0、
`curl -H 'X-FR: hunhepan.com' -H 'EO-Connecting-IP: 1.14.49.179' http://127.0.0.1:3001/` 返回 200。

> 注意：白名单只在**判定前**跳过，不会自动摘掉已有封禁；已封的 IP 要先加白名单再 `--unban`。

## 自己的设备怎么免封（X-Guard-Key）

手机 SIM / 家宽出口 IP 会一直变，按 IP 白名单维护不过来（一个 `/16` 就有 6 万多个地址，
还容易把同段里的采集器一起放走）。所以额外做了一条**与 IP 无关**的免封通道：

```json
// /etc/gate-ipguard/ipguard.json
"bypass_key": "<32 位随机十六进制>"
```

- 请求带 `X-Guard-Key: <该值>` 时：
  1. gate 生成的封禁 matcher 会跳过它（片段里是 `not header X-Guard-Key <值>`）；
  2. `gate-ipguard.py` 也不把这些请求计入速率/日总量统计（日志里的 `gk` 字段等于该值就跳过）。
- **只免封，不放行别的**：`X-FR` 校验、WAF、应用鉴权照旧。
- 日志里的 `gk` 字段会记录这个值（gate 上 root 可读）。所以别拿真凭据当 key，用随机串；
  想轮换就同时改 `ipguard.json` 和客户端，下一次 timer 触发会自动重写片段并 reload。

用法：

```bash
# curl / 脚本
curl -H 'X-Guard-Key: <key>' https://hhp.misiai.com/...

# 自己的工具（如 go-online-tools/hhprun）：在发请求处加同一个 header
# 浏览器：装 Header Editor / ModHeader，给 *.misiai.com / *.hunhepan.com / *.lzpanx.com 加这个 header
```

实测（gate:3001，用一个永久封禁的 IP 模拟）：

| 请求 | 结果 |
|---|---|
| 被封 IP，无 key | 403 Forbidden |
| 被封 IP + 正确 key | 200（正常返回页面） |
| 被封 IP + 错误 key | 403 Forbidden |
| 未封 IP + key | 200（不计数，也不影响别人） |

计数跳过也单独验证过：同一份合成日志里，带 key 的 IP 计数为 `None`（完全不进统计），
不带 key 的 IP 正常计数。

> 保留的 IP 白名单通道：`/etc/gate-ipguard/whitelist.txt` 与 `whitelist.d/*.txt`
> （仓库里 `scripts/gate/etc/whitelist.d/10-home-sichuan.txt` 预留了 `116.169.0.0/16` 注释行，
> 需要按段放行时取消注释即可，但注意它等于放行 65536 个地址）。

## 会不会误封 Googlebot / Bingbot

**有风险，已经处理掉了。** 搜索类爬虫的抓取速度是由站点容量"自适应"的，大站上持续 1–2 req/s（60–120 次/分钟）并不罕见，正好压在 `rate_per_min: 60` 的阈值上 —— 靠阈值区分"人 / 爬虫"在这里不成立，必须按 IP 段放行。

实测（2026-10-21 最近 3 小时，只看 CDN 链路流量）：

| 爬虫 | 请求数 | 单 IP 峰值 |
|---|---|---|
| Bingbot | 277 | 13 次/分 |
| Googlebot | 185 | 33 次/分 |
| Applebot | 97 | — |
| Baiduspider | 10 | — |
| PetalBot / AhrefsBot / facebookexternalhit | 13 | — |

当前还没到阈值，也确认过**被封的 32 个 IP 里没有一个是搜索爬虫**。但不能赌，所以：

1. `gate-ipguard.py` 的白名单现在支持目录：`/etc/gate-ipguard/whitelist.txt` + `/etc/gate-ipguard/whitelist.d/*.txt`。
2. `whitelist.d/bot-allowlist.txt` 由 `scripts/gate/refresh-bot-allowlist.sh` 自动生成，来源是官方列表：
   - `common-crawlers.json`（Googlebot 等；2026-10 前叫 `googlebot.json`）
   - `special-crawlers.json`（AdsBot / Mediapartners-Google（AdSense）/ GoogleOther 等）
   - 注：Google 已把段文件从 `/static/search/apis/ipranges/` 迁到 `/static/crawling/ipranges/`
     （旧路径 301）。脚本直接用新路径，并用 `curl -f` + “前缀数 < 300 就拒绝生成”避免
     把 404 的 HTML 错误页或残缺列表当成白名单推上去。
   - `bingbot.json`（Bingbot）
   - 再加 Applebot 的 `17.0.0.0/8`（Apple 官方文档写明）
   当前共 618 条前缀 + 内置 10 条 = 628 条白名单。
3. 白名单命中的 IP 在判定前直接跳过 —— 离线验证：把 Googlebot（`66.249.68.167`）和 Bingbot（`40.77.167.143`）的计数灌到 500 次/分钟，`decide()` 依然不封；同时喂一个爬虫 IP（`185.218.5.31`）则正常封 30 分钟。

**AdSense 是覆盖的**（2026-10-21 核查）：AdSense 的内容抓取用 `Mediapartners-Google`，它的段就在
`special-crawlers.json` 里；实测 gate 全量日志里 23 次 CDN 链路的 `Mediapartners-Google` 请求
（`66.249.87–92.x` 等）全部命中白名单，封禁表里也没有任何 Google 段 IP。两点容易搞混：

- AdSense 的**广告投放**（素材/统计）是用户浏览器直连 Google，根本不经过 gate，与本策略无关；
- 白名单是**按 IP** 判的，UA 伪造成 `Mediapartners-Google` 没有任何好处 —— 日志里就有伪装 UA
  扫 `/infra/terraform.tfvars` 的扫描器，照样按 IP 计数、照样会被封。

**故意没放进去的**：GPTBot / ClaudeBot / CCBot / Bytespider / PetalBot / AhrefsBot / SemrushBot 等 AI 训练与 SEO 分析爬虫 —— 量大、通常也不希望被爬，该封就封。要放行某个只需在 `/etc/gate-ipguard/whitelist.txt` 里加一行 CIDR（或自己写个 `whitelist.d/xxx.txt`）。

维护：`scripts/gate/refresh-bot-allowlist.sh` 每月跑一次（Google/Bing 偶尔加新段），跑完会自动推送到 gate 并打印白名单条目数。

## 阈值怎么定的（2026-10-21 数据）

- 全天 143 万请求 / 21.8 万独立 IP，其中 **99.9% 的 IP 只发过 1 次**（扫描器）。
- 日总量分布：≥1000 次的 136 个 IP 占 57% 流量，≥3000 次的 66 个占 49%，≥2000 次约 82 个。
- 每分钟峰值分布：≥120/分 16 个、≥60/分 41 个、**≥300/分 0 个**。
- 真实用户（浏览器/APP）单页请求量级是"十几次"，持续 60 次/分钟 × 3 分钟 = 3 分钟内 180 次，不可能来自人。

所以 60/分 × 3 分钟是"机器行为"的下界附近；2000/天是兜底（防低速长时间爬）。

## 灰度与开关

```bash
# 看当前计数/封禁
sudo /usr/local/bin/gate-ipguard.py --status          # 含“永久”标记
sudo /usr/local/bin/gate-ipguard.py --unban 1.2.3.4   # 彻底解封（见下方说明）

# 手动跑一次（按配置文件里的 mode）
sudo /usr/local/bin/gate-ipguard.py

# 临时强制 dry-run（不写也不 reload）
sudo /usr/local/bin/gate-ipguard.py --dry-run

# 正式启用
sudo sed -i 's/"mode": "dry-run"/"mode": "enforce"/' /etc/gate-ipguard/ipguard.json
# 或者一次性：sudo /usr/local/bin/gate-ipguard.py --enforce
```

启用后观察点：

```bash
tail -f /var/log/gate-ipguard.log                     # 谁被封/解封
cat /etc/caddy/blocks/banned.caddyfile | head -3      # 生效片段
grep -c . /etc/caddy/blocks/banned.caddyfile          # 行数（IP 都在同一行，行数≈3）
```

## 解封（`--unban`）

`--unban <ip[,ip...]>` 会把这个 IP 的**全部历史**清掉，而不只是把它从片段里拿掉：

| 清什么 | 不清会怎样 |
|---|---|
| `bans`（封禁记录） | 旧片段里还会有它 |
| `strikes`（7 天处置次数） | 下次越线直接跳永久 |
| `daily`（当日总量） | **下一次 timer 会凭同一条日总量线立刻再封一次** |
| `minutes`（每分钟桶） | 下一次 timer 会凭速率线立刻再封一次 |

所以 `--unban` = “这个 IP 从没来过”，之后重新从 30 分钟起步。日志会打印实际清了什么，例如：

```
2026-10-21 23:11:45 [enforce] 手动解封 101.204.77.211（封禁=有 strikes=1 当日计数=3407 分钟桶=清）
解封后剩余封禁: 84
```

> 早期版本只清 `bans` + `strikes`，**实测踩过两次坑**（2026-10-21 23:03）：
> ① 那次 `--unban` 与同一秒启动的 timer 撞车，timer 先把旧 state 读进内存、随后 `save_state()`
> 把删掉的记录写了回去，解封被静默撤销；② 即使没撞车，`daily=3407 ≥ daily_total` 会让下一分钟的
> timer 用同一条理由再封一次。现在 `state.json` 读写有 `flock`（`/var/lib/gate-ipguard/state.lock`），
> 手工解封与 timer 串行，且 `--unban` 会一并清空 `daily`/`minutes`。

注意：

- 精确匹配、不支持 CIDR（传 `1.2.3.0/24` 会静默“解封 0 个”）；IPv6 要写全地址。
- 如果那个 IP **仍在继续打**，解封后它照样会再次越线被封（这次是首次 30 分钟）—— 想长期放行请用
  `X-Guard-Key`（与 IP 无关）或 `whitelist.txt`。
- `--status` 只显示前 20 条，别用“看不见”判断是否被封；用
  `sudo grep -c '<ip 转义点>' /etc/caddy/blocks/banned.caddyfile`。

## 已做的验证

- 片段机制：`curl -H 'X-FR: hunhepan.com' -H 'EO-Connecting-IP: <已封 IP>' http://110.40.167.56:3001/`
  → `403 Forbidden`（走 `Eo-Connecting-Ip` 和 `Cf-Connecting-Ip` 两条路都验证过）；换成未封 IP → 200。
- 上线即时效果：2026-10-21 18:57 切 enforce 后 1 分钟内就有 26 条封禁生效，日志里出现爬虫
  `185.218.5.31 - "POST /open/search/disk" 403 9` 之类的记录。
- `header_regexp` 各档条目数的性能：见下方专节（2026-10-21 重测，早期那组 `0.388ms / 0.377ms / 0.380ms`
  分辨率不够，把约 0.17ms 的真实差异盖住了）。
- dry-run 首跑（回填当前日志里的最近 30 分钟）：判定 20 个 IP 越线，日志流水正常，未 reload。
- 定时器每分钟执行，单次 CPU ≈ 0.2s（`systemctl show gate-ipguard.service -p CPU`）。

## 性能：条目数 vs 单请求耗时（2026-10-21 实测）

gate 上临时起 `:3999` 实例（`admin off`、loopback、HTTP/1.1 keepalive，每组 400 次、去掉前 3 次预热），
Caddy v2.11.4。基线是「同一份 Caddyfile，去掉封禁 matcher」。绝对数含 python `http.client`
客户端开销 ≈0.26ms，**看差值**。

| 片段条目数 | 未命中均值 | 相对基线 | 命中均值 | RSS | 配置加载（`caddy run` 到可连接） |
|---|---|---|---|---|---|
| 0（基线） | 0.266 ms | — | — | 44.3 MB | 61 ms |
| 56（当前线上） | 0.270 ms | +0.004 ms | 0.268 ms | 44.7 MB | 41 ms |
| 500 | 0.280 ms | +0.014 ms | 0.296 ms | 46.8 MB | 41 ms |
| 2000 | 0.378 ms | +0.11 ms | 0.409 ms | 53.3 MB | 61 ms |
| 3000（`max_bans` 上限） | 0.437 ms | +0.17 ms | 0.457 ms | 60.4 MB | 122 ms |
| 5000 | 0.574 ms | +0.31 ms | 0.615 ms | 65.0 MB | 102 ms |
| 20000 | 1.595 ms | +1.33 ms | 1.629 ms | 107.9 MB | 287 ms |

结论：

1. **不是「与 1 条无差别」，而是线性增长 ≈ 0.06 µs/条/请求**。原因：Caddy `header_regexp` 用 Go `regexp`，
   语法是 RE2（无回溯），但 Go **没有实现 DFA 缓存**，匹配是按字节做 NFA 线程表模拟；
   `^(ip1|ip2|…)$` 只有公共前缀被 `syntax.simplify` 合并，随机 IP 几字节后就分叉，线程表规模 ~O(N)。
2. **正常请求要扫两遍**：`Eo-Connecting-Ip` 与 `Cf-Connecting-Ip` 是两条独立 matcher（matcher 集合是 AND，
   写不出 OR 两个 header），两个都没命中的请求两遍成本都付。3000 条满额 ≈ **0.34 ms/请求**。
3. 实际影响可忽略：143 万请求/天 ≈ 16.5 QPS，3000 满额时 `16.5 × 0.34ms ≈ 5.6ms/s`，约 **0.6% 单核**；
   即使 QPS 涨到 500 也只吃 17% 单核。
4. 内存才是硬约束：gate 只有 945MB（已用 ~650MB），3000 条 +16MB 无压力，2 万条要 +60MB。所以
   `max_bans: 3000` 不只是防片段膨胀，也是内存保险 —— 脚本按 `until` 倒序截断（`gate-ipguard.py` 第 303 行）。
5. reload 成本：3000 条配置加载 ~100ms，且只在封禁集合变化时触发，`caddy reload` 不断连接。
6. 线上实测（`:3001` 真实配置 + 已封 IP，56 条）：403 路径 **0.371 ms**、p99 0.6ms。

真要把封禁量放到万级，改用 `map` 从文件查表（哈希 O(1)，代价与条目数无关）：

```caddyfile
map {http.request.header.Eo-Connecting-Ip} {banned_eo} {
	import /etc/caddy/blocks/banmap_eo.txt   # 每行: 1.2.3.4 1
	default ""
}
@banned_eo expression {banned_eo} != ""
```

代价是同步改 `gate-ipguard.py` 的片段生成、把 `X-Guard-Key` 豁免挪进 `expression`、并重新验证 CDN 链路。
当前只有几十条，**没到需要动的程度**，等常态超过 1000 条再考虑。

## 已知局限 / 注意

1. 被封的 IP 仍会经过 EdgeOne / Cloudflare 到达 gate（流量在 CDN 已经产生），只是源站立刻 403。想真正省流量得在 EdgeOne/CF 侧也封（EdgeOne 有 IP 黑名单规则，免费版有配额限制）。
2. 封禁靠请求头，若某天把 EdgeOne 的回源 Host/头规则改坏，所有流量都会"看起来没有 IP"，此时守护脚本会停止计数（不会误封），但也不会封人。
3. `banned.caddyfile` 里所有 IP 在一行，条目上限 `max_bans`（3000）。匹配成本随条目数线性增长
   （≈0.06 µs/条/请求，且正常请求要扫 eo/cf 两遍），上限同时是内存保险，见上方性能专节。
4. 脚本用 `caddy reload` 应用变更；reload 失败会记日志并保留旧片段（`banned.caddyfile` 已经是新内容，下次成功时生效）。

## 回滚

```bash
# 关闭自动封禁并清空片段
sudo systemctl disable --now gate-ipguard.timer
printf "# disabled\n" | sudo tee /etc/caddy/blocks/banned.caddyfile
sudo caddy reload --config /etc/caddy/Caddyfile --adapter caddyfile

# 完全撤销接入（含 Caddyfile 的 (ipguard) 片段与 17 处 import）
sudo cp -a /root/xfr-rollout-20261021/Caddyfile.before-ipguard /etc/caddy/Caddyfile
sudo systemctl reload caddy
```

## 前台 inbox 轮询已收敛（2026-10-22）

`175.152.177.9` 那次 `daily=2011` 的根因不是后台，而是 **go-hunhepan 前台的站内信轮询**：
`/auth/v1/inbox/summary` 与 `/auth/v1/inbox/messages` 两条各自 60s，登录用户只要前台页面可见就是
**2 次/分钟 = 2880 次/天**，连续开约 16.7 小时必然撞上 `daily_total: 2000`。

改动（`go-hunhepan/web`，未动后台接口）：

| 项 | 改前 | 改后 |
|---|---|---|
| 查询条数 | summary、messages 两条独立 query | 合并为一条 `useInboxOverview`（内部 `Promise.all`） |
| 轮询条件 | 常开，与面板无关 | **仅铃铛面板打开时轮询**（`refetchInterval: panelOpen ? 5min : false`） |
| 间隔 | 60s | **5 分钟**（`INBOX_POLL_INTERVAL_MS`） |
| 面板关闭时 | 每 60s 打两次 | 只在挂载 / 窗口聚焦 / 读信删除后各取一次 |

涉及文件：`web/src/hooks/useInboxSummary.ts`、`web/src/pages/front/components/InboxBell.tsx`。
普通用户前台常驻请求量因此从 ~2880/天 降到接近 0。后台页面（系统任务 3s 等）未改，仍有撞阈值风险。

## 日总量封禁 IP 复核与解封（2026-10-22）

2026-10-22 17:07 复核 `daily_total: 2000` 这条线封掉的 IP，判断是否为「普通用户被误封」。

**方法**：`state.json` 里 `reason` 以 `daily=` 开头的共 **127** 个；逐个查 `ip-api.com`（`hosting`/`proxy`）+ `whois` 的 `netname`/`descr` + 反查 PTR 判断机房/IDC，再用 gate 的 `/var/log/caddy/*.log` 看真实请求行为。判定标准：`hosting=true` 或 `whois` 归属「Network Technology / IDC / Cloud / 机房公司」的一律算机房；归属省电信/联通/移动、境外消费级 ISP（如 OPTAGE、Superloop、PCCW IMS）的算普通 IP。

**结果**：

| 类别 | 数量 | 处置 |
|---|---|---|
| 机房 / VPS / VPN（`hosting=true`） | 67 | 保持封禁 |
| `hosting=false` 但 `whois` 实为 IDC/机房公司 | 30 | 保持封禁 |
| 普通 IP（消费级 ISP） | 30 | **解封**（`--unban`，未加白名单） |

后 30 个里，只有 `2408:8207:c05:4b01:14be:3706:b118:ee18` 是**真实用户**（日志里有 `GET /search`、`GET /doc/...` 的页面浏览）；其余 29 个的行为全是 `POST /v1/search/disk` / `POST /open/search/disk`，**没有任何页面浏览**，UA 是伪装成 `Chrome/91` 的脚本，属于「用住宅/移动 IP 做出口的分布式采集器」。

| IP | 属地 | ISP | 行为判定 |
|---|---|---|---|
| `115.70.61.103` | Australia Melbourne | SUPERLOOP (AUSTRALIA) PTY LTD | 采集器 |
| `182.200.127.192` | China Shenyang | Chinanet | 采集器 |
| `117.10.145.224` | China Tianjin | CNC Group CHINA169 Tianjin Province Network | 采集器 |
| `121.238.93.12` | China Nanjing | Chinanet | 采集器 |
| `183.211.82.83` | China Suzhou | China Mobile communications corporation | 采集器 |
| `59.172.116.85` | China Wuhan | China Telecom | 采集器 |
| `2408:8207:c05:4b01:14be:3706:b118:ee18` | China Beijing | China Unicom | **真实用户** |
| `183.23.192.53` | China Shenzhen | Chinanet | 采集器 |
| `39.144.155.124` | China Wuxi | China Mobile Communications Corporation | 未确认 |
| `106.41.70.135` | China Qingyuan | Chinanet | 未确认 |
| `113.80.90.231` | China Guangzhou | Chinanet | 采集器 |
| `115.204.129.186` | China Hangzhou | Chinanet | 采集器 |
| `171.8.92.28` | China Guancheng | Chinanet | 未确认 |
| `59.190.126.195` | Japan Osaka | OPTAGE Inc. | 采集器 |
| `112.38.75.73` | China Jinan | China Mobile Communications Group Co., Ltd | 未确认 |
| `2409:8a20:50f2:8a00:befd:cff:fecc:b9da` | China Suzhou | China Mobile Communications Corporation | 未确认 |
| `112.81.128.250` | China Suzhou | China Unicom CHINA169 Jiangsu Province Network | 采集器 |
| `39.149.235.124` | China Guancheng | China Mobile Communications Group Co., Ltd | 未确认 |
| `112.20.126.49` | China Nanjing | China Mobile communications corporation | 未确认 |
| `116.176.124.41` | China Jinrongjie | China Unicom CHINA169 Network | 采集器 |
| `2404:c800:9160:bf2:eee8:98ec:5a0f:1fcc` | Hong Kong Central | PCCW IMS Limited | 采集器 |
| `125.119.40.227` | China Hangzhou | Chinanet | 未确认 |
| `117.174.18.42` | China Chengdu | China Mobile communications corporation | 采集器 |
| `2408:8274:60d:9b00:638c:6a63:81e0:232b` | China Jinrongjie | China Unicom Network | 采集器 |
| `27.8.138.199` | China Chongqing | China Unicom Chongqing Province Network | 采集器 |
| `113.56.39.87` | China Wuhan | CNC Group CHINA169 Hubei Province Network | 采集器 |
| `120.229.87.28` | China Shenzhen | China Mobile communications corporation | 未确认 |
| `222.131.222.154` | China Beijing | China Unicom Beijing Province Network | 采集器 |
| `60.179.224.18` | China Ningbo | Chinanet | 采集器 |
| `2404:c800:9160:bd7:1c99:4c85:22d8:b7b7` | Hong Kong Central | PCCW IMS Limited | 采集器 |

**关键发现**：这些采集器会在同一住宅网段内**轮换 IP**，单独解封某个地址没有意义。复核过程中日志就抓到同段新地址继续打：`2408:8274:60d:9b00:88e5:1d43:80d1:5910`（与已封 `…:638c:6a63:81e0:232b` 同 `/64`）、`113.80.93.109`（与 `113.80.90.231` 同段）。也就是说 `daily_total: 2000` 这条线本身没有在误伤真实用户，命中的是采集网络。

**备份**（gate 上，root）：

| 文件 | 说明 |
|---|---|
| `/root/gate-state-bak-20261022.json` | 解封前 `state.json` 快照 |
| `/root/banned.caddyfile.bak-20261022` | 解封前封禁片段快照 |

解封后校验：`banned.caddyfile` 里 30 个 IP 全部 `grep -Fc` 为 0；`curl -H 'X-FR: hunhepan.com' -H 'EO-Connecting-IP: 182.200.127.192' http://127.0.0.1:3001/` → 200，未解封的 `64.90.17.103` / `185.218.5.31` → 403。封禁数 159 → 132。

> 复核结论：**29 个普通 IP 实际是采集器，已于 17:51 全部重新封禁**（在 `state.json` 里恢复原 `bans`/`strikes`，重写片段并 `caddy reload`，封禁数 132 → 165；审计记录已写入 `/var/log/gate-ipguard.log`）。真实用户只有 1 个（`2408:8207:c05:4b01:14be:3706:b118:ee18`），保持解封；若它继续高频访问仍会再次触发 `daily_total`，长期放行应使用 `X-Guard-Key` 或加白名单。

重新封禁后校验：29 个 IP 全部回到 `banned.caddyfile`；`curl -H 'X-FR: hunhepan.com' -H 'EO-Connecting-IP: 27.8.138.199' http://127.0.0.1:3001/` → 403，真实用户 → 200。
