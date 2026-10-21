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
#   https://developers.google.com/static/search/apis/ipranges/googlebot.json
#   https://developers.google.com/static/search/apis/ipranges/special-crawlers.json
#   https://www.bing.com/toolbox/bingbot.json

set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT="$DIR/etc/bot-allowlist.txt"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
DRY_RUN=0
[ "${1:-}" = "--dry-run" ] && DRY_RUN=1

fetch() { # url outfile
  curl -sL --max-time 30 "$1" -o "$2"
  [ -s "$2" ] || { echo "!!! 下载失败: $1" >&2; return 1; }
}

echo "==> 下载官方 IP 段"
fetch "https://developers.google.com/static/search/apis/ipranges/googlebot.json" "$TMP/googlebot.json"
fetch "https://developers.google.com/static/search/apis/ipranges/special-crawlers.json" "$TMP/special.json"
fetch "https://www.bing.com/toolbox/bingbot.json" "$TMP/bingbot.json"

python3 - "$TMP" "$OUT" <<'PY'
import json, sys, datetime as dt
tmp, out = sys.argv[1], sys.argv[2]
rows = [("Googlebot", f"{tmp}/googlebot.json"),
        ("Google special crawlers (AdsBot 等)", f"{tmp}/special.json"),
        ("Bingbot", f"{tmp}/bingbot.json")]
lines = ["# 自动生成，勿手工编辑（scripts/gate/refresh-bot-allowlist.sh）",
         "# 生成时间: %s" % dt.datetime.now().strftime("%Y-%m-%d %H:%M:%S"),
         "# 只包含搜索类爬虫；AI 训练爬虫故意不放（需要放行就自己加）", ""]
total = 0
for label, path in rows:
    try:
        data = json.load(open(path))
    except Exception as exc:
        print("!!! 解析失败 %s: %s" % (path, exc), file=sys.stderr)
        continue
    lines.append("# %s" % label)
    for prefix in data.get("prefixes", []):
        for key in ("ipv4Prefix", "ipv6Prefix"):
            value = prefix.get(key)
            if value:
                lines.append(value)
                total += 1
    lines.append("")
# Applebot 官方文档说明使用 17.0.0.0/8
lines += ["# Applebot", "17.0.0.0/8", ""]
total += 1
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
