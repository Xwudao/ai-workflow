# app3：网络收敛与 UFW 配置记录

> 完成时间：2026-09-06

## 目标

仅允许 gate（`10.0.12.17`）访问 app3 的后端 TCP 服务；保留 SSH 管理入口，并将仅供本机程序使用的 sing-box 入站代理绑定到回环地址。

## 已执行的变更

### sing-box

`/etc/sing-box/config.json` 中的 `shadowsocks-in` 入站已调整：

```text
8080: ::  →  127.0.0.1
```

重启并验证 `sing-box.service` 为 `active`，`8080` 当前仅监听：

```text
127.0.0.1:8080
```

### UFW

UFW 已启用，策略为：

```text
默认：拒绝入站、允许出站
允许：任意来源 → TCP 4344（SSH）
允许：10.0.12.17（gate）→ 任意 TCP 端口
```

对应规则：

```bash
ufw allow 4344/tcp comment 'SSH management'
ufw allow proto tcp from 10.0.12.17 to any comment 'gate to app3 backends'
ufw --force enable
```

按**来源 gate 放行任意 TCP**，而不是按业务端口放行。因此以后新增 `gate → app3` 的 TCP 反代端口不需要再更新 UFW。

若未来有 UDP 后端，需另行显式放行，例如：

```bash
ufw allow proto udp from 10.0.12.17 to any
```

## 验证

- 使用新 SSH 连接验证 `app3:4344` 正常可达。
- 从 gate 验证以下 app3 后端端口均可连接：

  ```text
  2045 3765 4441 4678 4685 4686 4859
  5384 6655 8484 8788 8799 8899
  ```

- 从 gate 验证不能连接 `app3:8080`。

## 备份

变更前备份：

```text
/root/app3-firewall-singbox-backup-20260906-130300
```

其中包括：

- `/etc/sing-box/`
- `/etc/ufw/`
- `/etc/default/ufw`
- `/etc/ssh/sshd_config`

## 运维说明

- SSH 当前端口为 `4344/tcp`。修改 UFW 时必须先放行该端口，并新建 SSH 连接验证后再关闭旧会话。
- gate 是 app3 全部 TCP 后端的可信上游；若 gate 被攻破，其可访问 app3 的任意 TCP 监听服务。
- 若要撤销防火墙：

  ```bash
  ufw disable
  ```

- 若要恢复 sing-box 配置，使用上述备份内的 `sing-box/config.json`，执行 `sing-box check -C /etc/sing-box` 后重启 `sing-box.service`。
