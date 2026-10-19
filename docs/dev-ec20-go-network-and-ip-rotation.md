# Go 使用 EC20 发起网络请求与定期更换公网 IP

## 1. 目标与实测依据

目标：Go 请求只经 EC20 移动网络发送，定期通过射频关闭/开启更换公网 IP，同时保持主机有线默认出口与 SSH 不受影响。

实测记录：[dev EC20 公网 IP 切换测试](dev-ec20-ip-switch-test.md)。

- 模块使用 QMI，ModemManager 负责管理，数据接口为 `wwan0`。
- `3gnet` 是联通 APN 名称，不是 3G 制式开关；实测接入制式为 LTE（4G）。
- 仅短时断开/重连数据连接未观察到公网 IP 改变。
- ModemManager disable + power low，等待 5 秒，再 power on + enable + 注册 + 拨号：3 次均换 IP，平均恢复 10.82 秒（含等待的 5 秒）。小样本不保证以后每次成功。
- 模块获得运营商私网地址，公网出口经运营商 NAT；应通过外部检测站确认公网 IP，不能只比较模块地址。

本文是实现方案，不代表已部署常驻 Go 服务。此前测试已清理，开始开发/运行前需要重新拨号并建立测试路由。

## 2. 推荐架构与权限边界

```text
普通权限 Go 业务程序
        │ Unix Socket：状态查询、申请切换
        ▼
受限的 EC20 网络管理服务
        ├─ ModemManager D-Bus：发现模块、拨号、射频切换
        ├─ netlink：配置接口地址和独立策略路由
        ├─ 健康检查：移动出口、公网 IP、默认路由保护
        └─ 串行化切换、定时调度、失败恢复
```

第一版可由管理服务使用 `exec.CommandContext` 调用固定参数的 `mmcli`、`ip`；稳定后改用 D-Bus 与 netlink。禁止拼接 shell 命令或接收任意用户传入的命令参数。

- 管理服务需要控制 ModemManager 的授权，以及修改地址和路由的权限；具体取决于 D-Bus/Polkit 与服务部署方式。
- `SO_BINDTODEVICE` 的权限要求与内核有关，常见环境需要 `CAP_NET_RAW` 等权限。启动时必须检查绑定是否成功，失败即拒绝请求。
- 拆分管理服务不代表业务进程自动获得绑定接口的权限。若不希望业务进程持有此权限，可由受限网络代理负责绑定接口，或采用独立网络命名空间。后者需要额外设计 QMI 控制与接口管理，不能直接移动接口后假定 ModemManager 仍可正常工作。
- 不建议整个业务程序长期以 root 运行，也不要只为方便直接给可写的业务二进制添加 capabilities。
- 不直接打开正在由 ModemManager 使用的 AT 串口；不与管理进程并发读写串口。

## 3. 路由隔离与拨号

### 3.1 保留有线默认网络

dev 实测主默认路由：

```text
default via 192.168.1.1 dev enp4s0 metric 100
```

EC20 不应成为主路由表的默认出口。绑定 `wwan0` 的测试流量使用专用路由表 `2020`：

```sh
ip -4 rule add pref 20200 oif wwan0 lookup 2020
```

表号、规则优先级、网卡名均为本机示例；部署前检查未被其他配置占用。管理服务应持有单实例锁并检查现状，不可盲目重复添加规则或清空他人的路由表。

### 3.2 拨号并动态应用地址

```sh
mmcli -m 0 --simple-connect="apn=3gnet,ip-type=ipv4"
```

实现步骤：

1. 根据硬件、端口和管理状态发现目标 modem，不把 modem 0 写死到生产逻辑。
2. 选择 `connected=yes` 且 IPv4 参数有效的 bearer，不取列表首项。
3. 有界等待 bearer 的地址、前缀、网关就绪，验证格式和数据接口。
4. 启用数据接口，按 bearer 配置 IPv4 地址；添加时使用 `noprefixroute`，避免向主表自动加入移动网段路由。
5. 将移动网段路由和经移动网关的默认路由写入表 2020，不写入主表。
6. 通过接口绑定的公网请求验证移动网络可用。

路由示意（变量必须来自本次 bearer，不可直接使用旧测试值）：

```sh
ip link set "$IFACE" up
ip -4 address add "$ADDRESS/$PREFIX" dev "$IFACE" noprefixroute
ip -4 route replace table 2020 "$NETWORK" dev "$IFACE" src "$ADDRESS"
ip -4 route replace table 2020 default via "$GATEWAY" dev "$IFACE"
```

生产实现应使用结构化参数/netlink，并明确记录自身创建的地址和路由。换 IP 时删除旧的测试地址和网段路由，再应用新参数；不要无条件 flush 一个可能由其他程序管理的接口。

### 3.3 验证与禁止回退

```sh
ip -4 route get 1.1.1.1 oif wwan0
ip -4 route get 1.1.1.1
ip -4 route get 192.168.1.9
```

预期依次为移动表、有线默认出口、有线 SSH 路径。

Go 所有业务连接必须绑定移动接口；绑定失败、接口无地址或移动链路不可用时返回错误，不能改用未绑定的默认客户端。独立表查询失败可能继续匹配后续路由规则，不能把“存在一条策略规则”当作禁止回退的充分保证。需要更强隔离时，增加适配本机防火墙的出口限制或使用独立命名空间，并验证断链时不会从有线发出业务流量。

实测 `rp_filter` 为 loose 模式（值 2），无需修改。本方案不要求关闭防火墙或全局反向路径检查；如其他主机表现不同，应先诊断再决定，变更前备份并记录原值。

## 4. Go HTTP 请求示例（Linux）

依赖：

```sh
go get golang.org/x/sys/unix
```

代码只负责请求，要求前述拨号、地址和路由已经就绪。使用 IPv4，禁用环境代理，TLS 校验保持开启。

```go
package main

import (
    "context"
    "fmt"
    "io"
    "net"
    "net/http"
    "syscall"
    "time"

    "golang.org/x/sys/unix"
)

func newEC20Client(iface string) (*http.Client, *http.Transport) {
    dialer := &net.Dialer{
        Timeout: 15 * time.Second,
        Control: func(_, _ string, c syscall.RawConn) error {
            var bindErr error
            err := c.Control(func(fd uintptr) {
                bindErr = unix.SetsockoptString(
                    int(fd),
                    unix.SOL_SOCKET,
                    unix.SO_BINDTODEVICE,
                    iface,
                )
            })
            if err != nil {
                return err
            }
            return bindErr
        },
    }

    tr := &http.Transport{
        Proxy: nil,
        DialContext: func(ctx context.Context, _, addr string) (net.Conn, error) {
            return dialer.DialContext(ctx, "tcp4", addr)
        },
        TLSHandshakeTimeout:   10 * time.Second,
        ResponseHeaderTimeout: 15 * time.Second,
        IdleConnTimeout:       60 * time.Second,
    }

    return &http.Client{
        Transport: tr,
        Timeout:   30 * time.Second,
    }, tr
}

func main() {
    client, tr := newEC20Client("wwan0")
    defer tr.CloseIdleConnections()

    resp, err := client.Get("https://myip.ipip.net")
    if err != nil {
        panic(err)
    }
    defer resp.Body.Close()
    if resp.StatusCode != http.StatusOK {
        panic(fmt.Sprintf("unexpected HTTP status: %s", resp.Status))
    }

    body, err := io.ReadAll(io.LimitReader(resp.Body, 4096))
    if err != nil {
        panic(err)
    }
    fmt.Println(string(body))
}
```

### DNS 边界

上述 `Control` 绑定的是业务 TCP socket，系统 DNS 查询不一定走 EC20。若 DNS 也必须走移动网络：

- 使用 `net.Resolver{PreferGo: true, Dial: ...}` 配置自定义解析路径。
- 解析连接也需绑定当前移动接口，使用本次 bearer 提供的 DNS 地址，支持 UDP/TCP，并在换 IP 后刷新配置。
- 不要全局覆盖主机 DNS，以免影响 SSH 及其他业务。

公网 IP 对比测试可临时固定检测站域名到一个已验证地址，但应保留原域名的 Host/SNI 和 TLS 校验；服务地址可能变化，不宜把固定检测站 IP 当作永久配置。

## 5. 定期换 IP 的状态机

```text
READY：接受业务请求
   ↓ 定时器 / 手动申请切换
DRAINING：停止接收新请求，等待在途请求结束
   ↓ 到达等待上限则取消在途请求
ROTATING：关闭旧连接池，射频关闭/开启，重新注册并拨号
   ↓ 动态应用 bearer 地址与路由
VERIFYING：检查移动出口、公网 IP 与有线默认路由
   ├─ 成功：创建新 Client/Transport，进入 READY
   └─ 失败：进入 DEGRADED，拒绝业务请求，有界重试并告警
```

实现要求：

- 请求入口与切换入口共享并发控制，切换期间不能再有新请求进入旧连接池。多个定时/手动切换必须串行。
- `CloseIdleConnections()` 只关闭空闲连接，不能终止在途请求；先等待，必要时通过 context 取消，最后释放旧 Transport。
- WebSocket、流式请求、下载和其他长连接也必须纳入停流与取消机制。
- 切换成功后创建新的 Client/Transport，避免复用旧连接。
- 每轮从“数据连接断开”开始计时，到首次成功获得有效公网 IP 为止；记录是否与上一轮不同，并重复采样。
- 不因一次返回旧公网 IP 就立刻无限切射频。区分“联网恢复成功”和“换 IP 成功”，配置最大尝试次数及退避时间。
- 定时周期应明显长于一次恢复时间，并结合在途请求调度；恢复失败不应产生重叠任务。
- 链路切换时非幂等请求可能出现“服务端已执行但客户端未收到响应”，不能盲目重试；使用业务幂等键或显式确认机制。

## 6. 射频关闭/开启的具体步骤

以下命令用于说明逻辑，生产应动态发现 modem，并为每步设置超时：

```sh
mmcli -m 0 --simple-disconnect
mmcli -m 0 --disable
mmcli -m 0 --set-power-state-low
# 查询并确认 state=disabled、power-state=low。
sleep 5
mmcli -m 0 --set-power-state-on
mmcli -m 0 --enable
# 有界等待 registration-state=home/roaming。
mmcli -m 0 --simple-connect="apn=3gnet,ip-type=ipv4"
# 读取当前已连接 bearer，更新地址、路由，再探测公网。
```

- 不直接执行 `CFUN=1,1`，不将模块硬重启作为常规换 IP 手段。
- 一轮切换可能使移动网络中断约 11 秒，实际耗时会随信号、注册和运营商状态变化。
- 设备 USB 重枚举时应重新发现 modem、数据口与 bearer，不无限等待旧路径。
- 避免切换期间 NetworkManager 或其他拨号程序同时管理相同连接。明确唯一管理者，不为省事停止整机 NetworkManager。

## 7. 配置、日志与安全

建议配置项：目标设备匹配条件、APN、期望接口、路由表及规则优先级、切换周期、射频关闭等待时间、各阶段超时、最大重试次数、检测站与自动恢复策略。

- 不在文档、日志、命令输出或提交中记录 SIM PIN、APN 密码、设备/SIM 唯一标识或其他凭据。
- 需要凭据时通过受限配置或凭据管理机制传入，不拼接到日志；注意命令行参数可被进程列表读取。
- 不打开可能泄露隐私的全局敏感调试日志。
- 日志只记录阶段、耗时、错误分类、必要的接口/路由状态及公网 IP。公网 IP 本身也应按业务日志的访问和保留策略管理。
- 启动时保存受影响的运行态；变更现有持久化配置或二进制前先备份，先在临时路径验证再切换。替换长期运行的二进制后应 restart，而不是仅 reload。

## 8. 异常恢复、回滚与验收

### 自动恢复

管理服务即使切换失败，也应尝试恢复 power on / enable，避免模块停留在低功耗状态。使用进程外 watchdog 或 systemd 恢复机制兜底，不能只依赖 Go defer（SIGKILL、断电时不会执行）。

恢复顺序：

1. 保持业务暂停，禁止回退到有线。
2. 恢复射频开启，重新发现设备并等待注册。
3. 有界重试拨号、地址/路由配置及公网探测。
4. 超过上限后维持 DEGRADED 并告警，不无限重启模块。

### 停用与回滚

停用前先暂停业务并结束在途请求。按部署前快照决定恢复目标：

- 如初始为未拨号：断开本服务连接、删除自身创建的 bearer；清理自身添加的规则、路由和地址；按初始状态恢复接口。
- 如初始已有移动业务：不得直接 flush 接口或断开所有 bearer，应只撤销本服务拥有的资源，并恢复先前状态。
- 保持有线默认路由及 SSH 路径不变。
- 恢复/删除本服务的 systemd unit、定时器等持久化资源时，记录备份位置与实际变更；关闭已无用途的 watchdog。

此前测试的 `/run/ec20-*-test/cleanup.sh` 仅适用于当次初始状态，且文件随重启消失，不应作为未来常驻服务的通用回滚脚本。

### 上线验收

- [ ] Go 请求出口与绑定 EC20 的公网探测一致，接口流量计数增长。
- [ ] 普通主机流量和 SSH 仍走有线，主默认路由未改变。
- [ ] DNS 是否走移动网络符合预先约定。
- [ ] 连续多轮射频切换均有完整阶段日志与计时，区分联网成功/换 IP 成功。
- [ ] 移动链路断开、接口消失、绑定权限不足时业务请求失败，绝不改走有线。
- [ ] 在途请求、长连接和非幂等请求的切换行为经过测试。
- [ ] 管理服务崩溃、超时及 USB 重插后能恢复或进入明确告警状态。
- [ ] 停用后地址、路由、规则、模块状态符合部署前快照或明确约定的目标状态。
