# gate 运维脚本（本地存档 + 部署源）

这里的文件是 **gate 上运行版本的权威副本**（服务器上的路径见下表）。改动流程：改这里 → 用 `install.sh` 推送 → 在服务器上验证。

| 本地文件 | 服务器路径 | 作用 |
|---|---|---|
| `gate-ipstats.py` | `/usr/local/bin/gate-ipstats.py` | 按天统计每 IP 访问次数（`docs/gate-access-log-ipstats.md`） |
| `gate-ipguard.py` | `/usr/local/bin/gate-ipguard.py` | 按阈值自动封禁（`docs/gate-ip-auto-ban.md`） |
| `systemd/gate-ipstats.{service,timer}` | `/etc/systemd/system/` | 每天 00:10 跑统计 |
| `systemd/gate-ipguard.{service,timer}` | `/etc/systemd/system/` | 每分钟跑一次封禁判定 |
| `etc/ipguard.json` | `/etc/gate-ipguard/ipguard.json` | 阈值与模式（`mode: enforce` 才真正封） |
| `etc/whitelist.txt` | `/etc/gate-ipguard/whitelist.txt` | 手工额外白名单（IP/CIDR）。**服务器上可能有本地追加，install 默认不覆盖** |
| `etc/bot-allowlist.txt` | `/etc/gate-ipguard/whitelist.d/bot-allowlist.txt` | 自动生成的搜索引擎爬虫 CIDR（Googlebot / Bingbot / Applebot），防止误封 |
| `refresh-bot-allowlist.sh` | —（本地运行） | 重新下载官方 IP 段并推送到服务器，建议每月一次 |

其他相关但不在本目录的东西：

- `/etc/caddy/blocks/banned.caddyfile` — 由 `gate-ipguard.py` 生成，不要手改。
- `/var/lib/gate-ipguard/state.json` — 增量读取位置 + 每分钟计数 + 封禁表；删掉会重新回填当前日志。
- `/var/log/gate-ipguard.log`、`/var/log/caddy-stats/` — 运行产物。

## 部署

```bash
./install.sh          # 推脚本 + systemd 单元，daemon-reload，重启 timer
./install.sh --config # 额外覆盖 ipguard.json / whitelist.txt（会盖掉服务器上的本地修改）
```

## 常用命令

```bash
# 统计
sudo /usr/local/bin/gate-ipstats.py --date 2026-10-21 --top 100

# 封禁：状态 / 立即执行 / 手动解封
sudo /usr/local/bin/gate-ipguard.py --status
sudo /usr/local/bin/gate-ipguard.py
sudo /usr/local/bin/gate-ipguard.py --unban 1.2.3.4,5.6.7.8

# 切模式
sudo sed -i 's/"mode": "enforce"/"mode": "dry-run"/' /etc/gate-ipguard/ipguard.json
```

配置改动（阈值、模式）在**下一次 timer 触发**时生效，无需重启服务。

## 注意

- 两个脚本都依赖 gate 日志里的 `xfr` / `eoip` / `cfip` / `remote` 字段，字段定义在 gate Caddyfile 的 `(logger)` 片段里。改那个片段会让这两个脚本取不到数据（ipguard 会停止计数而不是误封）。
- `ipguard` 封禁的是 `EO-Connecting-IP` / `CF-Connecting-IP`（CDN 覆盖、伪造不了），不是 socket 对端 IP，原因见 `docs/gate-ip-auto-ban.md`。
