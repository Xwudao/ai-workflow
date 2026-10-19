# dev EC20 公网 IP 切换测试

## 2026-10-19：射频关闭/开启，3 次均成功换公网 IP

### APN 与制式澄清

`3gnet` 是本次使用的联通 APN 名称，并非 3G 制式开关。此前及本轮拨号后，ModemManager 均报告 `access-technologies=lte`，实际为 4G。为单独检验射频重注册的效果，本轮保持 APN `3gnet` 不变。

### 方法与结果

在用户提出手机飞行模式会换 IP 后，新开一轮 3 次射频测试。仍用 modem 0、wwan0、独立表 2020 和 pref 20200 的 oif 规则；固定同一公网检测站及服务地址，绑定 wwan0、禁用代理，保持 TLS 校验。未改有线默认出口、DNS 或持久化网络配置。

每轮流程：

```sh
sudo mmcli -m 0 --simple-disconnect
sudo mmcli -m 0 --disable
sudo mmcli -m 0 --set-power-state-low
# 确认 state=disabled、power-state=low，注册状态已清空。
sleep 5
sudo mmcli -m 0 --set-power-state-on
sudo mmcli -m 0 --enable
# 有界等待注册状态恢复 home/roaming，本轮实际均恢复 LTE/home。
sudo mmcli -m 0 --simple-connect="apn=3gnet,ip-type=ipv4"
# 选择已连接且 IPv4 参数有效的 bearer；只更新测试接口与独立路由表。
# 查询公网 IP，2 秒后再次查询确认。
```

上述是通过 ModemManager 协调的“飞行模式式”低功耗/恢复操作，不是模块硬重启；未直接发送 AT 指令，也未执行 `CFUN=1,1`。以管理接口报告的 disabled/low 状态作为射频关闭的验证依据，未额外测量物理射频。

初始模块地址 `10.97.214.46`，初始公网 IP 连续两次为 `116.169.10.233`。

| 轮次 | 重注册后模块 IPv4 | 重注册后公网 IPv4 | 相比上一轮换 IP | 断开至首次公网响应 |
|---|---|---|---|---|
| 1 | 10.115.113.104 | 116.169.0.72 | 是 | 10.84 s |
| 2 | 10.192.42.65 | 116.169.80.40 | 是 | 10.70 s |
| 3 | 10.198.145.64 | 116.169.80.96 | 是 | 10.92 s |

每轮重复采样均与该轮首次 IP 相同。**本轮换 IP 为 3/3，平均恢复 10.82 秒（含主动等待 5 秒）**。这说明当前 SIM/网络环境下，射频低功耗后重新注册能换运营商 NAT 公网出口，而上一轮仅短时 PDP 重连未能换 IP；小样本不保证以后每次都成功。

### 运行路径、自动恢复与最终验证

- 变更前运行态快照：远端 root-only `/run/ec20-rf-test/` 下的 `routes.before`、`rules.before`、`wwan0.before.json`。未改现有配置文件或二进制，无对应文件备份需求。
- 本轮脚本 `/run/ec20-rf-test/test.py`；清理脚本 `/run/ec20-rf-test/cleanup.sh`；结果 `/run/ec20-rf-test/results.json`；日志 `sudo journalctl -u ec20-rf-test`。这些运行态文件随重启消失。
- 测试由独立 systemd 服务执行，运行上限 600 秒；拨号前设置 12 分钟 watchdog，脚本 `finally` 也执行清理。清理包含恢复 modem power on / enable，避免异常时停留在射频关闭状态，然后断开数据、删除测试 bearer、规则和路由、清空原本无地址的 wwan0 并置 DOWN。
- 手动回滚：`sudo /bin/sh /run/ec20-rf-test/cleanup.sh`。仅适用于本轮测试期间；不可在日后其他移动连接工作时直接复用。
- 最终已正常清理并停用 watchdog timer；modem 恢复 `on / registered / LTE / home`，无 bearer，wwan0 DOWN 且无 IPv4；表 2020 无路由，IPv4 rule 与测试前完全相同。
- 默认路由始终为 `192.168.1.1 / enp4s0 metric 100`；到 SSH 客户端 `192.168.1.9` 走 enp4s0；ModemManager、NetworkManager 均 active，SSH 正常。

## 2026-10-19：恢复测试，短时 PDP 重连未换公网 IP

### 结论

- 用户补充：此前异常是 EC20 被设为默认网络。本轮开始时确认默认路由已恢复为 `192.168.1.1 / enp4s0`；全程未让 EC20 接管默认出口，SSH 保持正常。
- EC20 可联网。模块 IPv4 为 `10.97.214.46/30`，网关 `10.97.214.45`；检测到公网出口 `116.169.10.233`（四川联通）。模块地址与公网地址不同，说明经过运营商 NAT。
- 5 次短时数据连接断开重连中未观察到公网 IP 改变；其中第 1 次采集脚本异常，恢复采样后地址仍相同，第 2～5 次完成完整计时及重复采样。
- **只能说明当前 SIM/网络下短时 PDP 重连不能有效换 IP**，不能据此断言射频重注册、长时间离线或其他方法也不能换 IP。本轮未执行 CFUN 或模块重启。

### 本轮拓扑与隔离方式

- SSH：`192.168.1.9 → 192.168.1.11:22`，到客户端走 `enp4s0`。
- ModemManager modem 0：联通 LTE、已注册、信号 84%；本轮控制口为 `/dev/cdc-wdm2`，数据口为 `wwan0`，AT 口为 ttyUSB7/ttyUSB8。端口编号已较上一轮变化，应每次动态确认。
- 使用 ModemManager `--simple-connect="apn=3gnet,ip-type=ipv4"`，不直接打开 AT 串口，不修改 NetworkManager 持久化配置。
- 手动应用已连接 bearer 的 IPv4 参数，地址添加时使用 `noprefixroute`；连接网段及默认路由仅放入独立表 `2020`。
- 临时规则：`ip -4 rule add pref 20200 oif wwan0 lookup 2020`。仅显式绑定 `wwan0` 的测试流量进入此表，主路由表默认路由保持不变。
- curl 使用 `-4 --noproxy '*' --interface wwan0`；最终固定 `myip.ipip.net:443` 到 `103.41.2.6`（`--resolve`），避免域名解析变化影响比较。TLS 校验保持开启。
- 路由验证：`ip -4 route get 1.1.1.1 oif wwan0` 走表 2020 / wwan0；不带 `oif` 则走 enp4s0。
- `wwan0` 累计 RX 69,520 字节、TX 19,931 字节；结合显式接口绑定、独立路由与公网响应验证实际移动出口。
- `rp_filter` 的 all / wwan0 均为 2，未修改。未修改 DNS、主默认路由或其他网卡。

### 测试记录

基准公网 IP 连续两次均为 `116.169.10.233`。重连流程为：

```sh
sudo mmcli -m 0 --simple-disconnect
sleep 5
sudo mmcli -m 0 --simple-connect="apn=3gnet,ip-type=ipv4"
# 动态选择 connected=yes 且 IPv4 参数有效的 bearer，再更新 wwan0 与表 2020。
# 绑定 wwan0 读取公网 IP，间隔 2 秒重复采样。
```

| 轮次 | 模块 IPv4 | 公网 IPv4（含重复采样） | 换 IP | 断开至首次公网响应 |
|---|---|---|---|---|
| 1 | 恢复后为 10.97.214.46 | 恢复后均为 116.169.10.233 | 未观察到 | 脚本异常，未取得有效计时 |
| 2 | 10.97.214.46 | 116.169.10.233 | 否 | 5.87 s |
| 3 | 10.97.214.46 | 116.169.10.233 | 否 | 5.94 s |
| 4 | 10.97.214.46 | 116.169.10.233 | 否 | 5.89 s |
| 5 | 10.97.214.46 | 116.169.10.233 | 否 | 5.91 s |

第 2～5 次平均 5.90 秒（包含主动等待的 5 秒），换 IP 为 0/4；第 1 次只作为异常及恢复观察记录，不纳入完整样本成功率。

### 异常与修正

- Cloudflare `1.1.1.1:443` 超时，api.ipify.org 连接失败，4.ipw.cn 解析失败；这些探测失败不代表 EC20 无法访问公网。国内检测站成功后统一固定该站进行比较。
- 第 1 次重连后脚本取了 bearer 列表中的首项，遇到未连接/无 IPv4 参数的旧 bearer（地址为 `--`），触发自动清理。随后修正为选择 `connected=yes` 且地址有效的 bearer，恢复拨号与采样后再执行余下 4 次。后续脚本还应对 bearer 参数短暂未就绪增加有界等待。
- `/run` 挂载为 `noexec`，首次注册清理定时器失败，且因命令保护尚未拨号；改为 `/bin/sh /run/ec20-ip-test/cleanup.sh` 后成功注册，再开始测试。

### 备份、关键路径、清理与回滚

- 未修改现有配置文件或二进制，故无需备份配置/二进制。变更前运行态快照存于远端 root-only 目录 `/run/ec20-ip-test/`：`routes.before`、`rules.before`、`wwan0.before.json`。
- 远端测试脚本：`/run/ec20-ip-test/test.py`；清理脚本：`/run/ec20-ip-test/cleanup.sh`；结果：`/run/ec20-ip-test/results.json`（完整第 2～5 轮）；创建的 bearer 路径记录于 `bearers.created`。这些均为临时文件，重启即失效。
- 使用 systemd 独立服务执行，避免 SSH 断开中断清理；Python `finally` 清理，并在拨号前另注册 15 分钟 watchdog。最终脚本正常完成清理后已停用 watchdog timer。
- 清理动作：断开测试数据连接；删除 pref 20200 的测试规则；清空测试专用表 2020；清除原本为空的 wwan0 IPv4 并置 DOWN；删除本轮创建的 bearer。
- 手动回滚（本轮已经完成）：`sudo /bin/sh /run/ec20-ip-test/cleanup.sh`。该脚本按本轮初始状态设计，仅在测试期间使用，不应在将来其他移动连接运行时执行。
- 最终验证：wwan0 DOWN、无 IPv4；modem 为 registered、bearers 为空；IPv4 rule 只剩 local/main/default；默认路由仍为 `192.168.1.1 / enp4s0 metric 100`；到 SSH 客户端走有线；ModemManager 与 NetworkManager 均 active。

后续若继续测试换 IP，应另开一轮评估受控射频关闭/开启（优先通过 ModemManager 协调，避免串口并发）、延长离线间隔，仍保持独立路由与自动清理；不要直接执行 `CFUN=1,1`。

## 2026-10-19：环境检测，因 SSH 超时中止

### 已确认的拓扑与状态

- 主机：SSH 别名 `dev`，主机名 `tim-ubuntu`。
- SSH：客户端 `192.168.1.9` → 服务端 `192.168.1.11:22`，到客户端的路由为 `enp4s0`，不依赖 EC20。
- 原有 IPv4 默认路由均经 `192.168.1.1` / `enp4s0`（其中一条 metric 100）。
- EC20：USB `2c7c:0125`；lsusb 数据库名称为 EC25，但 ATI 返回 Quectel EC20F，固件 `EC20CEHDLGR08A03M1G`。
- 驱动：串口 `option`，数据 `qmi_wwan`；控制接口 `/dev/cdc-wdm0`；网卡 `wwan0`。当前为 QMI，不是 ECM/MBIM。
- ModemManager：modem 0，已注册中国联通 LTE，信号 83%（早先读取为 89%）。
- AT 端口：`/dev/ttyUSB2`、`/dev/ttyUSB3`；GPS 为 ttyUSB1。
- 数据接口：`wwan0` 为 DOWN，无 IPv4 地址、无相关路由；尚无可记录的移动公网 IP 基准。
- ModemManager 与 NetworkManager 均 active；NM 显示 cdc-wdm0 disconnected。
- 当前用户不在 dialout 组，但 `sudo -n` 可用；已安装 mmcli、nmcli、qmicli、python3、curl。
- 主机另有 Huawei ME906s USB 模块，本次未操作。

### 已执行与异常

1. 完成 USB、内核相关日志、接口地址、路由规则、ModemManager 状态等只读检查。
2. fuser 显示 AT 端口已有进程打开。通过 sudo 临时打开 ttyUSB2，发送 `AT` 和 `ATI` 均返回 OK。
3. 随后的非阻塞串口读取遇到 EAGAIN，脚本退出，并在 finally 恢复该串口原始 termios 设置。未获得 CPIN、CGATT 等完整结果；AT 端口与管理进程并发访问需要在后续测试中协调。
4. 后续尝试读取 ttyUSB3 状态时，SSH 在连接阶段超时，命令未在远端执行；再次独立连接仍超时。
5. 不能据此认定 SSH 超时由 EC20 引起。未发送任何改变模块状态的 AT 指令。

### 变更、备份与回滚

- 未修改配置文件、二进制、主机路由、接口地址、持久化网络配置或模块射频状态。
- 未重启主机、模块或服务，未建立数据连接。
- 无持久化变更，无配置/二进制备份需求，无需回滚。

### 测试结果

| 阶段 | 结果 |
|---|---|
| 硬件 / QMI 识别 | 通过 |
| AT / ATI | 通过 |
| CPIN / CGATT 等完整检查 | 未完成 |
| EC20 公网 IP 基准 | 未取得，接口未连接 |
| IP 切换测试（最多 5 次） | 未执行 |

尚不能判断能否换公网 IP、最佳方式、成功率或平均恢复耗时，也不能判断运营商地址分配、CGNAT 或 PDP 保留是否影响换 IP。

### 恢复连接后继续的方法与安全边界

1. 重新确认 SSH 的有线路径与默认路由，并快照受影响的运行状态。
2. 协调 ModemManager 的端口所有权，避免两个进程同时读写串口；不为测试打开全局敏感日志。
3. 补做 `AT+CPIN?`、`AT+CGATT?`、注册状态、PDP 上下文等只读查询；不要输出 SIM/设备唯一标识或凭据。
4. 采用仅运行时的数据连接与独立策略路由/测试目标路由，保留原默认路由，不创建持久化网络配置。所有临时修改均须有自动清理。
5. curl 显式绑定 wwan0、禁用代理，通过路由与接口流量计数验证实际出口，再记录公网 IP 基准。
6. 先验证适合 QMI 的 PDP 断开重连方法，再视结果评估 CFUN=0/1，总计最多 5 次；每次记录指令、前后公网 IP、耗时与异常。
7. 不直接执行 CFUN=1,1；如确需模块重启，先评估并说明风险。
8. 测试结束后恢复初始状态（wwan0 未拨号），验证默认路由、SSH 与管理服务状态。
