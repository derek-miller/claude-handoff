#!/bin/bash
# Runs the engine behaviour suite as parallel test processes, each running a chunk of one suite's tests.
# The tables the tests swap (fs, process, childProcess, cloudFetch) are process-global, so tests run in
# separate processes rather than in parallel threads.
#   JOBS   processes at once (default: CPU count)
#   CHUNK  tests per process (default: 8)
#   SHARD  i/n runs every n-th chunk starting at the i-th, so n machines can split the suite (default: 1/1)
set -euo pipefail
cd "$(dirname "$0")/.."
config=(-c release -Xswiftc -enable-testing)
jobs="${JOBS:-$(sysctl -n hw.ncpu)}"
chunk="${CHUNK:-8}"
shard="${SHARD:-1/1}"
logs="$(mktemp -d)"
trap 'rm -rf "$logs"' EXIT

swift build "${config[@]}" --build-tests
swift test list "${config[@]}" --skip-build > "$logs/list"

# One line per chunk: "<name> <expected test count> <filter>...", slow suites first so they never start last.
# A filter is the escaped test ID; anchoring it with $ matches nothing, and the escaped (...) already ends the name.
python3 -I - "$logs/list" "$chunk" "$shard" > "$logs/chunks" <<'EOF'
import re, sys
listing, size, shard = sys.argv[1], int(sys.argv[2]), sys.argv[3]
index, count = (int(x) for x in shard.split('/'))
suites = {}
for line in open(listing):
    m = re.match(r'^[^.]+\.Engine/([^/]+)/(.+)$', line.strip())
    if m: suites.setdefault(m[1], []).append(line.strip())
if not suites: sys.exit('no Engine tests found')
slow = ['Restarts', 'Receipts', 'Cloud', 'Moves', 'Inventory']
order = [s for s in slow if s in suites] + sorted(s for s in suites if s not in slow)
chunks = []
for suite in order:
    tests = suites[suite]
    parts = [tests[i:i + size] for i in range(0, len(tests), size)]
    for n, part in enumerate(parts, 1):
        name = f'{suite}-{n}of{len(parts)}'
        chunks.append((name, len(part), [re.escape(t.split('.', 1)[1]) for t in part]))
for i, (name, n, filters) in enumerate(chunks):
    if i % count == index - 1: print(name, n, *filters)
EOF

run() {
    local line name expected start=$SECONDS filters=()
    read -r -a line < <(sed -n "${1}p" "$logs/chunks")
    name=${line[0]}; expected=${line[1]}
    for f in "${line[@]:2}"; do filters+=(--filter "$f"); done
    local ok=1
    swift test "${config[@]}" --skip-build --ignore-lock "${filters[@]}" > "$logs/$name.log" 2>&1 || ok=0
    local ran
    ran="$(sed -nE 's/.*Test run with ([0-9]+) tests? .*/\1/p' "$logs/$name.log" | tail -1)"
    if [ "$ok" = 1 ] && [ "${ran:-0}" = "$expected" ]; then
        echo "passed  $name ($ran tests, $((SECONDS - start)) s)"
    else
        echo "FAILED  $name (ran ${ran:-0} of $expected tests, $((SECONDS - start)) s)"; touch "$logs/$name.failed"
    fi
}
export -f run; export logs; export config_str="${config[*]}"
# Bash cannot export arrays; rebuild config inside each worker.
# Workers get line numbers, not the filters: xargs would strip the backslashes the filters rely on.
seq 1 "$(wc -l < "$logs/chunks")" | xargs -P "$jobs" -I{} bash -c 'config=($config_str); run "$1"' _ {}

failed=0
while read -r name _; do
    [ -e "$logs/$name.failed" ] || continue
    failed=1
    [ -n "${GITHUB_ACTIONS:-}" ] && echo "::group::$name"
    cat "$logs/$name.log"
    [ -n "${GITHUB_ACTIONS:-}" ] && echo "::endgroup::"
done < "$logs/chunks"
exit $failed
