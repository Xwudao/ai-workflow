# dev EC20 配置检查

## 检查结果

通过 `ssh dev` 只读检查，未修改远程配置、未执行射频开关、未重启服务。

- 应用：`/home/tim/webs/go-online-tools/go-online-tools`，由 `pm2-tim.service` 下的 PM2 管理，以 `tim` 身份运行，并非容器运行。
- 模块由 udev 识别为 Quectel EC20-CE-HDLG；USB ID 显示为 EC25 系列，不应仅凭 lsusb 名称判断型号。
- 当前串口为 `/dev/ttyUSB5` 至 `/dev/ttyUSB8`，截图所填 `/dev/ttyUSB2` 不存在。
- ModemManager 确认 `/dev/ttyUSB7`、`/dev/ttyUSB8` 是 AT 端口；首选接口 02 对应 `/dev/ttyUSB7`。
- 推荐稳定路径：`/dev/serial/by-id/usb-Quectel_EC20-CE-HDLG_0123456789ABCDEF-if02-port0`，避免 USB 重枚举后编号变化。
- `wwan0` 与该模块同属 USB 设备 `3-3.2`，网卡名称正确，但检查时链路为 DOWN；ModemManager 显示已注册本地网络，不代表数据连接已建立。
- 串口权限为 `root:dialout`、`0660`；应用运行用户及进程附加组均没有 `dialout`，当前用户对 AT 串口无读写权限。仅修改设备路径仍会报权限错误。
- ModemManager 正在运行，后续直连串口时应检查串口占用/并发控制，避免两个控制器互相干扰。

## 建议配置及后续操作

- 波特率 `115200` 可作为常规配置；尚未通过串口验证 AT 应答。
- 查询 `AT+CFUN?`、开启 `AT+CFUN=1` 是常用命令。
- `AT+CFUN=0` 表示最小功能模式，不只是关闭 RF；若仅需要关闭收发射频，可根据模块手册与实际验证考虑 `AT+CFUN=4`。
- 修改前备份受影响配置（页面提示配置持久化于 PostgreSQL `site_configs/tool_ec20_config`）；不要将数据库凭据写入文档。
- 经授权后为服务设置串口访问权限，并确保新进程确实继承 `dialout` 组；只给用户加组而继续使用旧 PM2 守护进程可能不生效。
- 先验证 `AT` 与 `AT+CFUN?`，再进行可能断网的开关测试；代理还需独立验证移动数据连接、地址、路由及绑定网卡后的出口。

## 回滚

初次检查没有远程变更。

## 权限修复执行记录

经用户授权，已执行：

1. 在 `/var/backups/ec20-permissions-20261019-192417` 建立 root 专用备份目录，备份 `/etc/group`、`/etc/gshadow`、`/etc/systemd/system/pm2-tim.service`，以及保存前后的 PM2 dump。备份可能含敏感信息，不得输出其内容。
2. `pm2 save` 保存当前进程列表。
3. `sudo usermod -aG dialout tim`。
4. `sudo systemctl restart pm2-tim`，使 PM2 和应用继承新的附加组；此操作重启了该 PM2 管理的应用。

验证：`go-online-tools` 仍以 UID 1000 (`tim`) 运行，新进程附加组包含 GID 20 (`dialout`)；新 SSH 会话对 AT 稳定路径有读写权限；应用 PM2 状态为 online。`transfer` 保持原先 stopped 状态。`refresher` 在操作前已频繁重启，操作后仍出现同样现象，未在本次处理。

未修改源码、页面 AT 路径或数据库配置，未发送 AT 命令或切换射频。源码路径由用户说明为本地 `~/Codes/go/go-online-tools`，远端运行路径不变。

回滚权限修复：`sudo gpasswd -d tim dialout`，再执行 `sudo systemctl restart pm2-tim`。不要直接覆盖整个 `/etc/group` 或 `/etc/gshadow`，以免覆盖其他并行变更。若需恢复旧 PM2 列表，先备份当前状态，再在维护窗口使用备份的 `dump.pm2.before`；其中可能包含敏感配置，禁止输出内容。
