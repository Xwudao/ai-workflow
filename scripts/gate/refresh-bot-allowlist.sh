#!/usr/bin/env bash
# 生成/更新「搜索引擎爬虫白名单」，推到 gate 的 /etc/gate-ipguard/whitelist.d/。
#
# 为什么只放"搜索类"爬虫：Googlebot / Bingbot 这类会按站点容量自适应抓取速度，
# 但在大站上仍可能持续 1-2 req/s（60-120 次/分钟），正好顶到 ipguard 的阈值上，
# 属于"合法但可能误封"的对象。AI 训练爬虫（GPTBot / ClaudeBot / Bytespider / CCBot /
# PetalBot 等）故意不放进来 —— 它们量大且通常不希望被爬，该封就封。
#
# 用法：
#   ./refresh-bot-allowlist.sh            # 下载 + 生成 + 推到 gate
#   ./refresh-bot-allowlist.sh --dry-run  # 只生成到本地 etc/bot-allowlist.txt
#
# 建议每月跑一次（Google/Bing 的段偶尔会加新的）。来源：
#   https://developers.google.com/static/crawling/ipranges/common-crawlers.json   # 原 googlebot.json
#   https://developers.google.com/static/crawling/ipranges/special-crawlers.json
#   https://www.bing.com/toolbox/bingbot.json
#
# 2026-10-21：Google 把 IP 段 JSON 从 /static/search/apis/ipranges/ 迁到 /static/crawling/ipranges/
# （旧路径 301；googlebot.json 同时改名 common-crawlers.json）。下面的地址直接用新路径，
# 避免哪天重定向被撤。fetch 用 curl -f：HTTP 4xx/5xx 直接失败，不会把 HTML 错误页写成白名单。

set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT="$DIR/etc/bot-allowlist.txt"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
DRY_RUN=0
[ "${1:-}" = "--dry-run" ] && DRY_RUN=1

fetch() { # url outfile
  if ! curl -fsSL --max-time 30 "$1" -o "$2"; then
    echo "!!! 下载失败: $1" >&2
    return 1
  fi
  [ -s "$2" ] || { echo "!!! 下载为空: $1" >&2; return 1; }
}

echo "==> 下载官方 IP 段"
fetch "https://developers.google.com/static/crawling/ipranges/common-crawlers.json" "$TMP/common.json"
fetch "https://developers.google.com/static/crawling/ipranges/special-crawlers.json" "$TMP/special.json"
fetch "https://www.bing.com/toolbox/bingbot.json" "$TMP/bingbot.json"

python3 - "$TMP" "$OUT" <<'PY'
import json, sys, datetime as dt, ipaddress
MIN_TOTAL = 300        # 低于这个数说明上游改了结构/被截断，宁可不生成也不推个残缺白名单
tmp, out = sys.argv[1], sys.argv[2]
rows = [("Google common crawlers (Googlebot 等)", f"{tmp}/common.json"),
        ("Google special crawlers (AdsBot / Mediapartners-Google 等)", f"{tmp}/special.json"),
        ("Bingbot", f"{tmp}/bingbot.json")]
lines = ["# 自动生成，勿手工编辑（scripts/gate/refresh-bot-allowlist.sh）",
         "# 生成时间: %s" % dt.datetime.now().strftime("%Y-%m-%d %H:%M:%S"),
         "# 只包含搜索类爬虫；AI 训练爬虫故意不放（需要放行就自己加）", ""]
total = 0
for label, path in rows:
    try:
        data = json.load(open(path))
    except Exception as exc:
        sys.exit("!!! 解析失败 %s: %s（不生成，避免推残缺白名单）" % (path, exc))
    prefixes = data.get("prefixes") or []
    if not prefixes:
        sys.exit("!!! %s 里没有 prefixes，格式变了？" % path)
    lines.append("# %s" % label)
    for prefix in prefixes:
        for key in ("ipv4Prefix", "ipv6Prefix"):
            value = prefix.get(key)
            if value:
                ipaddress.ip_network(value)     # 非法 CIDR 直接抛异常退出
                lines.append(value)
                total += 1
    lines.append("")
# Applebot 官方文档说明使用 17.0.0.0/8
lines += ["# Applebot", "17.0.0.0/8", ""]
total += 1
if total < MIN_TOTAL:
    sys.exit("!!! 只解析到 %d 条前缀（< %d），疑似上游变更，不生成" % (total, MIN_TOTAL))
open(out, "w").write("\n".join(lines))
print("==> 生成 %s（%d 条前缀）" % (out, total))
PY

if [ "$DRY_RUN" -eq 1 ]; then
  echo "==> dry-run，未推送。文件: $OUT"
  exit 0
fi

GATE_HOST="${GATE_HOST:-gate}"
echo "==> 推送到 $GATE_HOST:/etc/gate-ipguard/whitelist.d/bot-allowlist.txt"
ssh -o BatchMode=yes "$GATE_HOST" 'mkdir -p /etc/gate-ipguard/whitelist.d'
scp -q "$OUT" "$GATE_HOST:/etc/gate-ipguard/whitelist.d/bot-allowlist.txt"
ssh -o BatchMode=yes "$GATE_HOST" '/usr/local/bin/gate-ipguard.py --status | head -1'
