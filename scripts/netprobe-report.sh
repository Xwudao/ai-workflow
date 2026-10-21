#!/usr/bin/env bash
# 汇总 netprobe 探针数据（数据源：alhk / txsp2 / gate 上的 /var/log/netprobe/*.csv）
# 用法:
#   scripts/netprobe-report.sh [小时数，默认 24] [--since 2026-10-21T00:00:00Z]
# 说明: 各机 cron 每 5 分钟跑一次 /usr/local/bin/netprobe.sh，按 UTC 日期落盘 CSV。
set -euo pipefail

HOURS="${1:-24}"
HOSTS="${NETPROBE_HOSTS:-alhk txsp2 gate}"
TMP="$(mktemp)"
trap 'rm -f "$TMP"' EXIT

for h in $HOSTS; do
  ssh -o BatchMode=yes -o ConnectTimeout=15 "$h" \
    "sh -c 'awk FNR\>1 /var/log/netprobe/*.csv 2>/dev/null' | sed 's/^/$h,/' " >> "$TMP" || \
    echo "warn: $h 取数失败" >&2
done

if [ ! -s "$TMP" ]; then
  echo "没有取到任何数据" >&2
  exit 1
fi

python3 - "$TMP" "$HOURS" <<'PY'
import sys, csv, statistics, datetime, collections

path, hours = sys.argv[1], float(sys.argv[2])
cutoff = datetime.datetime.now(datetime.timezone.utc) - datetime.timedelta(hours=hours)

rows = []
with open(path) as f:
    for line in f:
        parts = line.rstrip("\n").split(",")
        if len(parts) < 11:
            continue
        host, ts, probe, loss, rtt, code, tc, ttfb, ttot, tcpok, tcpavg = parts[:11]
        try:
            t = datetime.datetime.strptime(ts, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=datetime.timezone.utc)
        except ValueError:
            continue
        if t < cutoff:
            continue
        rows.append(dict(host=host, t=t, probe=probe, loss=loss, rtt=rtt, code=code,
                         ttfb=ttfb, ttot=ttot, tcpok=tcpok, tcpavg=tcpavg))

if not rows:
    print(f"最近 {hours:g} 小时内没有数据")
    sys.exit(0)

def num(v):
    try:
        return float(v)
    except (TypeError, ValueError):
        return None

groups = collections.defaultdict(list)
for r in rows:
    groups[(r["host"], r["probe"])].append(r)

hdr = f"{'host':6} {'probe':16} {'n':>4} {'loss%':>7} {'rtt ms':>7} {'tcp ok':>8} {'tot med':>8} {'tot p90':>8} {'>1s%':>6}"
print(f"窗口: 最近 {hours:g} 小时   样本 {len(rows)}   截止 {datetime.datetime.now(datetime.timezone.utc):%Y-%m-%d %H:%M}Z")
print(hdr)
print("-" * len(hdr))

def med(xs):
    return statistics.median(xs) if xs else None

for (host, probe), rs in sorted(groups.items()):
    losses = [v for v in (num(x["loss"]) for x in rs) if v is not None]
    rtts = [v for v in (num(x["rtt"]) for x in rs) if v is not None]
    tots = [v for v in (num(x["ttot"]) for x in rs) if v is not None]
    okn, tot_n = 0, 0
    for x in rs:
        if "/" in x["tcpok"]:
            a, b = x["tcpok"].split("/")
            okn += int(a); tot_n += int(b)
    tcp_rate = f"{okn*100//tot_n}%" if tot_n else "-"
    loss_s = f"{statistics.mean(losses):.1f}" if losses else "-"
    rtt_s = f"{statistics.mean(rtts):.1f}" if rtts else "-"
    if tots:
        tots_sorted = sorted(tots)
        p90 = tots_sorted[min(len(tots_sorted) - 1, int(len(tots_sorted) * 0.9))]
        slow = sum(1 for v in tots if v > 1.0) * 100 // len(tots)
        print(f"{host:6} {probe:16} {len(rs):>4} {loss_s:>7} {rtt_s:>7} {tcp_rate:>8} "
              f"{statistics.median(tots):>8.3f} {p90:>8.3f} {slow:>5}%")
    else:
        print(f"{host:6} {probe:16} {len(rs):>4} {loss_s:>7} {rtt_s:>7} {tcp_rate:>8} "
              f"{'-':>8} {'-':>8} {'-':>6}")
PY
