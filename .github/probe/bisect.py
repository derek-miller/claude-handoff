import re, subprocess, sys, pathlib
files = sorted(pathlib.Path('Tests/HandoffCoreTests').glob('ReceiptTests*.swift'))
original = {f: f.read_text() for f in files}
units = []  # (file, start, end) line ranges of @Test blocks
for f, text in original.items():
    lines = text.split('\n')
    i = 0
    while i < len(lines):
        m = re.match(r'^(\s*)@Test\(', lines[i])
        if m:
            indent = m.group(1)
            j = i + 1
            while not re.match(r'^' + indent + r'}\s*$', lines[j]): j += 1
            units.append((f, i, j))
            i = j
        i += 1
print(f'{len(units)} test blocks', flush=True)

def build(removed):
    for f, text in original.items():
        lines = text.split('\n')
        for (g, s, e) in sorted(removed, key=lambda u: -u[1]):
            if g == f: del lines[s:e + 1]
        f.write_text('\n'.join(lines))
    out = subprocess.run(['swift', 'build', '--build-tests'], capture_output=True, text=True)
    log = out.stdout + out.stderr
    crashed = 'signal 4' in log
    errors = [l for l in log.split('\n') if 'error:' in l and 'signal 4' not in l][:3]
    print(f'  removed {len(removed)}: crash={crashed} status={out.returncode} {errors}', flush=True)
    return crashed

if not build([]): print('no crash at baseline'); sys.exit(0)
if build(units): print('still crashes with every receipts test removed: culprit is outside the test blocks'); sys.exit(0)
suspects = units
while len(suspects) > 1:
    half = suspects[:len(suspects) // 2]
    rest = suspects[len(suspects) // 2:]
    # keep only `half` of the suspects (remove rest and all non-suspects)
    keep = set(half)
    if build([u for u in units if u not in keep]): suspects = half
    else: suspects = rest
f, s, e = suspects[0]
print(f'CULPRIT {f}:{s + 1}-{e + 1}')
print('\n'.join(original[f].split('\n')[s:min(e + 1, s + 60)]))
