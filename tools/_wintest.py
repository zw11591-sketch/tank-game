import os, re, collections

ROOT = r'd:\IdeaProjects\tank-game'
P = os.path.join(ROOT, 'scripts', 'tank.gd')
REF = os.path.join(os.environ['TEMP'], 'tank_new.gd')
raw = open(P, 'rb').read()
text = raw.decode('utf-8', 'replace')
ref = open(REF, encoding='utf-8').read()
MARK = '\ufffd?'

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


for w in (4, 6, 8, 10, 12, 16, 24, 32):
    hit = 0
    for s_i, p in enumerate(sites):
        idx = ph[s_i]
        C = cands(raw[p], raw[p + 1])
        left = text[max(0, idx - w):idx]
        hits = []
        st = 0
        while True:
            h = ref.find(left, st)
            if h < 0:
                break
            hits.append(h)
            st = h + 1
        good = [ref[h + len(left)] for h in hits
                if h + len(left) < len(ref) and ref[h + len(left)] in C]
        if good and len(set(good)) == 1:
            hit += 1
    print('window', w, 'unique hits', hit, '/', len(sites))
