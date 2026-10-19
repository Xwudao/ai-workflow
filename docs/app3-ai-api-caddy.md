# app3：部署 Caddy 并为 ai-api.misiai.com 提供自动 TLS

> 完成时间：2026-10-19

## 背景

`ai-api.misiai.com` 原为 CNAME 到腾讯 EdgeOne（`*.eo.dnse1.com`），回源到一个 Caddy。
现改为解析到 app3 公网 IP `118.89.110.51`，由 app3 新增的 Caddy 直接提供 TLS 并反代
本机 `go-ai-api`（`127.0.0.1:5384`）。

## 变更内容

### 1. 二进制

从 gate 复制同款 Caddy（含 caddy-waf 等模块）：

- 源：gate `/usr/local/sbin/caddy`
- 版本：`v2.11.4`
- SHA256：`a027867c3821d88ed8e5023ffa5804f13176a5ad672b31c1ac6cda69a972ae26`
- 目标：app3 `/usr/local/sbin/caddy`（先落到 `/root/caddy-v2.11.4-waf.tmp` 校验后再 install）

app3 此前无 Caddy，无旧二进制/配置需要备份。

### 2. 系统与目录

```bash
useradd --system --home /var/lib/caddy --shell /usr/sbin/nologin caddy
mkdir -p /etc/caddy /var/log/caddy /var/lib/caddy
chown -R caddy:caddy /var/log/caddy /var/lib/caddy
```

systemd 单元：`/etc/systemd/system/caddy.service`（与 gate 一致，`User=caddy`，
`AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE`），已 `enable --now`。

### 3. Caddyfile

`/etc/caddy/Caddyfile`：

```caddyfile
(proxy) {
	reverse_proxy {
		{args[:]}
		header_up -Host
		header_up X-Real-IP {http.request.remote.host}
		header_up X-Forwarded-For {http.request.remote.host}
	}
}

(logger) {
	log {
		output file /var/log/caddy/{args[0]} {
			roll_size 10M
			roll_local_time
			roll_keep 10
			roll_keep_for 240h
		}
		format transform `...` {
			time_format "02/Jan/2006:15:04:05 -0700"
		}
	}
}

ai-api.misiai.com {
	import proxy to 127.0.0.1:5384
	import logger ai-api.misiai.com.log
}
```

说明：

- 未设置 `auto_https disable_redirects`，保留 Caddy 默认 `:80 → :443` 跳转。
- 证书由 Caddy 通过 Let's Encrypt HTTP-01 自动申请/续期，存储于 `/var/lib/caddy`。
- `header_up -Host` 沿用 gate 的代理语义。
- 客户端 IP 头**不能**沿用 gate 面向 CDN 的写法 `header_up X-Forwarded-For {header.X-Forwarded-For}`：
  该写法依赖上游 CDN 已经注入 `X-Forwarded-For`，直连场景下该头为空，会把 XFF 覆盖成空值，
  应用回退到 `RemoteAddr`（Caddy 从 `127.0.0.1` 发起反代）从而记成 `127.0.0.1`。
  现在显式设置：

  ```caddyfile
  header_up X-Real-IP {http.request.remote.host}
  header_up X-Forwarded-For {http.request.remote.host}
  ```

  顺带消除了客户端伪造 `X-Forwarded-For` 绕过 IP 限流 / 写错误来源 IP 的风险。
  若未来重新在 app3 前面加 CDN/反代，应改为配置 `trusted_proxies`（仅可信 CDN 出口网段）
  并让 Caddy 自行计算 XFF，而不是写死 `remote.host`。
- 日志：`/var/log/caddy/ai-api.misiai.com.log`，10 MiB 轮转、保留 10 份 / 240h。

### 4. UFW

app3 原策略为默认拒绝入站，仅放行 `4344/tcp` 和 gate。为让公网访问 `:80`/`:443`：

```bash
ufw allow 80/tcp
ufw allow 443/tcp
```

### 5. DNS

通过 `cloudctl --provider aliyun` 操作（`misiai.com` 在阿里云云解析）：

```bash
# 删除原 CNAME ai-api.misiai.com → ai-api.misiai.com.eo.dnse1.com
cloudctl --provider aliyun dns delete --zone misiai.com --type CNAME --name ai-api --yes --json
# 新建 A 记录
cloudctl --provider aliyun dns create --zone misiai.com --type A --name ai-api --content 118.89.110.51 --ttl 600 --json
```

原 CNAME 记录 ID：`2091793089651680256`；新 A 记录 ID：`2112013108448724992`。

## 验证结果

- `systemctl is-active caddy` → `active`
- 监听：`*:80`、`*:443`
- Let's Encrypt 证书签发成功（`certificate obtained successfully`）
- 本机 `--resolve ...:127.0.0.1` 与 gate 侧 `https://ai-api.misiai.com/` 均返回 `200`，TLS 校验通过（`ssl_verify_result=0`）
- 客户端 IP：从 gate 发起请求时应用日志记录为 gate 公网 IP `110.40.167.56`；
  携带伪造 `X-Forwarded-For: 9.9.9.9` 时仍记录 `110.40.167.56`，伪造头被覆盖

## 回滚

1. 删除/停用 app3 Caddy：

   ```bash
   systemctl disable --now caddy
   ufw delete allow 80/tcp
   ufw delete allow 443/tcp
   ```

2. DNS 恢复 EdgeOne CNAME：

   ```bash
   cloudctl --provider aliyun dns delete --zone misiai.com --type A --name ai-api --yes --json
   cloudctl --provider aliyun dns create --zone misiai.com --type CNAME --name ai-api --content ai-api.misiai.com.eo.dnse1.com --ttl 600 --json
   ```

3. 如需彻底移除：删除 `/usr/local/sbin/caddy`、`/etc/caddy`、`/var/lib/caddy`、
   `/var/log/caddy`、`/etc/systemd/system/caddy.service`，并 `userdel caddy`。

## 注意

- app3 公网 IP 为 `118.89.110.51`；腾讯云安全组需放行入站 TCP `80`/`443`（已在主机 UFW 放行，安全组需在控制台确认）。
- 若后续把 DNS 切回 EdgeOne，记得同步回源/证书策略，避免与 app3 Caddy 的 HTTP-01 冲突。
