---
name: mysql-s3-backup
description: 用 go-sqlvault 把 MySQL/MariaDB 备份到 S3 兼容对象存储（腾讯云 COS）——流式 dump/压缩/上传、按库 retention、配置发现与迁移、替换 gobackup 及其 cron，以及 COS 内网 endpoint 的坑（用错会慢约 17 倍）。
allowed-tools: Bash(*) Bash(ssh:*) Bash(scp:*)
---

# MySQL → S3 备份（go-sqlvault / Tencent COS）

用于把一台或多台服务器上的 MySQL/MariaDB 备份到 S3 兼容对象存储，典型是腾讯云 COS。本文是实战踩坑总结，命令可直接复制。

## TL;DR

1. **COS 一定用内网 endpoint**：`https://cos-internal.<region>.myqcloud.com`。用公网域名可能解析到公网 IP，上传被公网带宽卡到 <1 MiB/s；内网可到十几 MiB/s（实测 17 倍差距）。
2. go-sqlvault 是**全程流式** `mysqldump → gzip → (age) → S3`，内存恒定（~50 MB，与库大小无关）。
3. 配置发现顺序：`./config.yml` → `~/.go-sqlvault/config.yml` → `/etc/go-sqlvault/config.yml`；推荐放 `~/.go-sqlvault/`，cron 里不要写 `--config`。
4. root 若是 `auth_socket`，配置 `host: localhost`（走 unix socket）且不写 password，比 `127.0.0.1` 更省事。
5. 替换 gobackup：把它的库列表搬过来 → 删它的 cron → 保留二进制/配置以便回滚。

---

## 1. COS 内网 endpoint（最大的坑）

### 症状

上传吞吐只有 ~0.9 MiB/s，一个 889 MiB 的备份要 16 分钟；CPU 很低（个位数），说明是网络瓶颈而非压缩。

### 根因

`cos.<region>.myqcloud.com` 的 DNS 解析结果决定走内网还是公网：

```bash
# 关键诊断
getent hosts cos.ap-chengdu.myqcloud.com
#   -> 183.66.100.19 / 183.66.100.32   （公网 IP：走公网，慢）
getent hosts cos-internal.ap-chengdu.myqcloud.com
#   -> 169.254.0.47                    （内网 VIP：走内网，快）
```

同一地域的 CVM，VPC DNS 有时会把**公网域名**也解析成 `169.254.0.47`（所以有的机器一直很快）；一旦解析到公网 IP，就会被公网带宽限制。

### 修复

```yaml
s3:
  endpoint: https://cos-internal.ap-shanghai.myqcloud.com   # 或 ap-chengdu 等
  region: ap-shanghai
  bucket: <bucket>
  path_style: false
```

- 内网域名的 TLS 证书 SAN 覆盖 `*.cos-internal.<region>.myqcloud.com`，虚拟主机风格（`<bucket>.cos-internal...`）可用。
- 验证：

```bash
getent hosts <bucket>.cos-internal.<region>.myqcloud.com   # 应指向 169.254.0.47
curl -sS -o /dev/null -w "http=%{http_code} ip=%{remote_ip} t=%{time_total}s\n" \
  --max-time 10 https://<bucket>.cos-internal.<region>.myqcloud.com/
# 返回 403（需鉴权）即说明 TLS/路由 OK；返回 400/证书错误才需要排查
```

### 实测对比（同一库、同一台机器）

| 指标 | 公网 endpoint | 内网 endpoint | 提升 |
|---|---:|---:|---:|
| 总耗时 | 16m23.8s | 55.9s | ~17.6x |
| 上传吞吐 | 0.90 MiB/s | 15.9 MiB/s | ~17.6x |
| raw 吞吐 | 3.1 MiB/s | 54.4 MiB/s | ~17.6x |
| CPU | 8% | 149%（多核） | 网络不再瓶颈 |

> 不要只看“同地域就应该走内网”，务必用 `getent hosts` 确认解析结果。

---

## 2. 配置发现与迁移（/etc → ~/.go-sqlvault）

发现顺序（无 `--config` 时）：

```
./config.yml  →  ~/.go-sqlvault/config.yml  →  /etc/go-sqlvault/config.yml
```

- 也支持环境变量 `GO_SQLVAULT_CONFIG` 覆盖。
- 迁移步骤：

```bash
mkdir -p ~/.go-sqlvault && chmod 700 ~/.go-sqlvault
cp -a /etc/go-sqlvault/config.yml ~/.go-sqlvault/config.yml
chmod 600 ~/.go-sqlvault/config.yml
# 删除旧目录前先备份原文件
mv /etc/go-sqlvault/config.yml /tmp/...  # 或 rm -rf /etc/go-sqlvault
```

- cron 里**去掉** `--config`：

```cron
30 3 * * * /usr/local/bin/go-sqlvault backup >> /var/log/go-sqlvault.log 2>&1
```

- cron 的 `HOME` 通常是该用户 home（root → `/root`），`~/.go-sqlvault/config.yml` 能被发现。用最小环境验证：

```bash
cd / && env -i HOME=/root PATH=/usr/local/bin:/usr/bin:/bin go-sqlvault config path
# 应输出 /root/.go-sqlvault/config.yml
```

---

## 3. MySQL 认证方式（auth_socket 的坑）

有的机器 root 用 `auth_socket`（只能本地 socket 登录，TCP 会被拒）：

```bash
mysql -uroot -e "select user,host,plugin from mysql.user;"
# root@localhost  auth_socket
mysql -h127.0.0.1 -uroot -p<pass> ...   # ERROR 1698 Access denied
mysqldump -hlocalhost -uroot ...        # 走 socket，成功
```

配置写法：

```yaml
mysql:
  host: localhost      # 关键：localhost 走 unix socket；127.0.0.1 走 TCP
  port: 3306
  username: root
  # 不写 password（auth_socket 不需要）
```

- go-sqlvault 通过临时 `--defaults-extra-file`（0600）传参，不把密码暴露在命令行。
- 若以后需要非 root 运行，另建带密码的备份账号并改回 `127.0.0.1`。

---

## 4. 从 gobackup 迁移

gobackup 的流程是 `dump → tgz → openssl 加密 → 写本地临时文件 → 上传`，非流式，且有临时文件/二次压缩开销。迁移做法：

1. **抄库列表**：读 `~/.gobackup/gobackup.yml`，把每个 model 的 `database:` 搬进 go-sqlvault 的 `mysql.databases`，`keep` 对应 `retention`。
2. **确认 gobackup 没有 systemd 服务**（通常只有 cron）：

```bash
systemctl list-units --all | grep -i gobackup
ps aux | grep -i gobackup | grep -v grep
crontab -l | grep gobackup
```

3. **删 cron 行**（先备份 crontab）：

```bash
crontab -l > /root/crontab.bak.$(date +%Y%m%d%H%M%S)
crontab -l | grep -v "gobackup perform" > /tmp/newcron
echo '30 3 * * * /usr/local/bin/go-sqlvault backup >> /var/log/go-sqlvault.log 2>&1' >> /tmp/newcron
crontab /tmp/newcron && rm -f /tmp/newcron
```

4. **保留 gobackup 二进制与配置**（不删除），仅停用，便于回滚。
5. **先小库验证再全量**：不要为了验证一次性跑所有库；挑一个小库（如几十 MB）验证，其余交给当天 cron。

---

## 5. verify 的逻辑与取舍

`go-sqlvault verify <db> [latest|ts]`：

```
S3 body → [age 解密] → [gzip 解压] → io.Discard
```

- 完整读一遍对象，从而校验：对象可下载未截断、gzip CRC/ISIZE、age AEAD 认证。
- **不**比对备份时写入的 `sha256` 对象标签，**不**校验 SQL 语义，**不**导入数据库。
- 代价：必须完整下载。内网下很快（~45 MiB/s），公网下会非常慢。
- 若已确认备份流程正常、且网络/成本敏感，可跳过 verify，仅用 `list` 确认对象存在与大小。

---

## 6. retention

- `retention.max_backups` 是全局默认；每个库的 `retention:` 覆盖它。
- 语义是**按数量**保留最新 N 份；新备份上传成功后才删最旧的（`retention_deleted` 记录删除数）。
- 混合配置示例：核心库 3 份，次要库 1 份：

```yaml
  databases:
    - name: go-nav
      retention: 3
    - name: go-slide
      retention: 1
```

---

## 7. 运维安全与常见踩坑

- **`pkill -f` 会自杀**：在 `ssh host 'pkill -f "go-sqlvault verify"'` 里，远端命令行本身包含该字符串，会把执行它的 shell 一起杀掉（SSH 退出码 255）。用正则规避：`pkill -f "go-sqlvault verif[y]"`。
- **中途 kill 上传会残留 multipart**：aws-sdk-go-v2 的 uploader 用分片上传（本项目 8 MiB/片、并发 4）。中断进程不会 abort 已上传分片，会留下未完成的分片（占用存储）。尽量避免中途杀进程；必要时到 COS 控制台/生命周期规则清理未完成分片。
- **时间戳时区**：备份 key 用 UTC（`20060102T150405Z`），日志用本地时间（`+08:00`）。`list` 里显示的是 UTC，别误判。
- **先备份再改**：改配置/换二进制前，`cp -a` 备份原文件和旧二进制；二进制先传 `*.new` 验证 `version` 再 `mv` 替换。
- **凭据不入文档**：配置文件里有 `access_key`/`secret_key`，只描述位置，不写进 skill/doc/提交。编辑配置时保留现有凭据；多台机器注意凭据一致性（密钥可能被轮换）。
- **判断备份范围要看应用配置**：以 app 的 `config.yml` 里 `database:` 为准，和实际 schema 对照。注意有些 app 不连 MySQL（只连 Redis），有些连的是别的库主机。
- **`go-sqlvault` 的 dump 参数**：默认 `--single-transaction --quick --routines --triggers --events --hex-blob --default-character-set=utf8mb4`，MySQL 追加 `--set-gtid-purged=OFF`（MariaDB 不加）。

---

## 8. 实测基线（供判断“正常/异常”）

| 场景 | raw | uploaded | 耗时 | 备注 |
|---|---:|---:|---:|---|
| 单库 go-qkpanso（内网） | 2.17 GiB | 602 MiB | 60.4s | raw ~36.9 MiB/s，upload ~10 MiB/s |
| 单库 go-youjuso（公网 endpoint） | 2.97 GiB | 889 MiB | 16m23.8s | upload ~0.90 MiB/s（异常） |
| 单库 go-youjuso（内网 endpoint） | 2.97 GiB | 889 MiB | 55.9s | upload ~15.9 MiB/s |
| 7 库全量（内网） | — | 1.94 GiB | 17m14.6s | 峰值内存 53.5 MiB |
| 小库 go-reman（内网） | 56 MiB | 11.7 MiB | 2.0s | — |

判读：CPU 很高（接近单核打满）→ 压缩瓶颈；CPU 很低但很慢 → 网络瓶颈，先查 endpoint/DNS。

---

## 9. 快速检查清单

```bash
# 1. 版本与配置
go-sqlvault version
go-sqlvault config path
go-sqlvault config check

# 2. endpoint 是否内网
getent hosts cos.<region>.myqcloud.com
getent hosts cos-internal.<region>.myqcloud.com

# 3. MySQL 认证方式
mysql -uroot -e "select user,host,plugin from mysql.user;"

# 4. 只读演练
go-sqlvault backup --dry-run

# 5. 单库真跑
/usr/bin/time -v go-sqlvault backup <small-db>

# 6. 核对对象
go-sqlvault list <db>

# 7. cron 状态
crontab -l | grep -v '^#'
```

## 回滚要点

- 配置：`cp -a ~/.go-sqlvault/config.yml.bak.* ~/.go-sqlvault/config.yml`
- 二进制：`mv /usr/local/bin/go-sqlvault.bak.* /usr/local/bin/go-sqlvault`
- 恢复 gobackup：把备份的 crontab 里 gobackup 行加回去，二进制和 `~/.gobackup/` 都还在。
