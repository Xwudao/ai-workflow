# gate IP 自动封禁：日志格式 / Python 现状总结 + Go 重写 prompt

本文分两部分：

1. **现状总结**：Caddy 访问日志格式，以及当前 `gate-ipguard.py` + systemd timer 的做法。
2. **Go 重写 prompt**：一段可直接粘给 AI 的、自包含的需求说明，用来生成一个常驻 Go 工具替代
   “每分钟跑一次 Python 脚本 + state.json” 的模式。

---

## 一、Caddy 访问日志格式

### 1.1 生成方式（gate `/etc/caddy/Caddyfile`）

17 个 `:30NN` 站点各自 `import logger <name>.log`：

```caddyfile
(logger) {
	log {
		output file /var/log/caddy/{args[0]} {
			roll_size 10M
			roll_local_time
			roll_keep 10
			roll_keep_for 240h
		}
		format transform `{request>headers>X-Forwarded-For>[0]} - {user_id} [{ts}] "{request>method} {request>uri} {request>proto}" {status} {size} "{request>headers>Referer>[0]}" "{request>headers>User-Agent>[0]}" xfr="{request>headers>X-Fr>[0]}" host="{request>host}" eoip="{request>headers>Eo-Connecting-Ip>[0]}" cfip="{request>headers>Cf-Connecting-Ip>[0]}" remote="{request>remote_ip}" gk="{request>headers>X-Guard-Key>[0]}"` {
			time_format "02/Jan/2006:15:04:05 -0700"
		}
	}
}
```

- 每行是 **单行纯文本**（不是 JSON），字段之间用空格分隔，带值的字段用 `key="value"`。
- 滚动：`roll_size 10M`、本地时间、保留 10 份 / 240h。滚动后文件名形如
  `hunhepan-2026-10-22T17-10-00.874-size.log.gz`，当前文件是 `hunhepan.log`。

### 1.2 样例行

```text
116.176.124.41 - - [22/Oct/2026:08:59:39 +0000] "POST /open/search/disk HTTP/1.1" 403 9 "https://hunhepan.com/search" "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/91.0.4472.124 Safari/537.36" xfr="hunhepan.com" host="110.40.167.56:3001" eoip="-" cfip="116.176.124.41" remote="43.160.224.101" gk="-"
```

### 1.3 字段说明

| 字段 | 来源 | 是否可信 | 用途 |
|---|---|---|---|
| 第 1 列 | `X-Forwarded-For[0]` | ❌ 客户端可伪造（EdgeOne 是追加不覆盖） | **不参与判定** |
| `[ts]` | 请求时间，`02/Jan/2006:15:04:05 -0700` | ✅ | 分桶 / 日统计 |
| `"METHOD URI PROTO"` | 请求行 | ✅ | 行为分析（可选） |
| `{status}` `{size}` | 响应 | ✅ | 统计（可选） |
| `"Referer"` `"User-Agent"` | 请求头 | ⚠️ 可伪造 | 行为分析（可选） |
| `xfr` | `X-Fr` 请求头 | 由 Caddy `(xfr)` 片段校验 | **计数前置条件** |
| `host` | 请求 Host | ✅ | 识别站点 |
| `eoip` | `Eo-Connecting-Ip`（EdgeOne 覆盖写入） | ✅ 可信 | **封禁依据之一** |
| `cfip` | `Cf-Connecting-Ip`（Cloudflare 覆盖写入） | ✅ 可信 | **封禁依据之一** |
| `remote` | socket 对端 IP | ✅ 但是 CDN 节点 | **不参与判定** |
| `gk` | `X-Guard-Key` 请求头 | 客户端提供 | 免封通道比对 |

### 1.4 关键约束（为什么不能按来源 IP 封）

- `remote` 是 EdgeOne 边缘节点或自家入口机（txsp2 `43.160.224.101` / alhk `47.242.228.248`），
  按它封会封掉整条 CDN 链路。
- `X-Forwarded-For` 是追加，可伪造。
- 所以**只按 `eoip` / `cfip` 封**。两者同一时刻通常只有一个有值，另一个是 `-`。
- 计数只认 **带合法 `xfr` 且带 `eoip` 或 `cfip`** 的行；直连扫描器（`X-FR` 校验 403）不计入。

`xfr` 合法值（正则，与 gate `(xfr)` 一致）：

```text
^([a-z0-9-]+\.)*(misiai\.com|panso\.me|lzpanx\.com|hunhepan\.com|qkpanso\.com|fuxipan\.com|kitboxpro\.com|lzpan\.com|jujuso\.com|xwd\.pw)$   (忽略大小写)
```

---

## 二、现有 Python 实现（`gate-ipguard.py`）

### 2.1 运行方式

- `gate-ipguard.timer`（`OnCalendar=*-*-* *:*:00`，`AccuracySec=5s`）每分钟触发
  `gate-ipguard.service`（`Type=oneshot`，`ExecStart=/usr/local/bin/gate-ipguard.py`，`Nice=5`）。
- 每次运行：读增量日志 → 更新计数 → 判定 → 生成片段 → 必要时 `caddy reload` → 写 state。
- 单次 CPU ≈ 0.2s，通常 0.2–1.5s 跑完。

### 2.2 路径

| 路径 | 作用 |
|---|---|
| `/usr/local/bin/gate-ipguard.py` | 主程序 |
| `/etc/gate-ipguard/ipguard.json` | 配置 |
| `/etc/gate-ipguard/whitelist.txt` | 手工白名单（IP/CIDR，一行一个，`#` 注释） |
| `/etc/gate-ipguard/whitelist.d/*.txt` | 追加白名单目录（按文件名排序），含自动生成的爬虫段 |
| `/var/lib/gate-ipguard/state.json` | 状态（增量偏移 + 计数 + 封禁表） |
| `/var/lib/gate-ipguard/state.lock` | `flock` 串行化 timer 与手工 `--unban` |
| `/etc/caddy/blocks/banned.caddyfile` | 生成的封禁片段 |
| `/var/log/gate-ipguard.log` | 处置流水 |
| `/etc/caddy/Caddyfile` | reload 用的主配置 |

### 2.3 配置（`ipguard.json`）

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
  "max_bans": 3000,
  "bypass_key": "<32 位随机十六进制>",
  "minute_keep": 30
}
```

- `mode`: `dry-run` | `enforce`（dry-run 只写 `banned.caddyfile.dryrun`，不 reload）。
- `rate_per_min` + `rate_minutes`: 连续 N 个完整分钟，每分钟都 ≥ 阈值 → 触发速率线。
- `daily_total`: 当日总量兜底。
- `ban_seconds`: 首次封禁秒数；`0` = 永久。
- `ban_seconds_repeat`: 第 2 次越线（`strikes >= 2`）时长；`0` = 永久。
- `ban_seconds_long`: 7 天内处置次数 ≥ `strikes_for_long` 时时长；`0` = 永久。
- `max_bans`: 片段最多保留条数，按 `until` 倒序截断（内存保险）。
- `bypass_key`: 请求带 `X-Guard-Key: <该值>` 时既不计入统计也不被封；生成的 matcher 里
  `not header X-Guard-Key <值>`。
- `minute_keep`: 内存里保留多少分钟的桶。

### 2.4 state.json 数据模型

```json
{
  "files":  { "<log 文件名>": {"inode": 123, "offset": 456} },
  "minutes": { "<ip>": {"<unix 分钟>": 次数} },
  "daily":  { "<YYYY-MM-DD>": {"<ip>": 次数} },
  "bans":   { "<ip>": {"until": 253402300799, "strikes": 2, "reason": "daily=5492", "permanent": true} },
  "strikes": { "<ip>": [epoch, ...] }
}
```

- 永久用 `until = 253402300799`（9999-12-31）+ `permanent: true`。
- `strikes` 只保留 7 天窗口内的 epoch。

### 2.5 `ingest()`：增量读日志

1. `glob /var/log/caddy/*.log`（只读当前文件，不含 `.gz`；靠 state 里的 offset 续读）。
2. 对每个文件按 `(inode, offset)` 续读；若 inode 变了或文件变小（滚动/截断）则从 0 开始。
3. 逐行：
   - 提取 `xfr="..."`，不匹配合法域名则跳过；
   - 若行内含 `bypass_key` 则跳过（免统计）；
   - 取 `eoip="..."`，为空/`-` 再取 `cfip="..."`；都没有则跳过；
   - 解析 `[ts]`，换算到 `Asia/Shanghai`；
   - `minutes[ip][minute]++`，`daily[YYYY-MM-DD][ip]++`；
   - 丢弃早于 `minute_keep` 的分钟桶；`daily` 只保留最近 3 天。
4. 返回本次读到的行数。

> 注意：被判定越线但仍在请求的 IP **继续计数**（403 也会被计入 `daily`）。这是已知行为。

### 2.6 `decide()`：判定

```text
for ip in minutes:                      # 只遍历最近窗口内有活动的 IP
    if in_whitelist(ip): continue       # 内置 + whitelist.txt + whitelist.d/*.txt，支持 CIDR
    if 最近 rate_minutes 个完整分钟都 >= rate_per_min:
        trigger = "rate=<n>/min x<k>"
    elif daily[today][ip] >= daily_total:
        trigger = "daily=<n>"
    else: continue
    if bans[ip].until > now: continue   # 已在封禁中，不重复处置
    strikes[ip] = [7 天内的历史] + [now]
    if len(strikes) >= strikes_for_long: secs = ban_seconds_long
    elif len(strikes) >= 2:              secs = ban_seconds_repeat
    else:                                secs = ban_seconds
    until = now + secs if secs > 0 else PERMANENT
    bans[ip] = {until, strikes: len, reason: trigger, permanent: secs <= 0}
清理 until <= now 且非 permanent 的封禁
```

内置白名单 CIDR：`127/8`、`::1/128`、`10/8`、`172.16/12`、`192.168/16`、`100.64/10`、`fd00::/8`、
gate `110.40.167.56`、txsp2 `43.160.224.101`、alhk `47.242.228.248`。

### 2.7 片段生成与生效

- 取 `until > now` 的封禁，按 `until` 倒序，截断到 `max_bans`。
- 生成（IP 里的 `.` 转义为 `\.`）：

```caddyfile
# 由 gate-ipguard.py 自动生成，勿手工编辑。
# 生成时间: ...，封禁条目: N
@banned_eo {
	header_regexp Eo-Connecting-Ip ^(ip1|ip2|…)$
	not header X-Guard-Key <bypass_key>
}
respond @banned_eo "Forbidden" 403
@banned_cf {
	header_regexp Cf-Connecting-Ip ^(ip1|ip2|…)$
	not header X-Guard-Key <bypass_key>
}
respond @banned_cf "Forbidden" 403
```

- **只有内容变化才写文件**；写 `.tmp` 再 `rename`。
- 变化且 `mode=enforce` 才 `caddy reload --config /etc/caddy/Caddyfile --adapter caddyfile`
  （不是 restart；reload 不断连接）。
- gate 的 `(ipguard)` 片段被 17 个 `:30NN` 全部 `import`，内容就是
  `import /etc/caddy/blocks/banned.caddyfile`。

### 2.8 CLI

```bash
gate-ipguard.py                 # 按配置 mode 跑一次（timer 用的就是这个）
gate-ipguard.py --enforce       # 强制 enforce
gate-ipguard.py --dry-run       # 强制 dry-run
gate-ipguard.py --status        # 打印 mode/封禁数/追踪 IP 数/白名单条目 + 前 20 条封禁
gate-ipguard.py --unban IP[,IP…] # 彻底解封：清 bans + strikes + daily + minutes
```

### 2.9 为什么改成 Go / 常驻

- timer 每分钟 fork 一次 Python，冷启动 + 全量 `glob` + 反复读 state，粒度粗（最坏 60s 延迟）。
- 增量状态和 `flock` 是为了弥补“无状态进程 + 定时调度”的缺陷；常驻进程可以天然持有内存窗口，
  直接 tail 日志、亚秒级判定。
- Python 在 gate 上是额外运行时依赖；Go 单二进制更省心。

---

## 三、给 AI 的 Go 重写 Prompt

把下面整段（从 `==== PROMPT BEGIN ====` 到 `==== PROMPT END ====`）粘给 AI 即可。

````text
==== PROMPT BEGIN ====

# 任务：用 Go 重写 gate 的 IP 自动封禁工具（常驻进程，替代 Python + systemd timer）

## 背景

我们有一台 Linux 服务器（下称 gate，Ubuntu 22.04，root 运行），上面跑 Caddy 反向代理。
Caddy 把访问日志按站点写成**单行纯文本**。需要按“单 IP 的请求速率 / 当日总量”自动把滥用 IP
加入 Caddy 的 403 黑名单。现有实现是一个 Python 脚本 + systemd timer（每分钟跑一次、读写
state.json）。现在要改成一个**常驻 Go 进程**，直接 tail 日志、在内存里维护计数、实时判定并
热更新 Caddy 配置。

请用 Go 实现，产出可编译、可部署、可测试的完整项目。

## 运行环境与硬性约束

- OS：Linux（Ubuntu 22.04），systemd。进程以 root 运行。
- Caddy 版本 2.x（当前 v2.11.4），支持 `caddy reload`。
- **不能依赖任何 CGO / 外部二进制**，除调用 `caddy` 做 reload 外。
- 单二进制，systemd `Type=simple` 常驻；不是 timer、不是 oneshot。
- 内存占用要小（gate 只有 ~945MB，已用 ~650MB），几千个追踪 IP 不能吃几十 MB 以上。
- 必须能在进程重启后恢复封禁状态与计数（状态持久化）。
- 绝对不能因为日志滚动、文件被删、Caddy reload 失败而崩溃或退出；要容错并继续运行。

## Caddy 访问日志格式（必须按此解析）

日志是 `format transform` 生成的单行文本，样例：

```text
116.176.124.41 - - [22/Oct/2026:08:59:39 +0000] "POST /open/search/disk HTTP/1.1" 403 9 "https://hunhepan.com/search" "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/91.0.4472.124 Safari/537.36" xfr="hunhepan.com" host="110.40.167.56:3001" eoip="-" cfip="116.176.124.41" remote="43.160.224.101" gk="-"
```

字段（从左到右）：

1. `X-Forwarded-For[0]`（或 `-`）—— **不可信，禁止用于判定**
2. 字面量 `-`
3. `{user_id}`（空时为 `-`）
4. `[02/Jan/2006:15:04:05 -0700]` 时间戳（Go 的 time layout：`02/Jan/2006:15:04:05 -0700`）
5. `"METHOD URI PROTO"`
6. `STATUS`
7. `SIZE`
8. `"REFERER"`
9. `"USER-AGENT"`
10. `xfr="X-Fr 头"`
11. `host="请求 Host"`
12. `eoip="Eo-Connecting-Ip 头"`（EdgeOne 覆盖写入，**可信**；无值时为 `-`）
13. `cfip="Cf-Connecting-Ip 头"`（Cloudflare 覆盖写入，**可信**；无值时为 `-`）
14. `remote="socket 对端 IP"` —— CDN 节点，**不可信，禁止用于判定**
15. `gk="X-Guard-Key 头"`（无值时为 `-`）

注意：

- Referer / User-Agent 里可能含空格和引号，解析要稳健。推荐用「按固定 `key="..."` 提取」
  而不是简单 `strings.Split`，或用一个能处理引号内空格的 tokenizer。
- IPv4 / IPv6 都要支持。
- 日志文件滚动方式：`roll_size 10M`，滚动后旧文件叫
  `hunhepan-2026-10-22T17-10-00.874-size.log.gz`，当前文件是 `hunhepan.log`。
  **只处理当前 `.log`（不读 `.gz`）**，通过 offset 增量读，并正确处理
  “inode 变化 / 文件变小（被截断）”= 从头读。

## 计数规则

只统计同时满足以下条件的请求：

1. `xfr` 匹配合法域名列表（正则，忽略大小写）：
   `^([a-z0-9-]+\.)*(misiai\.com|panso\.me|lzpanx\.com|hunhepan\.com|qkpanso\.com|fuxipan\.com|kitboxpro\.com|lzpan\.com|jujuso\.com|xwd\.pw)$`
2. 整行**不包含** `bypass_key`（见配置）—— 带免封 key 的请求完全不计入统计。
3. 能从 `eoip` 或 `cfip` 取到非空且非 `-` 的 IP（优先 `eoip`，否则 `cfip`）。
4. 时间戳能解析。

对每个 IP 维护：

- **每分钟计数**：滑动窗口，只保留最近 `minute_keep`（默认 30）分钟。
- **每日计数**：按 `Asia/Shanghai` 日期分桶，只保留最近 3 天。

已封禁 IP 的请求**仍然计数**（保持现有语义）。

## 判定规则（必须与现有实现一致）

配置项（JSON，见下）语义：

- **速率线**：最近 `rate_minutes`（默认 3）个**完整分钟**，每分钟计数都 `>= rate_per_min`
  （默认 60）→ 触发，reason 形如 `rate=60/min x3`。
- **日总量线**：`daily[today][ip] >= daily_total`（默认 2000）→ 触发，reason 形如 `daily=5492`。
- 速率线优先于日总量线（先判断速率）。
- 白名单命中的 IP 在判定前直接跳过（支持 IP 和 CIDR）。
- 已在封禁中（`until > now`）的 IP 不重复处置。
- **升级只看 strikes**（7 天窗口内的处置次数），不看旧封禁是否还在：
  - `len(strikes) >= strikes_for_long`（默认 3）→ `ban_seconds_long`（0 = 永久）
  - 否则 `len(strikes) >= 2` → `ban_seconds_repeat`（0 = 永久）
  - 否则 → `ban_seconds`（默认 1800）
  - `0` 表示永久；永久在状态里记 `until = 253402300799`（9999-12-31）且 `permanent = true`。
- 每次触发把当前时间追加进该 IP 的 strikes（只保留 7 天内的）。
- 定期清理 `until <= now` 且非 permanent 的封禁。

## 白名单

内置（硬编码）：`127.0.0.0/8`、`::1/128`、`10.0.0.0/8`、`172.16.0.0/12`、`192.168.0.0/16`、
`100.64.0.0/10`、`fd00::/8`、`110.40.167.56`、`43.160.224.101`、`47.242.228.248`。

再加：

- `/etc/gate-ipguard/whitelist.txt`（每行一个 IP 或 CIDR，`#` 后为注释）
- `/etc/gate-ipguard/whitelist.d/*.txt`（目录内所有 `.txt`，**按文件名排序**读取，同样格式）

文件不存在 / 条目非法要跳过并记日志，不能报错退出。白名单文件变化应能在运行时重新加载
（例如每次判定周期读一次，或监听 mtime；简单起见每分钟或每次判定重读也可以接受，注意成本）。

## 输出：Caddy 黑名单片段

生成 `/etc/caddy/blocks/banned.caddyfile`，格式必须严格如下（IP 中的 `.` 转义为 `\.`，
IPv6 原样；条目按 `until` 倒序取前 `max_bans` 条）：

```caddyfile
# 由 gate-ipguard 自动生成，勿手工编辑。
# 生成时间: 2026-10-22 17:07:44，封禁条目: 132
@banned_eo {
	header_regexp Eo-Connecting-Ip ^(185\.218\.5\.31|64\.90\.17\.103|…)$
	not header X-Guard-Key <bypass_key>
}
respond @banned_eo "Forbidden" 403
@banned_cf {
	header_regexp Cf-Connecting-Ip ^(185\.218\.5\.31|64\.90\.17\.103|…)$
	not header X-Guard-Key <bypass_key>
}
respond @banned_cf "Forbidden" 403
```

要求：

- 所有 IP 在**同一行**用 `|` 连接（`header_regexp` 走 RE2，线性匹配）。
- 用 `header_regexp` 而不是 `header`（Caddy 的 `header` matcher 一个 matcher 只能一个值）。
- `bypass_key` 为空时省略 `not header X-Guard-Key ...` 那行。
- **内容没变化就不要写文件、不要 reload**（避免每分钟无意义 reload）。
- 写入用临时文件 + `rename` 原子替换。
- `mode=dry-run` 时写到 `/etc/caddy/blocks/banned.caddyfile.dryrun`，不 reload、不生效。
- 内容变化且 `mode=enforce` 时执行：
  `caddy reload --config /etc/caddy/Caddyfile --adapter caddyfile`
  reload 失败只记日志，保留旧文件，下个周期再试；**不能退出进程**。
  记录 reload 前后耗时/结果。
- gate 的 `/etc/caddy/Caddyfile` 里已有一个 `(ipguard)` 片段（内容仅一行
  `import /etc/caddy/blocks/banned.caddyfile`）被 17 个 `:30NN` 站点 import，本工具不需要改它。

## 配置

从 `/etc/gate-ipguard/ipguard.json` 读取，缺失用默认值，支持运行时重载（改配置不用重启）：

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
  "max_bans": 3000,
  "bypass_key": "",
  "minute_keep": 30
}
```

- `mode`: `enforce` | `dry-run`。
- `0` 表示永久封禁。

## 状态持久化

- 状态文件：`/var/lib/gate-ipguard/state.json`（要与现有 Python 版本的 schema 兼容，便于灰度/回滚）。
- 建议 schema（保持兼容）：

```json
{
  "files":  { "<log 文件名>": {"inode": 123, "offset": 456} },
  "minutes": { "<ip>": {"<unix 分钟>": 次数} },
  "daily":  { "<YYYY-MM-DD>": {"<ip>": 次数} },
  "bans":   { "<ip>": {"until": 253402300799, "strikes": 2, "reason": "daily=5492", "permanent": true} },
  "strikes": { "<ip>": [epoch, ...] }
}
```

- 定时（如每 5–10s，或状态变化后防抖）原子落盘；退出时落盘。
- 多实例互斥：用文件锁 `/var/lib/gate-ipguard/state.lock`（`flock`）。
- `--unban` 等 CLI 子命令与常驻进程并发时，必须通过同一把锁串行化，避免“解封被内存态覆盖”。

## 免封通道（X-Guard-Key）

- 配置里的 `bypass_key` 是随机串。
- 请求头 `X-Guard-Key: <bypass_key>` 时：不计入任何统计；生成的封禁 matcher 用
  `not header X-Guard-Key <bypass_key>` 跳过。
- 只免封，不做别的放行。

## CLI 子命令

提供一个二进制，例如 `gate-ipguard`：

- `gate-ipguard run`：常驻模式（systemd 用），前台运行，支持 `SIGTERM`/`SIGINT` 优雅退出。
- `gate-ipguard status`：打印 `mode`、封禁中数量、追踪中 IP 数、白名单条目数，以及按 `until`
  倒序的前 20 条封禁（IP / until（永久显示“永久”）/ strikes / reason）。需要读锁。
- `gate-ipguard unban <ip>[,<ip>...]`：彻底解封——清 `bans` + `strikes` + 所有天的 `daily`
  + `minutes`。日志打印实际清了什么，然后重写片段并在 enforce 下 reload。
- `gate-ipguard check` / `replay`（**新增，很有用**）：离线把指定的历史日志文件（含 `.gz`）
  按上述规则跑一遍，输出“谁会越线、按什么 reason、封多久”，不写任何文件、不 reload。
  用于上线前验证阈值与灰度。
- `gate-ipguard version`。

## 日志与可观测性

- 处置流水写到 `/var/log/gate-ipguard.log`（追加），同时打到 stdout 交给 journald。
- 格式参考现有：
  - `2026-10-22 17:07:44 [enforce] 越线 185.218.5.31 -> 封 永久 (strikes=2)`
  - `2026-10-22 17:07:44 [enforce] 解封 <ip>`
  - `2026-10-22 17:07:44 快照更新: 132 条封禁, reload=True`
  - `... [enforce] 手动解封 <ip>（封禁=有 strikes=1 当日计数=2128 分钟桶=清）`
- 建议再加一个 `--metrics` / `/metrics`（Prometheus 文本格式）或定期打印统计：读到的行数、
  追踪 IP 数、封禁数、reload 次数/耗时。非必需，但加分。
- 用 `log/slog` 或标准库，不要引重型依赖。

## 部署

- 提供 `gate-ipguard.service`（`Type=simple`，`ExecStart=/usr/local/bin/gate-ipguard run`，
  `Restart=always`，`RestartSec=2`，`Nice=5`），并说明要 `systemctl disable --now gate-ipguard.timer`
  以停用旧的 timer 方案。
- 说明灰度步骤：先 `mode=dry-run` 观察 `banned.caddyfile.dryrun`，确认与旧实现判定一致后再切
  `enforce`。
- 说明回滚：恢复 Python 脚本 + timer 的方法。

## 性能要求

- 日志量级：全天约 140 万行，峰值约 500 QPS，QPS 日常约 16。常驻进程必须能轻松处理。
- tail 要支持一次读取多行（批量），不要每行一次 syscall。
- 内存窗口用 map + 定期 GC 过期桶；注意别让 map 无限增长（尤其扫描器海量一次性 IP）。
- 生成 matcher 的字符串拼接在几千条时也不能明显卡顿。

## 测试要求

- 单元测试（`go test`）：
  - 日志解析：普通行、IPv6、eoip 为 `-` 取 cfip、UA/Referer 含空格与引号、缺字段、非法行。
  - 计数：速率窗口“连续 3 个完整分钟”边界、日总量跨天、bypass_key 跳过、xfr 非法跳过。
  - 判定：首次 30 分钟 → 第 2 次永久 → 累计 3 次永久（模拟同一 IP 连续越线）。
  - 白名单：CIDR 命中、白名单文件缺失/非法条目。
  - 片段生成：转义、排序截断、内容不变不写。
- 提供一个可运行的端到端脚本或测试：喂一个包含合成日志的目录，跑 `replay`，断言输出。
- 提供 `make build` / `make test`（或等价说明）。

## 交付物

1. 完整 Go 项目源码（`go.mod`、`cmd/`、内部包、测试）。
2. 上述 systemd unit 文件。
3. 一份 `README.md`：构建、安装、配置、灰度、回滚、CLI 用法。
4. 明确列出与现有 Python 实现的**行为差异**（如果有，必须说明原因）。

请先给出设计（模块划分、状态机、并发模型），再给出完整代码。

==== PROMPT END ====
````

---

## 附：迁移时的注意事项

1. **行为对齐优先**：Go 版与 Python 版对同一份日志必须给出相同的封禁集合与时长。上线前用
   `replay` 对比两边判定结果。
2. **state.json 兼容**：Go 版应能直接读现有 `state.json`（含 `permanent`、`strikes`），
   这样切换时不会“忘记”已有封禁。
3. **停用 timer**：切换后 `systemctl disable --now gate-ipguard.timer`，只留常驻 service，
   避免两个实现同时写 `banned.caddyfile` 和 `state.json`（虽然有锁，但没必要）。
4. **reload 用 reload 不用 restart**：本工具只改 `banned.caddyfile` 片段，用
   `caddy reload`；只有替换 Caddy 二进制 / 编译进模块时才用 `restart`。
5. **不要读私钥、不要把凭据写进日志**：`bypass_key` 只写进片段和日志的既有格式里，别额外扩散。
