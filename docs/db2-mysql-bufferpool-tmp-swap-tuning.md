# db2：MySQL 缓冲池扩容 + `/tmp` 清理 + 新增 swap

> 执行时间：2026-09-26 12:44–12:52（服务器本地时间 CST）。
> 关联文档：[`db2-mysql-legacy-retire.md`](db2-mysql-legacy-retire.md)、[`db2-pg18-systemd.md`](db2-pg18-systemd.md)
> 主机：`db2`（SSH 别名，端口 5634，仅公钥登录）

## 一句话结论

`db2` 的瓶颈**不是 CPU/内存，是磁盘 IO 被 MySQL 打满**（`vda` 读 135 MB/s、`%util` 87–90%、iowait 85–90%）。
根因是 **`innodb_buffer_pool_size` 停留在默认 128 MB，而数据目录已 16 GB**（未命中率 33.7%）。
本次在线把缓冲池扩到 **1 GB**（零重启），并清理 `/tmp` 2.3 G、新增 4 GB swap。
变更后：**load 6.41 → 0.40，IO 压力 full avg10 91.7% → 1.2%，vda 读 135 MB/s → 2~4 MB/s**。

## 一、变更前状态（证据）

| 指标 | 变更前 |
|---|---|
| CPU / 内存 / 磁盘 | 4 vCPU AMD EPYC 7K62，3.8 GiB RAM，59 G（54% 用），**Swap = 0** |
| Load / uptime | 6.41 / 4.87 / 6.04，up 204 天 |
| `%iowait` | 85–90%（`%user` 仅 5%，确认非 CPU 瓶颈） |
| PSI io | some 94.7% / **full 91.7%** |
| `vda` | 读 135 MB/s，`%util` 87–90%，`aqu-sz` 15–18，`r_await` 15–17 ms |
| MySQL | 8.0.46，RSS 867 MB，数据目录 16 G，`innodb_buffer_pool_size` = **128 MB**（`mysqld.cnf` 中该项全被注释） |
| 缓冲池 | `pages_free` = 0 / 8192；`Innodb_buffer_pool_reads` / `read_requests` = 5.71e9 / 16.92e9（**33.7% 的逻辑读落到磁盘**） |
| PostgreSQL | 18，数据 5.8 G，18 个后端连接，监听 5432 |

IO 打满的直接来源：`pidstat` 显示 **mysqld 单进程持续读 135 MB/s**，对应 8 个并发的
`SELECT COUNT(id) FROM disks WHERE create_time > ? AND create_time < ?`
（`go-lzpan` / `go-qkpanso` 的日报统计），单条耗时 13–193 s。`disks` 表上**没有 `create_time` 索引**，
表 4.4 G / 217 万行，每次都是全表扫。

> 口径修正：上一版口头报告把 33.7% 说成“未命中率”时表述含糊。准确说法是
> `Innodb_buffer_pool_reads / Innodb_buffer_pool_read_requests` = 33.7% **为磁盘读（即未命中）**，
> 命中率 66.3%。

## 二、备份位置与回滚

统一备份根目录：**`/root/backup/pre-change-20260926/`**（`chmod 700`）

| 备份内容 | 路径 |
|---|---|
| MySQL 全配置目录 | `etc-mysql/`（`cp -a /etc/mysql`） |
| `/etc/fstab` 原始副本 | `fstab.orig` |
| 变更前 sysctl | `vm-sysctl.before`（`vm.swappiness=60`、`vfs_cache_pressure=100`、`overcommit_memory=0`） |
| 变更前 MySQL 变量 | `mysql-vars.before`（`innodb_buffer_pool_size=134217728`） |
| 变更后 MySQL 持久化文件 | `mysqld-auto.cnf.after` |
| `/tmp` 散落文件（见第四节） | `tmp-kept/`（`chmod 700`，文件 `600`） |

### 回滚

```bash
# 1) 回滚 MySQL 缓冲池（在线，无需重启）
sudo mysql --defaults-file=/etc/mysql/debian.cnf \
  -e "SET PERSIST innodb_buffer_pool_size = 134217728;"
sudo mysql --defaults-file=/etc/mysql/debian.cnf \
  -NBe 'show status like "Innodb_buffer_pool_resize%";'   # 等 Completed

# 2) 回滚 swap
sudo swapoff /swapfile && sudo rm -f /swapfile
sudo cp -a /root/backup/pre-change-20260926/fstab.orig /etc/fstab
sudo rm -f /etc/sysctl.d/99-db-tuning.conf
sudo systemctl daemon-reload && sudo sysctl --system

# 3) 回滚 MySQL 配置文件（本次未改动 /etc/mysql，仅用 SET PERSIST）
sudo rm -f /var/lib/mysql/mysqld-auto.cnf && sudo systemctl restart mysql
```

## 三、变更明细

### 1. MySQL 缓冲池 128 MB → 1 GB（在线，零停机）

用 `SET PERSIST` 而不是改配置文件 + 重启：MySQL 8.0 支持在线 resize，且 `PERSIST` 会把值写进
`/var/lib/mysql/mysqld-auto.cnf`，**重启后自动生效**，避免了一次全库停机。

```bash
sudo mysql --defaults-file=/etc/mysql/debian.cnf \
  -e "SET PERSIST innodb_buffer_pool_size = 1073741824;"
```

- 约束：resize 值必须是 `innodb_buffer_pool_chunk_size`(128 MB) × `instances`(1) 的整数倍，1 G = 8 chunk，满足。
- 执行账号：`debian-sys-maint`（具备 `SYSTEM_VARIABLES_ADMIN`）。
- 结果：`Innodb_buffer_pool_resize_status = Completed resizing buffer pool at 260926 12:49:33`，
  进程未重启（PID `2602871` 全程不变），期间应用连接未断（`go-lzpan` / `go-qkpanso` / `go-nav` / `go-kitboxpro` 均正常）。
- **注意**：`mysqld-auto.cnf` 的加载顺序在 `my.cnf` 之后，因此它**优先于** `/etc/mysql/**` 中的同名项。
  以后要改缓冲池，要么继续用 `SET PERSIST`，要么同时清掉 `mysqld-auto.cnf`，否则配置文件不生效。

### 2. `/tmp` 清理（2.3 G → 56 K）

清理前 `/tmp` 里有两类东西：

- **已停用 gobackup 的遗留加密归档**（占 2.3 G 的绝大部分）：`/tmp/{qkpanso,lzpan,hunhepan,go-nav,go-ai-api,keyhub,v2fd}/*.tar.gz.enc`，
  最后写入时间 **2026-09-07**。`root` crontab 中 gobackup 那行已被注释，现由 `go-sqlvault` 接管，
  故这批归档是**孤儿数据**。
  → 已删除（删前确认：`lsof +D /tmp` 无占用，`/etc/cron*` 与进程 cmdline 均无 `/tmp` 引用）。
- **散落的运维临时文件**（共约 30 K）：`.sql` 脚本、备份 `.out/.err`、迁移清单 `.txt`、`cron.bak.*` 等。
  → **未直接删除**，已整体移入 `/root/backup/pre-change-20260926/tmp-kept/` 并收紧权限。

未触碰：`systemd-private-*`、`snap-private-tmp`（运行中服务的私有 tmp）。

### 3. 新增 4 GB swap + 降低 swappiness

```bash
sudo fallocate -l 4G /swapfile
sudo chmod 600 /swapfile && sudo chown root:root /swapfile
sudo mkswap /swapfile && sudo swapon /swapfile
# /etc/fstab 追加：/swapfile none swap sw 0 0
# /etc/sysctl.d/99-db-tuning.conf：vm.swappiness = 10 / vm.vfs_cache_pressure = 100
sudo systemctl daemon-reload
```

- 该机此前**完全没有 swap**（`kswapd0` 已累计消耗 3302 分钟 CPU），在 3.8 G 内存上跑 MySQL + PG 属于高风险。
- `swappiness=10`：swapfile 与数据盘同一块 `vda`，调低可避免在 IO 已紧张时把热页换出导致抖动。
- 持久化验证：`systemd-fstab-generator` 已生成 `swapfile.swap` 单元，`is-enabled=generated`、`is-active=active` → 重启自动挂载。

## 四、验证结果（变更后 ~10 分钟）

| 指标 | 变更前 | 变更后 |
|---|---|---|
| Load (1/5/15) | 6.41 / 4.87 / 6.04 | **0.40 / 1.32 / 3.73** |
| PSI io full (avg10) | 91.7% | **1.2%** |
| `vda` 读 / `%util` | 135 MB/s / 87–90% | **2.4–3.7 MB/s / 4.9–6.0%** |
| `r_await` | 15–17 ms | **0.46–0.58 ms** |
| mysqld 磁盘读 | ~135 MB/s | **~0.29 MB/s**（60 s 内 `Innodb_data_read` +17 MB） |
| 缓冲池瞬时未命中率 | 33.7%（累计） | **3.05%**（60 s 采样：1040 / 34085） |
| `pages_free` / `pages_total` | 0 / 8192 | 56179 / 65536 |
| mysqld RSS | 867 MB | 959 MB（缓冲池惰性填充中，会继续增长到 ~1.1 G） |
| 内存 available | 2.4 GiB | 2.2 GiB |
| `/tmp` | 2.3 G | **56 K** |
| Swap | 无 | 4.0 G（已用 16.8 M） |
| 磁盘占用 | 30 G / 54% | 32 G / 57%（+4 G swap，−2.3 G `/tmp`） |
| MySQL / PG 服务 | active | active（**未重启**） |

补充：全表 `COUNT` 那 8 条查询在变更窗口内自行跑完，此后 `information_schema.processlist` 已无全表扫描。

## 五、遗留项（未处理，待跟进）

1. **`create_time` 索引需在程序层面加**（已与用户确认走应用侧，本次不动 DDL）。
   涉及 `go-lzpan.disks`(4.4 G)、`go-qkpanso.disks`(3.8 G)、`go-alipanx.disks`(1.4 G) 三张表。
   在此之前，日报统计**再来一轮仍会把 IO 打满**——缓冲池 1 G 装不下 4.4 G 的全表扫描。
2. **`/tmp/fuxipan_pw.txt` 是一份明文口令，且原本位于世界可读的 `/tmp`（目录 1777 / 文件 644）**。
   该文件已移入 `/root/backup/pre-change-20260926/tmp-kept/`（600），**内容未读取**。
   建议：确认后删除，并**轮换该口令**。
3. `/var/log` 1.7 G，其中 systemd journal 1.5 G（`journald.conf` 未设上限）。
   建议 `SystemMaxUse=300M` + `journalctl --vacuum-size=300M`。
4. PG 侧 10 个 `idle` 后端各占 ~150–200 MB，在 3.8 G 机器上偏重，建议连接池收紧 idle 回收。
5. `/root/backup` 1.2 G（含本次变更备份、PG 安装备份、drop 备份），建议后续统一归档策略。
