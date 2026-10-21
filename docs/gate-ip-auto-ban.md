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
sudo /usr/local/bin/gate-ipguard.py --unban 1.2.3.4   # 手动解封（同时清 strikes）

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
