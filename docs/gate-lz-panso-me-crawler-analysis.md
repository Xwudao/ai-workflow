# lz.panso.me 访问日志分析：分布式爬虫为主

分析时间：2026-10-22 21:02–21:18（CST），数据源 `gate:/var/log/caddy/lzpan.log`（live 快照）。
结论：**是的，绝大部分是爬虫流量，而且不是单一爬虫**——主体是一个「浏览器 UA 轮换 + 海量住宅 IP 单次请求」的分布式抓取网络，叠加若干具名 AI/搜索爬虫和几个单 IP 语料镜像器。

## 1. 域名是怎么落到 lzpan.log 的

`lz.panso.me` 不是 Caddyfile 里的 vhost，它是 EdgeOne 上的域名，回源到 gate 的 `:3006`（lzpan），
所以日志落在 `/var/log/caddy/lzpan.log`，靠 `xfr`（EdgeOne 注入的原始域名）区分：

| 入口 | xfr | host | 客户端 IP 头 |
|---|---|---|---|
| `lz.panso.me` | `lz.panso.me` | `panso.pro` | `Eo-Connecting-Ip` |
| `www.lzpanx.com` | `www.lzpanx.com` | `110.40.167.56:3006`（源站 IP） | `Cf-Connecting-Ip` |
| `lz.misiai.com`（管理域） | `lz.misiai.com` | `panso.pro` | `Eo-Connecting-Ip` |

同一份日志还混着 `lz.lzpan.com` 的直连请求（`xfr=-`、无 CDN 头）。

## 2. 量级

- 快照 16 分钟：**22,873 请求 / 18,286 个独立客户端 IP**，约 1,400 req/min，全天平稳无峰谷。
- 当日（10-22）11 个 rotation 合计约 **305,000 请求**，每 ~30 分钟轮转一次 10MB。
- 状态码：200=22,328、403=258、410=164、502=107。
- 参考：10-21 全站 `lzpan` 就有 286,467 请求（当日全站 1,067,672，其中 403 493,683、429 35,785）。

## 3. 核心特征：海量 IP，每个只来一次

| 指标 | 值 |
|---|---|
| 独立客户端 IP | 18,286 |
| **只发 1 个请求的 IP** | **16,967（92.8%）** |
| ≥10 个请求的 IP | 73 |
| 独立 /16 网段 | 3,647 |

按来源拆分：

| xfr | 请求 | 独立 IP | req/IP |
|---|---|---|---|
| `lz.panso.me` | 17,465 | 16,622 | **1.05** |
| `www.lzpanx.com` | 4,503 | 1,629 | 2.76 |
| `lz.misiai.com` | 678 | 80 | 8.47 |

真实用户一个会话会产生 5–20 个请求（页面 + 资源 + API）。**平均 1.05 req/IP 只能解释为「每个 URL 换一个 IP」的分布式抓取**，配合 3,647 个不同 /16 网段，是住宅代理池 / P2P 抓取节点的典型形状。

## 4. 伪装 UA 的证据

UA 家族分布（快照）：

```
Chrome145 5134  Edge(14x) 4756  Chrome144 4453  Chrome142 2297  Chrome143 2248
Chrome140  614  Chrome155  182  Chrome135  146  Chrome150  102
```

两个破绽（都不依赖「当前 stable 是哪个版本」这个前提）：

1. **版本分布是阶梯函数，不是衰减曲线**。流量集中在 6 个 UA 上：
   Chrome 142/143/144/145 + Edge 144/145，每个版本几乎 1.0 req/IP；
   而老版本（Chrome 90/120/131…）加起来只有个位数百分比。
   真实浏览器人群的版本分布是平滑衰减 + 长尾（大量不升级的机器），
   这里是一个只有 6 个取值的固定 UA 池被随机抽取的结果。
2. **另有一簇「离群版本」来自极少数 IP**。`Chrome/148–155` 这一簇不在主池里，
   且高度集中，说明是另一个工具手写的 UA：

| 离群 UA | 请求 | 独立 IP | req/IP |
|---|---|---|---|
| Chrome/155 | 609 | 51 | **11.9** |
| Chrome/151 | 493 | 76 | 6.5 |
| Chrome/150 | 102 | 98 | 1.0 |

   注：这些版本号是否真的「超前」取决于 Chrome 的实际发布节奏（服务器时钟不可作为依据），
   但**主池之外的孤立 UA 簇 + 单 IP 高请求密度**本身就是自动化特征。

## 5. 在爬什么：语料枚举，不是自然流量

| 路径 | 请求 | 说明 |
|---|---|---|
| `/doc/*` | 11,862 | **10,005 个唯一 docID，其中 8,397 个只被请求 1 次** |
| `/admin/disks` | 5,852 | SPA 按 doc 拉取磁盘列表，200，正常前端行为 |
| `/tag/*` | 2,182 | 1,947 个唯一 tag |
| `/v1/*` | ~1,900 | `list_store/by_types`、`search/disk`、`device/register` 等 |

`/doc/*` 返回的是 23KB–176KB 的完整 HTML（中位 31KB），**9,241 个 doc 各被拉一次**——
这是把整个内容库顺序扫一遍，自然流量不会这样分布（热门页会反复出现）。
9,842 个 `/doc/*` 请求的 Referer 是 `lz.panso.me/doc/*`，即顺着站内「相关文档」链一路爬。

## 6. 具名爬虫与单 IP 镜像器

| 客户端 | 量 | 行为 |
|---|---|---|
| `Reflectionbot/1.0`（reflection.ai） | 491 reqs / 74 IPs | `/doc/*`、`/tag/*`、`/v1/*` |
| `ExaSearchBot/1.0`（crawler.exa.ai） | 411 reqs / 112 IPs | `/tag/*`、`/favicon.ico`、`/v1/site_config/all` |
| `codex-video-crawler/0.1` | **423 reqs / 1 IP**（49.72.188.69） | 抓 sitemap.xml/index.xml/sitemap.txt/robots.txt，再 `/tag/*`(273)、`/doc/*`(85)、`/index_2.html`、`/news/index_*.html` → **整站镜像** |
| `bingbot/2.0` | 144 | — |
| `YisouSpider` | 111 | — |
| `Googlebot` | 28 | — |
| `inner-http-client` | 309 / 1 IP（118.89.110.51，腾讯云） | 全部打 `/open/disk/api_import`，**站内自有导入任务** |

单 IP 高密度语料抓取（都在阈值之下，未被封）：

| IP | 请求 | 速率 | 行为 |
|---|---|---|---|
| 49.72.188.69 | 423 / 10min | ~42/min | 见上，整站镜像 |
| 106.5.16.15 | 171 / 3.5min | ~49/min | 16×`/search` + ~150 个唯一 `/doc/*` |
| 183.197.98.117 | 121 / 12min | ~10/min | 16×`/search` + ~100 个唯一 `/doc/*` |
| 121.25.212.197 | 56 | — | UA 属离群簇（`Chrome/155`）；16×`POST /v1/device/challenge` + 5×`/v1/device/register` + `/v1/search/disk` → **反复过设备指纹** |

## 7. 需要人工确认的异常：疑似管理员会话

`175.152.177.9`（经 `lz.misiai.com`，UA Chrome/145 macOS，15 分钟内 113 请求）在打管理接口：

```
57  GET  /admin/v1/app/stream-logs      -> 52×403, 4×200, 1×502
 6  POST /admin/v1/site_config/update   -> 全部 200   ← 写操作
 2  POST /admin/v1/user/temp_token      -> 全部 200   ← 签发临时令牌
11  GET  /admin/v1/site_config/all      -> 200
 5  GET  /admin/v1/analysis/            -> 200
 2  GET  /auth/v1/cdkey/invite-code     -> 200
 3  GET  /auth/v1/user/stats, /auth/v1/user/info, /auth/v1/message/unread-count
```

`/admin/v1/site_config/update` 与 `/admin/v1/user/temp_token` 返回 200 说明**会话是已认证的**。
`stream-logs` 被 403 挡住 52 次，看起来是 WAF/规则在拦 SSE 日志流路径。
如果这是自己的运维/管理账号，属正常（只是被 WAF 反复拦）；**如果不是，需要立即查会话来源并吊销**。

另外 `/admin/v1/app/stream-logs` 总共 57 次调用全部来自这一个 IP，其余无人在碰该接口。

## 8. 为什么现有防护拦不住

`gate-ipguard` / `go-log2ban` 的策略是**按单 IP 速率**封禁：

- `/etc/gate-ipguard/ipguard.json`：`rate_per_min: 60`，`rate_minutes: 3`，`daily_total: 2000`
- 即「连续 3 分钟每分钟 >60 请求」才封；当前封禁表 179 条。

对本次流量的两类形态天然无效：

1. **分布式单次请求**——每个 IP 只发 1 个请求，永远不可能越线。
2. **中等速率语料抓取**——上面几个单 IP 抓取器都在 10–49 req/min，正好卡在 60 以下。

同时：

- `robots.txt` 已声明 `Crawl-delay: 20`、`Disallow: /admin/`、`/film/`，并对 Googlebot 额外 `Disallow: /doc/`、`/search` —— **无人遵守**。
- `/etc/gate-ipguard/whitelist.d/bot-allowlist.txt` 只放行搜索类爬虫，AI 训练爬虫故意不放；上述具名爬虫不在其中，但也没被封（速率不够）。

## 9. 可选处置方向（未实施）

按性价比排序：

1. **确认 175.152.177.9 的会话归属**（最高优先级，涉及写接口）。
2. **加 UA / 指纹维度规则**：按 UA 池特征拦截，而不是按版本号高低——
   例如对 `codex-video-crawler`、`Reflectionbot`、`ExaSearchBot` 按 UA 限速或直接拒绝；
   对「同 IP 短时间内反复 `POST /v1/device/challenge` + `/v1/device/register`」的组合直接封。
   （不要单纯按版本号大于某个值就 403，会误伤正常升级到新版的真实用户。）
3. **给 `/doc/*` 加「每 IP 每日独立 URL 数」配额**，而不是请求速率——单 IP 拉 100+ 个不同 doc
   是很强的爬虫信号，且不影响正常用户。
4. **给源站加缓存**：`/doc/*` 是 23–176KB 的 SSR HTML，若在 EdgeOne 侧能命中缓存，
   爬虫请求就不会打到 gate（当前 9,241 个 doc 各一次，说明全是 cache miss）。
5. **收敛源站暴露面**：`www.lzpanx.com` 回源时 `Host` 直接是 `110.40.167.56:3006`，
   且有 219 个请求完全不带 CDN 头直达源站；建议源站只接受 CDN 回源 IP + 校验回源密钥。

## 10. 复现命令

```bash
# 抓快照（日志在滚动，边分析边变，先固定一份）
ssh gate 'cp /var/log/caddy/lzpan.log /tmp/lzsnap.log'

# 关键指标
ssh gate "grep -c '' /tmp/lzsnap.log"                                  # 总量
ssh gate "awk '{print \$1}' /tmp/lzsnap.log | sort -u | wc -l"         # 独立 IP
ssh gate "grep -o 'xfr=\"[^\"]*\"' /tmp/lzsnap.log | sort | uniq -c"   # 来源
ssh gate "grep -o 'host=\"[^\"]*\"' /tmp/lzsnap.log | sort | uniq -c"  # 入口 host
```

日志格式定义见 `/etc/caddy/Caddyfile` 的 `(logger)` 片段；`(xfr)` 白名单、
`(ipguard)` 封禁接入见 [`gate-300n-xfr-noise-filter.md`](./gate-300n-xfr-noise-filter.md)
与 [`gate-ip-auto-ban.md`](./gate-ip-auto-ban.md)。

> 注意：`ipguard.json` 内含 `bypass_key`（凭据），仅描述其位置，勿抄录。
