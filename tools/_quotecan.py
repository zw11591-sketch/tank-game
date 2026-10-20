import re
import sys

p = r'd:\IdeaProjects\tank-game\scripts\tank.gd'
lines = open(p, encoding='utf-8').read().split('\n')
bad = []
for i, l in enumerate(lines, 1):
    # strip single-line comments crudely (only when the # is outside a string)
    s = l
    in_str = False
    out = []
    j = 0
    while j < len(s):
        ch = s[j]
        if ch == '\\' and j + 1 < len(s):
            out.append(s[j:j + 2])
            j += 2
            continue
        if ch == '"':
            in_str = not in_str
        if ch == '#' and not in_str:
            break
        out.append(ch)
        j += 1
    code = ''.join(out)
    if code.count('"') % 2 == 1:
        bad.append((i, l))
print('lines with unbalanced quotes:', len(bad))
for i, l in bad:
    print(i, '|', l)
