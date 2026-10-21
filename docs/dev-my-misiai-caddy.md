# my.misiai.com → txsp2 Caddy → dev:8080（2026-10-20）

## 架构及变更

`https://my.misiai.com` → txsp2 `43.160.224.101:443` → WireGuard → dev `10.77.43.2:8080`（go-online-tools）。

- 使用 cloudctl 的 **aliyun** provider，先 dry-run 后 ensure，新增 `my.misiai.com` A = `43.160.224.101`，TTL 600，记录 ID `2112519950472036352`。变更前没有此名称记录。
- txsp2 `/etc/caddy/Caddyfile` 末尾新增 HTTPS 站点，`reverse_proxy 10.77.43.2:8080`，保留正常 Host 和 Caddy 默认转发头行为。访问日志 `/var/log/caddy/my.misiai.log`，复用 logger snippet。
- 由于既有全局 `auto_https disable_redirects`，另加显式 HTTP 站点，301 跳转 HTTPS；由 Caddy 自动管理证书。
- dev UFW 仅新增 `allow in on wg-txsp2 from 10.77.43.1 to 10.77.43.2 port 8080 proto tcp`，不全量信任 WG、不放行其他端口、不改变 Docker 转发保护。
- 未修改应用、WG、默认路由、现有 Caddy 站点或二进制。只进行 Caddy reload，未替换模块，无需 restart。

## 2026-10-20：按要求关闭后端连接

已删除 dev 上上述 WG → 8080 的 UFW 放行规则；Caddy 和 DNS 均保持不变，WG 不停止。删除前备份 `/var/backups/my-misiai/close-20261020-212515/ufw.before/`。

验证：txsp2 到 `10.77.43.2:8080` TCP 建连超时（4 秒），dev 本地 8080 仍返回 200，Caddy active，站点配置仍在。尝试通过 `ss -K` 清理连接时内核返回 Invalid argument；随后精确检查该地址对的 8080 established 连接为空，无残留已建立连接。公网域名现不能正常获取后端内容，可能表现为等待或网关错误。

如需重新开放，只恢复精确规则：`sudo ufw allow in on wg-txsp2 from 10.77.43.1 to 10.77.43.2 port 8080 proto tcp comment 'txsp2 Caddy my.misiai.com'`。不要整体恢复 UFW 快照。

## 安全边界（开放时）

8080 应用已通过该域名公开到互联网，未额外添加 Caddy 登录认证，也未导入既有 WAF（避免对工具请求造成未评估的限制）。应用自身认证和敏感功能权限需独立评估。即便 UFW 仅放行 txsp2，互联网用户仍能通过反向代理访问应用；如果 txsp2 被攻破，攻击者也能直接访问 dev 的这个端口。其他端口继续由原策略保护。日志可能包含 URL 和访问元数据，应避免把敏感信息放入 URL。

## 备份与部署细节

两端备份目录：`/var/backups/my-misiai/20261020-1222/`（0700）。

- txsp2：`Caddyfile.before`、`caddy.before`，以及校验日志 `validate.log`。
- dev：`ufw.before/`。

使用 `/etc/caddy/Caddyfile.my-stage` 暂存，校验成功后替换正式配置。首次 root 校验创建了 root-owned 站点日志，导致 reload 权限错误，原运行实例仍 active；随后参照已有 `lzpanx.log` 修正该新增日志的属主和权限，重新 reload 后成功。一次 SSH 在 reload 期间断开，重连确认服务 active、301 和 HTTPS 200。未通过重启规避问题。

## 验证结果

- dev 本地 `127.0.0.1:8080` HTTP 200。
- 放行前 txsp2 连接 WG:8080 超时；精确放行后 HTTP 200。
- txsp2 本地携带 Host 的 HTTP 请求返回 301。
- txsp2 本地 TLS/SNI 请求（正常校验证书）返回 200。
- 本机指定公网 IP 的 HTTPS 请求返回 200；txsp2 正常 DNS 解析后的 HTTPS 请求同样返回 200。
- aliyun API 确认 A 记录正确，txsp2 查询 `223.5.5.5` 也返回 `43.160.224.101`。本地代理 DNS 返回 fake-IP，不能用本地解析值判断真实 DNS。
- 未做长期压测或全面应用功能验证。

## 回滚

1. txsp2 删除本次新增的两个 `my.misiai.com` 站点块，临时文件校验后替换并 reload。若期间无其他配置变化，可恢复 `Caddyfile.before` 后校验并 reload；否则不要整体覆盖。
2. dev 删除本次唯一新增规则：

```sh
sudo ufw delete allow in on wg-txsp2 from 10.77.43.1 to 10.77.43.2 port 8080 proto tcp
```

3. DNS 确认仍是本次记录后撤销：

```sh
cloudctl --provider aliyun dns delete --zone misiai.com --type A --name my --id 2112519950472036352 --yes --json
```

不恢复整份 UFW 快照，以免覆盖后续规则；不删除或停止 WG，不动其他 Caddy 站点。证书和日志不包含在回滚删除范围内，继续受原权限控制。
