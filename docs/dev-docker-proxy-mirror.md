# dev：Docker 拉镜像改走 sing-box 代理（移除国内 mirror）

> 完成时间：2026-09-09
> 主机：`dev`（`tim-ubuntu`，Ubuntu 24.04.3 LTS，Docker 29.1.3）

## 背景与问题

dev 上 Docker 原本配置了两套拉镜像路径，二者叠加导致失败：

1. `/etc/docker/daemon.json` 里配了 7 个国内 `registry-mirrors`。
2. `/etc/systemd/system/docker.service.d/http-proxy.conf` 里配了指向本机 sing-box 的代理：

   ```ini
   [Service]
   Environment="HTTP_PROXY=http://127.0.0.1:7890"
   Environment="HTTPS_PROXY=http://127.0.0.1:7890"
   Environment="NO_PROXY=localhost,127.0.0.1,::1"
   ```

实际表现：拉 `postgres:18` 时 dockerd 先按顺序试所有 mirror，全部超时/失败（日志中为
`trying next host ... context canceled`），才轮到官方源，整体表现为长时间卡住或失败。
直连 `registry-1.docker.io` 本身是被墙的（实测 `curl` 15s 超时），所以必须走代理。

实测结论：

```bash
# 走代理（root 与 tim 均可用）
https_proxy=http://127.0.0.1:7890 curl -o /dev/null -w '%{http_code}\n' https://registry-1.docker.io/v2/
# → 401（正常，无凭据）
# 直连
curl -o /dev/null -w '%{http_code}\n' https://registry-1.docker.io/v2/
# → 000，Connection timed out
```

## 变更内容

移除 `registry-mirrors`，让 dockerd 直接通过 sing-box 代理访问官方 registry。

变更后的 `/etc/docker/daemon.json`：

```json
{
  "registry-mirrors": []
}
```

代理仍由 systemd drop-in（`/etc/systemd/system/docker.service.d/http-proxy.conf`）提供，
`docker info` 中可见：

```text
HTTP Proxy: http://127.0.0.1:7890
HTTPS Proxy: http://127.0.0.1:7890
No Proxy: localhost,127.0.0.1,::1
```

sing-box 以 `tim` 用户运行，mixed 入站监听 `127.0.0.1:7890`（配置：`/home/tim/tools/sing-box/config.json`）。
dockerd 在宿主网络命名空间运行，因此可直接访问 `127.0.0.1:7890`。

## 关键坑：`systemctl reload docker` 不会清空 mirror

Docker 的 SIGHUP 热加载只合并**在新 `daemon.json` 中显式出现**的字段：

- 写成 `{}` → 旧的 `registry-mirrors` 仍然保留（日志 `Reloaded configuration` 里能看到旧值）。
- 必须显式写 `"registry-mirrors": []`，`systemctl reload docker` 才会清空。

本次用 reload 而非 restart，因此所有运行中的容器（mysql57 / redis / es1 / kibana1 / gitea-postgres-1）未被重启。

```bash
sudo systemctl reload docker
docker info | grep -A8 "Registry Mirrors"   # 无输出即已清空
```

如果后续需要修改代理地址等需要重启的项，注意 `Live Restore Enabled: false`，
`systemctl restart docker` 会重启容器（现有容器均有 restart 策略，会自动拉起）。

## 验证

拉取 `postgres:18` 成功，约 3 分钟：

```bash
docker pull postgres:18
# → docker.io/library/postgres:18
docker run --rm --entrypoint postgres postgres:18 --version
# → postgres (PostgreSQL) 18.6 (Debian 18.6-1.pgdg13+2)
```

## ⚠️ postgres:18 镜像的数据目录变更

`postgres:18` 官方镜像改了数据目录布局：

```text
PGDATA=/var/lib/postgresql/18/docker
VOLUME /var/lib/postgresql
```

因此**不能**再沿用旧写法 `- ./data:/var/lib/postgresql/data`（该目录不会被使用，数据会落到匿名卷里）。
持久化应挂载父目录：

```yaml
volumes:
  - ./data:/var/lib/postgresql
```

## 备份与回滚

变更前备份：

```text
/etc/docker/daemon.json.bak-20260909-155343
```

回滚（恢复国内 mirror）：

```bash
sudo cp -a /etc/docker/daemon.json.bak-20260909-155343 /etc/docker/daemon.json
sudo systemctl reload docker
```

或直接恢复“无 mirror、走代理”的最小配置：

```json
{
  "registry-mirrors": []
}
```
