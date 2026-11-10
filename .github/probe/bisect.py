import re, subprocess, sys, pathlib
TARGET = pathlib.Path('Tests/HandoffCoreTests/ReceiptTests+Recovery.swift')
NAME = 'func parentAndArchivedFork()'
files = sorted(pathlib.Path('Tests/HandoffCoreTests').glob('ReceiptTests*.swift'))
original = {f: f.read_text() for f in files}

def blocks(text):
    lines, out, i = text.split('\n'), [], 0
    while i < len(lines):
        m = re.match(r'^(\s*)@Test\(', lines[i])
        if m:
            j = i + 1
            while not re.match(r'^' + m.group(1) + r'}\s*$', lines[j]): j += 1
            out.append((i, j)); i = j
        i += 1
    return out

def only_culprit(f, body=None):
    lines = original[f].split('\n')
    keep = None
    for s, e in sorted(blocks(original[f]), key=lambda b: -b[0]):
        if f == TARGET and NAME in lines[s + 1]:
            keep = (s, e); continue
        del lines[s:e + 1]
    if keep and body is not None:
        s, e = keep
        text = '\n'.join(lines); seg = original[f].split('\n')[s:e + 1]
        text = text.replace('\n'.join(seg), '\n'.join(body))
        return text
    return '\n'.join(lines)

lines = original[TARGET].split('\n')
s, e = next((s, e) for s, e in blocks(original[TARGET]) if NAME in lines[s + 1])
seg = lines[s:e + 1]
loop = next(i for i, l in enumerate(seg) if l.startswith('        for richer'))
end = max(i for i, l in enumerate(seg) if l == '        }')
stmts, cur = [], None
for i in range(loop + 1, end):
    l = seg[i]
    if re.match(r'^ {12}\S', l) and not re.match(r'^ {12}[}\])]', l):
        cur = [l]; stmts.append(cur)
    else:
        cur.append(l)
print(f'{len(stmts)} statements', flush=True)

def build(k, skip=None):
    chosen = [st for i, st in enumerate(stmts[:k]) if i != skip]
    body = seg[:loop + 1] + [l for st in chosen for l in st] + seg[end:]
    for f in files: f.write_text(only_culprit(f, body if f == TARGET else None))
    out = subprocess.run(['swift', 'build', '--build-tests'], capture_output=True, text=True)
    log = out.stdout + out.stderr
    crashed = 'signal 4' in log
    errors = [l for l in log.split('\n') if 'error:' in l and 'signal 4' not in l][:3]
    print(f'  first {k} skip {skip}: crash={crashed} status={out.returncode} {errors}', flush=True)
    return crashed

if not build(len(stmts)): print('culprit alone does not crash'); sys.exit(0)
lo, hi = 0, len(stmts)  # crash with hi, assume none with lo
while hi - lo > 1:
    mid = (lo + hi) // 2
    if build(mid): hi = mid
    else: lo = mid
print(f'CULPRIT statement {hi}:')
print('\n'.join(stmts[hi - 1]))
build(len(stmts), skip=hi - 1)
