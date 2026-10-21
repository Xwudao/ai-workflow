# txhk 服务盘点与迁移规划（2026-10-21）

盘点方式：`ssh -J alhk txhk`（经阿里 HK 中转，直连丢包 20% 走不动）。
服务器：腾讯云 HK，`43.161.227.45`，Ubuntu 22.04.5，2 vCPU / 961MiB RAM / 40G 盘（已用 8.7G）。
迁移目标：阿里云 HK，`47.242.228.248`（别名 `alhk`，端口 9844），Ubuntu 24.04.5，2 vCPU / 1.8GiB RAM / 39.9G 盘。

本文不记录任何 Token / 私钥 / UUID，凭据只说明所在位置。

## 一、服务清单

| # | 服务 | 运行方式 | 监听 | 配置路径 | 迁移必要性 |
|---|---|---|---|---|---|
| 1 | **Caddy**（含 WAF） | systemd `caddy.service`（User=caddy） | tcp 80、tcp/udp 443、管理口 127.0.0.1:2019 | `/usr/local/sbin/caddy`、`/etc/caddy/Caddyfile`、`/etc/caddy/waf/`、`/var/lib/caddy/` | 必须 |
| 2 | **v2ray**（代理入口） | systemd `v2ray.service`（User=nobody） | 127.0.0.1:3344（vmess + ws） | `/usr/local/bin/v2ray`、`/usr/local/etc/v2ray/config.json` | 必须 |
| 3 | **WireGuard `wg-hksh`** | `wg-quick@wg-hksh` | UDP 32472 | `/etc/wireguard/wg-hksh.conf` + `.key`/`.pub` | 必须 |
| 4 | **WireGuard `wg-sghk`** | `wg-quick@wg-sghk` | UDP 32471 | `/etc/wireguard/wg-sghk.conf` + `.key`/`.pub` | 必须 |
| 5 | **pm2 应用 `magnet`** | `pm2-root.service`（fnm node v24.20.0） | udp 34631、tcp 34631、udp 58241 | `/root/magnet/`（`magnet.sh`、`magnet-harvester`、`resource_names.txt` 28M） | 必须（业务） |
| 6 | pm2-logrotate | pm2 module 3.0.0 | - | `/root/.pm2` | 顺带 |
| 7 | **sshd** | systemd `ssh.service` | tcp **2323** | `/etc/ssh/sshd_config(.d)` | 已在 alhk 重建（9844） |
| 8 | python http.server | 裸进程 pid 46679，PPID=1 | tcp 8080 | cwd=/tmp（`big50.bin`、`t30.bin`） | **不迁**（临时文件分发，建议直接 kill） |
| 9 | lxd（snap） | snap 5.0.10 | - | - | **不迁**（无任何容器） |
| 10 | usque | `/root/app/usque`，**当前未运行** | -（v2ray `warp-out` 指向 socks 127.0.0.1:1080，无监听） | `/root/app/` | 待定（WARP 客户端，需确认是否还要） |
| 11 | ufw | 已安装但 **inactive** | - | - | 不迁，alhk 后续独立加固 |

其它：无 docker、无 nginx、无 snap 业务、root crontab 为空、`/etc/cron.d` 仅 `e2scrub_all`、无额外登录用户（仅 `nobody` 服务账号）。

## 二、Caddy（重点）

- 版本 `v2.11.4`，**自编译**（构建机为 macOS homebrew go1.23，gopath `/opt/homebrew/opt/go@1.23/gopath`）。
- 嵌入模块：
  - `http.handlers.waf` ← `github.com/fabriziosalmi/caddy-waf@v0.4.14`
  - `dns.providers.cloudflare`
- 二进制 76M（`/usr/local/sbin/caddy`），**迁移必须用相同插件集重新构建**，否则 `waf` 指令导致启动失败。

站点与上游：

| 站点 | 上游 | TLS | WAF | 日志 |
|---|---|---|---|---|
| `m14.panso.me`、`m14.xwd.pw` | `127.0.0.1:3344`（仅 `/tim` WebSocket） | 自有证书（TLS1.2/1.3，手工 cipher 列表） | 否 | `/var/log/caddy/caddy.log` |
| `jujuso.com`、`v4.jujuso.com`、`www.jujuso.co` | `139.155.21.35:3007`（公网直连，非本机） | 自动 ACME | 否 | 默认 |
| `lzpanx.com`、`www.lzpanx.com`、`panso.me`（**:80**） | `10.77.42.2:3006`（经 wg-hksh） | 无（源站 80，前面 Cloudflare） | 是 | `/var/log/caddy/lzpanx.log` |
| `api.hunhepan.com`、`www.hunhepan.com`、`hunhepan.com`（**:80**） | `10.77.42.2:3001`（经 wg-hksh） | 无（同上） | 是 | `/var/log/caddy/hunhepan.log` |

WAF 配套文件（`/etc/caddy/waf/`）：`rules.json`(15K)、`legacy-rules.json`(12K)、`ip_blacklist.txt`(4.5K)、`ip_whitelist.txt`(27B)。
WAF 仪表盘 `/waf`、`/waf/*`、`/waf_metrics` 仅允许 `127.0.0.1`/`::1` 访问（`waf-dashboard-local` 片段），线上需 SSH 隧道访问。

证书：`/var/lib/caddy/.local/share/caddy/`（200K），已有 LE 正式 + staging 两套 ACME 账号；
现有站点证书：`jujuso.com`、`v4.jujuso.com`、`m14.panso.me`、`m14.xwd.pw`。
注意 `m14.xwd.pw` 当前 DNS 指向 `162.4.84.247`（parklogic parking），**与该站点无关的旧记录**，续期会失败，迁移时应确认是否仍需要该域名。

日志：`/var/log/caddy/` 共 **447M**（caddy.log 78K 行、lzpanx.log 23K 行、hunhepan.log 11K 行，其余为 waf.json 等），迁移时不搬历史日志。

## 三、v2ray

- 入口：`vmess` + `ws`，监听 `127.0.0.1:3344`，由 Caddy 的 `m14.panso.me/tim` WebSocket 反代暴露；未开 sniffing/dns 段。
- 出站：
  - `proxy`：vmess → `m15.panso.me:443`（**另一台前置/落地**，迁到 alhk 后仍指向它）
  - `warp-out`：socks → `127.0.0.1:1080`（对应 usque，**当前无进程监听，等于不可用**）
  - `direct`（freedom）、`block`（blackhole）
- 路由（3 条）：
  1. `geoip:private` → block
  2. 54 个域名（x.ai / grok.com / OpenAI / Copilot / Google / YouTube 等）→ `proxy`
  3. 其余 → `direct`
- 迁移要点：`config.json` 里有 UUID（客户端 id），属凭据，**只能整文件搬运，不得贴到文档/聊天**。

## 四、WireGuard

| 接口 | 本端地址 | 监听 | Peer 公钥（公钥可公开） | Peer 来源 | AllowedIPs | 用途 |
|---|---|---|---|---|---|---|
| `wg-hksh` | 10.77.42.1/32 | UDP 32472 | `tKV3QVy...aiEI=` | `110.40.167.56:42733` | 10.77.42.2/32 | lzpanx/hunhepan 应用后端（:3006/:3001） |
| `wg-sghk` | 10.77.41.1/32 | UDP 32471 | `m2OEs+Q...e7hI=` | 43.160.224.101（txsp2 SG） | 10.77.41.2/32 | txsp2 ↔ hksh 互联 |

- 私钥在 `/etc/wireguard/wg-*.key`（0600），配置用 `PostUp = wg set %i private-key ...` 加载 —— **配置里不含私钥**，搬迁时 key 文件与 conf 一起走。
- 转发策略（iptables，由 wg-quick PostUp 下发）：
  - `-i wg-hksh -j DROP`、`-i wg-sghk -j DROP`（默认全拒）
  - 仅放行 `10.77.41.2 → 10.77.42.2` 与反向（两条 ACCEPT）
  - 无 NAT、无上网转发
- 现状流量：wg-hksh 5.94 GiB 收 / 4.19 GiB 发；wg-sghk 2.19 GiB 收 / 2.48 GiB 发。

## 五、pm2 应用 magnet

- 服务：`pm2-root.service` → `pm2 resurrect`，`PM2_HOME=/root/.pm2`，node 走 fnm
  （`/root/.local/share/fnm/node-versions/v24.20.0/installation`，非系统 node，**PATH 里没有**）。
- 应用：`magnet`（id 1，fork 模式，interpreter bash）→ `/root/magnet/magnet.sh` →
  `./magnet-harvester --api-url https://hunhepan.com/open/magnet_link/batch_create --token <位于脚本内> --batch-size 10`
- 监听：tcp/udp 34631、udp 58241。已重启 19 次，当前 online 18 分钟。
- 目录：`/root/magnet/` 86M（`magnet-harvester` 20M + 两个 `.bak-*` 各 20M + `resource_names.txt` 28M）。
- **凭据**：API token 硬编码在 `magnet.sh` 里，迁移时整目录搬（`scp`/`tar` 走 SSH 通道），
  文档与聊天只记"在 magnet.sh 中"，不要复制值。建议迁移后改为环境变量 / 0600 的 env 文件。

## 六、DNS 现状（迁移必须同步改）

| 域名 | 当前解析 | 备注 |
|---|---|---|
| `m14.panso.me` | 43.161.227.45 | Cloudflare DNS-only，直接指源站 |
| `jujuso.com` / `v4.jujuso.com` | 43.161.227.45 | DNS-only，直接指源站 |
| `panso.me` / `lzpanx.com` / `www.lzpanx.com` | 104.21.x / 172.67.x | Cloudflare **橙色云代理**，源站 80 |
| `hunhepan.com` / `www.hunhepan.com` / `api.hunhepan.com` | 104.21.x / 172.67.x | 同上 |
| `www.jujuso.co` | - | Caddy 里有站点但未见 A 记录，待确认 |
| `m14.xwd.pw` | 162.4.84.247 | parklogic 停放，疑似废弃 |

Zone 均在 Cloudflare（`tony/lana.ns.cloudflare.com`），可用 `cloudctl` skill 改记录。

## 七、迁移前置条件

1. **Caddy 二进制重建**：caddy v2.11.4 + `fabriziosalmi/caddy-waf@v0.4.14` + `dns.providers.cloudflare`，用 xcaddy 构建后 `caddy list-modules` 与现网逐条比对。
2. **阿里云安全组放行**：tcp 80/443、udp 443（Caddy）、udp 32471/32472（WG）、tcp/udp 34631（magnet，如对外需要）、udp 58241。
3. **DNS 切换顺序**：先切 DNS-only 的记录做验证（`m14.panso.me`、`jujuso.com`），Cloudflare 代理的记录最后切，切前调低 TTL。
4. **证书**：直接搬 `/var/lib/caddy/.../caddy`（含 ACME 账号与私钥，`caddy:caddy` 0700）可免重签；
   Cloudflare 代理站点（`lzpanx`/`panso.me`/`hunhepan`）只在 80 端口服务、本身无证书。
5. **WG 密钥搬迁**：conf + key 一起复制后 `wg-quick@` 两接口启用；对端（110.40.167.56、43.160.224.101）无需改动，因为本端公钥不变。
6. **alhk 容量**：内存 1.8G（比 txhk 的 961M 宽裕），磁盘剩 ~35G，跑这套足够；建议加 1G swap 做保险。

## 八、建议迁移顺序（每步可回滚）

1. 建 Caddy 自编译二进制 + 装 v2ray，**不监听公网**，本地 `curl` 验证站点反代（用 `--resolve` 打本地 IP）。
2. 装 WG 两接口，验证 `10.77.42.2:3001/:3006` 通（先确认对端是否允许新 IP 建连）。
3. 装 fnm + node + pm2，搬 `/root/magnet`，先 `pm2 start` 手工跑一轮看日志，确认 API 调用正常再 `pm2 save`。
4. DNS-only 记录切到 47.242.228.248 → 观察 24h。
5. Cloudflare 代理记录切源站 IP → 观察。
6. 全部稳定后：txhk 上 `systemctl disable --now caddy v2ray`、`wg-quick@` 停用、pm2 删除应用、kill 8080 的 python http.server，保留 3~7 天再下线。
7. 回滚：DNS 改回 43.161.227.45 → 启动 txhk 服务（配置未动，随时可回）。

## 九、盘点发现的问题（迁移时顺带处理）

1. **txhk 的 sshd 允许密码登录且 `PermitRootLogin yes`**（端口 2323）；alhk 已是"仅公钥 + 9844"，迁移后应把 txhk 一并收紧或直接下线。
2. `magnet.sh` 明文硬编码 API token（文件权限 755），建议迁移后改 0600 + 环境变量。
3. 裸进程 `python3 -m http.server 8080`（cwd=/tmp，含 `big50.bin` 等测试文件）已存活 4 天 16 小时，
   把 `/tmp` 整个目录暴露在公网 8080，**建议立即 kill**。
4. WARP 链路是断的（`warp-out` → socks 127.0.0.1:1080，usque 未运行），v2ray 若命中相关路由会失败，需确认取舍。
5. `lxd` snap 装了但没有任何容器，白占空间，可直接 `snap remove lxd`。
6. `/var/log/caddy` 447M 且 caddy 服务 `ProtectSystem=full`；迁移后需保留同样的 logrotate 策略（Caddyfile 内 `roll_size 10M / roll_keep 10 / roll_keep_for 240h`）。
7. `/root/backup-wg-relay-20260926`、`/root/mig-hhp-lzpanx`（116M）、`/root/backups`（70M）、`/root/.config-backups` 是历史备份，**不迁**，迁移完成后人工确认删除。
