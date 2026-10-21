#!/usr/bin/env bash
# 把本目录的脚本 / systemd 单元推到 gate（默认 dry-run 之外什么都不改）。
#
#   ./install.sh            # 只推 .py 和 systemd 单元
#   ./install.sh --config   # 额外覆盖 /etc/gate-ipguard/{ipguard.json,whitelist.txt}
#
# 需要本地能 `ssh gate`（免密），远端是 root。

set -euo pipefail

HOST="${GATE_HOST:-gate}"
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WITH_CONFIG=0
[ "${1:-}" = "--config" ] && WITH_CONFIG=1

echo "==> 推送脚本到 $HOST"
scp -q "$DIR/gate-ipstats.py" "$HOST:/usr/local/bin/gate-ipstats.py"
scp -q "$DIR/gate-ipguard.py" "$HOST:/usr/local/bin/gate-ipguard.py"
ssh "$HOST" 'chmod +x /usr/local/bin/gate-ipstats.py /usr/local/bin/gate-ipguard.py'

echo "==> 推送 systemd 单元"
for unit in gate-ipstats.service gate-ipstats.timer gate-ipguard.service gate-ipguard.timer; do
  scp -q "$DIR/systemd/$unit" "$HOST:/etc/systemd/system/$unit"
done

ssh "$HOST" 'mkdir -p /etc/gate-ipguard/whitelist.d /etc/caddy/blocks /var/lib/gate-ipguard'

if [ -f "$DIR/etc/bot-allowlist.txt" ]; then
  echo "==> 推送搜索引擎爬虫白名单（whitelist.d/bot-allowlist.txt）"
  scp -q "$DIR/etc/bot-allowlist.txt" "$HOST:/etc/gate-ipguard/whitelist.d/bot-allowlist.txt"
fi

if [ -d "$DIR/etc/whitelist.d" ]; then
  echo "==> 推送手工白名单段（whitelist.d/*）"
  scp -q "$DIR"/etc/whitelist.d/*.txt "$HOST:/etc/gate-ipguard/whitelist.d/"
fi

if [ "$WITH_CONFIG" -eq 1 ]; then
  echo "==> 覆盖配置（ipguard.json / whitelist.txt）"
  scp -q "$DIR/etc/ipguard.json" "$HOST:/etc/gate-ipguard/ipguard.json"
  scp -q "$DIR/etc/whitelist.txt" "$HOST:/etc/gate-ipguard/whitelist.txt"
else
  echo "==> 保留服务器上的现有配置（要覆盖加 --config）"
fi

echo "==> 生效"
ssh "$HOST" 'systemctl daemon-reload && systemctl enable --now gate-ipstats.timer gate-ipguard.timer >/dev/null 2>&1; systemctl restart gate-ipstats.timer gate-ipguard.timer; systemctl list-timers gate-ipstats.timer gate-ipguard.timer --no-pager'

echo "==> 自检"
ssh "$HOST" '/usr/local/bin/gate-ipguard.py --status | head -3; echo; systemctl is-active caddy'
