# dev：PostgreSQL 18（Docker Compose）

> 完成时间：2026-09-09
> 主机：`dev`（`tim-ubuntu`，Ubuntu 24.04.3 LTS，Docker 29.1.3 / Compose v5.0.1）

## 结果

dev 上以 Docker Compose 方式运行 PostgreSQL 18.6，与 `mysql` / `redis` / `gitea` 等项目同一套目录约定。

| 项 | 值 |
| --- | --- |
| 项目目录 | `/home/tim/apps/postgres` |
| Compose 项目名 | `postgres` |
| 容器名 | `pg18` |
| 镜像 | `postgres:18`（PostgreSQL 18.6，Debian 18.6-1.pgdg13+2） |
| 宿主端口 | `0.0.0.0:5432 -> 5432` |
| 数据目录 | `/home/tim/apps/postgres/data`（挂到容器 `/var/lib/postgresql`） |
| 实际 PGDATA | `/home/tim/apps/postgres/data/18/docker` |
| 时区 | `Asia/Shanghai`（`TZ` / `PGTZ` / `-c timezone` / `-c log_timezone`） |
| 编码 / 排序 | `UTF8` / `C.UTF-8` |
| 重启策略 | `unless-stopped` |
| 健康检查 | `pg_isready`，`interval=10s`，`start_period=30s` |

状态：`docker ps` 显示 `pg18  Up (healthy)`；`docker compose ls` 中 `postgres  running(1)`。

## 关键路径

```text
/home/tim/apps/postgres/docker-compose.yml    # 编排定义
/home/tim/apps/postgres/.env                  # POSTGRES_USER / POSTGRES_DB / POSTGRES_PASSWORD，权限 600
/home/tim/apps/postgres/data/18/docker        # PGDATA，持久化位置
```

凭据只存在于 `.env`（`chmod 600`），compose 文件通过 `${POSTGRES_PASSWORD}` 引用，本文档不记录其值。
如需查看：`sudo grep POSTGRES_PASSWORD /home/tim/apps/postgres/.env`。

## 两个必须记住的坑

### 1. postgres:18 改了数据目录布局

```text
PGDATA=/var/lib/postgresql/18/docker
VOLUME /var/lib/postgresql
```

因此**不能**照抄 gitea 的 `./data:/var/lib/postgresql/data`。官方镜像的 entrypoint 会检测
`/var/lib/postgresql/data` 下的旧数据并直接报错退出（`docker_error_old_databases`）。
正确做法是挂父目录：

```yaml
volumes:
  - ./data:/var/lib/postgresql
```

### 2. 数据目录属主必须是容器内的 postgres（uid 999）

首次启动曾失败，日志刷：

```text
mkdir: cannot create directory '/var/lib/postgresql': Permission denied
```

原因：bind mount 的 `./data` 属主是 `tim(1000)`、权限 `700`，而容器内 `postgres` 是 **uid 999**。
entrypoint 第一轮以 root 创建 `18/docker` 并 chown 给 postgres，第二轮以 postgres 身份执行
`mkdir -p /var/lib/postgresql/18/docker` 时，因父目录 `/var/lib/postgresql` 属主 1000 且 700，
无法进入而报错。

修复（与 mysql 数据目录一致，宿主上显示为 `dnsmasq`）：

```bash
cd /home/tim/apps/postgres
sudo chown -R 999:999 data
sudo chmod 700 data
```

注意：chown 后 `tim` 用户无法直接 `ls data/`，需 `sudo`。

## 常用命令

```bash
cd /home/tim/apps/postgres

docker compose ps
docker compose logs -f
docker compose restart          # 重启
docker compose down             # 停止并删容器（保留 data）
docker compose up -d            # 启动

# 连接（容器内 socket，免密）
docker exec -it pg18 psql -U postgres

# 从外部用密码连接
docker exec -e PGPASSWORD="$(grep POSTGRES_PASSWORD .env | cut -d= -f2)" \
  pg18 psql -h 127.0.0.1 -U postgres -c '\l'
```

新增初始化脚本可放 `./initdb.d/`（当前未创建），在 compose 里加：

```yaml
volumes:
  - ./initdb.d:/docker-entrypoint-initdb.d:ro
```

仅在数据目录为空（首次初始化）时执行。

## 验证记录

```text
$ docker exec pg18 psql -U postgres -Atc "select version();"
PostgreSQL 18.6 (Debian 18.6-1.pgdg13+2) on x86_64-pc-linux-gnu, ...

$ docker exec pg18 psql -U postgres -Atc "show timezone;"
Asia/Shanghai

$ docker exec pg18 psql -U postgres -Atc "select datname,datcollate,datctype,pg_encoding_to_char(encoding) from pg_database where datname='postgres';"
postgres|C.UTF-8|C.UTF-8|UTF8

# 密码认证 + TCP
$ docker exec -e PGPASSWORD=... pg18 psql -h 127.0.0.1 -U postgres -Atc "select current_user, current_database(), inet_server_port();"
postgres|postgres|5432

# 重启后数据保留
$ docker compose restart
PostgreSQL Database directory appears to contain a database; Skipping initialization
```

## 安全提示

`ufw` 当前未启用，5432 与 3306 一样暴露在 `0.0.0.0`。如仅需本机访问，把 compose 的
`ports` 改为 `127.0.0.1:5432:5432`，或启用防火墙限制来源。

## 回滚

该服务为新增，回滚即删除：

```bash
cd /home/tim/apps/postgres
docker compose down            # 保留数据
# 彻底清理（会丢数据，先确认）：
# docker compose down && sudo rm -rf data
```

镜像可删除：`docker rmi postgres:18`。

拉取该镜像所依赖的 Docker 代理配置见 `docs/dev-docker-proxy-mirror.md`。
