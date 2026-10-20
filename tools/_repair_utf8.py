import collections
import glob
import math
import os
import sys

P = r'd:\IdeaProjects\tank-game\scripts\tank.gd'
b = bytearray(open(P, 'rb').read())

# ---- 1. locate broken 3-byte sequences -------------------------------------
bad = []
i = 0
while i < len(b) - 2:
    if 0xE0 <= b[i] <= 0xEF and 0x80 <= b[i + 1] <= 0xBF and b[i + 2] == 0x3F:
        try:
            b[i:i + 2].decode('utf-8')
        except UnicodeDecodeError:
            bad.append(i)
            i += 3
            continue
    i += 1
print('broken sites:', len(bad))

# ---- 2. corpus from the whole project --------------------------------------
corpus_parts = []
for pat in ('scripts/*.gd', 'tools/*.gd', '*.md'):
    for f in glob.glob(os.path.join(r'd:\IdeaProjects\tank-game', pat)):
        if os.path.abspath(f) == os.path.abspath(P):
            continue
        try:
            corpus_parts.append(open(f, 'rb').read().decode('utf-8', errors='replace'))
        except OSError:
            pass
# clean parts of tank.gd itself
corpus_parts.append(b.decode('utf-8', errors='replace'))
corpus = ''.join(corpus_parts).replace('\ufffd', '')
uni = collections.Counter(corpus)
bi = collections.Counter(zip(corpus, corpus[1:]))
tri = collections.Counter(zip(corpus, corpus[1:], corpus[2:]))
print('corpus chars:', len(corpus))


def char_at(pos):
    if pos >= len(b):
        return '', 0, False
    if b[pos] < 0x80:
        return chr(b[pos]), 1, True
    for n in (2, 3, 4):
        try:
            s = b[pos:pos + n].decode('utf-8')
            if len(s) == 1:
                return s, n, True
        except UnicodeDecodeError:
            pass
    return '', 1, False


def prev_chars(pos, k):
    out = []
    cur = pos
    while len(out) < k:
        found = False
        for back in range(1, 5):
            if cur - back < 0:
                break
            c, n, ok = char_at(cur - back)
            if ok and n == back:
                out.append(c)
                cur -= back
                found = True
                break
        if not found:
            break
    return out


def next_chars(pos, k):
    out = []
    cur = pos
    while len(out) < k:
        c, n, ok = char_at(cur)
        if not ok or n == 0:
            break
        out.append(c)
        cur += n
    return out


def score(c, p2, p1, n1, n2):
    s = 0.0
    s += 3.0 * math.log1p(tri.get((p2, p1, c), 0))
    s += 3.0 * math.log1p(tri.get((p1, c, n1), 0))
    s += 3.0 * math.log1p(tri.get((c, n1, n2), 0))
    s += math.log1p(bi.get((p1, c), 0))
    s += math.log1p(bi.get((c, n1), 0))
    s += 0.06 * math.log1p(uni.get(c, 0))
    return s


# ---- 3. plan ---------------------------------------------------------------
plan = []
for pos in bad:
    lead, cont = b[pos], b[pos + 1]
    cands = []
    for t in range(0x80, 0xC0):
        try:
            ch = bytes((lead, cont, t)).decode('utf-8')
        except UnicodeDecodeError:
            continue
        if len(ch) == 1:
            cands.append((ch, t))
    pc = prev_chars(pos, 2)
    nc = next_chars(pos + 3, 2)
    while len(pc) < 2:
        pc.append('')
    while len(nc) < 2:
        nc.append('')
    p2, p1 = pc[1], pc[0]
    n1 = nc[0]
    n2 = nc[1]
    ranked = sorted(((score(ch, p2, p1, n1, n2), ch, t) for ch, t in cands), reverse=True)
    plan.append((pos, p2, p1, n1, n2, ranked))

OUT = P + '.repaired'
out = bytearray(b)
low = []
auto = []
for pos, p2, p1, n1, n2, ranked in plan:
    best = ranked[0]
    second = ranked[1][0] if len(ranked) > 1 else -99.0
    if best[0] - second >= 2.5:
        out[pos:pos + 3] = best[1].encode('utf-8')
        auto.append((pos, best[1]))
    else:
        low.append((pos, p2, p1, n1, n2, ranked))

print('auto-fixed:', len(plan) - len(low), 'needs review:', len(low))

MARK = '\u25a1'.encode('utf-8')
for pos, *_rest in low:
    out[pos:pos + 3] = MARK
try:
    out.decode('utf-8')
    print('result is valid UTF-8')
except UnicodeDecodeError as e:
    print('STILL INVALID', e.start)
    sys.exit(1)


def line_of(buf, pos):
    return buf[:pos].count(b'\n') + 1


def full_line(buf, pos):
    s = pos
    while s > 0 and buf[s - 1] != 0x0A:
        s -= 1
    e = buf.find(b'\n', pos)
    if e < 0:
        e = len(buf)
    return bytes(buf[s:e]).decode('utf-8', 'replace')


with open(r'd:\IdeaProjects\tank-game\tools\_repair_auto.txt', 'w', encoding='utf-8') as f:
    for pos, ch in auto:
        f.write('%d\t%s\t%s\n' % (line_of(out, pos), ch, full_line(out, pos)))

with open(r'd:\IdeaProjects\tank-game\tools\_repair_review.txt', 'w', encoding='utf-8') as f:
    for pos, p2, p1, n1, n2, ranked in low:
        opts = ' '.join('%s(%.1f)' % (c, sc) for sc, c, t in ranked[:6])
        f.write('%d\t%s%s□%s%s\t%s\t%s\n' % (
            line_of(out, pos), p2, p1, n1, n2, opts, full_line(out, pos)))

open(OUT, 'wb').write(out)
print('wrote', OUT)
