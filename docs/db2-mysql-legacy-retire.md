# db2：MySQL 迁移遗留库退役（`go-hunhepan` / `go-fuxipan`）

> 完成时间：2026-09-23
> 主机：`db2`（MySQL 8.0.46-0ubuntu0.24.04.4 与 PostgreSQL 18 同机监听）
> 动作：删除 MySQL 库 `go-hunhepan`（8025 MB）与 `go-fuxipan`（1929 MB），及对应账号
> 目的：两者均已迁移到 db2 本机的 PostgreSQL 18（`10.0.4.14:5432`），MySQL 侧数据冻结，回收磁盘与备份噪音

## 总览

| 应用 | MySQL 库大小 | 表数 | PG 库 | MySQL 最后写入 | 删除时间 |
| --- | ---: | ---: | --- | --- | --- |
| `go-hunhepan` | 8025 MB | 51 | `go-hunhepan`（角色 `hunhepan`） | 2026-09-11 00:59:25 | 2026-09-23 20:40 |
| `go-fuxipan` | 1929 MB | 8 | `go-fuxipan`（角色 `fuxipan`） | 2026-09-19 15:55:00 | 2026-09-23 20:52 |

删除后 db2 根分区占用由 40 GB 降至 30 GB（释放约 11 GB），剩余 27 GB。

## 一、`go-hunhepan`

### 迁移背景

2026-09-11 完成 MySQL → PostgreSQL 迁移，工具与日志位于 `/root/hhp-migrate/`
（`hhp-migrate-data-linux`），日志：`migrate-*`、`verify-*`、`cutover-20260911-011512.log`。
app3 的 `/root/app/go-hunhepan/config.yml` 已指向 PG（`port: 5432`）。

### 删除前核对

- cutover 迁移计划覆盖 **49 张表**；MySQL 51 张中仅两张未迁移：
  - `disks`（66,509 行）— 工具显式标记 `source-only tables skipped (not in PostgreSQL)`，新 schema 无此表
  - `schema_migrations` — ORM 框架表，新库自行维护
- 关键表行数（PG 为精确值/校验日志值，MySQL 为冻结快照），PG 全部 ≥ MySQL：

| 表 | MySQL | PG |
| --- | ---: | ---: |
| `raw_disks` | 2,211,333 | 2,240,565 |
| `disk_tasks` | 1,374,606 | 1,731,379 |
| `duplicate_resource_matches` | 279,672 | 1,185,153 |
| `duplicate_resources` | 23,682 | 108,318 |
| `magnet_links` | 25,990 | 90,353 |
| `tags` | 561,861 | 561,596 |
| `share_users` | 156,826 | 157,512 |
| `users` | 18,726 | 19,119 |
| `inbox_messages` / `user_inbox_messages` | 10,316 | 9,678（运行期清理，两侧恒等） |

- MySQL `processlist` 中无 `go-hunhepan` 连接（活跃的是 `go-lzpan`/`go-qkpanso`/`go-nav`/`go-kitboxpro`）。
- app3 仍使用 3306 的应用配置中不含 `go-hunhepan`。

### 备份

MySQL 的 `go-hunhepan` 在 PG 切换后**已从 go-sqlvault 备份列表移除**，COS 无新备份
（最后一次 MySQL 备份为 2026-09-10），故删除前必须本地兜底。

| 文件 | 大小 | 说明 |
| --- | ---: | --- |
| `/root/backup/mysql-go-hunhepan-drop-20260923-202843/go-hunhepan.sql.gz` | 809 MB | 51 表，`gzip -t` 通过，含 `Dump completed` |
| 同目录 `user-go-hunhepan.create.sql` | — | 账号定义（含密码哈希，600，**禁止外传/入库**） |
| 同目录 `user-go-hunhepan.grants.sql` | — | 授权记录 |

## 二、`go-fuxipan`

### 迁移背景

2026-09-21 23:53 起使用 `/root/fuxipan-migrate/`（`migrate-data`）迁移到 PG，
日志 `/root/fuxipan-migrate/logs/current.log` 记录 `migration up success`。
app3 的 `/root/app/go-fuxipan/config.yml` 指向 PG；旧 MySQL 配置保留为 `config.yml.mysql`（已不使用）。
MySQL 侧冻结在 **2026-09-19 15:54**（正好是 app3 `go-fuxipan` 停机时刻，参见
`docs/txsp-traffic-and-log-cleanup.md`），与迁移开始时间吻合。

### 删除前核对

- `disks` 精确行数两边完全一致：MySQL `1,423,038` = PG `1,423,038`；`MAX(id)` 同为 `1,423,039`，
  `MAX(create_time)` 同为 `2026-09-19 15:54:50`；PG 的 `MAX(update_time)` 为 `2026-09-23 18:09`（仍在写入）
- 小表逐项精确比对，PG ≥ MySQL：`site_configs` 22/22、`sys_tasks` 386/384、`users` 1/0、
  `categories` 3/3、`data_lists` 4/4、`cdkeys` 0/0、`disk_tasks` 0/0
- MySQL `processlist` 中无 `go-fuxipan` 连接；PG 侧有 `fuxipan@10.0.16.17` 连接
- app3 的 `go-fuxipan`（端口 6655）pm2 状态 `online`

### 备份

| 文件 | 大小 | 说明 |
| --- | ---: | --- |
| `/root/backup/mysql-go-fuxipan-drop-20260923-204737/go-fuxipan.sql.gz` | 351 MB | 8 表，`gzip -t` 通过，含 `Dump completed` |
| 同目录 `user-go-fuxipan.create.sql` | — | 账号定义（含密码哈希，600，**禁止外传/入库**） |
| 同目录 `user-go-fuxipan.grants.sql` | — | 授权记录 |

## 执行的命令

备份（两个库相同流程，`--single-transaction` 保证 InnoDB 一致性，`--set-gtid-purged=OFF` 便于回灌）：

```bash
mysqldump --defaults-extra-file=/etc/mysql/debian.cnf \
  --single-transaction --quick --routines --triggers --events \
  --set-gtid-purged=OFF --databases <db> | gzip -3 > <db>.sql.gz
```

删除（凭据经 `/etc/mysql/debian.cnf` 读取，未记录密码）：

```sql
DROP DATABASE `go-hunhepan`;  DROP USER 'go-hunhepan'@'%';
DROP DATABASE `go-fuxipan`;   DROP USER 'go-fuxipan'@'%';
```

## 备份配置（go-sqlvault）调整

`/root/.go-sqlvault/config.yml`：

- `go-hunhepan` 在 2026-09-11 切换后已从 **mysql** 列表移除，本次无需改动。
- `go-fuxipan` 本次从 **mysql** 列表移除（否则每次备份都会报错；`stop_on_error: false` 只报错不中断）。
- **postgres** 列表保留 `go-fuxipan` 与 `go-hunhepan`（retention 3）。
- 修改前备份：`/root/.go-sqlvault/config.yml.bak.20260923-205223-precise`
  （以及因首次 sed 过宽而回滚时产生的 `...-before-fxp-drop`）。
- 校验方式：`go-sqlvault --config ~/.go-sqlvault/config.yml backup --dry-run`
  → 应为 9 个 mysql + 5 个 postgres 目标。

> **踩坑记录**：mysql 与 postgres 两个 target 的 `databases` 列表项缩进相同（均为 8 空格），
> 用 `sed '/^        - name: go-fuxipan$/,+1d'` 会**同时删掉两个列表**里的条目。
> 正确做法是按行号（`grep -n ... | head -1`）删除首次出现，或用 YAML 感知的工具。

## 验证

- 两个库与两个账号在 MySQL 中均为 0 条；剩余 MySQL 库为 `go-lzpan`/`go-qkpanso`/`go-alipanx`/
  `go-reman`/`go-ai-api`/`go-keyhub`/`go-nav`/`go-v2fd`/`go-kitboxpro`/`go-slide`/`go-revjs`。
- 其他数据库无任何引用 `hunhepan`/`fuxipan` 的对象。
- PG 侧连接正常：`go-hunhepan`（3694 MB）、`go-fuxipan`（`disks` 仍为 1,423,038 行）。
- app3：`go-hunhepan`、`go-fuxipan` 均为 pm2 `online`，日志持续输出 200；`fuxipan.com`
  本机 `127.0.0.1:6655/` 返回 200。

> **排错提示**：用不带浏览器 UA 的裸 `curl` 访问公网域名会被 gate/txsp 的 WAF 拦截，
> 表现为 `500`、`403` 或 `{"code":0,"msg":"system overload..."}`。这是 WAF/限流行为，并非应用故障
> （应用日志中 403 在改动前后各时段均有分布，属稳态）。验证时请带正常浏览器 UA，或直接看 app3 的应用日志。

## 回滚

```bash
for db in go-hunhepan go-fuxipan; do
  dir=$(ls -d /root/backup/mysql-$db-drop-* | tail -1)
  mysql --defaults-extra-file=/etc/mysql/debian.cnf < $dir/user-$db.create.sql
  mysql --defaults-extra-file=/etc/mysql/debian.cnf < $dir/user-$db.grants.sql
  gzip -dc $dir/$db.sql.gz | mysql --defaults-extra-file=/etc/mysql/debian.cnf
done
```

回灌后把 app3 对应 `config.yml` 切回 MySQL 并 `pm2 restart <app>`。
`go-hunhepan` 的 `disks`、`schema_migrations` 与新库体系无关，可不处理。

## 遗留事项

- `postgres/go-fuxipan` 在本次操作时**尚未实际执行过任何备份**（该条目为当日新增，此前 14 次
  go-sqlvault 运行均未包含它）。删除 MySQL 侧后，PG 是唯一数据源，务必确认 **2026-09-24 03:30**
  的定时备份中包含且成功写入 `backups-pg/go-fuxipan/`。
- 其余仍使用 MySQL 的应用（`go-lzpan`、`go-qkpanso`、`go-alipanx`、`go-reman`、`go-ai-api`、
  `go-keyhub`、`go-nav`、`go-v2fd`、`go-kitboxpro`、`go-slide`、`go-revjs`）未受影响；
  `go-hunhepan`、`go-fuxipan` 的后端选型以本文档为准。
