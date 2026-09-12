---
name: magnet-safety-rules-merge
description: 清理并合并“磁力链内容安全规则”JSON（如 go-hunhepan 的 data/magnet_link_content_safety_rules.json）——去除完整番号/编号等杂音、去重、把相似词并到同一分组、把番号补进前缀规则，并安全备份 + 重启 PM2 生效。适用于规则文件膨胀、碎片化、混入大量 VIDEO-123 番号或文件名杂音的场景。
allowed-tools: Bash(*) Bash(ssh:*) Bash(scp:*)
---

# 磁力链内容安全规则清理合并

用于整理 `go-hunhepan` 这类服务的规则文件
`data/magnet_link_content_safety_rules.json`：规则由「人工审核 + AI 审核候选批准」长期累积，
会混入两类脏数据：

1. **杂音**：完整番号（`SHKD749`、`SONE-983C`、`200GANA-2997`）、带卷/话号的标题、文件名后缀、
   纯数字、乱码串。
2. **碎片化**：同一批相似词被拆成几十条规则、多个 `(group, match_mode, weight)` 组合，
   同一词条甚至重复出现在多条规则里。

核心结论（先记住）：

- **完整番号是冗余**。程序会把「番号类词条」自动学习为**前缀规则**（`adult.code.learned`，
  `number_min/number_max` 限定编号位数），所以 keyword 规则里不该再存 `PREFIX-1234`。
- **`group` 字段只用于后台展示/筛选，不参与匹配**。匹配只看 `type / match_mode / weight /
  include_files / number_min / number_max`。因此把词条在分组间搬移是安全的。
- **规则文件会被程序回写**：后台批准候选时、以及定时审核（如每日 03:03）时都会重写。
  所以清理是**一次性整理**，之后还会再长出来；需要时重跑脚本。

## 文件结构

```json
{
  "rules": [
    {
      "type": "keyword",              // keyword | prefix（另有 pattern 可能存在于旧数据）
      "id": "adult.merged.xxxxxxxx",  // 全局唯一
      "label": "adult",
      "keywords": ["..."],            // type=keyword 用 keywords
      "weight": 90,
      "match_mode": "substring",      // substring | token | compact | exact
      "group": "adult.explicit",      // 仅展示：explicit / signal / marker / code / ai.reviewed
      "description": "...",
      "include_files": true,
      "number_min": 0,
      "number_max": 0
    },
    {
      "type": "prefix",
      "id": "adult.code.learned",
      "prefixes": ["SSIS", "SONE", "..."]  // type=prefix 用 prefixes
    }
  ]
}
```

`match_mode` 语义：`substring` 子串命中；`token` 整词命中；`compact` 去掉分隔符后命中；
`exact` 整串相等。`substring` 面最广，去重时优先级最高。

## 无源码时如何确认语义

服务是 Go 二进制、后端源码不在服务器上时，可以这样取证（注意别对 90 MB 二进制跑
`grep -aE '.{0,200}...'` 这类重正则，会超时）：

```bash
# 1) 路由 / 前端契约
ssh <host> "cd <appdir> && grep -abo '/admin/v1/magnet_link/content_safety_rules' <binary> | head"
ssh <host> "cd <appdir> && grep -abo '一键批准\|番号类词条' <binary> | head"

# 2) 把可打印串落盘后再 grep（快）
ssh <host> "cd <appdir> && tr -c '[:print:]' '\n' < <binary> > /tmp/strings.txt"
ssh <host> "grep -nE 'adult\.(explicit|signal|marker|code|ai)' /tmp/strings.txt | head"

# 3) 取某偏移附近的原文
ssh <host> "cd <appdir> && dd if=<binary> bs=1 skip=43390000 count=20000 2>/dev/null | grep -aoE '.{0,200}匹配模式.{0,200}'"
```

管理接口（前端 PUT 的 body 是 `{rules:[...]}`）：

```text
GET /admin/v1/magnet_link/content_safety_rules
PUT /admin/v1/magnet_link/content_safety_rules      # data: {rules:[...]}
```

## 清理合并流程

自包含脚本见本目录 `clean_magnet_safety_rules.py`（读取 `orig.json`，输出 `clean.json`
与 `report.md`）。先拉取线上文件：

```bash
scp <host>:<appdir>/data/magnet_link_content_safety_rules.json orig.json
python3 clean_magnet_safety_rules.py
```

脚本的关键判定（可按项目调整）：

- **番号判定**：无 CJK、无空格、含数字；命中任一即视为番号——
  单个数字串 ≥4 位；多个数字串且总位数 ≥4；`^[A-Za-z]{1,12}[-_.]?\d{2,6}[A-Za-z]{0,3}$`；
  `^[A-Za-z]{1,12}[-_.][A-Za-z]{1,3}\d{2,6}[A-Za-z]{0,3}$`；
  `^\d{2,6}[A-Za-z]{2,12}[-_.]?\d{2,6}$`（如 `200GANA-2997`）。
  保留短标记词（`r18/fc2/3p/18+/69/...`，用 `KEEP` 集合兜底）。
- **尾部编号**：迭代剥离 `Vol./Scene/Part/No./x<数字>` 和贴着的尾数（`GIRLS9`→`GIRLS`）。
  纯 CJK 词干要求 ≥3 字、纯拉丁单词要求 ≥5 字符，避免削成通用词（`尾行3`、`色界007` 不处理）。
- **去重（保留变体）**：用 `canonical`（小写、去掉标点/空格、保留各语种字母数字）分组。
  完全/大小写重复只留一个；**标点/空格变体保留全部写法并归入同一 bucket**
  （`Anissa Kate` 与 `AnissaKate` 同组，匹配面不丢）。
- **乱码/文件杂音**：`.mp4/.zip/.xp3` 等后缀、压制标记、`\d{3,4}[xX]\d{3,4}` 分辨率、
  纯数字、`FckAlHrHo` 一类无元音随机串。
- **分组收敛**：`adult.ai.reviewed` 词条并入 `explicit`（`weight≥50`）或 `signal`（`<50`）；
  未成年年龄标记（`8yo/9-yo/10yo/.../16岁`）并入 `adult.explicit` 的 `substring/weight=100`。
- **前缀回填**：从被删番号中用严格形状提取前缀补进 `adult.code.learned`
  （只收 3–8 位纯字母、排除 `COM/MONO/SIS/PPV` 之类歧义词）。

## 安全部署

先备份，再写入，然后**重启**进程确保按文件重新加载。

```bash
TS=$(date +%Y%m%d%H%M%S)
ssh <host> "cp -a <appdir>/data/magnet_link_content_safety_rules.json \
  <appdir>/data/magnet_link_content_safety_rules.json.bak-$TS"
scp clean.json <host>:/tmp/rules_clean.json

# 服务器上先校验，再用 cat 就地覆盖（保留 inode）
ssh <host> "python3 -c \"import json;d=json.load(open('/tmp/rules_clean.json'));print(len(d['rules']))\" \
  && cat /tmp/rules_clean.json > <appdir>/data/magnet_link_content_safety_rules.json \
  && md5sum <appdir>/data/magnet_link_content_safety_rules.json"
```

重启 PM2 托管的进程。**非交互 SSH 不会加载 nvm**，`pm2` 常不在 PATH：

```bash
ssh <host> "export PATH=/root/.nvm/versions/node/v24.14.0/bin:\$PATH; \
  pm2 restart <app-name>; sleep 5; pm2 describe <app-name> | grep -E 'status|uptime|restarts'"
```

## 验证

```bash
# JSON 合法 + 计数
ssh <host> "python3 -c \"import json;d=json.load(open('<appdir>/data/magnet_link_content_safety_rules.json'));\
print('rules',len(d['rules']),'terms',sum(len(r.get('keywords',[])) for r in d['rules']))\""
# 进程 online、日志无 invalid prefix / panic、接口 200
ssh <host> "cd <appdir> && grep -aiE 'invalid prefix|panic|fatal' logs/current.log | tail"
# 替换后 1 分钟内文件未被回写
ssh <host> "md5sum <appdir>/data/magnet_link_content_safety_rules.json; date"
```

## 回滚

```bash
ssh <host> "cp <appdir>/data/magnet_link_content_safety_rules.json.bak-<时间戳> \
  <appdir>/data/magnet_link_content_safety_rules.json"
ssh <host> "export PATH=/root/.nvm/versions/node/v24.14.0/bin:\$PATH; pm2 restart <app-name>"
```

## 注意事项

1. 线上文件随时可能被程序回写；**部署前立即重新拉取**，否则会覆盖掉刚批准的候选。
2. 不要把 Token、密码、JWT secret 写进脚本或文档；日志/命令输出里的凭据要脱敏。
3. `adult.ai.reviewed` 并入 `explicit` 只是改展示分组，不影响拦截；但会失去“待人工复核”的标识，
   如需要保留该语义就不要做这一步。
4. 保留权重不变以维持拦截强度；若想进一步压缩规则数，可按权重分档合并（如 `98→100`、`92/88→90`），
   但这会改变命中强度，需明确告知使用方。
5. 规则数不是越少越好：过度剥离尾部数字会把标题削成通用词，反而增加误报。
