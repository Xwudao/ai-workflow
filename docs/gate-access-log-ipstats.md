# gate 按天统计 IP 访问次数（不需要 Caddy 插件）

2026-10-21 实施。结论先说：**不用写 Caddy 插件**。Caddy 自身就能把每个请求的日志（含可信客户端 IP）写成文件，剩下的按天聚合用系统自带的 python + systemd timer 就够了。插件（如 `caddy-metrics` 扩展）也拿不到 IP 维度——Prometheus 指标里带 IP label 会直接把基数炸掉，官方和社区都不这么做。

## 数据来源：日志里新增三个 IP 字段

gate 的 `(logger)` 片段（`/etc/caddy/Caddyfile`，全局对所有站点生效）：

```caddyfile
format transform `{request>headers>X-Forwarded-For>[0]} - {user_id} [{ts}] "{request>method} {request>uri} {request>proto}" {status} {size} "{request>headers>Referer>[0]}" "{request>headers>User-Agent>[0]}" xfr="{request>headers>X-Fr>[0]}" host="{request>host}" eoip="{request>headers>Eo-Connecting-Ip>[0]}" cfip="{request>headers>Cf-Connecting-Ip>[0]}" remote="{request>remote_ip}"`
```

| 字段 | 含义 | 可信度 |
|---|---|---|
| `eoip` | EdgeOne 注入的 `EO-Connecting-IP` | 可信：**EO 会覆盖**客户端自带的同名头（实测 `curl -H 'EO-Connecting-IP: 5.6.7.8'` 到源站仍是真实 IP） |
| `cfip` | Cloudflare 注入的 `CF-Connecting-IP` | 可信：CF 侧同样覆盖 |
| `remote` | TCP 对端 IP（`{http.request.remote_ip}`） | 直连时唯一可信；经 CDN 时是 CDN 边缘 IP / 入口机 IP |
| 首列 | `X-Forwarded-For` | **不完全可信**：EO 是"追加"而不是覆盖 —— 伪造 `X-Forwarded-For: 1.2.3.4` 到源站会变成 `1.2.3.4,<真实IP>`，真实 IP 在**最右** |

> 日志占位符的坑：`{request>headers>...}` 走的是 transform encoder，按 Go canonical key **精确查表**，
> 所以必须写 `X-Fr` / `Eo-Connecting-Ip` / `Cf-Connecting-Ip`；写成 `X-FR` / `EO-Connecting-IP` 会永远输出 `-`。

## 统计脚本

仓库内源码：`scripts/gate/gate-ipstats.py`（部署用 `scripts/gate/install.sh`），服务器上：`/usr/local/bin/gate-ipstats.py`（python3 标准库，无第三方依赖）。

IP 取值优先级：

```
请求带 X-FR（说明来自 EdgeOne / txsp2 / alhk 等 CDN 链路）
    eoip -> cfip -> X-Forwarded-For 最右一段 -> remote
请求没有 X-FR（直连，多半是被 403 的扫描器）
    remote（老格式日志没有 remote 字段时退化到 XFF）
```

输出（默认 `/var/log/caddy-stats/`）：

- `daily/<YYYY-MM-DD>.tsv`：`ip  hits  files  first  last`，按次数降序
- `summary/<YYYY-MM-DD>.txt`：请求总数 / 独立 IP 数 / 状态码分布 / IP 取证方式统计 / 各日志文件量 / Top N
- 结果保留 `--keep-days 180` 天（源日志本身只有约 10 次轮转，所以**过期就没法补算**）

按天边界用的是 **Asia/Shanghai**（日志内时间戳是 UTC，脚本会转换）。文件筛选靠轮转文件名里的时间戳 + 逐行时间戳二次过滤，因此跨轮转的边界是精确的、重复跑同一天结果幂等。

### 常用命令

```bash
# 统计昨天（默认）
sudo /usr/local/bin/gate-ipstats.py

# 统计指定日期 / 只统计某目录 / 看前 100
sudo /usr/local/bin/gate-ipstats.py --date 2026-10-21 --top 100

# 看结果
head -50 /var/log/caddy-stats/daily/2026-10-21.tsv
cat /var/log/caddy-stats/summary/2026-10-21.txt

# 按次数筛（例如找出 >1000 次的 IP）
awk -F'\t' 'NR>1 && $2>1000' /var/log/caddy-stats/daily/2026-10-21.tsv
```

### 定时任务

```ini
# /etc/systemd/system/gate-ipstats.timer
[Timer]
OnCalendar=*-*-* 00:10:00
Persistent=true      # 关机/漏跑会补
Unit=gate-ipstats.service
```

`gate-ipstats.service` 为 `oneshot` + `Nice=10` + `IOSchedulingClass=idle`（统计约 20–40 秒，扫 ~200MB 日志，不影响业务）。

安装/检查：

```bash
sudo systemctl enable --now gate-ipstats.timer
systemctl list-timers gate-ipstats.timer
systemctl start gate-ipstats.service && journalctl -u gate-ipstats.service -n 20
```

## 2026-10-21 基线数据（供对照）

```text
请求数: 1,489,278   独立 IP: 217,975
状态码: 200=546k 403=395k 429=434k 410=9k 502=1.5k
IP 取证方式: xff-right=1.42M cfip=15k eoip=3.5k remote=123
日志文件量: hunhepan 478k / qkpanso 458k / lzpan 400k / fuxipan 90k
Top IP: 47.88.60.237 (23k)、132.232.2.140 (21k)、38.76.212.13 (21k) 
```

`429` 是应用自身的限流（hunhepan/qkpanso 的搜索接口），`403` 里大部分来自本项目的 X-FR 降噪（见 `gate-300n-xfr-noise-filter.md`）。

## 局限

1. **IP 可以被伪造**：走 CDN 时用 `eoip`/`cfip`（CDN 覆盖，可信）；但直连 IP 打端口的客户端可以自带 `EO-Connecting-IP`/`CF-Connecting-IP`/`X-Forwarded-For`。这类请求基本都被 X-FR 规则 403 掉了，同时 `remote` 字段留了真实对端可交叉验证。
2. 只统计"打到 gate 的请求"，不包含 CDN 边缘直接拦掉的流量（那部分只有在 EdgeOne / Cloudflare 后台看）。
3. 源日志按大小轮转（`roll_size 10M`、`roll_keep 10`、`roll_keep_for 240h`），**晚于约 10 天就补算不出来**，所以 timer 不能长期停。

## 变更记录 / 回滚

- gate 日志格式变更备份：`/root/xfr-rollout-20261021/Caddyfile.before-ipfields`；回滚 `cp -a` 回去后 `systemctl reload caddy` 即可（不影响业务，只是少了新字段）。
- 统计相关新增文件（可随时删，无业务影响）：
  - `/usr/local/bin/gate-ipstats.py`
  - `/etc/systemd/system/gate-ipstats.{service,timer}`
  - `/var/log/caddy-stats/`
