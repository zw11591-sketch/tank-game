"""Restore scripts/tank.gd after an encoding round-trip destroyed it.

Damage model (verified byte by byte):
  * every CJK char whose 3rd UTF-8 byte got mangled is now  <lead><cont> '?'
    -> 632 sites, all of them 3-byte sequences;
  * at some of those sites the byte that followed (often the newline) was eaten,
    so doc-comment lines and even `const` / `var` declarations got glued onto
    the previous line.

Pass 1  exact: find the 8..16 char window before the hole, unique in the rest of
        the project -> use the char that follows it.
Pass 2  statistical: score the 64 chars sharing the known first two UTF-8 bytes
        with a project-wide n-gram model plus position priors (end-of-line
        punctuation, CJK punctuation blocks).
Pass 3  structure: split at every TAB that is not indentation, before every
        mid-line "##", and before code tokens glued onto a comment line.
"""
import collections
import glob
import math
import os
import re

ROOT = r'd:\IdeaProjects\tank-game'
P = os.path.join(ROOT, 'scripts', 'tank.gd.corrupt')
REF = os.path.join(os.environ['TEMP'], 'tank_new.gd')
OUT = os.path.join(ROOT, 'scripts', 'tank.gd.fixed')

raw = open(P, 'rb').read()
text = raw.decode('utf-8', 'replace')
MARK = '\ufffd?'

corpus_parts = [open(REF, encoding='utf-8').read()]
for pat in ('scripts/*.gd', 'tools/*.gd', '*.md'):
    for f in glob.glob(os.path.join(ROOT, pat)):
        if os.path.abspath(f) in (os.path.abspath(P), os.path.abspath(OUT)):
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
        assert raw[p + 2] == 0x3F, (p, raw[p:p + 6])
        sites.append(p)
        i = p + 3

ph = []
k = 0
for _ in sites:
    ph.append(text.index(MARK, k))
    k = ph[-1] + 2
assert len(sites) == len(ph) == 632, len(sites)

EOL_TOKENS = ('var ', 'const ', 'func ', 'signal ', 'static ', 'match ', 'if ',
              'for ', 'while ', 'return ', 'elif ', 'else', '@', 'extends',
              'class_name', '\t', '##', '# ')


def cands(lead, cont):
    out = []
    for t in range(0x80, 0xC0):
        try:
            out.append(bytes((lead, cont, t)).decode('utf-8'))
        except UnicodeDecodeError:
            pass
    return out


def at_line_end(right):
    if not right:
        return True
    if right[0] in '\n#\t':
        return True
    return right.startswith(EOL_TOKENS)


def score(c, left, right, eol):
    s = 0.0
    for k in range(max(0, len(left) - 4), len(left)):
        if k >= 1:
            s += 3.0 * math.log1p(tri.get((left[k - 1], c, right[0] if right else ''), 0))
            s += math.log1p(bi.get((left[k - 1], c), 0))
        if k >= 2:
            s += 1.5 * math.log1p(tri.get((left[k - 2], left[k - 1], c), 0))
    for k in range(0, min(2, len(right))):
        s += 3.0 * math.log1p(
            tri.get((c, right[k], right[k + 1] if k + 1 < len(right) else ''), 0))
        s += math.log1p(bi.get((c, right[k]), 0))
    s += 0.06 * math.log1p(uni.get(c, 0))
    block = (left[-1:].encode('utf-8')[:2] if left else b'')
    if eol:
        # a comment line almost always closes with a full stop
        s += {'。': 9.0, '）': 3.0, '，': 1.0, '」': 1.0, '】': 1.0}.get(c, 0.0)
    else:
        s += {'。': -2.0, '，': 2.5, '、': 1.5, '：': 1.0, '（': 1.0,
              '）': 1.0, '“': 0.5, '”': 0.5}.get(c, 0.0)
    return s


resolved = []
stats = collections.Counter()
for s_i, p_byte in enumerate(sites):
    idx = ph[s_i]
    lead, cont = raw[p_byte], raw[p_byte + 1]
    C = cands(lead, cont)
    left = text[max(0, idx - 16):idx]
    right = text[idx + 2: idx + 12]
    pick = None
    for w in (16, 12, 10, 8):
        win = left[-w:]
        hits = []
        st = 0
        while True:
            h = corpus.find(win, st)
            if h < 0:
                break
            hits.append(h)
            st = h + 1
        good = set(corpus[h + len(win)] for h in hits
                   if h + len(win) < len(corpus) and corpus[h + len(win)] in C)
        if len(good) == 1:
            pick, why = good.pop(), 'exact'
            break
    if pick is None:
        eol = at_line_end(right)
        ranked = sorted(((score(c, left, right, eol), c) for c in C), reverse=True)
        pick, why = ranked[0][1], ('eol' if eol else 'mid')
    stats[why] += 1
    resolved.append((idx, pick))
print('resolution:', dict(stats))

out = []
cursor = 0
for idx, ch in resolved:
    out.append(text[cursor:idx])
    out.append(ch)
    cursor = idx + 2
out.append(text[cursor:])
text = ''.join(out)
assert '\ufffd' not in text

# ------------------------------------------------------------ structure -----
n_tabs = len(re.findall(r'(?<=\S)\t', text))
text = re.sub(r'(?<=\S)\t', '\n\t', text)
n_hash = len(re.findall(r'(?<=\S)##', text))
text = re.sub(r'(?<=\S)##', '\n##', text)

CODE_GLUE = re.compile(r'(?<=[^\s])(const |var |func |static |signal |class_name |extends )')
split_lines = []
for line in text.split('\n'):
    if line.lstrip().startswith('#') and CODE_GLUE.search(line):
        pieces = CODE_GLUE.split(line)
        # re-join keyword with what follows it
        rebuilt = [pieces[0]]
        for j in range(1, len(pieces), 2):
            rebuilt.append(pieces[j] + pieces[j + 1])
        if len(rebuilt) > 1:
            split_lines.append(rebuilt)
            continue
    split_lines.append([line])
text = '\n'.join('\n'.join(part) for part in split_lines)

print('internal tabs split:', n_tabs, ' mid ## split:', n_hash,
      ' code-glue lines:', sum(1 for p in split_lines if len(p) > 1))

open(OUT, 'w', encoding='utf-8', newline='\n').write(text)
print('wrote', OUT, len(text), 'chars', text.count('\n') + 1, 'lines')
