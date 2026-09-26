# SG→HK→SH WireGuard 中转部署与分批迁移（2026-09-26）

## 拓扑及路由

- `txsp2`（SG）：`wg-sghk` = `10.77.41.2/32`；与 `txhk` 公网 UDP **32471** 建立隧道。仅为 `10.77.41.1/32`、`10.77.42.2/32` 添加 WG 路由。
- `txhk`（HK）：`wg-sghk` = `10.77.41.1/32`（UDP **32471**），`wg-hksh` = `10.77.42.1/32`（UDP **32472**）。打开 `net.ipv4.ip_forward=1`，FORWARD 规则只允许 `10.77.41.2 → 10.77.42.2` 从前一条 WG 接口转至后一条 WG 接口及反向回程；从两条 WG 接口进入的其他转发包丢弃。规则写入两份 HK WG 配置的 PostUp/PostDown，当前也已应用；云安全组香港侧放行相应 UDP 入站。
- `gate`（SH）：`wg-hksh` = `10.77.42.2/32`；连接香港公网 UDP **32472**。仅为 `10.77.42.1/32`、`10.77.41.2/32` 添加 WG 路由。
- 三台主机的默认路由及公网 SSH 路由均未改变；到 gate 公网 `110.40.167.56` 的 SG 路由仍经公网。WireGuard 密钥只存各主机的 `/etc/wireguard/*.key`（权限受限），**不得读取或在文档、日志中记录密钥内容**；WG 配置的 PostUp 使用密钥文件路径，由 `wg set ... private-key <路径>` 自行读取。HK 的转发开关持久化于 `/etc/sysctl.d/97-wg-hk-relay.conf`。

## 验证及迁移结果

| 测试 | RTT / 丢包 | 说明 |
|---|---|---|
| SG→HK WG | 38.9 ms / 0%（20 ping） | 路径正常 |
| HK→SH WG | 31.6 ms / 0%（20 ping） | 路径正常 |
| SG→SH WG 经香港 | **70.7 ms / 0%**（100 ping） | MTR 30 轮显示 `10.77.41.1 → 10.77.42.2`，两跳均 0% 丢包；转发规则生效后 20 ping 仍 0% 丢包 |
| SG→SH 公网直连 | **106.4 ms / 18%**（同期 100 ping） | 本次短时采样，较此前 20–35% 的 ICMP 丢包有所变化 |

SG 对 gate `3001–3009` 公网地址和 WG 地址逐个进行 TCP 建连测试，每个端口、每个地址各 5 次，本轮全部连通；但 TCP 建连成功不等于应用功能正常。目标地址经香港隧道的 RTT 约减少 35–36 ms（约 34%），本次 100 ping 无丢包。需要长时间、不同时间段及真实业务请求验证生产稳定性，不能仅用短时 ICMP 数据推断 UDP 实际丢包率。

在 `txsp2` 检索 `/etc/caddy`、`/etc/systemd/system`、`/root/app`、`/opt`、`/srv`、`/home`，排除密钥、环境变量及二进制等敏感文件后，活动配置中只有 `/etc/caddy/Caddyfile` 使用 `110.40.167.56:300X`。迁移前 Caddy 有对 3001/3006/3007 的公网 TCP 连接；对应配置另有 3009。其他 3002–3005、3008 在 gate 上监听，但未发现 txsp2 的活动目标配置。`/etc/caddy/Caddyfile` 中 3006 另有一条注释示例，未修改。随后按用户明确要求，将 3001 也直接迁往 WG，不以应用返回码为迁移门槛。

| 服务（txsp2 Caddy） | 原目标 | 当前目标 | 验证 |
|---|---|---|---|
| `lzpanx.com` | `110.40.167.56:3006` | **`10.77.42.2:3006`** | 迁移后本地 Host 入口 5/5 HTTP 200，观察到 WG 目标新建连接 |
| `qkpanso.com` | `110.40.167.56:3007` | **`10.77.42.2:3007`** | 迁移后本地 Host 入口 5/5 HTTP 200，观察到 WG 目标新建连接 |
| `api.hunhepan.com` | `110.40.167.56:3001` | **`10.77.42.2:3001`** | 用户明确要求直接迁移；Caddy 校验及 reload 成功，已观察到 WG 目标连接；入口根路径依旧 HTTP 500（迁移前同样为 500），应用功能未确认 |
| `reman.xwd.pw` | `110.40.167.56:3009` | **维持公网** | 迁移前根路径公网/WG 均为 HTTP 502，需先排查原有错误 |

目前没有关闭 gate 的任何 300X 公网端口。**尚不可关闭**：3009 仍通过公网访问；即使未来全部迁完，也应先确认其他来源、长期稳定性、应急回滚和云安全组规则，再按需限制公网访问。

## 变更文件、备份与回滚

新增：三台机器 `/etc/wireguard/` 中的相应 `wg-sghk.conf` / `wg-hksh.conf` 及密钥/公钥文件；香港 `/etc/sysctl.d/97-wg-hk-relay.conf`；安装 `wireguard-tools` 并启用对应 `wg-quick@...` 服务。唯一修改的既有业务文件：**txsp2 `/etc/caddy/Caddyfile`**，通过临时文件验证后原子切换，`caddy reload` 生效；未更换 Caddy 二进制，未重启 Caddy。三台机器的 WG 配置在新建前不存在；香港 WG 配置加转发规则前已备份。

备份位置（文件内容可能包含业务配置，不在文档中展开）：
- txsp2：`/root/backup-wg-relay-20260926/Caddyfile.pre-wg`、`Caddyfile.before-3006`、`Caddyfile.before-3007`、`Caddyfile.before-3001`、`caddy.pre-wg`（Caddy 二进制）。
- txhk：`/root/backup-wg-relay-20260926/wg-sghk.conf.before-forward-filter`、`wg-hksh.conf.before-forward-filter`、`iptables.before-forward-filter.rules`。

单服务回滚：从相应的 `Caddyfile.before-300X` 取出**该服务**的原目标，将当前目标 `10.77.42.2:300X` 改回 `110.40.167.56:300X`；先 `caddy validate --config /etc/caddy/Caddyfile` 再 `caddy reload --config /etc/caddy/Caddyfile`，并从本地 Host 入口测试。`Caddyfile.before-3001` 保留了已迁移的 3006/3007，若只回滚 3001 可整体恢复该文件；若要全部回滚，可整体恢复 `Caddyfile.pre-wg`。整体恢复前先备份当前文件，检查期间其他运维是否做了新修改，避免覆盖。

撤销隧道必须**先回滚已迁移的 Caddy 上游**。再分别在 txsp2、gate、txhk 执行相应 `systemctl disable --now wg-quick@wg-sghk` / `wg-quick@wg-hksh`（HK 两个接口）；HK 的 PostDown 会删除专用 FORWARD 规则，随后删除本次新增的转发 sysctl 文件并设 `net.ipv4.ip_forward=0`（仅在确认没有其他新业务依赖转发后）。保留受限密钥文件以备审计或按安全策略清理，切勿输出密钥内容。云防火墙的香港 UDP 32471/32472 可在确认不再使用后撤销。

## 遗留风险

- 3001 已按用户要求迁移，但入口仍 HTTP 500（迁移前已是 500），应用功能未获验证；需排查。3009 未迁移，原先即有 HTTP 502；需排查后再决定是否切换。
- WG UDP 使用香港云防火墙入站放行；任一香港节点或两段链路故障均会影响已迁移的 3001/3006/3007，届时按以上步骤回退公网地址。
- 本轮是短时间采样，未做长时间压测、重启演练或跨时段监控；公网直连保留作应急回退。
