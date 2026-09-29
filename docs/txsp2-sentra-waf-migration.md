# txsp2：WAF 从 caddy-waf 迁移到 Sentra

> 完成时间：2026-09-29

## 目标

把 txsp2（`43.160.224.101`，公网入口）上当前启用 WAF 的站点，从
`github.com/fabriziosalmi/caddy-waf v0.4.14` 全部替换为自研的
[`github.com/Xwudao/sentra`](../../sentra)，并把现有 caddy-waf 规则、IP 黑/白名单
转换成 Sentra 格式。

## 结果

- Caddy：`v2.11.4`（不变）
- WAF：`fabriziosalmi/caddy-waf v0.4.14` → `github.com/Xwudao/sentra`
- 服务：`caddy.service`，`active`
- 覆盖站点（原先 import `(waf)` 的 4 组，现改为 import `(sentra)`）：
  - `fuxipan.com` / `www.fuxipan.com`
  - `lzpanx.com` / `www.lzpanx.com` / `panso.me`
  - `api.hunhepan.com` / `www.hunhepan.com` / `hunhepan.com`
  - `reman.xwd.pw`
- 规则：Sentra 内置 12 条 + caddy-waf 转换 61 条 = **73 条**
- IP 规则：**block 313 条 / allow 1 条**
- 关键参数：`anomaly_threshold 10`、`max_request_body_size 1048576`、`trusted_proxies` = Cloudflare 全部边缘网段、`client_ip_header CF-Connecting-IP`、`events_retention_days 3`

`qkpanso.com`、`m15.xwd.pw` / `m15.panso.me` 原本没有 WAF，保持不变。

## 行为变化（重要）

1. **规则换了实现**。原 caddy-waf 的 JSON 规则、`ip_blacklist.txt` 不再被读取；
   规则和 IP 名单改存 Sentra 的 SQLite（`/var/lib/caddy/sentra/sentra.db`），
   通过管理 API / UI 或 `sentra-convert` 维护。
2. **拦截日志不再写 JSON 文件**。原 `/var/log/caddy/waf.json` 停止写入；Sentra 把
   安全事件写入 SQLite，并在管理 UI / `GET /api/events` 查看。站点访问日志
   （`/var/log/caddy/*.log`）仍按原 transform 格式记录，命中拦截的请求状态为 403。
3. **客户端 IP 语义更严格**。原 caddy-waf 的 IP 黑名单会检查直连对端和所有
   `X-Forwarded-For`；Sentra 只信任来自 `trusted_proxies` 的转发头，并使用
   `CF-Connecting-IP` 作为真实客户端 IP。因此：
   - 真实访客按 `CF-Connecting-IP` 命中黑名单；
   - 伪造 `X-Forwarded-For` 无法绕过，也不会被当作真实 IP；
   - 直连的 Cloudflare 边缘节点不会再被误判为黑名单目标。
   这与当前所有入站都经 Cloudflare 的实际情况一致。
4. **不支持响应阶段规则**。caddy-waf 的 `phase: 3/4`（响应检查）在 Sentra 中
   不存在；本次迁移的两份规则文件里没有响应阶段规则，无损失。
   注意 caddy-waf 的 `phase: 1/2` 分别表示请求头和请求体，二者都是请求侧，
   已统一映射为 Sentra 的 `request` 阶段。
5. Sentra 额外带一套保守的内置规则（SQLi / XSS / 穿越 / 命令注入 / Log4Shell /
   敏感文件等），与转换规则并存，属预期覆盖。
6. 原 fabriziosalmi caddy-waf 在超时/中断请求上会打 `PANIC in ServeHTTP`
   （`net/http: abort Handler`）；迁移后不再出现。

## 事件保留与 Sentra 修复

Sentra 原实现存在两个与本次上线相关的问题，已在 sentra 仓库修复并重新构建部署：

1. **`acquire` 引用计数错误**：新建共享实例时 `refs` 未初始化为 1，多个 handler 指向同一 DB 时
   `Cleanup` 会把计数减到 0 以下，导致 `shutdownInstance` 被调用两次。已修正并新增
   `caddy/instance_test.go` 覆盖。同时 `shutdownInstance` 用 `sync.Once` 保证幂等。
2. **安全事件无保留上限**：`security_events` 只增不减，按当时约 2000 次/分钟的拦截量，
   DB 每天增长约 1.8 GB，两周左右会占满磁盘。新增 `events_retention_days` 选项
   （Caddyfile 与 JSON 均可配），由后台 janitor 启动时清理一次、之后每 6 小时清理早于
   保留窗口的事件。txsp2 设为 `3`，稳态约 5–6 GB。

对应新增：`internal/storage.PruneEvents`（含测试）、`caddy` 的 `events_retention_days`。

## 规则转换

转换工具：`sentra` 仓库新增 `cmd/sentra-convert`（含单元测试）。

```bash
# 从 txsp2 拉取源文件后，在 sentra 仓库生成 Sentra SQLite
go run ./cmd/sentra-convert \
  -db sentra.db \
  -rule rules.json -rule legacy-rules.json \
  -ip-block ip_blacklist.txt -ip-allow ip_whitelist.txt
```

映射规则：

| caddy-waf target | Sentra target |
|---|---|
| `ARGS` | `query` |
| `BODY` | `body` |
| `URI` | `uri` |
| `HEADERS` | `header` |
| `HEADERS:<Name>` | `header:<name>` |
| `COOKIES` | `cookie` |

- 所有转换规则统一加 `url_decode,remove_nulls` 归一化流水线
  （用 `-transforms` 覆盖，`-print-json` 可先审阅）。
- 转换规则 ID 加 `fw-` 前缀（例如 `fw-path-traversal`、`fw-legacy-args-1`），
  避免与 Sentra 内置规则 ID（`path-traversal`、`log4shell-jndi`、`sensitive-files` 等）冲突。
- `action` / `severity` 大小写归一；`score` / `priority` 原样保留。
- 源文件（取自 txsp2 迁移前的 `/etc/caddy/waf/`）SHA-256：

```text
76424f5585ef9f529772342c722a7a36d0f7752d882bce638c125dd8a0b5e688  rules.json
e553dd906075a905cb4512995a4b59035db6663494c0a608b634aca6f683a2fd  legacy-rules.json
03205cdec8b5ace3c82daffd15ffaa08d7b737cf8675c76a445b251cb8d55445  ip_blacklist.txt
39288f156b737d0f274d032543dbf374aee38e2b36ee776511c0988705629c8f  ip_whitelist.txt
```

## 构建

服务器在国内，二进制在本地 macOS 交叉编译后 `scp` 上传。保留原有模块，去掉
caddy-waf，加入 sentra：

```bash
cd ~/Codes/sentra
make web                      # 先构建 SPA（pnpm build + 拷入 internal/webassets/dist）
GOOS=linux GOARCH=amd64 CGO_ENABLED=0 xcaddy build v2.11.4 \
  --with github.com/Xwudao/sentra=$PWD \
  --with github.com/caddy-dns/cloudflare@v0.2.4 \
  --with github.com/caddyserver/transform-encoder@v0.0.0-20260423033309-ba4124974830 \
  --with github.com/mholt/caddy-dynamicdns@v0.0.0-20260805195708-67d107a42c02
```

> UI 走 `make web` 重新构建并 embed；改了 `web/` 后必须重跑，否则二进制里仍是旧 SPA。
> 升级只换二进制时，`internal/webassets/dist/index.html` 引用的 `assets/index-*.js|css`
> 哈希会变，`scp` 后用 `curl http://127.0.0.1:2020/` 核对新哈希即可。

- 新二进制 SHA-256：`b61417f3514ac19d44db2207a4725b92ceb4b0e302c85fca9567384883b76e5b`
  （含新版 Web 控制台，`index-TJu_xNGX.js` / `index-BbK9NhRB.css`；修复引用计数 +
  `events_retention_days`）
- 本地保存：`~/Backups/caddy-txsp2-v2.11.4-sentra-linux-amd64`
- 生成好的初始 DB（12 内置 + 61 转换规则、313 block + 1 allow）：
  SHA-256 `400a388d5319bbecca67355b6953f81ff01214fb89160ee02cde096db50d27aa`

## 关键文件与路径

```text
/etc/caddy/Caddyfile                      # (sentra) 宏替换原 (waf) 宏
/var/lib/caddy/sentra/sentra.db           # Sentra 规则/事件/设置（caddy:caddy 640）
/etc/caddy/waf/                           # 旧 caddy-waf 规则与名单，保留待回滚
/etc/caddy/rule/                          # 更早的 *.rule 源文件，保留
/usr/local/sbin/caddy                     # 新二进制
```

Caddyfile 全局顺序：`order sentra before reverse_proxy`（旧的 `order waf …` 已删除）。
管理 API/UI 监听 `127.0.0.1:2020`，仅回环可达；公网站点上的 `/waf`、`/waf/*`、
`/waf_metrics` 仍由 `(waf-dashboard-local)` 宏对非本机来源返回 404。

## 管理界面

本机运行：

```bash
./scripts/open-txsp-waf-dashboard.sh
```

脚本把本地 `127.0.0.1:13002` 转发到 txsp2 的 `127.0.0.1:2020`，访问
<http://127.0.0.1:13002/>。未配置 `admin_token`，因此管理 API 仅允许回环访问；
如需改为 bearer 鉴权，在 `(sentra)` 宏里加 `admin_token {env.SENTRA_ADMIN_TOKEN}`
并通过 systemd 注入环境变量（不要把 token 写进 Caddyfile 或文档）。

## 验证（2026-09-29）

```bash
# 四个站点对 SQLi 测试载荷均返回 403，且带 X-Sentra-Action: blocked
curl -s -o /dev/null -w '%{http_code}' -H 'Host: hunhepan.com' \
  "http://127.0.0.1/?q=1%27%20union%20select%201--"   # 403

# 管理 API 统计
curl -s http://127.0.0.1:2020/api/rules      # 73 条
curl -s http://127.0.0.1:2020/api/ip-rules   # 314 条
curl -s http://127.0.0.1:2020/api/settings   # anomaly_threshold=10, client_ip_header=CF-Connecting-IP, trusted_proxies=22
```

- 迁移前 fabriziosalmi 拦截约 1800 次/分钟；迁移后 Sentra 约 2100 次/分钟，量级一致。
- 抽样 400 条最近的 403：全部为 IP 黑名单命中，没有规则误伤。
- `403` 响应体为 10 字节（`Forbidden\n`），可与上游自带的 403 区分。

## 备份与回滚

迁移前完整备份（服务器）：

```text
/root/sentra-migration-backup-20260929-111753
```

包含：`Caddyfile`、`waf/`（含 rules / legacy-rules / ip 名单）、旧 `caddy` 二进制、
`caddy.service`、`caddy-waf.logrotate`、`SHA256SUMS`。

回滚步骤：

```bash
BK=/root/sentra-migration-backup-20260929-111753
sudo install -m 0755 "$BK/caddy" /usr/local/sbin/caddy
sudo install -m 0644 "$BK/Caddyfile" /etc/caddy/Caddyfile
sudo systemctl restart caddy
```

更换二进制/模块必须 `restart`，不能只 `reload`。

## 已知问题与后续

- `reman.xwd.pw` 一直返回 502：因为 `(cfproxy)` 会 `header_up -Host`，上游
  `110.40.167.56:3009` 依赖原始 Host。此问题在迁移前就存在（`/var/log/caddy/reman.log`
  在 09-25/09-26 已有 502），与 Sentra 无关，需要单独修（例如该站点改用不删 Host 的代理）。
- 旧 `/var/log/caddy/waf.json`（约 458 MiB）已停止写入；`/etc/logrotate.d/caddy-waf`
  仍会轮转这个静态文件。确认不再需要历史日志后可删除该文件与 logrotate 配置。
- 安全事件保留 3 天；如需更长/更短，改 Caddyfile 的 `events_retention_days` 后 `reload` 即可。
- `fw-idor-attacks`（继承自旧规则，action=log，score=2）命中量较大，属日志噪声，
  不单独触发拦截（anomaly 阈值 10）。
- 后续如迁移 gate / txhk：gate 与 txsp2 配置同源，可直接复用本流程；
  txhk 目前只有编译进去的旧 `github.com/Xwudao/caddy-waf v0.0.5` 模块、且 Caddyfile
  未启用 WAF，属于“新启用”而非“替换”。
