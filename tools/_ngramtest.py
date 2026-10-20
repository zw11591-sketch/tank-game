import os, glob, collections, math

ROOT = r'd:\IdeaProjects\tank-game'
P = os.path.join(ROOT, 'scripts', 'tank.gd')
REF = os.path.join(os.environ['TEMP'], 'tank_new.gd')
raw = open(P, 'rb').read()
text = raw.decode('utf-8', 'replace')
MARK = '\ufffd?'

corpus_parts = [open(REF, encoding='utf-8').read()]
for pat in ('scripts/*.gd', 'tools/*.gd', '*.md'):
    for f in glob.glob(os.path.join(ROOT, pat)):
        if os.path.abspath(f) == os.path.abspath(P):
            continue
        try:
            corpus_parts.append(open(f, 'rb').read().decode('utf-8', 'replace'))
        except OSError:
            pass
corpus = ''.join(corpus_parts).replace('\ufffd', '')
uni = collections.Counter(corpus)
bi = collections.Counter(zip(corpus, corpus[1:]))
tri = collections.Counter(zip(corpus, corpus[1:], corpus[2:]))

sites = []
i = 0
while i < len(raw):
    try:
        raw[i:].decode('utf-8')
        break
    except UnicodeDecodeError as e:
        p = i + e.start
        sites.append(p)
        i = p + 3

ph = []
k = 0
for _ in sites:
    ph.append(text.index(MARK, k))
    k = ph[-1] + 2


def cands(lead, cont):
    out = []
    for t in range(0x80, 0xC0):
        try:
            out.append(bytes((lead, cont, t)).decode('utf-8'))
        except UnicodeDecodeError:
            pass
    return out


def score(c, left, right):
    s = 0.0
    for k in range(2, len(left)):
        s += 3.0 * math.log1p(tri.get((left[k - 2], left[k - 1], c, c), 0))
        s += 3.0 * math.log1p(tri.get((left[k - 1], c, right[0] if right else ''), 0))
        s += math.log1p(bi.get((left[k - 1], c), 0))
    for k in range(0, min(2, len(right))):
        s += 3.0 * math.log1p(tri.get((c, right[k], right[k + 1] if k + 1 < len(right) else ''), 0))
        s += math.log1p(bi.get((c, right[k]), 0))
    s += 0.06 * math.log1p(uni.get(c, 0))
    return s


agree = 0
total = 0
for s_i, p in enumerate(sites):
    idx = ph[s_i]
    C = cands(raw[p], raw[p + 1])
    left = text[max(0, idx - 8):idx]
    hits = []
    st = 0
    while True:
        h = corpus.find(left, st)
        if h < 0:
            break
        hits.append(h)
        st = h + 1
    good = set(corpus[h + len(left)] for h in hits
               if h + len(left) < len(corpus) and corpus[h + len(left)] in C)
    if len(good) != 1:
        continue
    truth = good.pop()
    right = text[idx + 2: idx + 10]
    ranked = sorted(((score(c, left[-4:], right), c) for c in C), reverse=True)
    total += 1
    if ranked[0][1] == truth:
        agree += 1
    elif total <= 40:
        print('MISS', repr(left[-6:]), 'picked', ranked[0][1], 'truth', truth, repr(right[:6]))
print('agreement', agree, '/', total)
