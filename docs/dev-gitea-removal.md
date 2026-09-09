# dev：彻底移除 Gitea

> 完成时间：2026-09-09
> 主机：`dev`（`tim-ubuntu`）

## 结论

`gitea` Compose 项目已完全删除：容器、网络、镜像、项目目录全部清理，无残留。
其余服务（`mysql` / `redis` / `elastic7` / `postgres`）未受影响。

## 删除前的现状

| 对象 | 说明 |
| --- | --- |
| `4db3a142c2d9` / `gitea-postgres-1` | `postgres:14`，gitea 的数据库（用户询问的就是它） |
| `gitea-runner-1` | `gitea/act_runner:latest`，因 `lookup gitea ... server misbehaving` 无限重启 |
| `gitea` 主容器 | **已不存在**（不在 `docker ps -a` 中），所以 gitea 本身早已不可用 |
| `gitea_default` 网络 | 只剩 `gitea-postgres-1` 一个成员 |

判定为“无人使用”的依据：

- 3000 / 2222 端口无监听。
- 无 nginx / caddy 反代配置引用 `gitea`、`3000`、`2222`。
- 无 systemd unit、无 cron 引用 `gitea`。
- `gitea/data/git/repositories` 为空（16K），**没有任何代码仓库**。
- 本机各项目及 `ai-workflow` 仓库的 git remote 均指向 GitHub，无指向该 Gitea 的 remote。
- 无 docker named volume 关联（原项目全部使用 bind mount）。

## 执行的操作

```bash
# 1) 备份整个项目目录（含 postgres 数据）
sudo tar czf /home/tim/backups/gitea-removed-20260909-160240.tar.gz -C /home/tim/apps gitea

# 2) 移除容器与网络
cd /home/tim/apps/gitea && docker compose down --remove-orphans

# 3) 删除镜像（已确认无其他容器使用 postgres:14）
docker rmi docker.gitea.com/gitea:1.25.3-rootless gitea/act_runner:latest postgres:14

# 4) 删除项目目录
sudo rm -rf /home/tim/apps/gitea
```

## 验证

```text
docker ps -a | grep gitea        → 无
docker network ls | grep gitea   → 无
docker images | grep gitea       → 无
docker images | grep postgres:14 → 无
ss -tlnp | grep -E ':3000|:2222' → 无（端口已释放）

docker compose ls
NAME        STATUS          CONFIG FILES
elastic7    running(2)      /home/tim/apps/elastic7/docker-compose.yml
mysql       running(1)      /home/tim/apps/mysql/docker-compose.yml
postgres    running(1)      /home/tim/apps/postgres/docker-compose.yml
redis       running(1)      /home/tim/apps/redis/docker-compose.yml
```

删除后 `docker ps`：`pg18`(healthy) / `kibana1` / `redis` / `es1` / `mysql57`(healthy) 均正常。

## 备份与恢复

备份文件：

```text
/home/tim/backups/gitea-removed-20260909-160240.tar.gz   # 12M
```

内含 `apps/gitea/` 全量：`docker-compose.yml`、`.env`（含 runner token，注意保密）、
`postgres/`（数据库数据，77M 未压缩）、`gitea/data`、`gitea/config/app.ini`、`runner/data`。

如需恢复：

```bash
sudo tar xzf /home/tim/backups/gitea-removed-20260909-160240.tar.gz -C /home/tim/apps
cd /home/tim/apps/gitea && docker compose up -d
```

注意：恢复需要重新拉取 `docker.gitea.com/gitea:1.25.3-rootless`、`gitea/act_runner:latest`、
`postgres:14` 三个镜像（走 sing-box 代理，见 `docs/dev-docker-proxy-mirror.md`），
且 `gitea-postgres-1` 的数据目录属主为 uid 999，`tar` 恢复后属主会保留。

确认不再需要后，可自行删除该备份：

```bash
sudo rm /home/tim/backups/gitea-removed-20260909-160240.tar.gz
```
