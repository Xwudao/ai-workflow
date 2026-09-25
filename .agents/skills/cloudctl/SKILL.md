---
name: cloudctl
description: 使用 cloudctl 统一 Cloud CLI 管理云资源（当前支持 Cloudflare DNS）。当任务需要查询/创建/更新/删除 DNS 记录、查看 zone，或需要多云 Provider 抽象时使用本 skill。
allowed-tools: Bash(cloudctl:*)
---

# cloudctl skill

`cloudctl` 是面向 AI Agent 的统一 Cloud CLI。当前实现 Cloudflare DNS
（A / AAAA / CNAME / TXT / MX）。命令稳定、非交互、支持 `--json`。

## 核心约定

- 二进制名：`cloudctl`
- 所有命令支持 `--json`，输出稳定 envelope；JSON 模式下 stdout 只有 envelope。
- 所有核心命令完全非交互，不要依赖交互 prompt。
- 修改类命令支持 `--dry-run`，先看计划再执行。
- `ensure` 幂等，优先使用它而不是 create/update 组合。
- `delete` 是危险操作，必须传 `--yes`（不会弹确认）；也可先用 `--dry-run` 预览。
- secret（API token）永不输出；不要把 token 写进日志或回显。

## JSON 输出

成功：

    {"ok": true, "data": {}}

失败：

    {"ok": false, "error": {"code": "record_not_found", "message": "..."}}

判断错误请使用 `error.code`（稳定），不要解析 message。

常见错误码：

| code | 含义 |
| --- | --- |
| `invalid_argument` | 参数缺失 / 非法 |
| `confirmation_required` | 危险操作缺少 `--yes` |
| `already_exists` | 资源已存在 |
| `record_not_found` | 没有匹配的 DNS 记录 |
| `record_ambiguous` | 匹配到多条 DNS 记录 |
| `zone_not_found` | zone 不存在 |
| `authentication_failed` | 凭证被拒绝（401） |
| `permission_denied` | 权限不足（403） |
| `rate_limited` | 被限流 |
| `provider_not_configured` | 未配置 / 未选择 provider |
| `provider_error` | 云厂商通用错误 |
| `config_error` | 配置文件错误 |
| `internal_error` | cloudctl 内部错误 |

退出码：`0` 成功，非 `0` 失败（业务错误看 `error.code`）。

## 全局参数

    --json                 稳定 JSON envelope
    --provider <profile>   选择配置 profile
    --config <path>        指定配置文件（默认 ~/.config/cloudctl/config.yaml）
    --timeout <duration>   单命令超时（默认 30s）

环境变量：`CLOUDCTL_CONFIG`、`CLOUDCTL_PROVIDER`、
`CLOUDCTL_<TYPE>_API_TOKEN`（如 `CLOUDCTL_CLOUDFLARE_API_TOKEN`）。

## 配置与 Provider

    cloudctl init
    cloudctl init --type cloudflare --api-token "$CLOUDFLARE_API_TOKEN"
    cloudctl provider list --json

一个 provider type 可以有多个 profile（多账号），用 `--provider <profile>` 选择。

## 查询

    cloudctl dns zones --json
    cloudctl dns list --zone example.com --json
    cloudctl dns list --zone example.com --type A --json
    cloudctl dns get --zone example.com --name api.example.com --json
    cloudctl dns get --zone example.com --name api --type A --json

对应 `data`：`{"zones":[...]}`、`{"zone":"...","records":[...]}`、
`{"record":{...}}`。

## 创建 / 更新 / 删除

    cloudctl dns create --zone example.com --type A --name api --content 1.2.3.4 --json
    cloudctl dns update --zone example.com --type A --name api --content 5.6.7.8 --json
    cloudctl dns delete --zone example.com --type A --name api --yes --json
    cloudctl dns delete --zone example.com --type A --name api --dry-run --json

可选字段：`--ttl`（`1` = 自动）、`--proxied`（仅 A/AAAA/CNAME）、
`--priority`（MX 必填）。`--id` 可用于精确定位记录。

## 幂等 ensure（推荐）

    cloudctl dns ensure --zone example.com --type A --name api --content 1.2.3.4 --json

行为：

- 记录不存在 → `action: create`
- 记录存在但内容不同 → `action: update`
- 记录已完全一致 → `action: none`，不调用任何写 API

只强制传入的字段：不传 `--ttl` 就不会修改已有记录的 TTL。

修改类命令的 `data` 是 MutationResult：

    {
      "action": "update",
      "changed": true,
      "dry_run": false,
      "before": { "...": "..." },
      "after":  { "...": "..." }
    }

## 名称规则

`--name` 支持短名或完整域名：

- `--name api` → `api.example.com`
- `--name api.example.com` → 原样
- `--name @` → zone 根域

## 推荐 Agent 流程

1. `cloudctl dns ensure --zone ... --type ... --name ... --content ... --dry-run --json`
   查看计划（`action` / `changed` / `before` / `after`）。
2. 确认后去掉 `--dry-run` 执行；或直接重复调用 `ensure`（幂等）。
3. 按 `error.code` 处理失败：
   - `record_ambiguous`：用 `--content` 或 `--id` 收窄后再操作。
   - `record_not_found`：确认 zone / name / type。
   - `confirmation_required`：删除时补 `--yes`。

## skills 自管理

    cloudctl skills            # 在当前目录写入 .agents/skills/cloudctl/SKILL.md
    cloudctl skills show       # 打印本 skill 内容

> 本文件由 `cloudctl skills` 生成，内容随 cloudctl 版本更新。
