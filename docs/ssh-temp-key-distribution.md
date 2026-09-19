# 临时 SSH 密钥分发记录

日期：2026-09-19
操作机：本机 macOS（`TimdeMac-mini`），工作目录 `/Users/tim/Codes/ai-workflow`

## 目的

临时生成一对 ed25519 密钥，把公钥分发到多台线上服务器，用于免密登录调试。
**私钥不进入仓库，用完应删除（见文末清理）。**

- 私钥：`/Users/tim/Codes/ai-workflow/tmp_ssh_ed25519`（权限 `600`，未纳入 git）
- 公钥：`tmp_ssh_ed25519.pub`
- 公钥指纹：`SHA256:oEdO1B7bc66PTiUKHqLPJEGG/vpVi3PTkBjrvKr76io`
- 公钥注释：`temp-TimdeMac-mini-20260919`（用于事后在 `authorized_keys` 中定位删除）

## 生成命令

```bash
cd /Users/tim/Codes/ai-workflow
ssh-keygen -t ed25519 -a 64 -N '' -C "temp-$(hostname -s)-$(date +%Y%m%d)" -f ./tmp_ssh_ed25519
```

## 分发结果

| 别名 | 结果 | 说明 |
| --- | --- | --- |
| `app3` | ✅ 已安装并校验 | 远程 `authorized_keys` 命中 `matches=1` |
| `db2` | ✅ 已安装并校验 | 同上 |
| `rd2` | ✅ 已安装并校验（登录用户 `root`，主机名 `redis2`） | 同上 |
| `es7v3` | ✅ 已安装并校验 | 同上 |
| `db` | ❌ 失败 | `kex_exchange_identification: Connection closed by remote host` |
| `es7v2` | ❌ 失败 | 同上（`42.193.20.18:2311`） |
| `es7` | ❌ 失败 | `Permission denied (publickey,password)`，该机现有免密不可用，需人工输密码 |
| `es7xx` | — | 别名不存在；按 `es7*` 推断为 `es7` / `es7v2` / `es7v3` |

本机能连通的即上表前 4 台（判断方式：`ssh -o BatchMode=yes <别名> hostname`）。

> 后续把范围扩大到所有可达别名，共 13 台装上新钥匙（详见下文
> 「~/.ssh/config 切换为 id_ed25519」章节）。

## 校验方式（推荐）

不要用“登录成功”作为校验依据，直接查公钥是否落盘：

```bash
BLOB=$(awk '{print $2}' tmp_ssh_ed25519.pub)
ssh <别名> "grep -c '$BLOB' ~/.ssh/authorized_keys"
```

期望输出 `1`；`0` 表示未安装。

## 踩坑记录

1. **`ssh-copy-id` 会误报 “All keys were skipped because they already exist”。**
   原因：它用 `ssh -o IdentitiesOnly=yes -i <key>` 试探登录来判定公钥是否已存在，
   但 `~/.ssh/config` 中 `Host` 段里写的 `IdentityFile`（如 `~/.ssh/id_rsa`）
   **不受 `-i`/`IdentitiesOnly` 约束，仍会被尝试**，于是任何 `-i` 都能登录成功，
   新钥匙被误判为“已存在”而跳过。
   - 处理：加 `-f` 强制安装：`ssh-copy-id -f -i ./tmp_ssh_ed25519.pub <别名>`
   - 同理，`ssh -i <新key> -o IdentitiesOnly=yes` 的“登录成功”也是假阳性，不能当真。
2. **`kex_exchange_identification: Connection closed`**（`db`、`es7v2`）：
   TCP 能建连，但 sshd 在版本交换阶段就断开，通常是源 IP 被 hosts.deny / fail2ban /
   云安全组限制，或 sshd 未监听该来源。需在该机侧排查，本机无法绕过。
3. 直连测试不要用 `timeout`（macOS 无该命令），用 `ssh -o ConnectTimeout=N` 即可。

## 未完成机器的补做方式（需人工交互输密码）

```bash
ssh-copy-id -f -i /Users/tim/Codes/ai-workflow/tmp_ssh_ed25519.pub es7
# db / es7v2 需先解决源 IP 被拒/sshd 侧问题后再执行同一命令
```

## 本机 ~/.ssh 备份与新钥匙落地（2026-09-19）

1. 备份：`cp -a ~/.ssh/. /Users/tim/Codes/ai-workflow/ssh-backup-<timestamp>/`
   - 备份含 `config` / `id_rsa` / `known_hosts` 等，**私钥明文**；仅 ssh-agent 的 unix socket 未复制（正常）。
   - 已写入 `.gitignore`：`ssh-backup-*/`、`tmp_ssh_ed25519*`，`git status` 中不可见。
2. 新钥匙落地为默认文件名（不覆盖原有 `id_rsa`）：

```bash
install -m 600 tmp_ssh_ed25519     ~/.ssh/id_ed25519
install -m 644 tmp_ssh_ed25519.pub ~/.ssh/id_ed25519.pub
chmod 700 ~/.ssh
```

3. 校验配对（只比 key 本体，注释字段必然不同）：

```bash
ssh-keygen -y -f ~/.ssh/id_ed25519 | awk '{print $1" "$2}'   # 与 .pub 的前两列一致即 OK
```

### 单把钥匙的连通性测试技巧

`~/.ssh/config` 里的 `IdentityFile` 会污染测试结果（见上文踩坑 1）。要真正只测一把钥匙：

```bash
ssh -F /dev/null -i ~/.ssh/id_ed25519 -o IdentitiesOnly=yes -T git@github.com
```

（GitHub 主机名/端口/用户均为标准值，`-F /dev/null` 不影响；但测试 `app3` 这类别名不行，因为别名定义就在 config 里。）

### GitHub 现状（2026-09-19 已更新并验证通过）

- 新 `~/.ssh/id_ed25519` 已加入 GitHub 账号，作为唯一身份直连返回 `Hi Xwudao!`。
- 默认连接（不指定 `-i`）实测：先尝试 `id_rsa` 被服务器**拒绝**，回退 `id_ed25519` 被接受
  （`Server accepts key: ~/.ssh/id_ed25519`）——即 GitHub 上旧 RSA key 已不再生效。
- 真实 git 操作验证通过（`git ls-remote origin`、`git push --dry-run origin main` 均 exit 0）。
- 仓库 remote：`git@github.com:Xwudao/ai-workflow.git`（ssh 协议）。
- 注意：本机访问 github.com 走的是 fake-ip 代理（解析到 `198.18.0.90`），不是直连。

## ~/.ssh/config 切换为 id_ed25519（2026-09-19 13:08 执行，经用户显式授权）

### 原因

`Host` 块里一旦写了 `IdentityFile`，OpenSSH **不会**再把默认的 `~/.ssh/id_ed25519` 追加进待选列表（
默认文件仅在未配置 `IdentityFile` 时才使用），所以 23 个别名即使装好了新钥匙，实际仍只 offer `id_rsa`
（实测 `Server accepts key: ~/.ssh/id_rsa`）。config 中并没有 `IdentitiesOnly`，早前文档里
“推断开了 IdentitiesOnly” 的说法有误，此处更正。

### 改动内容

- 正则替换 23 处（全部命中，无遗漏）：

```sh
sed -i '' -E 's#^([[:space:]]*IdentityFile[[:space:]]+)~/.ssh/id_rsa[[:space:]]*$#\1~/.ssh/id_ed25519#' ~/.ssh/config
```

- 替换后统计：`IdentityFile ... id_ed25519` = 23 行，`...id_rsa` = 0 行；与备份 `diff` = 23 删 + 23 增。
- 备份：`~/.ssh/config.bak-20260919_130623`（仓库备份目录内另有一份同名副本）。
- 回滚：`cp -p ~/.ssh/config.bak-20260919_130623 ~/.ssh/config`

### 前置：先补装新钥匙（避免换完即掉线）

用旧钥匙连上去装、**不删除旧钥匙授权**；安装前先 `grep -c` 判断是否已存在，
仅在为 0 时才用 `-f` 安装（`-f` 会跳过检查，无条件追加，重复执行会产生重复行）：

```bash
ssh-copy-id -f -i ./tmp_ssh_ed25519.pub -o IdentityFile=~/.ssh/id_rsa <别名>
```

覆盖范围（13 台可达机器，安装后逐台确认新公钥出现次数 = 1）：
`dev lh-misiai umami gate px3 app3es rd txsp txhk app3 db2 rd2 es7v3`
（`px3` 与 `txsp` 指向同一台机器。）

### 切换后的验证结果（无回归）

| 结果 | 别名 |
| --- | --- |
| ✅ 新钥匙可用（13） | dev, lh-misiai, umami, gate, px3, txsp, txhk, app3, app3es, db2, rd, rd2, es7v3 |
| ❌ 本就连不上（10） | cate, play（同网段机器已 down）、es7v2, es7, alhk, alhkv2, app1, app2, db, px2 |

- 对照组：切换前用旧钥匙探测的可达集合与上表 ✅ **完全一致** → 本次改动**未使任何机器失联**。
- 抽查 `ssh -v app3|gate|lh-misiai|rd|txhk true` 均显示 `Server accepts key: ~/.ssh/id_ed25519`。
- 旧 `id_rsa` 仍留在 `~/.ssh/`（config 已不再引用），且在上述服务器上依旧被授权，暂未清理。

### 剩余 10 台的处理

它们本就不可达（服务端拒连 / LAN 机器 down / `es7` 连旧钥匙都未授权、需密码）。
恢复可达后用旧钥匙显式补装：

```bash
ssh-copy-id -f -i ./tmp_ssh_ed25519.pub -o IdentityFile=~/.ssh/id_rsa <别名>
```

注意：这些别名的 config 已指向 `id_ed25519`，装之前 `ssh <别名>` 只会拿新钥匙去试
（失败后若服务端允许 password 认证则会提示输密码）。

### 新钥匙在四台的独立验证（绕开 config）

`ssh -F /dev/null -i ~/.ssh/id_ed25519 -o IdentitiesOnly=yes -p <port> root@<ip>` 均返回 `NEWKEY_OK`：

| 别名 | 地址 | 主机名 |
| --- | --- | --- |
| app3 | 118.89.110.51:4344 | app3 |
| db2 | 1.15.13.221:5634 | db2 |
| rd2 | 49.235.175.76:13567 | redis2 |
| es7v3 | 139.155.0.97:33689 | ubuntu |

## 清理 / 回滚

服务器侧（逐台，登录后执行；记得同时删除 `.pub` 与无 `.pub` 两处出现）：

```bash
sed -i.bak '/temp-TimdeMac-mini-20260919/d' ~/.ssh/authorized_keys
```

本机侧：

```bash
# 移除新落地/临时的钥匙
rm -f ~/.ssh/id_ed25519 ~/.ssh/id_ed25519.pub
rm -f /Users/tim/Codes/ai-workflow/tmp_ssh_ed25519 /Users/tim/Codes/ai-workflow/tmp_ssh_ed25519.pub

# 如需整体恢复到备份状态（会覆盖当前 ~/.ssh）
cp -a /Users/tim/Codes/ai-workflow/ssh-backup-<timestamp>/. ~/.ssh/ && chmod 700 ~/.ssh && chmod 600 ~/.ssh/id_rsa
```

注意：`tmp_ssh_ed25519*` 属于未跟踪文件且未写入 `.gitignore`，删除前不要 `git add -A`。
