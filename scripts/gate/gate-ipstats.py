#!/usr/bin/env python3
"""按天统计 Caddy 访问日志里的客户端 IP 访问次数（gate 专用，不需要任何 Caddy 插件）。

数据来源：/var/log/caddy/*.log（及其 *.log.gz 轮转文件）。gate 的 (logger) 片段已经把
可信客户端 IP 记录成三个字段：

    eoip="..."   EdgeOne 注入的 EO-Connecting-IP（EO 会覆盖客户端伪造值）
    cfip="..."   Cloudflare 注入的 CF-Connecting-IP（CF 会覆盖客户端伪造值）
    remote="..." TCP 对端 IP（直连时才是真实客户端）

取值优先级：
    请求带 X-FR（说明来自 EO / txsp2 / alhk 等 CDN 链路）
        eoip -> cfip -> X-Forwarded-For 最右一段 -> remote
    请求没有 X-FR（直连，多半是被 403 的扫描器）
        remote

输出：
    <out>/daily/<date>.tsv     "ip<TAB>hits<TAB>files<TAB>first<TAB>last"
    <out>/summary/<date>.txt   人读汇总（总量 / 独立 IP / top N / 按日志文件）

用法：
    gate-ipstats.py                      # 统计“昨天”（Asia/Shanghai）
    gate-ipstats.py --date 2026-10-21    # 统计指定日期
    gate-ipstats.py --date 2026-10-21 --top 100
"""

import argparse
import collections
import datetime as dt
import glob
import gzip
import ipaddress
import os
import re
import sys

TZ = dt.timezone(dt.timedelta(hours=8))  # Asia/Shanghai
LOGDIR = "/var/log/caddy"
OUTDIR = "/var/log/caddy-stats"
KEEP_DAYS = 180

RE_TS = re.compile(r"\[(\d\d/\w{3}/\d{4}:\d\d:\d\d:\d\d [+-]\d{4})\]")
RE_XFF = re.compile(r"^(\S+) - ")
RE_EOIP = re.compile(r'eoip="([^"]*)"')
RE_CFIP = re.compile(r'cfip="([^"]*)"')
RE_REMOTE = re.compile(r'remote="([^"]*)"')
RE_XFR = re.compile(r'xfr="([^"]*)"')
RE_ROT = re.compile(r"-(\d{4})-(\d\d)-(\d\d)T(\d\d)-(\d\d)-(\d\d)")
RE_ROT_SUFFIX = re.compile(r"-(\d{4})-(\d\d)-(\d\d)T(\d\d)-(\d\d)-(\d\d)(\.\d+)?(-size)?$")


def is_ip(value):
    if not value or value == "-":
        return False
    try:
        ipaddress.ip_address(value)
        return True
    except ValueError:
        return False


def field_ip(regex, line):
    m = regex.search(line)
    if not m:
        return None
    value = m.group(1).strip()
    return value if is_ip(value) else None


def pick_ip(line):
    """返回 (ip, how)。how 仅用于汇总说明。

    注意：轮转里的老日志没有 eoip/cfip/remote 字段（格式升级前写的），
    这时退化成用 X-Forwarded-For 的最右一段。
    """
    m = RE_XFR.search(line)
    via_cdn = bool(m and m.group(1).strip() not in ("", "-"))

    eoip = field_ip(RE_EOIP, line)
    cfip = field_ip(RE_CFIP, line)
    remote = field_ip(RE_REMOTE, line)

    xff = None
    m = RE_XFF.match(line)
    if m and m.group(1) != "-":
        for part in reversed([p.strip() for p in m.group(1).split(",")]):
            if is_ip(part):
                xff = part
                break

    if via_cdn:
        for ip, how in ((eoip, "eoip"), (cfip, "cfip"), (xff, "xff-right"), (remote, "remote")):
            if ip:
                return ip, how
        return None, None

    # 直连：remote 才是真实对端；老格式没有 remote 字段时退化到 XFF
    if remote:
        return remote, "remote"
    if xff:
        return xff, "xff-right"
    return None, None


def stats_date(day):
    """把日期窗口转成 [start, end) 的 epoch 秒。"""
    start = dt.datetime.combine(day, dt.time.min, tzinfo=TZ)
    end = start + dt.timedelta(days=1)
    return start, end


def candidate_files(logdir, window_start):
    """只扫描“轮转时间不早于当天 00:00”的文件：更早的文件不可能包含当天日志。"""
    paths = glob.glob(os.path.join(logdir, "*.log"))
    paths += glob.glob(os.path.join(logdir, "*.log.gz"))
    picked = []
    for path in paths:
        m = RE_ROT.search(os.path.basename(path))
        if m:
            try:
                stamp = dt.datetime(*(int(x) for x in m.groups()), tzinfo=TZ)
            except ValueError:
                stamp = None
        else:
            stamp = None
        if stamp is None:
            # 没有时间戳的文件：活跃日志或刚轮转的日志，按 mtime 判断
            stamp = dt.datetime.fromtimestamp(os.path.getmtime(path), TZ)
        if stamp >= window_start:
            picked.append(path)
    return sorted(picked)


def normalize_name(filename):
    """lzpan-2026-10-21T18-30-41.179-size.log.gz -> lzpan"""
    name = filename.split(".log")[0]
    return RE_ROT_SUFFIX.sub("", name) or name


def open_log(path):
    if path.endswith(".gz"):
        return gzip.open(path, "rt", encoding="utf-8", errors="replace")
    return open(path, encoding="utf-8", errors="replace")


def collect(day, logdir=LOGDIR):
    start, end = stats_date(day)
    start_epoch, end_epoch = start.timestamp(), end.timestamp()

    hits = collections.Counter()                     # ip -> 次数
    per_file = collections.defaultdict(collections.Counter)  # ip -> file -> 次数
    first_seen = {}                                  # ip -> epoch
    last_seen = {}                                   # ip -> epoch
    how = collections.Counter()                      # 取证方式
    file_totals = collections.Counter()              # file -> 总行数
    status = collections.Counter()                   # status -> 次数（仅统计窗口内）
    total = 0
    parsed = 0
    scanned = 0

    for path in candidate_files(logdir, start):
        name = normalize_name(os.path.basename(path))
        with open_log(path) as fh:
            for line in fh:
                scanned += 1
                m = RE_TS.search(line)
                if not m:
                    continue
                try:
                    ts = dt.datetime.strptime(m.group(1), "%d/%b/%Y:%H:%M:%S %z")
                except ValueError:
                    continue
                epoch = ts.timestamp()
                if not (start_epoch <= epoch < end_epoch):
                    continue
                total += 1
                ip, source = pick_ip(line)
                if not ip:
                    continue
                parsed += 1
                hits[ip] += 1
                per_file[ip][name] += 1
                how[source] += 1
                file_totals[name] += 1
                if ip not in first_seen or epoch < first_seen[ip]:
                    first_seen[ip] = epoch
                if ip not in last_seen or epoch > last_seen[ip]:
                    last_seen[ip] = epoch
                sm = re.search(r'" (\d{3}) \d+ ', line)
                if sm:
                    status[sm.group(1)] += 1
    return {
        "day": day, "total": total, "parsed": parsed, "scanned": scanned,
        "hits": hits, "per_file": per_file, "first_seen": first_seen,
        "last_seen": last_seen, "how": how, "file_totals": file_totals,
        "status": status,
    }


def fmt_epoch(epoch):
    return dt.datetime.fromtimestamp(epoch, TZ).strftime("%Y-%m-%d %H:%M:%S")


def write_outputs(result, outdir, top):
    day = result["day"]
    daily_dir = os.path.join(outdir, "daily")
    summary_dir = os.path.join(outdir, "summary")
    os.makedirs(daily_dir, exist_ok=True)
    os.makedirs(summary_dir, exist_ok=True)

    daily_path = os.path.join(daily_dir, day.isoformat() + ".tsv")
    ordered = result["hits"].most_common()
    with open(daily_path, "w", encoding="utf-8") as fh:
        fh.write("ip\thits\tfiles\tfirst\tlast\n")
        for ip, count in ordered:
            files = ",".join(sorted(result["per_file"][ip]))
            fh.write("%s\t%d\t%s\t%s\t%s\n" % (
                ip, count, files,
                fmt_epoch(result["first_seen"][ip]),
                fmt_epoch(result["last_seen"][ip]),
            ))

    summary_path = os.path.join(summary_dir, day.isoformat() + ".txt")
    with open(summary_path, "w", encoding="utf-8") as fh:
        fh.write("日期(Asia/Shanghai): %s\n" % day.isoformat())
        fh.write("请求数: %d（可解析 IP: %d，扫描行数: %d）\n"
                 % (result["total"], result["parsed"], result["scanned"]))
        fh.write("独立 IP: %d\n" % len(result["hits"]))
        if result["status"]:
            fh.write("状态码: %s\n" % " ".join(
                "%s=%d" % (code, cnt) for code, cnt in sorted(result["status"].items())))
        if result["how"]:
            fh.write("IP 取证方式: %s\n" % " ".join(
                "%s=%d" % (k, v) for k, v in result["how"].most_common()))
        fh.write("\n按日志文件:\n")
        for name, count in result["file_totals"].most_common():
            fh.write("  %-24s %d\n" % (name, count))
        fh.write("\nTop %d IP:\n" % top)
        for ip, count in ordered[:top]:
            fh.write("  %-40s %8d  %s\n" % (ip, count, ",".join(sorted(result["per_file"][ip]))))
    return daily_path, summary_path


def prune(outdir, keep_days, today):
    cutoff = (today - dt.timedelta(days=keep_days)).isoformat()
    removed = 0
    for sub in ("daily", "summary"):
        for path in glob.glob(os.path.join(outdir, sub, "*")):
            name = os.path.basename(path).split(".")[0]
            if name < cutoff:
                os.remove(path)
                removed += 1
    return removed


def main():
    ap = argparse.ArgumentParser(description="按天统计 Caddy 日志的客户端 IP 访问次数")
    ap.add_argument("--date", help="统计哪一天（YYYY-MM-DD，默认昨天，时区 UTC+8）")
    ap.add_argument("--logs", default=LOGDIR, help="日志目录，默认 %s" % LOGDIR)
    ap.add_argument("--out", default=OUTDIR, help="输出目录，默认 %s" % OUTDIR)
    ap.add_argument("--top", type=int, default=30, help="汇总里列出前 N 个 IP，默认 30")
    ap.add_argument("--keep-days", type=int, default=KEEP_DAYS, help="结果保留天数，默认 %d" % KEEP_DAYS)
    args = ap.parse_args()

    today = dt.datetime.now(TZ).date()
    if args.date:
        day = dt.date.fromisoformat(args.date)
    else:
        day = today - dt.timedelta(days=1)

    result = collect(day, args.logs)
    daily_path, summary_path = write_outputs(result, args.out, args.top)
    removed = prune(args.out, args.keep_days, today)

    print("%s: 请求 %d，独立 IP %d -> %s"
          % (day.isoformat(), result["total"], len(result["hits"]), daily_path))
    if removed:
        print("清理过期结果 %d 个" % removed)
    return 0


if __name__ == "__main__":
    sys.exit(main())
