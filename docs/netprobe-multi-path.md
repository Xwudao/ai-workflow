# 多路径网络探针（netprobe）

用于长期观测 **alhk（阿里云香港）/ txsp2（腾讯云新加坡）/ gate（腾讯云广州）** 三地之间的跨境链路质量，定位「站点慢到底是哪一段」的问题。

## 背景

2026-10-21 迁移期间发现 alhk ↔ 中国大陆丢包率剧烈波动：

| 时间点 | alhk → gate 丢包 |
|---|---|
| 迁移当天上午 | 0%（44.8ms，0% 丢包） |
| 事故期间（12:25–12:45） | 70–75%（TCP 20MB 只传 27KB） |
| 恢复后（13:30） | 14–19%（双向、所有大陆目标） |
| 14:00 复查 | 18.67%（gate 侧反向测） |

同一时间窗内 alhk → 1.1.1.1 / txsp2 均为 0%，alhk 网卡 errors/dropped 为 0，gate ↔ app3 VPC 8ms 0% 丢包 —— 说明丢包发生在**阿里云香港与大陆之间的跨境链路**，且随时间波动，需要用长期数据判断规律，不能靠单次采样下结论（早期用 6 次采样得出的「jujuso 稳定」结论就是错的）。

## 部署位置与探针矩阵

脚本 `/usr/local/bin/netprobe.sh`，目标定义 `/etc/netprobe/targets.txt`，cron `/etc/cron.d/netprobe`（每 5 分钟）。

| 主机 | 探针 |
|---|---|
| **alhk** | `ping_cf`(1.1.1.1 基线)、`ping_gate`、`ping_txsp2`、`tcp_gate3001`、`tcp_txsp2_443`、`http_gate_direct`(直连大陆 20KB 页面)、`http_via_txsp2`(经新加坡中转同页面) |
| **txsp2** | `ping_cf`、`ping_gate`、`ping_alhk`、`tcp_gate3001`、`tcp_alhk_443`、`http_gate_direct` |
| **gate** | `ping_alhk`、`ping_txsp2`、`tcp_app3_vpc`、`http_app3_vpc`(后端基线)、`http_alhk_origin`、`http_txsp2_origin` |

设计要点：

- **三类指标互补**：ICMP 丢包（便宜但可能被限速）、TCP 连接成功率（10 次连接，规避 ICMP 限速偏差）、HTTP 分段耗时（`t_connect` / `t_ttfb` / `t_total`，反映真实用户影响）
- **app3 VPC 基线**：`http_app3_vpc` 稳定在 10ms 说明后端没问题，反证慢在跨境段
- **对照组**：`ping_cf` / `ping_txsp2` 恒为 0%，用来证明「不是 alhk 网卡或整体出口的问题」
- `http_gate_direct` 与 `http_via_txsp2` 是**同一页面**（20KB index），可直接衡量「直连 vs 绕新加坡」的取舍

## 数据格式

`/var/log/netprobe/YYYY-MM-DD.csv`（日期按 UTC 分文件，时间戳 UTC，保留 14 天自动清理）：

```csv
ts_utc,probe,loss_pct,rtt_ms,http_code,t_connect,t_ttfb,t_total,tcp_ok,tcp_avg_ms
2026-10-21T07:00:11Z,ping_gate,35,30.911,,,,,,
2026-10-21T07:00:11Z,tcp_gate3001,,,,,,,9/10,274
2026-10-21T07:00:11Z,http_gate_direct,,,200,1.052586,1.108131,2.301572,,
```

每次运行：ping 20 包（0.2s 间隔）、TCP 10 次连接、HTTP 各 1 次；单机单轮约 15–20 秒。

## 查看报告

```bash
# 最近 24 小时汇总（默认）
scripts/netprobe-report.sh

# 最近 6 小时 / 72 小时
scripts/netprobe-report.sh 6
scripts/netprobe-report.sh 72
```

输出每台机器每个探针的样本数、平均丢包/延迟、TCP 成功率、HTTP 总耗时中位数/p90、`>1s` 比例。

原始数据也可以直接看：

```bash
ssh alhk 'cat /var/log/netprobe/$(date -u +%F).csv'
ssh gate 'tail -5 /var/log/netprobe/$(date -u +%F).csv'
```

## 新增探针

1. 编辑目标机的 `/etc/netprobe/targets.txt`，每行一种：

```
ping|<name>|<host>
http|<name>|<url>|<host:port:ip，可选，用于 --resolve 绕过 DNS/CF>
tcp |<name>|<host>:<port>
```

2. 立即手动跑一次验证：`/usr/local/bin/netprobe.sh && tail -3 /var/log/netprobe/$(date -u +%F).csv`

## 运维备注

- cron 文件：`/etc/cron.d/netprobe`（`*/5 * * * * root /usr/local/bin/netprobe.sh`），三台一致
- 脚本无外部依赖，只用 `ping`/`curl`/`bash /dev/tcp`（Ubuntu 自带）
- **不要**把探针目标指到有速率限制的接口（如业务 API），`http` 探针固定用 20KB 的站点首页
- alhk/txsp2 系统时区是 UTC+8，gate 是 UTC；CSV 里时间戳统一 UTC，聚合脚本按 UTC 计算
- 数据量极小（每台每天约 2000 行），无需特殊维护

## 如何使用这些数据做决策

- 若 `ping_gate`（alhk）长期 <2%，说明跨境链路健康，站点可以放 alhk（直连 `tot med` 通常在 0.15s 内）
- 若持续 >10%，站点应留在 txsp2；此时 `http_via_txsp2` 与 `http_gate_direct` 的对比可量化「绕新加坡」的收益
- 判断是否启用中转，看 `http_gate_direct` 的 `>1s%`：直连超过 25% 且 `http_via_txsp2` 明显更低时，中转才有意义
