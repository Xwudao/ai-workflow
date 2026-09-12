#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Clean + merge magnet_link_content_safety_rules.json

1. 去除杂音: full 番号 (PREFIX-1234 / 123PREFIX-456 / NAME-123), file artifacts
   (extensions, resolutions, encode tags), pure numbers, garbage blobs.
2. 合并类似词: strip trailing volume/episode numbers, dedupe case/format
   variants, fold adult.ai.reviewed + adult.code keywords into the canonical
   adult.explicit / adult.signal / adult.marker groups, one rule per
   (group, match_mode, weight).  Code prefixes are re-merged into adult.code.
"""
import json, re, hashlib, unicodedata
from collections import OrderedDict, defaultdict

SRC, OUT, REPORT = 'orig.json', 'clean.json', 'report.md'

CJK = re.compile(r'[\u3000-\u9fff\uff00-\uffef\u3040-\u30ff\uac00-\ud7af]')
EXT = re.compile(r'\.(mp4|mkv|avi|wmv|zip|rar|7z|xp3|jpg|jpeg|png|gif|torrent|txt|srt|ass)\s*$', re.I)
RES = re.compile(r'\d{3,4}\s*[xX]\s*[_]?\s*\d{3,4}')
ENCODE_TAG = re.compile(r'logo\s*&\s*title|no\.?\s*watermark|uncensored\s+version', re.I)

# short code-like markers that are meaningful and must survive
KEEP = {
    'r18','fc2','fc2ppv','3dh','3dhgame','3p','4p','2cst','18+','69','2 on 1',
    'xxx','xxxmas','jav','nsfw','onlyfans','av','bj','dp','sm','ts','js','ntr',
    'joi','pov','bbw','bbc','bdsm','cbt','cfnm','milf','pthc','pedo','pedomutter',
    'pedovater','pedogranny','sod','atm','ir','cp','j8','bb','pmv','dap',
}
JUNK = {'fckalhrho', 'anlgpng', 'of', 'no', 'the', 'and', 'a', 'css.e145'}
AGE = re.compile(r'''(?ix)
    ^ \s* \d{1,2} \s* (?:-\s*(?:\d{1,2}\s*)?)?
    (?:yo|y\.?o\.?|yrs?|years?|años?|anos?|岁) \s* $
    | ^ \s* \d{1,2} \s*岁
''')
PREFIX_STOP = {
    'mm','us','md','gl','ff','sm','co','sw','ms','kv','gar','red','real','same',
    'one','sex','iv','dc','cm','jc','dp','bj','av','ir','ai','sod','at','e','r',
    'c','j','s','ts','bb','atm','nr','h','k','n','p','qc','ii','ss','mm',
    'sis','touch','pthc','big','fan','crt','com','mono','het','css','tle','may',
    'paco','mega','best','hot','new','xxx','pro','max',
}

# strict shapes for learning a prefix from a dropped 番号
PC1 = re.compile(r'^([A-Za-z]{2,8})[-_.]?\d{2,6}[A-Za-z]{0,3}$')
PC2 = re.compile(r'^\d{2,6}([A-Za-z]{2,10})[-_.]?\d{2,6}$')
PC3 = re.compile(r'^([A-Za-z]{1,8})[-_.][A-Za-z]{1,3}\d{2,6}[A-Za-z]{0,3}$')

def code_prefix(t):
    for pat in (PC1, PC2, PC3):
        m = pat.match(t)
        if m:
            p = m.group(1).upper()
            if 3 <= len(p) <= 8 and p.isalpha() and p.lower() not in PREFIX_STOP:
                return p
    return None

def has_cjk(s):
    return bool(CJK.search(s))

def canon(s):
    """lowercase, keep only letters/digits of any script -> dedupe key."""
    return ''.join(ch for ch in s.lower() if unicodedata.category(ch)[0] in ('L', 'N'))

def letter_runs(s):
    return re.findall(r'[A-Za-z]{2,12}', s)

def is_code(t):
    """return True if the term is a release 番号 / code, not a title."""
    s = t.strip()
    if s.lower() in KEEP or has_cjk(s) or ' ' in s:
        return False
    if AGE.match(s):
        return False
    if not re.search(r'\d', s):
        return False
    runs = re.findall(r'\d+', s)
    if any(len(r) >= 4 for r in runs):
        return True
    if len(runs) >= 2 and sum(len(r) for r in runs) >= 4:
        return True
    if re.fullmatch(r'[A-Za-z]{1,12}[-_.]?\d{2,6}[A-Za-z]{0,3}', s):
        return True
    if re.fullmatch(r'[A-Za-z]{1,12}[-_.][A-Za-z]{1,3}\d{2,6}[A-Za-z]{0,3}', s):
        return True
    if re.fullmatch(r'[A-Za-z]{1,6}[-_.][A-Za-z]{1,3}[-_.]\d{2,6}', s):
        return True
    if re.fullmatch(r'\d{2,6}[A-Za-z]{2,12}[-_.]?\d{2,6}', s):
        return True
    return False

def is_artifact(t):
    if EXT.search(t):
        return 'file-extension'
    if RES.search(t):
        return 'resolution'
    if ENCODE_TAG.search(t):
        return 'encode-tag'
    if re.fullmatch(r'[a-z]{2,5}(\.\d{2,4}){2,}', t):
        return 'date-junk'
    return None

def is_junk(t):
    s = t.strip()
    if re.fullmatch(r'\d{3,}', s):
        return 'pure-number'
    if t.strip().lower() in JUNK:
        return 'garbage'
    if re.search(r'\S\s{2,}\S', s):
        return 'spaced-site-junk'
    return None

TRAIL = re.compile(r'''(?ix)
    (?:
        [\s._-]+(?:vol\.?|scene|part|pt\.?|no\.?|ep\.?|chapter|ch\.?|series|season)?\s*\.?\s*
      | [\s._-]+x\s*
      | (?<=[\u3000-\u9fff\uff00-\uffef\u3040-\u30ff\uac00-\ud7af])
    )
    (\d{1,4})
    \s*$''')
TRAIL_ATTACHED = re.compile(r'(?<=[A-Za-z])\d{1,3}$')

def strip_trailing(t):
    """iteratively strip trailing episode/volume numbers from titles."""
    cur = t.strip()
    changed = True
    while changed:
        changed = False
        if cur.lower() in KEEP:
            break
        m = TRAIL.search(cur)
        if m:
            base = cur[:m.start()].strip(' ._-')
            if len(base) >= 2 and not _too_generic(base):
                cur = base
                changed = True
                continue
        m = TRAIL_ATTACHED.search(cur)
        if m and (' ' in cur or re.search(r'[._-]', cur)):
            base = cur[:m.start()].strip(' ._-')
            if len(base) >= 4:
                cur = base
                changed = True
                continue
    # strip a trailing 'x<digits>' / bare 'x' marker (e.g. 强 奸系列x7)
    cur = re.sub(r'(?i)[\s._-]*[xX]\s*\d{1,4}\s*$', '', cur).strip(' ._-')
    cur = re.sub(r'(?<=[\u3000-\u9fff\uff00-\uffef\u3040-\u30ff\uac00-\ud7af])[xX]\s*$', '', cur).strip(' ._-')
    # drop leftover dangling volume words (must be separator-delimited)
    cur = re.sub(r'(?i)[\s._-]+(?:vol|no|scene|part|pt|series|season)\.?$', '', cur).strip(' ._-')
    return cur

def _too_generic(base):
    if has_cjk(base):
        # keep at least 3 CJK chars so 尾行/色界 don't become generic stems
        return len(re.findall(r'[\u3000-\u9fff\uff00-\uffef\u3040-\u30ff\uac00-\ud7af]', base)) < 3
    if ' ' in base or re.search(r'[._-]', base):
        return False
    return base.isalpha() and len(base) < 5

def main():
    data = json.load(open(SRC, encoding='utf-8'))
    rules = data['rules']

    prefixes, terms = set(), []
    for r in rules:
        if r.get('type') == 'prefix':
            prefixes.update(p.strip() for p in r.get('prefixes', []))
            continue
        for t in r.get('keywords', []):
            terms.append(dict(text=t, group=r.get('group', ''),
                              weight=r.get('weight', 0),
                              mode=r.get('match_mode', 'substring')))

    removed = []

    # 1. noise -------------------------------------------------------------
    stage = []
    for x in terms:
        t = x['text'].strip()
        if not t:
            removed.append((x['text'], 'empty')); continue
        if is_code(t):
            removed.append((x['text'], 'release-code')); continue
        a = is_artifact(t)
        if a:
            removed.append((x['text'], 'artifact:' + a)); continue
        j = is_junk(t)
        if j:
            removed.append((x['text'], 'junk:' + j)); continue
        x['text'] = t
        stage.append(x)

    # 2. strip trailing episode / volume numbers ---------------------------
    for x in stage:
        b = strip_trailing(x['text'])
        if b != x['text'] and len(b) >= 2:
            removed.append((x['text'], 'strip-number -> ' + b))
            x['text'] = b

    # 3. dedupe (canonical); keep distinct raw variants in one bucket -------
    RANK = {'substring': 3, 'compact': 2, 'token': 2, 'exact': 1}
    groups = defaultdict(list)
    for x in stage:
        k = canon(x['text'])
        if not k:
            removed.append((x['text'], 'empty-canon')); continue
        groups[k].append(x)
    kept = []
    for k, entries in groups.items():
        best = max(entries, key=lambda x: (RANK.get(x['mode'], 0), x['weight']))
        seen = {}
        for x in entries:
            lk = x['text'].lower()
            if lk in seen:
                removed.append((x['text'], 'duplicate -> ' + seen[lk]))
                continue
            seen[lk] = x['text']
        # all punctuation/space variants land in the *same* (best) bucket
        for txt in seen.values():
            kept.append(dict(text=txt, group=best['group'],
                             weight=best['weight'], mode=best['mode']))

    # 3b. learn proper prefixes from dropped 番号 --------------------------
    for t, why in removed:
        if why == 'release-code':
            p = code_prefix(t)
            if p:
                prefixes.add(p)

    # 4. canonical group + bucket -----------------------------------------
    def group_of(x):
        if AGE.match(x['text']):
            return 'adult.explicit'   # underage markers are top severity
        if x['group'] == 'adult.marker' or (x['mode'] == 'token' and x['text'].lower() in KEEP and x['weight'] <= 70):
            return 'adult.marker'
        return 'adult.explicit' if x['weight'] >= 50 else 'adult.signal'

    buckets = defaultdict(list)
    for x in kept:
        mode, w = x['mode'], x['weight']
        if AGE.match(x['text']):
            mode, w = 'substring', 100   # consolidate age markers
        buckets[(group_of(x), mode, w)].append(x['text'])

    DESC = {
        'adult.explicit': '合并整理的明确成人内容标识',
        'adult.signal': '需与其他成人证据组合的弱信号',
        'adult.marker': '成人内容常见独立标记',
        'adult.code': '经历史审核确认及自动学习的成人影片编号前缀',
    }
    out = []
    for (g, mode, w) in sorted(buckets, key=lambda k: (k[0], -k[2], k[1])):
        kws = sorted(set(buckets[(g, mode, w)]), key=lambda s: (s.lower(), s))
        h = hashlib.md5(('|'.join([g, mode, str(w)] + kws)).encode()).hexdigest()[:16]
        out.append(OrderedDict([
            ('type', 'keyword'), ('id', 'adult.merged.' + h), ('label', 'adult'),
            ('keywords', kws), ('weight', w), ('match_mode', mode), ('group', g),
            ('description', DESC[g]), ('include_files', True),
            ('number_min', 0), ('number_max', 0),
        ]))
    pref = sorted(set(prefixes))
    out.append(OrderedDict([
        ('type', 'prefix'), ('id', 'adult.code.learned'), ('label', 'adult'),
        ('prefixes', pref), ('weight', 80), ('group', 'adult.code'),
        ('description', DESC['adult.code']), ('include_files', True),
        ('number_min', 2), ('number_max', 6),
    ]))

    json.dump({'rules': out}, open(OUT, 'w', encoding='utf-8'), ensure_ascii=False, indent=2)

    tin = sum(len(r.get('keywords', [])) for r in rules)
    tout = sum(len(r.get('keywords', [])) for r in out)
    pin = sum(len(r.get('prefixes', [])) for r in rules if r.get('type') == 'prefix')
    with open(REPORT, 'w', encoding='utf-8') as f:
        f.write('# magnet rules cleanup report\n\n')
        f.write(f'- rules: {len(rules)} -> {len(out)}\n')
        f.write(f'- keyword terms: {tin} -> {tout} (removed/merged {tin-tout})\n')
        f.write(f'- prefixes: {pin} -> {len(pref)}\n\n## Changes\n\n')
        by = defaultdict(list)
        for t, why in removed:
            by[why.split(' ')[0].split(':')[0]].append((t, why))
        for why in sorted(by):
            f.write(f'### {why} ({len(by[why])})\n\n')
            for t, full in sorted(by[why]):
                f.write(f'- `{t}` — {full}\n')
            f.write('\n')
    print('rules', len(rules), '->', len(out))
    print('terms', tin, '->', tout, '| removed/merged', tin - tout)
    print('prefixes', pin, '->', len(pref))

if __name__ == '__main__':
    main()
