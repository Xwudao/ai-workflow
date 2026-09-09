# db2：PostgreSQL 18（systemd）

> 完成时间：2026-09-09
> 主机：`db2`（Ubuntu 24.04.3 LTS，x86_64）

## 结果

PostgreSQL 18 已通过浙江大学 PGDG APT 镜像安装，并由 systemd 管理；未保留 `apt.postgresql.org` 软件源。

| 项 | 值 |
| --- | --- |
| 已安装版本 | PostgreSQL 18.1（`18.1-1.pgdg24.04+2`） |
| APT 源 | `http://mirrors.zju.edu.cn/postgresql/repos/apt noble-pgdg main` |
| 元数据签名 | `/etc/apt/keyrings/postgresql.asc.gpg` |
| cluster | `18/main` |
| 数据目录 | `/var/lib/postgresql/18/main` |
| 配置目录 | `/etc/postgresql/18/main` |
| 日志 | `/var/log/postgresql/postgresql-18-main.log` |
| 监听 | `0.0.0.0:5432` |
| 初始化 | UTF-8 / `C.UTF-8`，时区 `Asia/Shanghai`，数据校验和已启用 |

## systemd 管理

```bash
# 查看服务及实际 cluster 单元
sudo systemctl status postgresql.service
sudo systemctl status postgresql@18-main.service

# 启停或重启数据库（修改配置后使用 restart）
sudo systemctl start postgresql@18-main.service
sudo systemctl stop postgresql@18-main.service
sudo systemctl restart postgresql@18-main.service

# 查看 cluster、日志与连接状态
pg_lsclusters
sudo journalctl -u postgresql@18-main.service -f
sudo -u postgres psql
```

验证时 `postgresql.service` 为 `enabled`、`active`，`postgresql@18-main.service` 为 `enabled-runtime`、`active`；`pg_lsclusters` 显示 `18/main` 在 5432 端口 `online`。

`postgres` 数据库角色已设置 SCRAM 密码，并已通过本机 TCP (`127.0.0.1:5432`) 密码认证验证。密码不记录在本文档；角色修改前的全局元数据备份位于 `/root/backup/postgresql-18-role-password-20260909-180342/globals-before.sql`，该文件含密码哈希且权限为 `600`。

已将 `listen_addresses` 设为 `*` 并以 `systemctl restart postgresql@18-main.service` 生效，配置备份为 `/root/backup/postgresql-18-listen-addresses-20260909-180507/postgresql.conf`。

已在 `pg_hba.conf` 添加 `app3` 私网地址 `10.0.16.17/32` 的 `scram-sha-256` 规则，并使用 `systemctl reload postgresql@18-main.service` 加载；修改前备份为 `/root/backup/postgresql-18-hba-app3-20260909-180628/pg_hba.conf`。规则语法已由 `pg_hba_file_rules` 验证。腾讯云安全组放行后，已从 app3 成功验证 TCP 连接 `10.0.4.14:5432`。app3 未安装 `psql` 客户端，故未在该机执行 SQL 级密码认证验证。不要放开全部来源。

## 变更与备份

安装前的 APT 源及 keyring 状态已备份在：

```text
/root/backup/postgresql-18-install-20260909-173958/apt-postgresql-state-before.tar.gz
```

该目录还包含切换为浙大镜像前的官方 PGDG 源文件副本。安装过程中曾临时停止卡住的 `apt-daily` 作业以释放 APT 锁；完成后已恢复 `apt-daily.timer` 和 `apt-daily-upgrade.timer`。

## 回滚

这是新增数据库，确认不再需要且已备份业务数据后：

```bash
sudo systemctl stop postgresql.service
sudo apt-get purge postgresql-18 postgresql-18-jit postgresql-client-18 postgresql-common postgresql-client-common
sudo rm -rf /etc/postgresql/18 /var/lib/postgresql/18 /var/log/postgresql/postgresql-18-main.log
sudo rm -f /etc/apt/sources.list.d/pgdg.list /etc/apt/keyrings/postgresql.asc.gpg
# 如需恢复安装前 APT 状态，使用上方备份文件核对后解压恢复。
```

删除数据目录会永久删除全部数据库；执行前必须确认备份可用。
