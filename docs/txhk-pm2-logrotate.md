# txhk：PM2 日志轮转配置

> 完成时间：2026-09-07

## 结果

`root` 用户的 PM2 已安装并运行 `pm2-logrotate` `3.0.0`。模块随 `pm2-root.service` 开机恢复，当前配置如下：

| 配置 | 值 | 含义 |
| --- | --- | --- |
| `rotateInterval` | `0 */12 * * *` | 每天 00:00、12:00 按时间轮转 |
| `compress` | `true` | 已轮转日志使用 gzip 压缩 |
| `retain` | `3` | 最多保留最近 3 个轮转文件 |

PM2 状态与保存文件已验证：`pm2-logrotate` 为 `online`，`/root/.pm2/dump.pm2` 已更新。

## 重要说明

PM2 的 `rotateInterval` 使用五段 cron：`分 时 日 月 周`。

- 需求中的 `* * */12 * *` **不是每 12 小时**；它会在每月日期为 1、13、25 日时每分钟执行一次。
- 每 12 小时应使用 `0 */12 * * *`。
- `retain 3` 是保留 3 个**轮转文件**，而不是 3 小时；在 12 小时轮转且无大小触发轮转时，约覆盖最近 36 小时。
- 默认 `max_size` 仍为 `10M`。日志达到此大小也可能提前触发轮转，因此实际覆盖时间可能少于 36 小时。

## 管理与验证

以 root 登录后执行：

```bash
pm2 conf pm2-logrotate
pm2 ls
pm2 logs
```

修改设置后需保存，确保重启后保留：

```bash
pm2 set pm2-logrotate:rotateInterval "0 */12 * * *"
pm2 set pm2-logrotate:compress true
pm2 set pm2-logrotate:retain 3
pm2 save --force
```

## 备份与回滚

变更前的 PM2 配置备份位于：

```text
/root/.config-backups/20260907-155457-pm2-logrotate/
```

其中包含变更前存在的 `/root/.pm2/module_conf.json` 与 `/root/.pm2/dump.pm2`。

若只需停止并移除日志轮转模块：

```bash
pm2 uninstall pm2-logrotate
pm2 save --force
```

如需恢复变更前的 PM2 配置，先还原上述备份中的文件，再执行：

```bash
systemctl restart pm2-root.service
```
