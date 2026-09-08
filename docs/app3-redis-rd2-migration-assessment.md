# app3 Redis（rd → rd2）迁移评估

检查时间：2026-09-08（UTC+8）

## 拓扑

- app3：`10.0.16.17`
- 旧 Redis `rd`：`10.0.4.17:6379`
- 新 Redis `rd2`：`10.0.4.15:6379`

## 配置与键空间

计划切换的应用当前均仍配置为 `rd`。其中 Redis 前缀来自 `redis.prefix`，不是 `app.prefix`：

| 应用 | 配置中的标识 | rd 上观察到的键 |
| --- | --- | ---: |
| go-fuxipan | `redis.prefix: ps` | 约 79.9 万 |
| go-hunhepan | `app.tag: hhp`（未配置 `redis.prefix`） | 约 113 万 |
| go-ai-api | `redis.prefix: aiapi` | 6 |
| go-keyhub | `redis.prefix: keyhub` | 0 |
| go-slide | 未配置前缀 | 0（未发现可归属键） |
| go-revjs | `redis.prefix: ""` | 0（未发现可归属键） |
| go-kitboxpro | 未配置前缀 | 0（未发现可归属键） |

`rd` 与 `rd2` 之间 TCP 6379 不通；但 app3 可同时连接两端。因此如后续执行迁移，应在 app3 上以 `SCAN` + `DUMP`/`PTTL` + `RESTORE REPLACE` 复制有前缀键，保留 TTL。切换时须先停止相应应用，做一次最终同步，修改配置并由 PM2 重启，避免写入窗口丢失。

## 本次结果和回滚

未修改任何应用的 `config.yml`，未重启应用，所有目标应用仍使用 rd。

曾在 app3 上验证复制 `ps*`、`hhp*`、`aiapi*` 到 rd2 的可行性，随后已用 `UNLINK` 清理验证数据；rd2 上不存在这些测试前缀的残留键。

已创建配置备份（即使本次未改配置）：

`/root/app3-redis-rd2-migration-backup-20260908-221025`

## 阻塞风险

rd2 在验证复制完成时 Redis 逻辑内存约 2.66 GB，主机可用内存约 724 MB，且 Swap 已使用约 860 MB；rd2 无 `maxmemory` 且策略为 `noeviction`。若再承担 rd 的约 1 GB Redis 数据，加上频繁 RDB 后台保存，存在显著的内存与 OOM 风险。

应先扩容 rd2 或制定内存上限、淘汰策略及持久化策略，并在容量验证后再切换。回滚方式为使用上述备份恢复各配置中的 `10.0.4.17:6379`，再由 PM2 重启对应应用。
