# dev：第二个独立 PostgreSQL（5431）

2026-10-19 部署。原开发实例 `/home/tim/apps/postgres` / `pg18` / 5432 保持不变，未修改或重启。

## 新实例

| 项目 | 配置 |
| --- | --- |
| 目录 | `/home/tim/apps/postgres-5431` |
| Compose 项目 / 容器 | `postgres-5431` / `pg18-5431` |
| 镜像 | 本机已有 `postgres:18`，实际 PostgreSQL 18.6；部署未重新拉取 |
| 局域网连接 | `192.168.1.11:5431` |
| 本机连接 | `127.0.0.1:5431` |
| 默认用户 / 数据库 | `postgres` / `postgres` |
| 凭据 | 独立随机密码，保存在该目录 `.env`，tim 所有、权限 600；不复用原库密码 |
| 数据 | `data` 挂载容器 `/var/lib/postgresql`，实际 `data/18/docker`，999:999 / 700 |
| 重启 / 健康检查 | `unless-stopped` / `pg_isready` |
| 时区 | Asia/Shanghai |

5431 只是宿主机端口，容器内仍使用标准 5432。新旧实例数据库、数据目录、凭据、Compose 网络均独立；没有同步或迁移原数据。当前只提供管理员账号，业务使用应另建最小权限角色和数据库。

密码不在文档或命令输出中记录。通过可信 SSH 在本机密码管理工具中读取/保存 `.env`，不要粘贴到聊天或提交。`docker compose config` 可能展开密码，检查配置仅用 `docker compose config --quiet`。

## 防火墙

沿用已部署的 [UFW + Docker 转发过滤](dev-firewall-ufw-ec20.md)，不新增全网开放规则：

- 端口只绑定 192.168.1.11 和 127.0.0.1，不绑定 0.0.0.0、移动接口或 IPv6。
- UFW 已允许 `enp4s0` 来源 192.168.1.0/24；同一来源经独立 `inet dev_guard` 转发过滤后可以访问 Docker 新端口。
- 4G/其他非可信入口仍被阻断；192.168.31.0/24 原例外仅包含 3306/6379/9200，不允许 5431。
- 不要运行 `ufw allow 5431`，Docker 也不能只依赖 UFW INPUT。

## 验证

- 新容器 healthy，重启策略 unless-stopped。
- 通过已发布的 `192.168.1.11:5431` 完成密码认证和 SQL 查询。
- 新库创建临时验证 schema/table、插入数据，重启**新容器**后查询成功，再清理测试 schema/table。
- 从局域网客户端完成 PostgreSQL 协议响应验证。
- 临时 namespace 模拟非可信接口，目标仍使用真实绑定的 192.168.1.11:5431，连接超时，guard 丢弃计数增加；测试网络已清理。
- 原 pg18 启动时间保持 `2026-10-19T09:18:47.982404329Z`，原库 healthy。
- 未实际拨号测试 EC20，未重启主机；本次不改变其路由和防火墙策略。

## 维护、备份与回滚

```sh
cd /home/tim/apps/postgres-5431
docker compose -p postgres-5431 ps
docker compose -p postgres-5431 logs --tail=100
docker exec -it pg18-5431 psql -U postgres -d postgres
```

部署前快照：`/var/backups/dev-postgres-5431/20261019-185513/`，包括原 UFW、nft 规则及原 pg18 身份/启动时间。由于本次没有修改原库、原编排或防火墙配置，不需要备份/替换已有二进制；备份中有新 Compose 与回滚脚本。尚未配置此新实例的自动数据备份。

HDMI 或 SSH 登录 tim 后停用**仅此新实例**：

```sh
bash /home/tim/apps/postgres-5431/rollback.sh
```

脚本执行指定 Compose 项目的 `down`，保留 data 与 .env，不停止原库、不关闭防火墙。重新启动：

```sh
cd /home/tim/apps/postgres-5431
docker compose -p postgres-5431 up -d --pull never --wait
```

不要删除 data，除非确认不再需要数据。只改 `.env` 不会修改已初始化数据库的密码；改密码须执行 SQL 并同步更新客户端凭据。
