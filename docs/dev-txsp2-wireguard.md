# dev ↔ txsp2 WireGuard（2026-10-20）

## 架构与结果

- dev（Ubuntu 24.04）：新增 wireguard-tools，接口 `wg-txsp2`，地址 `10.77.43.2/32`。
- txsp2（Ubuntu 22.04，公网 `43.160.224.101`）：新增接口 `wg-dev`，地址 `10.77.43.1/32`，监听 **UDP 45775**；用户已确认放行云安全组入站。
- dev 主动连接 txsp2，PersistentKeepalive=25，双方 MTU=1380，AllowedIPs 仅对端隧道地址 /32。
- 两端 `wg-quick@<接口>` 服务 active、enabled。已成功握手；双向各 5 次 ping 均 0% 丢包，平均 RTT 约 260ms；仅为短时验证，未做重启及长期稳定性测试。
- txsp2 原 `wg-sghk` 保持运行且有近期握手；未修改其配置。默认路由、EC20 策略路由、业务配置、防火墙、转发和 NAT 均未改动。
- dev 原有 UFW 策略继续生效：隧道 ICMP 可达不代表 TCP 服务已放行，后续按明确需求逐项开放，不全量信任 WG 来源。没有配置容器或局域网转发。

## 文件与备份

两端各自 `/etc/wireguard/<接口>.conf`（0600）、`<接口>.key`（0600）、`<接口>.pub`。私钥由程序生成到文件，配置通过 PostUp 的 `wg set %i private-key <路径>` 加载；禁止读取、输出或提交私钥。临时 WG 接口加载配置验证成功后才安装正式配置。

两端变更前备份目录均为 `/var/backups/wg-dev-txsp2/20261020-1920/`（root-only）：
- dev：原 UFW 目录、路由、策略规则、iptables 和安装前包状态；变更前无 `/etc/wireguard`。未改防火墙。
- txsp2：原 wireguard 目录副本、wg/wg-quick 二进制副本、路由、策略规则、iptables。未替换这些原有二进制。

执行期间发生工具超时：dev 的 apt update 首次中断，随后利用现有包索引成功安装；首次并行配置仅 dev 完成。重新检查实际状态后单独完成 txsp2 配置，最终双向验证通过。临时验证接口及暂存目录由退出清理逻辑删除。

## 验证

```sh
ssh dev 'sudo wg show wg-txsp2; systemctl is-active wg-quick@wg-txsp2; ping -c 5 -W 2 10.77.43.1'
ssh txsp2 'wg show wg-dev; systemctl is-active wg-quick@wg-dev; ping -c 5 -W 2 10.77.43.2'
```

不要使用 `wg showconf` 或展开私钥文件进行检查。

## 回滚

```sh
ssh dev 'sudo systemctl disable --now wg-quick@wg-txsp2'
ssh txsp2 'systemctl disable --now wg-quick@wg-dev'
```

只停本次新增接口，不动 `wg-sghk`，不恢复全局路由/iptables 快照。确认没有后续依赖后可撤销 txsp2 云安全组 UDP 45775 规则；配置和密钥可先保持 root-only 留存。无需卸载工具，避免影响其他 WG 使用。

本次到隧道配置和验证为止，未进行后续业务调整。
