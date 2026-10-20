import os, glob

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
print('corpus', len(corpus))

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


for w in (8, 12, 16, 20, 24, 32):
    uniq = 0
    multi_same = 0
    for s_i, p in enumerate(sites):
        idx = ph[s_i]
        C = cands(raw[p], raw[p + 1])
        left = text[max(0, idx - w):idx]
        hits = []
        st = 0
        while True:
            h = corpus.find(left, st)
            if h < 0:
                break
            hits.append(h)
            st = h + 1
        good = [corpus[h + len(left)] for h in hits
                if h + len(left) < len(corpus) and corpus[h + len(left)] in C]
        if not good:
            continue
        if len(set(good)) == 1:
            uniq += 1
    print('window', w, 'consistent', uniq, '/', len(sites))
