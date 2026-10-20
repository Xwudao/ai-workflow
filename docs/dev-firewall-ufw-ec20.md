# dev：EC20 接入后的主机与 Docker 防火墙

## 架构与策略

2026-10-19 在 `ssh dev`（tim-ubuntu，Ubuntu 24.04）部署。用户所说 WAF 按主机防火墙 UFW 处理；本次不是 HTTP 应用层 WAF。

- 有线可信入口：`enp4s0`，`192.168.1.11/24`，网关 `192.168.1.1`。SSH 当前为 TCP 22。
- `wwan0` 为 EC20 数据口，部署时 DOWN，未拨号或修改移动网络/策略路由。
- 有线接口已有公网 IPv6；原 UFW inactive，Docker 发布端口监听 IPv4/IPv6 所有地址。
- Docker 对外发布：3306、5432、5601、6379、9200；宿主机另有 SSH、3389、9003、RustDesk 等监听。

两层防护：

1. **UFW INPUT**：默认拒绝入站、允许出站、拒绝普通转发，IPv6 启用。仅允许 `enp4s0` 来源 `192.168.1.0/24` 的现有服务访问；历史 `192.168.31.0/24` 放行已于 2026-10-19 后续收紧时删除。允许 `docker0`/`br+` 来源 `172.16.0.0/12` 访问宿主机服务（包括 `172.17.0.1:7890` 代理）。
2. **独立 nftables inet 转发前置过滤**：`dev_guard.forward_guard`，priority -10，在 Docker filter ACCEPT 前执行。放行已建立/关联连接、lo、docker0、br-* 的转发，以及可信有线来源 `192.168.1.0/24`；其余转发丢弃，防止 Docker DNAT 端口绕过 UFW。IPv4/IPv6 通用，不依赖 wwan0 接口名，所以新增其他非可信网络也不自动放行。

UFW 保留标准 ICMP、IPv6 邻居发现、DHCP 与标准组播控制例外；不是屏蔽所有网络数据包。局域网仍被整体信任，受感染的局域网设备不在本次防护范围内。公网 IPv6 的新建服务连接不放行，局域网管理建议使用 IPv4。RustDesk 主动连接的中继可继续工作，非可信网络的入站直连不放行。

不修改 SSH、Docker daemon、容器配置、模块拨号、默认路由或任何凭据，不重启 Docker/主机。

## 持久化与关键路径

- `/etc/ufw/`、`/etc/default/ufw`：UFW 配置，服务 enabled。
- `/etc/dev-firewall/forward.nft`：独立 Docker 入站保护；仅原子替换自己的 `inet dev_guard` 表，不 flush 全局规则。
- `/etc/systemd/system/dev-firewall.service`：enabled，network-pre/Docker 之前加载；不依赖全局 nftables.service（该服务原本 disabled，保持不变）。
- `/etc/dev-firewall/backup-path`：当前回滚对应的备份目录。
- `/usr/local/sbin/dev-firewall-rollback`：root 所有的回滚脚本。
- `/home/tim/dev-firewall-rollback.sh`：HDMI 控制台可直接执行的入口，无网络依赖。

普通 UFW reload 不会删除独立 guard 表；Docker 正常维护自身表也不会删除它。禁止运行 `nft flush ruleset`；这会同时损坏 Docker/UFW 与本次防护。恢复 guard 可执行 `sudo systemctl reload dev-firewall.service`。

## 备份与回滚

最终部署前备份：`/var/backups/dev-firewall/20261019-184931/`（root-only）。包括原 UFW 配置、iptables/ip6tables/nft 规则快照、受 UFW 影响的 sysctl 原值、部署与验收脚本，以及已部署 guard/unit/rollback 副本。

第一轮备份 `/var/backups/dev-firewall/20261019-183514/` 保留。第一轮因工具批量验证超时，10 分钟定时器于 18:45:32 实际自动回滚成功，SSH/容器未中断。随后从原状态重新部署并完成逐项验收。第二轮临时自动回滚已取消，最终无遗留定时器。

**如有问题，在 HDMI 显示器的终端登录 tim，执行：**

```sh
bash /home/tim/dev-firewall-rollback.sh
```

或：

```sh
sudo /usr/local/sbin/dev-firewall-rollback
```

可能提示本机 sudo 密码；脚本本身不存储密码。操作会：取消自动回滚 timer、禁用 guard 开机加载并删除自己的表、关闭 UFW、恢复原 UFW 配置和记录的 sysctl。可重复执行。

**回滚会恢复此前无防火墙的状态**，公网 IPv6/移动网络存在暴露风险，建议先断开移动网络。脚本不恢复整份 iptables 快照，因为容器地址/规则可能已变化；不 flush Docker 规则，以保留当前容器网络。不删除备份和脚本，也不修改网卡/路由。

## 验证结果与后续检查

已完成：

- 禁用 SSH 复用后新建 SSH 连接成功。
- 从 `192.168.1.9` 连接 192.168.1.11 的 TCP 22、3389、9003、21118、3306、5432、5601、6379、9200 均成功。
- 用临时 network namespace/veth 模拟非可信入口，对上述端口的 IPv4/IPv6 连接全部阻断。IPv4 Docker 转发丢弃计数增加，证明不是仅靠 UFW INPUT；测试网络已自动清理。
- 全部容器仍运行，pg18/mysql57 healthy；pg_isready 正常，容器 DNS 正常。
- 在 pg18 的 network namespace 中访问两个已解析 example.com IPv4 地址的 TCP 443 和宿主机代理 172.17.0.1:7890 成功。1.1.1.1:443 在宿主机与容器均超时，因此未将其当作健康检测依据。
- 宿主机直连 HTTPS 返回 200；UFW 与 guard 服务 enabled，guard active。
- 回滚脚本通过 bash 语法检查；第一轮回滚实际执行成功。第二轮最终未执行回滚，防护保持启用。

**未执行**重启主机、Docker 重启和真实 EC20 拨号测试，避免打断业务。后续首次拨号后应再确认移动接口新入站阻断、绑定 wwan0 的业务出站正常，并在计划维护窗口验证开机持久化。

```sh
sudo ufw status verbose
systemctl is-enabled ufw dev-firewall.service
systemctl is-active dev-firewall.service
sudo nft list table inet dev_guard
sudo systemctl list-timers --all 'dev-firewall-autorevert*'
```

增加新可信网段或容器采用非 `docker0`/`br-*` 的特殊网络时，应同时评估 INPUT 和转发规则；变更前先备份并启用短时自动回滚，不全局放开移动接口。

## 2026-10-19：收紧为仅本机和主局域网

用户确认 Docker 服务仅供本机与 `192.168.1.0/24` 使用。保留现有 nftables guard，删除其 `192.168.31.0/24` 放行，并删除 UFW 对该网段 TCP 3306/6379/9200 的三条历史规则。容器之间及容器主动出站策略未变；保留 established/related，因此不会强制断开已有连接。不修改端口映射、不重启 Docker 或容器。

本次备份：`/var/backups/dev-firewall/lan-only-20261019-195456/`，含 `ufw/`、`forward.nft` 和 `ruleset.nft`，目录 root-only。先用 `nft -c` 校验临时规则，再安装并 reload `dev-firewall.service`。UFW 与 guard 均保持 enabled。

验证：
- 新建 SSH 连接成功；本机及局域网访问 3306、5431、5432、6379、9200、5601 全部成功。
- 临时 netns/veth 非可信入口访问上述 IPv4 端口全部阻断，guard drop 计数增加；通过测试链路 IPv6 地址访问上述端口也全部阻断（UFW INPUT，涵盖 docker-proxy）。测试网络已清理。
- 所有容器持续运行，两个 PG 与 MySQL healthy；未执行主机或 Docker 重启验证。

仅撤销本次网段收紧（不撤销原防火墙）的命令：

```sh
sudo cp -a /var/backups/dev-firewall/lan-only-20261019-195456/forward.nft /etc/dev-firewall/forward.nft
sudo systemctl reload dev-firewall.service
for port in 3306 6379 9200; do
  sudo ufw allow in on enp4s0 from 192.168.31.0/24 to any port "$port" proto tcp comment 'Legacy secondary LAN'
done
```

无需恢复全局 nft/iptables 快照。前述完整回滚脚本会关闭原防护，不用于仅撤销本次网段收紧。
