# app3 go-hunhepan 磁力链内容安全规则清理合并

## 背景

`/root/app/go-hunhepan/data/magnet_link_content_safety_rules.json` 是 go-hunhepan 的磁力链内容安全实时拦截规则。规则由两类来源累积：

- 历史人工审核确认的规则（`group: adult.explicit / adult.signal / adult.marker / adult.code`）；
- AI 审核候选批准后写入的规则（`group: adult.ai.reviewed` / `adult.ai.learned`）。

长期累积后出现两类问题：

1. **杂音**：大量完整番号（如 `SHKD749`、`SONE-983C`、`200GANA-2997`）被当作关键词写进 keyword 规则。程序本身已支持「番号自动学习为前缀规则」（`adult.code.learned`，`number_min=2` / `number_max=6`），这些完整番号属于冗余杂音。
2. **碎片化**：同一批相似词被拆到 73 条规则、多个 `(group, match_mode, weight)` 组合里，甚至同一词条重复出现在多条规则。

## 处理结果

用 `scripts/clean-magnet-safety-rules.py` 对文件做一次性清理合并：

| 指标 | 处理前 | 处理后 |
| --- | --- | --- |
| 规则数 | 73 | 45 |
| keyword 词条 | 2616 | 2449 |
| prefix | 364 | 383 |
| 文件大小 | ~96 KB | ~83 KB |

最终分组：

- `adult.explicit` 36 条关键词规则（按 `match_mode + weight` 合并）
- `adult.marker` 4 条
- `adult.signal` 4 条
- `adult.code` 1 条前缀规则（`number_min=2` / `number_max=6`）

变化明细（可复现生成 `report.md`）：

- **release-code 130 条**：删除完整番号/编号（`PREFIX-1234`、`123PREFIX-456`、`NAME-123`、超长数字串等），并从其中提取合法前缀补进 `adult.code.learned`（新增 19 个：`AKO/BTG/DCV/DIC/GANA/HKJ/HMDNV/JDSY/KMRD/KNB/LUXU/MAAN/MIDD/MIUM/MMR/NHMSG/PSTL/SATX/UUE`）。
- **strip-number 47 条**：去掉标题尾部的卷号/话号（如 `Lex The Impaler 5` → `Lex The Impaler`、`Maximum Perversum 39` → `Maximum Perversum`、`美丽新世界1-242` → `美丽新世界`）。为避免把词条削成过于宽泛的通用词，纯 CJK 词干要求 ≥3 字，纯拉丁单词要求 ≥5 字符。
- **duplicate 29 条**：大小写/完全重复词条去重。
- **artifact / junk 8 条**：文件后缀（`.mp4/.zip/.xp3`）、压制标记、纯数字、乱码串（`AnlGpng`、`FckAlHrHo`、`t 6 6 y.c o m`）。

### 合并策略

- 相似词不再跨模式/跨分组散落：同一 `canonical` 词（忽略大小写与标点差异）的多种写法（如 `Anissa Kate` / `AnissaKate`、`Met-Art` / `MetArt`）保留全部原始写法并归入**同一条规则**（取最高优先级/权重的 bucket），避免破坏匹配面。
- `adult.ai.reviewed` 关键词并入 `adult.explicit` / `adult.signal`（按权重 ≥50 判为 explicit，<50 判为 signal）。分组字段仅用于后台展示与筛选，不参与匹配计算，因此不影响拦截强度。
- 未成年年龄标记（`8yo/9-yo/10yo/11yo/12yo/13-14yo/16yo/11años/16岁…`）统一并入 `adult.explicit` 的 `substring/weight=100` 规则，作为最高优先级信号。

## 关键事实：规则文件会被程序回写

go-hunhepan 进程会在以下时机重写该 JSON：

- 后台批准/拒绝 AI 候选时；
- 每日定时 `content_safety_review`（当前约 03:03）。

因此本次清理是一次性整理，后续程序仍会追加新的 `adult.ai.reviewed` 规则。如需长期保持整洁，可定期重跑清理脚本。

## 部署记录

- 服务器：`app3`
- 目标：`/root/app/go-hunhepan/data/magnet_link_content_safety_rules.json`
- 备份：`/root/app/go-hunhepan/data/magnet_link_content_safety_rules.json.bak-20260912171955`（替换前原文件，md5 `079515516d19192b8591f4c9d33c3124`）。
- 新文件 md5：`dbf4a8421fd8ac0381e20aa7f9ea4a15`（45 条规则，2026-09-12 17:20 写入）。
- 应用方式：写入清理后的 JSON 后，通过 PM2 重启 `go-hunhepan` 进程，确保以文件为准重新加载：`pm2 restart go-hunhepan`（pm2 位于 `/root/.nvm/versions/node/v24.14.0/bin`）。重启后进程 online，日志无 `invalid prefix`/panic，接口正常返回 200。
- 清理脚本：`scripts/clean-magnet-safety-rules.py`（本地读取 `orig.json`，输出 `clean.json` 与 `report.md`）。
- 说明：文件替换后 1 分钟内程序未回写，规则文件保持与清理结果一致。

### 验证

```bash
# JSON 合法性 + 规则/词条计数
python3 -c "import json;d=json.load(open('/root/app/go-hunhepan/data/magnet_link_content_safety_rules.json'));print(len(d['rules']))"

# 进程状态
export PATH=/root/.nvm/versions/node/v24.14.0/bin:$PATH
pm2 describe go-hunhepan | grep -E 'status|uptime|restarts'
```

### 回滚

```bash
cd /root/app/go-hunhepan/data
cp magnet_link_content_safety_rules.json.bak-<时间戳> magnet_link_content_safety_rules.json
export PATH=/root/.nvm/versions/node/v24.14.0/bin:$PATH
pm2 restart go-hunhepan
```
