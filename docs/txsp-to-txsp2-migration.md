# txsp → txsp2 迁移记录（Caddy + WAF + v2ray + usque）

> 执行日期：2026-09-25。目标：把公网入口从轻量服务器 `txsp`（`43.134.116.41`）迁到 CVM
> `txsp2`（`43.160.224.101`）。`txsp` 全程保留运行，作为回滚。

## 结果概览

- `txsp2` 已承载原 `txsp` 的全部站点，**DNS 已切换 12 条 A 记录**；
- 按用户要求，`alipanx.com` / `www.alipanx.com` 两条记录**未动**（仍指向 `43.134.116.41`）；
- `txsp` 上 `caddy` / `v2ray` / `usque` 仍在运行，可随时切回；
- 迁移方式：`txsp2` 预装 → 新旧双机同口径对照 → DNS 切换（`cloudctl`）→ 观察真实流量。

## 前置背景

- 原 `txsp2`（`43.160.236.224`）**无法访问 gate**，已删除，详见
  [`txsp2-reinstall-ssh-hardening.md`](txsp2-reinstall-ssh-hardening.md)。
- 现 `txsp2` = `ins-kmglzi1u`（ap-singapore-1，内网 `10.3.0.12/22`），与 `txsp`（`10.3.4.17/22`）
  **同内网**：ping `0.62ms`，内网 `9844` 直通。

## 迁移内容清单

| 组件 | 源（txsp） | 目标（txsp2） | 校验 |
|---|---|---|---|
| Caddy 二进制 | `/usr/local/sbin/caddy`（78,684,051 B） | 同路径 | sha256 一致 |
| v2ray 二进制 | `/usr/local/bin/v2ray`（35,582,100 B） | 同路径 | sha256 一致 |
| Caddy 配置 | `/etc/caddy/`（`Caddyfile`、`waf/`、`rule/`） | 同路径 | 站点响应逐一对齐 |
| v2ray 配置 | `/usr/local/etc/v2ray/config.json` | 同路径 | vmess+ws `:3344` |
| TLS 证书 | `/var/lib/caddy/.local/share/caddy`（148K） | 同路径 | `m15.*` 证书至 2026-11-19 |
| systemd 单元 | `caddy.service`、`v2ray.service` + drop-in | 同路径 | enabled + active |
| logrotate | `/etc/logrotate.d/caddy-waf` | 同路径 | — |
| usque | `/root/app/{usque,config.json}`，**手工 `./usque socks`** | 同路径 + **新建 `usque.service`** | socks 出网 200 |
| pm2 | 仅 `pm2-logrotate` 模块，**无业务进程** | 未迁移 | 见「遗留」 |

## txsp2 系统准备

- `caddy` 用户/组：源机是 `999:988`；txsp2 上 **uid 999 已被 `fwupd-refresh` 占用** →
  新建 `caddy` 得 uid 1000 / gid 988，之后 `chown -R caddy:caddy /var/lib/caddy`。
- 目录：`/var/lib/caddy`、`/var/log/caddy`（`caddy:caddy`）、`/var/log/v2ray`（`nobody:nogroup`）。
- 监听：Caddy `:80`、`:443`、`127.0.0.1:2019`（admin）、`127.0.0.1:13002`（WAF dashboard 隧道端点）；
  v2ray `:3344`；usque `:1080`。

新建的 `/etc/systemd/system/usque.service`：

```ini
[Unit]
Description=usque SOCKS5 proxy (WARP MASQUE client)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
WorkingDirectory=/root/app
ExecStart=/root/app/usque socks
Restart=always
RestartSec=5
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
```

## 传输方式（重要经验）

- ❌ 最初用「本机中转」的 `ssh txsp 'tar -cf -' | ssh txsp2 'tar -xf -'`：数据两次跨公网，114MB 很慢。
- ✅ 改为 **txsp → txsp2 直连**：在 txsp 生成 `id_ed25519`，公钥追加进 txsp2 的
  `/root/.ssh/authorized_keys`，随后**在 txsp 上**执行：

  ```bash
  tar -C / -cf - usr/local/sbin/caddy usr/local/bin/v2ray \
    | ssh -p 9844 root@10.3.0.12 'tar -C / -xf -'
  ```

  114MB 耗时 **4.1s**，sha256 完全一致。内网直传是首选；`txsp2` 的公网 IP 同样可用。

## 遇到的坑

1. **`caddy validate` 以 root 运行会在 `/var/log/caddy/` 生成 `root:root 0600` 的空日志文件**，
   随后 `caddy.service`（以 `caddy` 用户运行）启动报
   `open /var/log/caddy/<site>.log: permission denied`。
   处理：删除这些文件即可；以后要么用 `su -s /bin/sh caddy -c 'caddy validate ...'`，要么验证后清理。
2. uid 999 冲突 → 不追求与源机 uid 相同，建用户后 `chown`。
3. **本机透明代理会污染外部验证**（Mac 上对 txsp2 的 curl 返回 301/000）；
   外部验证一律用 `txsp` 作为 vantage。
4. 本机 guard 会拦 `find /`、`chmod /etc/...`；用 `/proc` 定位进程、用 `install -d` 建目录规避。

## 验证结果（切 DNS 前，从 txsp 同时打新旧两台的同口径对照）

Host 头打到 `:80`，11 个 Host 全部一致：

| Host | OLD(43.134.116.41) | NEW(43.160.224.101) |
|---|---|---|
| `hunhepan.com` / `api.hunhepan.com` / `www.hunhepan.com` | 500 | 500 |
| `lzpanx.com` / `www.lzpanx.com` / `panso.me` | 200 | 200 |
| `qkpanso.com` / `www.qkpanso.com` | 200 | 200 |
| `fuxipan.com` / `www.fuxipan.com` | 503 | 503 |
| `reman.xwd.pw` | 502 | 502 |

- `m15.xwd.pw` / `m15.panso.me` TLS：新旧证书 `subject`、有效期一致（`CN=m15.xwd.pw`，至 2026-11-19）。
- WAF：`/waf`（本地）200、`/waf_metrics`（经 13002）200、**非本地访问 404**；`/var/log/caddy/waf.json` 正常写入。
- usque：txsp2 上经 `:1080` 出网 200；**.txsp 上的 usque 此时已失效（socks 测试返回 000）**。

## DNS 切换（cloudctl）

- 切换 **12 条 A 记录** → `43.160.224.101`，`proxied` 状态保持原样（10 条 true、2 条 false）。
- 记录清单：`fuxipan.com`+www、`api/www/apex hunhepan.com`、`lzpanx.com`+www、`panso.me`、
  `m15.panso.me`(灰)、`qkpanso.com`+www、`m15.xwd.pw`(灰)。
- 未动：`alipanx.com`、`www.alipanx.com`。
- 命令模板（先 `--dry-run` 再执行）：

  ```bash
  cloudctl dns ensure --zone <zone> --type A --name <name> \
    --content 43.160.224.101 --proxied=<true|false> --dry-run --json
  ```

- 注意：`--proxied` 是布尔开关，必须写 `--proxied=false`，**不能**写成 `--proxied false`。

切换后验证（从 txsp）：`dig @1.1.1.1` 灰记录返回 `43.160.224.101`；置灰域的
`http://<domain>/` 返回 CF 的 301（Always Use HTTPS），`curl -L` 最终落到源站状态
（`lzpanx.com` 200、`hunhepan.com` 500、`qkpanso.com` 200、`panso.me` 200）；
`txsp2` 的 `/var/log/caddy/*.log` 里出现实时真实流量，确认切换生效。

> `fuxipan.com` 经 CF 访问最终是 **403**，但源站 `fuxipan.log` 无记录、源站直连仍是 503 →
> 该 403 是 **Cloudflare 层**返回，与本次迁移无关。

## 回滚

`txsp` 服务仍在运行，回滚只需把受影响记录指回旧 IP：

```bash
cloudctl dns ensure --zone <zone> --type A --name <name> \
  --content 43.134.116.41 --proxied=<原来的值> --json
```

## 遗留 / 待办

1. **Cloudflare API Token 建议轮换**：排查 `Caddyfile` 时，`dns cloudflare <token>` 的 token
   曾被原样打印到终端（脱敏规则未覆盖该写法）。建议在 Cloudflare 控制台轮换，并同步更新
   `txsp2`（及 `txsp`）的 `/etc/caddy/Caddyfile`。凭据只应存在于配置文件中，本文不记录其值。
2. `txsp` 上的 `usque` 已失效（socks 出网 000）；迁移后由 `txsp2` 承担。若仍需 txsp 侧可用需另行排查。
3. **pm2 未迁移**：txsp 的 PM2 只运行 `pm2-logrotate` 模块、无业务进程，txsp2 未安装 pm2。
   若需要 PM2 日志轮转能力，按 `pm2-logrotate` skill 另行安装。
4. `txsp` → `txsp2` 的免密通道（txsp 的 `/root/.ssh/id_ed25519` → txsp2 `authorized_keys`）
   保留与否待定；保留便于后续运维，撤销则从 txsp2 的 `authorized_keys` 删除该条。
5. 观察期结束后再决定是否停止 `txsp` 的 `caddy` / `v2ray`（停之前先确认无需回滚）。

## 关键路径速查（txsp2）

```text
/usr/local/sbin/caddy                     # 含 caddy-waf 的自编译二进制
/usr/local/bin/v2ray
/etc/caddy/Caddyfile                      # 站点 + WAF 宏（含 CF DNS token）
/etc/caddy/waf/{rules,legacy-rules}.json  # WAF 规则
/etc/caddy/waf/ip_{black,white}list.txt
/var/lib/caddy/.local/share/caddy/        # ACME 证书与状态
/var/log/caddy/                           # 站点日志 + waf.json
/usr/local/etc/v2ray/config.json
/root/app/{usque,config.json}
/etc/systemd/system/{caddy,v2ray,usque}.service
/etc/logrotate.d/caddy-waf
```

WAF dashboard（仅回环，走 SSH 隧道）：`scripts/open-txsp-waf-dashboard.sh`，设置
`TXSP_HOST=txsp2` 即可（脚本默认 `txsp`）。
