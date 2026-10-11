# txsp2：从 Sentra 切回 caddy-waf

> 2026-10-10；此前的 Sentra 迁移记录见 [txsp2-sentra-waf-migration.md](txsp2-sentra-waf-migration.md)，其中“当前状态”以本文为准。

## 拓扑与变更

公网/CDN → txsp2（Caddy :80，第一层 WAF）→ gate（部分端口有第二层 WAF）→ app3。txsp2 的 Caddy v2.11.4 已从 `github.com/Xwudao/sentra` 切回 gate 使用的 `github.com/fabriziosalmi/caddy-waf v0.4.14`（含 `with_ui`）；直接使用 txsp2 上迁移前留存的二进制，SHA-256 为 `a027867c3821d88ed8e5023ffa5804f13176a5ad672b31c1ac6cda69a972ae26`，与 gate 当前二进制一致。Cloudflare DNS、dynamicdns、transform-encoder 模块仍保留。

- 配置：`/etc/caddy/Caddyfile`；`order waf after respond`、`order waf before reverse_proxy`；WAF 宏参数参考 gate，阈值 10、请求体检查上限 1 MiB、只读 dashboard `/waf`、metrics `/waf_metrics`、JSON 日志 `/var/log/caddy/waf.json`（warn、敏感数据脱敏）。
- 规则及名单使用 txsp2 **原有** `/etc/caddy/waf/{rules.json,legacy-rules.json,ip_blacklist.txt,ip_whitelist.txt}`，并未覆盖成 gate 的名单；切换前均已备份。Sentra SQLite 在 `/var/lib/caddy/sentra/sentra.db`，已备份且未删除。**Sentra 期间在 SQLite 中新增/修改的规则或 IP 名单不会自动同步回这些旧文件**，需要另行核对迁移。
- 覆盖五组：fuxipan、lzpanx/panso.me、qkpanso、hunhepan、reman。保持切换前的 `import sentra` 覆盖范围，统一替换为 `import waf`；其余站点不变。
- 上述五组全部加入 `(waf-dashboard-local)`：非回环来源请求 `/waf`、`/waf/*`、`/waf_metrics` 返回 404；本机访问返回看板/指标。注意原 Sentra 配置仅在其中两组导入该限制，切回带看板的模块时补齐。
- 原 Sentra 的 `trusted_proxies` / `client_ip_header` 配置不再生效；和 gate 一样，此次 caddy-waf **未设置可信代理**。IP 黑名单也检查 X-Forwarded-For，而基于 REMOTE_IP 的规则/限流等使用直连地址；不要将 Cloudflare 节点 IP 当成访客 IP。详情参见 [反代拓扑](online-reverse-proxy-topology.md)。

## 操作与验证

切换前先备份 Caddyfile、二进制、WAF 文件、service 和 Sentra DB 至：

```text
/root/caddy-waf-restore-backup-20261010-071740
```

二进制与候选 Caddyfile 先在 `/tmp/caddy-waf-stage`、`/tmp/Caddyfile-waf-stage` 暂存，以 `caddy` 用户运行 `validate` 通过后才替换；替换二进制后使用 **`systemctl restart caddy`**（而非 reload）。

验证结果：服务 active；模块 `http.handlers.waf` 存在；五组站点经本机 Host 头 SQLi 测试全部返回 403；本机 Host=hunhepan.com 请求 `/waf`、`/waf_metrics` 返回 200；从 gate 直接访问 txsp2 公网地址时，五组站点两个路径均返回 404。检查示例：

```bash
ssh txsp2 'systemctl is-active caddy; caddy list-modules | grep http.handlers.waf'
ssh txsp2 'curl --noproxy "*" -s -o /dev/null -w "%{http_code}\n" -H "Host: hunhepan.com" "http://127.0.0.1/?q=1%27%20union%20select%201--"'
ssh txsp2 'curl --noproxy "*" -s -o /dev/null -w "%{http_code}\n" -H "Host: hunhepan.com" http://127.0.0.1/waf_metrics'
```

`/waf` 看板只接受回环来源且要匹配受保护站点的 Host；此前 `scripts/open-txsp-waf-dashboard.sh` 指向 Sentra 的 `127.0.0.1:2020`，切换后不适用（不要继续将该端口作为 caddy-waf 看板）。运维时可在服务器上用上面的 Host 头命令查看指标。WAF 日志使用 `/etc/logrotate.d/caddy-waf` 轮转。规则及名单后续从 `/etc/caddy/waf/` 维护；Sentra DB 不再生效。

## 回滚

```bash
ssh txsp2 'sudo install -m 0755 /root/caddy-waf-restore-backup-20261010-071740/caddy /usr/local/sbin/caddy && sudo install -m 0644 /root/caddy-waf-restore-backup-20261010-071740/Caddyfile /etc/caddy/Caddyfile && sudo systemctl restart caddy'
```

该备份还包含原规则目录、service、Sentra DB；若这些文件后来有改动，回滚时先单独备份当前版本，再按需恢复。重启后检查 service、Sentra 管理 UI 和各站点拦截行为。若需要完整撤销请确认 `/var/lib/caddy/sentra/` 权限仍为 `caddy` 可读写。服务异常时立即按上述步骤恢复；换二进制必须 restart。
