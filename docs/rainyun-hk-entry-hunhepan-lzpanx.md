# RainYun HK 临时入口：hunhepan / lzpanx 改灰云直连（2026-10-15）

## 背景与目标

新增一台香港服务器作为 `hunhepan.com` / `lzpanx.com` 的**临时公网入口**：

- SSH 加固：自定义端口 **4859**、仅公钥登录（`id_ed25519`）、禁止密码登录。
- 复用 **gate 的 Caddy 二进制**（带 `fabriziosalmi/caddy-waf`），在新机启动。
- 将相关域名解析到本机，**改为灰云（proxied=false）**，由 Caddy 自行申请 Let's Encrypt
  证书并 `:443` 对外；`:80` 直接反代（不做 HTTP→HTTPS 跳转）。
- 上游访问方式：**直连 gate 暴露的公网端口**（不接入 WireGuard）。

## 节点与角色

| 项 | 值 |
|---|---|
| 主机 | `154.37.222.86`（`RainYun-O26vWYCR`） |
| 归属 | Hong Kong / AS979 NetLab Global（RainYun 雨云） |
| 系统 | Ubuntu 24.04.1 LTS / x86_64 / 1 vCPU / 961 MiB / KVM（`ens18`） |
| 角色 | hunhepan / lzpanx 的**临时公网入口**（灰云直连） |
| SSH | 端口 **4859**，仅公钥，root `prohibit-password` |
| Caddy | `v2.11.4` + `caddy-waf v0.4.14`（与 gate 同款，sha256 `a027867c...`） |

## 变更后的拓扑

```text
公网用户 (灰云直连, 无 CF 代理)
        │  http://  :80  —— 直接反代
        │  https:// :443 —— Caddy 自动签发 LE 证书
        ▼
  154.37.222.86 (HK, 本机 Caddy + WAF)
        │  http://110.40.167.56:3006   (lzpanx 组)
        │  http://110.40.167.56:3001   (hunhepan 组)
        ▼
  gate(SH) Caddy  →  app3 业务进程
```

- **不走 WireGuard**：新机 HK → gate(SH) `110.40.167.56:3001/3006` 直连实测正常
  （健康时 ~30–45 ms、0% 丢包），与 txhk 走 `wg-hksh` 访问的 `10.77.42.2` 是同一台 gate 的同一端口，
  因此直接公网端口即可，省掉一条隧道。
- 与 `txhk` 无关系：txhk 仍是 m14/jujuso 等站点与 WG 中继节点，本次未改动。

## 具体改动

### 1. SSH 加固（客户端侧、分阶段验证）

Ubuntu 24.04 由 **`ssh.socket`（socket 激活）** 决定监听端口，`sshd_config` 里的 `Port` 在此模式下**不生效**；
且 `sshd_config.d/50-cloud-init.conf` 里的 `PasswordAuthentication yes` 因 `Include` 行在最前而**优先生效**。

- 先装公钥，在**当前 22 端口**验证密钥登录成功。
- 通过 `/etc/systemd/system/ssh.socket.d/10-port.conf` 增删端口：
  - 先 `ListenStream=22` + `ListenStream=4859`（并存），验证 4859 可达；
  - 再改为仅 `ListenStream=4859`。
- 关闭密码：编辑**生效**的 `/etc/ssh/sshd_config.d/50-cloud-init.conf` → `PasswordAuthentication no`；
  `/etc/ssh/sshd_config` → `PermitRootLogin prohibit-password`。
- `sshd -t` 校验 + `systemctl restart ssh.socket`。

> 注意：`sshd -T` 仍显示 `port 22`，这只是主配置默认值；实际监听由 socket drop-in 提供 4859。

备份（服务器）：`/root/ssh-hardening-20261015-231423`（`sshd_config.pre`、`sshd_config.d.pre`、`ssh.socket.pre`）。

### 2. 从 gate 复制 Caddy 与 WAF

- 二进制经本地 Mac 中转到新机：`ssh gate 'cat .../caddy' | ssh 新机 'cat > ...'`（约 6 分钟）。
  sha256 与 gate 一致：`a027867c3821d88ed8e5023ffa5804f13176a5ad672b31c1ac6cda69a972ae26`。
- `/etc/caddy/waf/*`（`rules.json`、`legacy-rules.json`、`ip_blacklist.txt`、`ip_whitelist.txt`）
  与 gate **逐字节一致**（md5 已校验）。
- 创建 `caddy` 系统用户/组、`/var/log/caddy`（含 `lzpanx.log`/`hunhepan.log`/`waf.json`，属主 `caddy:caddy 0640`）、
  安装 `caddy.service`。

配置文件：`/etc/caddy/Caddyfile`、`/etc/caddy/waf/`。

### 3. Caddyfile 要点

- 复用 gate/txhk 的 `(logger)` / `(waf)` / `(waf-dashboard-local)` 片段。
- 站点同时绑定 `:80` 与 `:443`，并设置 **`auto_https disable_redirects`**：
  - `:80` 直接反代（**不做 301/308 跳转**，见下文踩坑）；
  - `:443` 由 Caddy 自动签发 LE 证书。
- 上游：`reverse_proxy 110.40.167.56:3006`（lzpanx 组）/ `110.40.167.56:3001`（hunhepan 组），`header_up -Host`。
- WAF 面板 `/waf`、`/waf_metrics` 仅回环可访问，公网 404。

### 4. Cloudflare DNS（cloudctl）

6 条 A 记录由 `43.161.227.45`（txhk）改为 `154.37.222.86`。

> **2026-10-15 后续：已改回橙云（proxied=true）**。即 DNS 仍指向 `154.37.222.86`，但恢复由
> Cloudflare 代理（`--proxied`）。因此客户端不再直连本机，CF 回源到 `:80`。灰云阶段暴露的问题
> （见“踩坑 1”）在橙云下不适用；本机 Caddy 仍同时服务 `:80`/`:443`。`lzpanx.com` 经 CF 返回
> `301 → https://www.lzpanx.com/`、`http → https` 均为 **CF 层重定向规则**（`server: cloudflare`），非源站行为。

以下为最初的灰云配置（保留供参考）：

| zone | name |
|---|---|
| lzpanx.com | `lzpanx.com`、`www.lzpanx.com` |
| panso.me | `@` |
| hunhepan.com | `@`、`www.hunhepan.com`、`api.hunhepan.com` |

未改动：`so.lzpanx.com`、`docs.hunhepan.com`、`m14/m15.panso.me` 等。

## 验证结果

| 检查项 | 结果 |
|---|---|
| SSH 4859 密钥登录（本地/远端） | OK；22 端口已关闭；密码认证被拒（`Permission denied (publickey)`） |
| Caddy 监听 | `:80`、`:443`，`systemd` `enabled` + `active` |
| Let's Encrypt 证书 | 6 张（6 个域名）全部签发，`issuer=Let's Encrypt` |
| gate / txhk 端到端 | `https://lzpanx.com`、`www`、`panso.me` 均 **200**（0.1–0.5 s）；`http://` 亦 200 |
| WAF | 注入探针 `?q=<script>...` → **403**；面板公网 **404** |
| hunhepan | `GET /` 仍 **500**（既有问题）；搜索接口 `POST /open/search/disk` 返回应用自身过载（见下） |

## 本次踩到的坑（重要）

1. **HTTP→HTTPS 自动跳转把业务打挂并引发重定向风暴。**
   初始配置让 Caddy 对 `:80` 做 308 跳转到 `:443`。但 hunhepan 的真实客户端**就是用
   `http://` POST 业务接口**（抓包见 `POST /open/search/disk` + JSON 搜索体），308 打断了请求；
   叠加切换瞬间部分国内解析器（如 AliDNS `223.5.5.5`）仍缓存旧的 **CF 代理 IP**，
   形成 `CF → 源站:80 → 308 → 回 https → CF → ...` 的循环，短时间内把 1 核小机的上行打满：
   - 连接态：`TIME-WAIT` ~5000、`SYN-RECV` ~300、`RX` ~2.5k pps；
   - `gate`/`txhk` → 本机 ping 出现 **20–30% 丢包、RTT 300+ ms**（本机 NIC/softnet 无丢包）。
   **改为 `:80` 直接反代（`auto_https disable_redirects`）后立刻恢复**：
   `txhk→本机 0%/10 ms`、`gate→本机 0%/~45 ms`，`TIME-WAIT` 回落到 ~100。
2. **本地 macOS 的 `ping`/`nc`/`dig` 全部不可信**（透明代理 utun8/198.18.0.1 对任意端口假 ACK、
   伪造 ICMP、拦 UDP 53）。连通性判断一律用远端 vantage（gate/txhk）与服务器 `ss`。
3. **Ubuntu 24.04 的 `ssh.socket`**：改端口必须动 socket drop-in，改 `sshd_config` 的 `Port` 无效；
   `sshd_config.d/*.conf` 因 `Include` 靠前而优先于主文件（first-value-wins）。
4. **`caddy validate` 以 root 运行会创建 root 属主的日志文件**，导致 `User=caddy` 启动失败。
   本次改用 `install` 预建 `caddy:caddy` 日志文件 + `sudo -u caddy caddy validate` 规避。
   （同上，`/root/caddy-stage` 对 caddy 不可读，校验前用 `/tmp` 且 `chmod 644`。）

## 观测：hunhepan 应用过载（非本次引入）

入口切换后 `hunhepan` 的搜索接口大量返回
`{"code":0,"msg":"system overload, please try again later"}`（HTTP 429）。
**绕过本机、直连 gate `110.40.167.56:3001` 复用相同重查询，同样 100% 返回该过载信息**，
说明是 **go-hunhepan 应用自身**的限流/过载行为，与本次入口无关；`GET /` 的 500 亦为既有问题。

## 备份与回滚

| 位置 | 内容 |
|---|---|
| 本机 `/root/ssh-hardening-20261015-231423/` | SSH 加固前 `sshd_config` / `sshd_config.d` / `ssh.socket` |
| 本机 `/root/caddy-backup-20261015-152430/` | 首次部署前的 `/etc/caddy/Caddyfile` |
| 本机 `/root/caddy-backup-tls-20261015-153715/` | 改灰云/443 前的 `Caddyfile` |
| 本机 `/root/caddy-stage/` | 从 gate 复制的二进制与 WAF 规则 |

回滚步骤：

1. **DNS**：把上表 6 条记录改回
   `cloudctl dns ensure --zone <z> --type A --name <n> --content 43.161.227.45 --proxied --json`
   （txhk 上的站点块仍在，改回即恢复原链路）。
2. **Caddy 配置**：`install -m644 /root/caddy-backup-tls-*/Caddyfile.pre-tls /etc/caddy/Caddyfile && systemctl restart caddy`。
3. **SSH**：恢复 `/root/ssh-hardening-*/` 下文件后 `systemctl daemon-reload && systemctl restart ssh.socket`；
   注意重新开放 22 端口前确保密钥可用。

## 当前已知问题：本机 SSH 一度不可用（2026-10-15）

改回橙云后，观察到本机 **`ssh.socket` 停止监听**：`22`/`4859` 从 gate/txhk 探测均为 `Connection refused`，
同时 `:80`/`:443`（Caddy）与 ICMP 均正常，说明主机本身在线、仅 sshd/ssh.socket 未在监听。
本地直连偶现 `Connection closed by ... port 4859`（透明代理假象）。

- 恢复方式（需 RainYun 控制台/VNC）：登录后执行
  `systemctl status ssh.socket; systemctl restart ssh.socket; ss -tlnp | grep 4859`，
  并确认 `/etc/systemd/system/ssh.socket.d/10-port.conf` 仍在、`systemctl is-enabled ssh.socket`。
- 待查原因（尚未定位）：是否主机重启导致 socket 未起、systemd-oomd/资源压力、或切换到橙云后
  流量激增相关；下次能登录时应检查 `journalctl -u ssh.socket -b`、`journalctl -u systemd-oomd`、`uptime`。

## 遗留风险与建议

- **单点 + 线路依赖**：灰云后客户端**直连**本机，入口可用性直接受本机香港线路质量影响；
  本机为 1 vCPU / 1G 小机，不适合作为长期唯一入口。建议观察丢包/延迟。
- **切换期解析缓存**：国内部分递归解析器（AliDNS 等）刷新 CF→灰云切换较慢，期间会有
  少量流量仍经 CF 回源；已知会因 CF 与源站跳转策略产生额外流量，需避免 HTTP 侧再做 HTTPS 跳转。
- **双层 WAF**：请求现经「本机 WAF + gate WAF」两层；gate 的 IP 黑名单会检查所有 `X-Forwarded-For` 值，
  故**回环/私网 XFF 会被拦**（本地自测 403 属正常现象，公网客户端不受影响）。
- **证书续期**：LE 证书 90 天，Caddy 自动续期；需保证 `:80` 与公网可达（HTTP-01）。
- 未做长时间压测与跨时段监控；hunhepan 业务功能未验证（迁移前后均异常）。
