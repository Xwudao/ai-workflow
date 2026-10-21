# gate :300N 端口 X-FR 降噪（2026-10-21）

> 目标：`gate` 的 `3001~3017` 因为国内 80/443 备案限制只能以非标准端口直接暴露公网，任何人都能直连 IP 打这些端口。本方案用 **EdgeOne 回源请求头 `X-FR`** + **自有入口机注入同一头** 做一层"降噪"过滤，挡掉裸 IP 扫描与随便打端口的第三方直连。
>
> **定位：降噪，不是安全边界。** 所有 L7 头（`Host` / `X-FR` / `X-Forwarded-*`）都可伪造；EdgeOne 免费版查不到回源 IP 段，无法做真正的 IP 白名单。

## 链路与关键事实

```text
公网用户 → EdgeOne（dnse1: *.misiai.com / dnse4: *.panso.me）→ 110.40.167.56:30NN → app3
公网用户 → Cloudflare → txsp2(43.160.224.101) / alhk(47.242.228.248) → 110.40.167.56:30NN → app3
第三方/扫描器 → 110.40.167.56:30NN（直连，绕过以上两层）
```

实测结论（tcpdump on gate `ens5`）：

| 来源 | 回源 Host | 其它头 |
|---|---|---|
| EdgeOne 直连 gate | **固定为 `panso.pro`**（所有站点/所有 zone 一致） | `EO-Connecting-IP`、`CDN-Loop: TencentEdgeOne`、`X-Forwarded-For/Proto`、`X-FR=<客户端请求的原域名>`（规则引擎注入的**请求头**） |
| txsp2 / alhk | `110.40.167.56:30NN`（站点块里的 `header_up -Host`，顺带绕开腾讯"未备案域名"拦截） | `X-Forwarded-Host: <原域名>`，本次改造后额外带 `X-FR: {host}` |
| 第三方直连 | 各种（`110.40.167.56:30NN`、任意字符串） | 无 `X-FR` |

注意两个坑：

1. EdgeOne 规则如果配成"**响应头**"，源站收不到，`curl -sI` 却能看到 `x-fr:`（容易误判）。
2. 带真实域名做 `Host` 直连 gate 会被腾讯未备案拦截（`302 → dnspod.qcloud.com/static/webblock.html?d=<域名>`）；用 IP 或 `panso.pro` 当 Host 不会被拦。

## 已实施改动

### 1. txsp2 / alhk：注入 `X-FR = {host}`

`(cfproxy)` 片段与 lzpanx 站点块各加一行：

```caddyfile
header_up X-FR {host}
```

- `{host}` 已实测：去端口、转小写（`Sub.Test.Local:8080` → `sub.test.local`）。
- 备份：
  - txsp2：`/etc/caddy/Caddyfile.before-xfr-1792572872`
  - alhk：`/etc/caddy/Caddyfile.before-xfr-1792572901`

### 2. gate：17 个 `:30NN` 块引入 `(xfr)` 片段（当前版：后缀白名单正则）

```caddyfile
(xfr) {
	@no_xfr {
		not header_regexp X-FR ^(?i)([a-z0-9-]+\.)*(misiai\.com|panso\.me|lzpanx\.com|hunhepan\.com|qkpanso\.com|fuxipan\.com|kitboxpro\.com|lzpan\.com|jujuso\.com|xwd\.pw)$
		not remote_ip 127.0.0.1/32 ::1 10.0.0.0/8 172.16.0.0/12 192.168.0.0/16
	}
	respond @no_xfr "Forbidden" 403
}
```

放行条件：`X-FR` 命中**自有域名后缀**（任意层级子域、不区分大小写），或来自内网/回环。其余一律 403（含 `Host: panso.pro`、裸 IP、任意域名直连）。

演进过程（三次收紧，每次都可回滚）：

1. `not header X-FR *`（只校验头存在）+ `Host: panso.pro` 豁免 → 先保业务。
2. 删掉 `Host: panso.pro` 豁免 → 没有 `X-FR` 就 403。
3. 改成后缀白名单正则 → 连"发个 `X-FR: x`"也过不了；同时覆盖值校验。

后缀白名单选型理由：比"逐域名枚举"自动覆盖新子域（如新增 `xx.misiai.com` 无需改配置），比"只校验存在"更难猜。代价：**新增别的域名后缀的站点时必须回来补一条**。

Caddy 语义已实测：`not { A; B }` = `NOT(A or B)`，即两条都不满足才拦；`order waf after respond` 让 403 先于 WAF 短路执行。

- 覆盖端口：3001–3017（含当前无流量的 3002/3003/3008/3011/3012）。
- 备份目录：`/root/xfr-rollout-20261021/`，依次为 `Caddyfile.before-xfr`（改动前）、`before-xfr2`、`before-strict`、`before-regex`、`before-kitboxpro`、`before-loglevel`。
- 生效方式：`systemctl reload caddy`（未替换二进制，无需 restart）。

#### 日志新增字段（gate 的 `(logger)` 片段，全局生效）

```
... "{request>headers>User-Agent>[0]}" xfr="{request>headers>X-Fr>[0]}" host="{request>host}"
```

- **坑**：`{request>headers>X-FR>[0]}` 解析不到（transform encoder 按 Go 的 canonical key 精确查表，`X-FR` 在 `r.Header` 里是 `X-Fr`），必须写成 **`X-Fr`**，否则永远输出 `-`，会误判“没传头”。
- `xfr="-"` / `host="..."` 可以直接看出：某站点是否配了注入规则、回源 Host 是什么，排查不再靠 tcpdump。

#### 收紧上线顺序（重要）

1. 先上“带 `Host: panso.pro` 豁免”的宽松版，观察无业务误杀。
2. 确认 EdgeOne **所有 zone** 都已配置回源请求头 `X-FR = Host`（已确认：`*.misiai.com`、`*.panso.me`）。
3. 删掉豁免行，变成“没有 `X-FR` 就 403”。
4. 再改成后缀白名单正则。

2026-10-21 实测 `dnse4` 已生效：抓包看到 `X-FR: lz.panso.me` / `hhp.panso.me` / `panso.me`。

### 3. 漏配的 EdgeOne zone：`kitboxpro.com`（待用户处理）

`www.kitboxpro.com` 在 **EdgeOne**（`www.kitboxpro.com.eo.dnse1.com` → 43.174.246.55），回源直连 `110.40.167.56:3005`，但该 zone **没有配** `X-FR` 请求头规则，日志里 `xfr="-"`，因此被 403。

处理方式：在 EdgeOne `kitboxpro.com` 这个 zone 里补一条和 misiai/panso.me 一样的回源请求头规则（`X-FR = Host`）即可，gate 侧已把 `kitboxpro.com` 加进后缀白名单，规则一生效就通。

> 推论：**每个自有 zone 都要单独配**。以后排查“某站点 403”第一步就是看 `xfr` 字段是否为 `-`。

## Caddyfile 语法坑（实测，v2.11.4）

| 写法 | 结果 |
|---|---|
| `not header X-FR`（只给字段名，想表达"存在"） | ❌ 解析失败：`malformed header matcher: expected both field and value` |
| `not header X-FR *` | ✅ 表示"存在且值任意"（空值也算存在） |
| `not header X-FR flow.misiai.com` | ✅ 但**大小写敏感**、**只能给一个值** |
| `not header_regexp X-FR ^(?i)(a\.com|b\.com)$` | ✅ 多值 + 忽略大小写 |
| `not header Host panso.pro` | ✅ `Host` 有特殊处理，同样大小写敏感 |
| `not expression {header.X-FR} == {http.request.host}` | ✅ 可用（`{http.request.host}` 去端口、大小写敏感） |

## 验证（2026-10-21 实施后，后缀正则版）

- EdgeOne（dnse1）：`flow/nav/keyhub/revjs/tool/qk/lz/hhp.misiai.com` 均 200 / 原状态码不变（`tkapi.misiai.com` 仍为应用自身的 404）。
- EdgeOne（dnse4）：`lz.panso.me`、`hhp.panso.me` 200；`qk.panso.me` 目前 DNS 是 `→ 127.0.0.1`（EO 侧未接入完成），与本次改动无关。
- Cloudflare → txsp2：`api.hunhepan.com`、`www.lzpanx.com`、`fuxipan.com`、`qkpanso.com` 200。
- 直连 `http://110.40.167.56:30NN/` → **403**；`Host: panso.pro` → 403；`Host: evil.attacker` → 403。
- `X-FR` 值测试（直连 gate:3006）：`lz.panso.me` → 200；`www.kitboxpro.com` → 200；`x` → 403；`evil-misiai.com` → 403；`misiai.com.evil.com` → 403；`flow.misiai.com.evil` → 403；`misiai.com:3001` → 403；`LZ.PANSO.ME` → 200（不区分大小写）。
- 内网回环 `http://127.0.0.1:3015/` → 200（内网豁免生效）。
- 60s 抓包：请求来源只有 txsp2（`43.160.224.101`）与 EdgeOne 边缘节点，**没有 Cloudflare 边缘 IP 直连 gate**（即不存在“CF → 回源 IP 直连”的漏配路径）。
- 被 403（body 长度 9）的均为扫描器（`Go-http-client`、`curl`、`InternetMeasurement/1.0`、空 UA、指向无关域名的百度搜索词探测）；业务侧 403（长度 38/60/62/77）是应用自身限流/反爬，未受影响。

## 已知局限

- `X-FR` 是实现降噪的“弱口令”：任何知道头名 + 一个自有域名的人都能伪造通过（`curl -H 'X-FR: lz.panso.me' http://110.40.167.56:3006/` → 200）。
- EdgeOne → gate 是明文 HTTP，`X-FR` 在链路可见。
- 因此本方案只降低噪声规模，不能替代“入口收敛到固定 IP”的方案。

> 说明：EdgeOne 侧原先还配过“响应头 X-FR”，会把头名泄露给任何客户端；已确认该响应头现在不存在（`curl -sI` 只剩 `server/eo-*`）。若将来又加回响应头规则，头名就等于公开了。

## 回滚

```bash
# gate
sudo cp -a /root/xfr-rollout-20261021/Caddyfile.before-xfr /etc/caddy/Caddyfile && sudo systemctl reload caddy

# gate：回退到"带 Host: panso.pro 豁免"的宽松版
sudo cp -a /root/xfr-rollout-20261021/Caddyfile.before-strict /etc/caddy/Caddyfile && sudo systemctl reload caddy

# txsp2
sudo cp -a /etc/caddy/Caddyfile.before-xfr-1792572872 /etc/caddy/Caddyfile && sudo systemctl reload caddy

# alhk
sudo cp -a /etc/caddy/Caddyfile.before-xfr-1792572901 /etc/caddy/Caddyfile && sudo systemctl reload caddy
```

## 实施过程中的两次失误（务必记住）

**失误 1：按端口硬编码域名白名单。** 第一版用 `header_regexp X-FR ^(?i)(hhp\.misiai\.com|...)$`。上线后 ~4 分钟内 `lz.panso.me` / `hhp.panso.me`（`*.panso.me` 属于另一个 EdgeOne zone）的真实流量被 403 约 5600 次，随即回滚。

**失误 2：后缀列表漏了 `kitboxpro.com`。** 换成后缀正则后，`www.kitboxpro.com`（独立 EO zone，回源直连 gate:3005）被 403；从日志 `sitemap/tools.xml` 的 Referer 发现后补上。

教训：

1. EdgeOne 站点分布在多个 zone（已知 `misiai.com`、`panso.me`、`kitboxpro.com`），规则要按 zone 逐个配，极易漏。
2. **每个自有 zone 都要单独配 `X-FR` 请求头**，gate 的后缀白名单只管“值合不合法”。
3. 排障第一步：看日志 `xfr=` 字段（`-` = 站点没配规则 / 值不在白名单），第二步看 `host=`。

## 后续可选加强

1. 已完工：删掉 `Host: panso.pro` 豁免 → 后缀白名单正则。
2. 若将来 EdgeOne 提供回源 IP 段，优先改成安全组/防火墙 IP 白名单，把 `X-FR` 退化为观测手段。
3. 可考虑把回源 Host 从固定的 `panso.pro` 改成每站点随机串（需同步改 gate 上游块的 Host 处理），再叠一层。
4. 回滚点：`/root/xfr-rollout-20261021/` 下 `Caddyfile.before-regex`（存在性校验版）、`before-strict`（带 `Host` 豁免版）、`before-xfr`（完全未启用）。
