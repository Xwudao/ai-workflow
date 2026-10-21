#!/usr/bin/env python3
"""gate IP 守护：按阈值把滥用 IP 自动加入 300N 端口的黑名单（默认 dry-run，只记录不封）。

设计要点
--------
1. 只认「可信客户端 IP」：EdgeOne 的 EO-Connecting-IP / Cloudflare 的 CF-Connecting-IP。
   这两个头会被 CDN 覆盖，客户端伪造不了；而 X-Forwarded-For 是「追加」，最右段才是真的，
   为了不被投毒，这里完全不用 XFF。
2. 只统计带合法 X-FR 的请求（说明确实是从 EdgeOne / txsp2 / alhk 进来的），
   这样直连扫描器（已被 X-FR 规则 403）不会污染计数，也不会误封 CDN 边缘节点
   —— 因为 socket 对端 IP 从头到尾不参与统计和封禁。
3. 封禁落地在 gate 自己的 Caddyfile 里（生成片段 + caddy reload），不依赖 caddy-waf
   （caddy-waf 只认 XFF / X-Real-IP，能被伪造，而且不是每个 300N 端口都挂了 waf）。

用法
----
    gate-ipguard.py               # 按配置文件（默认 dry-run）
    gate-ipguard.py --enforce     # 强制启用封禁（覆盖配置文件）
    gate-ipguard.py --status      # 看当前计数与封禁
"""

import argparse
import collections
import datetime as dt
import glob
import gzip
import ipaddress
import json
import os
import re
import subprocess
import sys

TZ = dt.timezone(dt.timedelta(hours=8))
LOGDIR = "/var/log/caddy"
STATE_DIR = os.environ.get("GATE_IPGUARD_STATE", "/var/lib/gate-ipguard")
STATE_PATH = os.path.join(STATE_DIR, "state.json")
CONF_PATH = "/etc/gate-ipguard/ipguard.json"
WHITELIST_PATH = "/etc/gate-ipguard/whitelist.txt"
WHITELIST_DIR = "/etc/gate-ipguard/whitelist.d"   # 追加白名单（如搜索引擎爬虫 CIDR），按文件名排序读取
SNIPPET_PATH = "/etc/caddy/blocks/banned.caddyfile"
CADDYFILE = "/etc/caddy/Caddyfile"
ACTION_LOG = "/var/log/gate-ipguard.log"

PERMANENT = 253402300799  # 9999-12-31 23:59:59 UTC，代表“永久封禁”

DEFAULTS = {
    "mode": "dry-run",          # dry-run | enforce
    "rate_per_min": 60,         # 每分钟请求数阈值
    "rate_minutes": 3,          # 连续超阈值的分钟数
    "daily_total": 1500,        # 单日总量兜底阈值
    "ban_seconds": 1800,        # 首次封禁时长（30 分钟）
    "ban_seconds_repeat": 0,    # 同一 IP 再次越线：0 = 永久
    "ban_seconds_long": 0,      # 屡犯：0 = 永久
    "strikes_for_long": 3,      # 7 天内被处置这么多次 -> 长封
    "max_bans": 3000,           # 快照里最多保留多少条，防止配置无限膨胀
    "minute_keep": 30,          # 内存里保留多少分钟的窗口
}

BUILTIN_WHITELIST = [
    "127.0.0.0/8", "::1/128",
    "10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16", "100.64.0.0/10", "fd00::/8",
    "110.40.167.56",   # gate 自己
    "43.160.224.101",  # txsp2
    "47.242.228.248",  # alhk
]

RE_TS = re.compile(r"\[(\d\d/\w{3}/\d{4}:\d\d:\d\d:\d\d [+-]\d{4})\]")
RE_EOIP = re.compile(r'eoip="([^"]*)"')
RE_CFIP = re.compile(r'cfip="([^"]*)"')
RE_XFR = re.compile(r'xfr="([^"]*)"')
# 与 gate 的 (xfr) 正则保持一致：只有这些后缀的请求才算“自己进来的流量”
RE_XFR_OK = re.compile(
    r"^([a-z0-9-]+\.)*(misiai\.com|panso\.me|lzpanx\.com|hunhepan\.com|qkpanso\.com"
    r"|fuxipan\.com|kitboxpro\.com|lzpan\.com|jujuso\.com|xwd\.pw)$",
    re.IGNORECASE,
)


def log(message):
    stamp = dt.datetime.now(TZ).strftime("%Y-%m-%d %H:%M:%S")
    line = "%s %s" % (stamp, message)
    print(line)
    try:
        with open(ACTION_LOG, "a", encoding="utf-8") as fh:
            fh.write(line + "\n")
    except OSError:
        pass


def load_config():
    conf = dict(DEFAULTS)
    try:
        with open(CONF_PATH, encoding="utf-8") as fh:
            conf.update(json.load(fh))
    except FileNotFoundError:
        pass
    return conf


def load_whitelist():
    """内置 + whitelist.txt + whitelist.d/*.txt（如自动生成的搜索引擎爬虫 CIDR）。"""
    nets = [ipaddress.ip_network(item, strict=False) for item in BUILTIN_WHITELIST]
    paths = [WHITELIST_PATH] + sorted(glob.glob(os.path.join(WHITELIST_DIR, "*.txt")))
    for path in paths:
        try:
            with open(path, encoding="utf-8") as fh:
                for raw in fh:
                    value = raw.split("#", 1)[0].strip()
                    if not value:
                        continue
                    try:
                        nets.append(ipaddress.ip_network(value, strict=False))
                    except ValueError:
                        log("whitelist 忽略无效条目 (%s): %r" % (os.path.basename(path), value))
        except FileNotFoundError:
            continue
    return nets


def in_whitelist(ip, nets):
    try:
        addr = ipaddress.ip_address(ip)
    except ValueError:
        return False
    return any(addr in net for net in nets)


def load_state():
    try:
        with open(STATE_PATH, encoding="utf-8") as fh:
            state = json.load(fh)
    except (FileNotFoundError, json.JSONDecodeError):
        state = {}
    state.setdefault("files", {})
    state.setdefault("minutes", {})   # ip -> {"<minute_epoch>": count}
    state.setdefault("daily", {})     # "<date>" -> ip -> count
    state.setdefault("bans", {})      # ip -> {"until": epoch, "strikes": n, "reason": str}
    state.setdefault("strikes", {})   # ip -> [epoch, ...]
    return state


def save_state(state):
    os.makedirs(STATE_DIR, exist_ok=True)
    tmp = STATE_PATH + ".tmp"
    with open(tmp, "w", encoding="utf-8") as fh:
        json.dump(state, fh, separators=(",", ":"))
    os.replace(tmp, STATE_PATH)


def open_log(path):
    if path.endswith(".gz"):
        return gzip.open(path, "rt", encoding="utf-8", errors="replace")
    return open(path, encoding="utf-8", errors="replace")


def ingest(state, conf):
    """从活跃日志里增量读取新行，更新每分钟计数与当日总量。"""
    now = dt.datetime.now(TZ)
    today = now.date().isoformat()
    minute_now = int(now.timestamp() // 60)
    keep_from = minute_now - int(conf["minute_keep"])

    daily = state["daily"].setdefault(today, {})
    minutes = state["minutes"]
    seen = 0

    for path in sorted(glob.glob(os.path.join(LOGDIR, "*.log"))):
        name = os.path.basename(path)
        try:
            st = os.stat(path)
        except OSError:
            continue
        entry = state["files"].get(name)
        if not entry or entry.get("inode") != st.st_ino or st.st_size < entry.get("offset", 0):
            entry = {"inode": st.st_ino, "offset": 0}   # 新文件或已轮转
        offset = entry["offset"]
        if st.st_size == offset:
            state["files"][name] = entry
            continue

        with open(path, "rb") as fh:
            fh.seek(offset)
            for raw in fh:
                line = raw.decode("utf-8", "replace")
                seen += 1
                m = RE_XFR.search(line)
                if not m or not RE_XFR_OK.match(m.group(1).strip()):
                    continue
                ip = None
                for regex in (RE_EOIP, RE_CFIP):
                    g = regex.search(line)
                    if g and g.group(1) not in ("", "-"):
                        ip = g.group(1).strip()
                        break
                if not ip:
                    continue
                tm = RE_TS.search(line)
                if not tm:
                    continue
                try:
                    small = dt.datetime.strptime(tm.group(1), "%d/%b/%Y:%H:%M:%S %z")
                except ValueError:
                    continue
                minute = str(int(small.astimezone(TZ).timestamp() // 60))
                if int(minute) < keep_from:
                    continue
                bucket = minutes.setdefault(ip, {})
                bucket[minute] = bucket.get(minute, 0) + 1
                day_key = small.astimezone(TZ).date().isoformat()
                target = state["daily"].setdefault(day_key, {})
                target[ip] = target.get(ip, 0) + 1
            entry["offset"] = fh.tell()
            state["files"][name] = entry

    # 清理过期窗口和过期日期
    for ip in list(minutes):
        bucket = {k: v for k, v in minutes[ip].items() if int(k) >= keep_from}
        if bucket:
            minutes[ip] = bucket
        else:
            del minutes[ip]
    for day in list(state["daily"]):
        if day < (now.date() - dt.timedelta(days=2)).isoformat():
            del state["daily"][day]

    return seen


def decide(state, conf, whitelist):
    """按速率/日总量决定处置哪些 IP。"""
    now_epoch = dt.datetime.now(TZ).timestamp()
    minute_now = int(now_epoch // 60)
    today = dt.datetime.now(TZ).date().isoformat()

    rate_th = int(conf["rate_per_min"])
    span = int(conf["rate_minutes"])
    daily_th = int(conf["daily_total"])

    triggered = {}
    for ip, bucket in state["minutes"].items():
        if in_whitelist(ip, whitelist):
            continue
        # 速率：最近 span 个完整分钟，每分钟都 >= 阈值
        windows = [str(minute_now - i) for i in range(1, span + 1)]
        counts = [bucket.get(w, 0) for w in windows]
        if all(c >= rate_th for c in counts):
            triggered[ip] = "rate=%d/min x%d" % (rate_th, span)
            continue
        total = state["daily"].get(today, {}).get(ip, 0)
        if total >= daily_th:
            triggered[ip] = "daily=%d" % total

    decided = []
    for ip, reason in triggered.items():
        ban = state["bans"].get(ip)
        if ban and ban.get("until", 0) > now_epoch:
            continue                                   # 已在封禁中
        # 升级路径只看 strikes（7 天窗口内被处置的次数），不看 bans 是否还在：
        # 首次 30 分钟；第 2 次 ban_seconds_repeat；累计达 strikes_for_long 次 ban_seconds_long。
        # 0 表示永久。
        strikes = [t for t in state.get("strikes", {}).get(ip, []) if t > now_epoch - 7 * 86400]
        strikes.append(now_epoch)
        state.setdefault("strikes", {})[ip] = strikes
        if len(strikes) >= int(conf["strikes_for_long"]):
            seconds = int(conf["ban_seconds_long"])
        elif len(strikes) >= 2:
            seconds = int(conf["ban_seconds_repeat"])
        else:
            seconds = int(conf["ban_seconds"])
        until = now_epoch + seconds if seconds > 0 else PERMANENT
        state["bans"][ip] = {"until": until, "strikes": len(strikes), "reason": reason,
                             "permanent": seconds <= 0}
        decided.append((ip, seconds, reason))

    # 清理过期封禁
    expired = [ip for ip, ban in state["bans"].items()
               if not ban.get("permanent") and ban.get("until", 0) <= now_epoch]
    for ip in expired:
        del state["bans"][ip]

    return decided, expired


def render_snippet(state, conf):
    """生成 Caddyfile 片段：用 header_regexp 匹配可信 CDN 头里的封禁 IP。

    为什么用 header_regexp 而不是 header：
      - Caddy 的 header 匹配器一个 matcher 只能给一个值（多值直接报
        "malformed header matcher: expected field"），几条 IP 可以拆成多个 matcher，
        但几千条不现实。
      - header_regexp 用 RE2，几千个 `ip1|ip2|...` 分支会被编译成自动机，
        实测 3000 条时单请求耗时与 1 条无差别（~0.38ms，本地回环基线）。
    """
    now_epoch = dt.datetime.now(TZ).timestamp()
    active = [(ip, ban) for ip, ban in state["bans"].items() if ban.get("until", 0) > now_epoch]
    active.sort(key=lambda item: item[1]["until"], reverse=True)
    active = active[: int(conf["max_bans"])]

    body = []
    if active:
        alt = "|".join(ip.replace(".", "\\.") for ip, _ in active)
        body.append("@banned_eo header_regexp Eo-Connecting-Ip ^(%s)$" % alt)
        body.append('respond @banned_eo "Forbidden" 403')
        body.append("@banned_cf header_regexp Cf-Connecting-Ip ^(%s)$" % alt)
        body.append('respond @banned_cf "Forbidden" 403')
    return body, len(active)


def write_snippet(state, conf, mode):
    """只在“封禁集合”变化时写文件，避免每分钟无意义 reload。"""
    body, count = render_snippet(state, conf)
    path = SNIPPET_PATH if mode == "enforce" else SNIPPET_PATH + ".dryrun"
    os.makedirs(os.path.dirname(path), exist_ok=True)

    try:
        with open(path, encoding="utf-8") as fh:
            existing = [line.rstrip("\n") for line in fh if not line.startswith("#")]
    except FileNotFoundError:
        existing = None

    if existing == body:
        return count, False

    header = [
        "# 由 gate-ipguard.py 自动生成，勿手工编辑。",
        "# 生成时间: %s，封禁条目: %d" % (
            dt.datetime.now(TZ).strftime("%Y-%m-%d %H:%M:%S"), count),
    ]
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as fh:
        fh.write("\n".join(header + body) + "\n")
    os.replace(tmp, path)
    return count, True


def reload_caddy():
    try:
        subprocess.run(["caddy", "reload", "--config", CADDYFILE, "--adapter", "caddyfile"],
                       check=True, capture_output=True, timeout=60)
        return True
    except (subprocess.CalledProcessError, subprocess.TimeoutExpired, FileNotFoundError) as exc:
        detail = getattr(exc, "stderr", b"")
        if isinstance(detail, bytes):
            detail = detail.decode("utf-8", "replace")
        log("caddy reload 失败: %s %s" % (exc, detail.strip()[:300]))
        return False


def main():
    ap = argparse.ArgumentParser(description="gate IP 自动封禁守护（默认 dry-run）")
    ap.add_argument("--enforce", action="store_true", help="启用封禁（覆盖配置文件里的 mode）")
    ap.add_argument("--dry-run", action="store_true", help="强制 dry-run")
    ap.add_argument("--status", action="store_true", help="只打印当前状态")
    ap.add_argument("--unban", metavar="IP[,IP...]", help="解封指定 IP（会清空其 strikes）")
    args = ap.parse_args()

    conf = load_config()
    mode = conf["mode"]
    if args.enforce:
        mode = "enforce"
    if args.dry_run:
        mode = "dry-run"

    whitelist = load_whitelist()
    state = load_state()

    if args.unban:
        targets = [item.strip() for item in args.unban.split(",") if item.strip()]
        for ip in targets:
            state["bans"].pop(ip, None)
            state["strikes"].pop(ip, None)
            log("[%s] 手动解封 %s" % (mode, ip))
        count, changed = write_snippet(state, conf, mode)
        save_state(state)
        if changed and mode == "enforce":
            reload_caddy()
        print("解封后剩余封禁: %d" % count)
        return 0

    if args.status:
        now_epoch = dt.datetime.now(TZ).timestamp()
        active = {ip: ban for ip, ban in state["bans"].items() if ban.get("until", 0) > now_epoch}
        print("mode=%s 封禁中=%d 追踪中 IP=%d 白名单条目=%d"
              % (mode, len(active), len(state["minutes"]), len(whitelist)))
        for ip, ban in sorted(active.items(), key=lambda kv: kv[1]["until"], reverse=True)[:20]:
            if ban.get("permanent") or ban.get("until", 0) >= PERMANENT:
                until = "永久"
            else:
                until = dt.datetime.fromtimestamp(ban["until"], TZ).strftime("%m-%d %H:%M")
            print("  %-40s until %s  strikes=%s  %s" % (ip, until, ban.get("strikes"), ban.get("reason")))
        return 0

    lines = ingest(state, conf)
    decided, expired = decide(state, conf, whitelist)

    for ip, seconds, reason in decided:
        label = "永久" if seconds <= 0 else "%ds" % seconds
        log("[%s] 越线 %s -> 封 %s (strikes=%s)" % (mode, ip, label, state["bans"][ip]["strikes"]))
    for ip in expired:
        log("[%s] 解封 %s" % (mode, ip))

    count, changed = write_snippet(state, conf, mode)
    save_state(state)

    if changed:
        if mode == "enforce":
            ok = reload_caddy()
            log("快照更新: %d 条封禁, reload=%s" % (count, ok))
        else:
            log("[dry-run] 快照更新: %d 条封禁（未 reload，也未生效）" % count)
    return 0


if __name__ == "__main__":
    sys.exit(main())
