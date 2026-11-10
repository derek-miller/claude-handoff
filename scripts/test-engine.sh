#!/bin/bash
# Runs the engine behaviour suite, one test process per Swift Testing suite under Engine, several at a time.
# The tables the tests swap (fs, process, childProcess, cloudFetch) are process-global, so suites run in
# separate processes rather than in parallel threads. JOBS sets how many run at once (default: CPU count).
set -euo pipefail
cd "$(dirname "$0")/.."
config=(-c release -Xswiftc -enable-testing)
jobs="${JOBS:-$(sysctl -n hw.ncpu)}"
logs="$(mktemp -d)"
trap 'rm -rf "$logs"' EXIT

swift build "${config[@]}" --build-tests
suites="$(swift test list "${config[@]}" --skip-build | sed -nE 's#^[^.]+\.Engine/([^/]+)/.*#\1#p' | sort -u)"
[ -n "$suites" ] || { echo "no Engine suites found"; exit 1; }
# Longest first, so the slow suites never start last.
slow=(Restarts Receipts Cloud Moves Inventory)
ordered="$( { for s in "${slow[@]}"; do grep -qx "$s" <<<"$suites" && echo "$s"; done; grep -vxF "$(printf '%s\n' "${slow[@]}")" <<<"$suites" || true; } )"

run() {
    local start=$SECONDS
    if swift test "${config[@]}" --skip-build --ignore-lock --filter "Engine/$1/" > "$logs/$1.log" 2>&1; then
        echo "passed  $1 ($((SECONDS - start)) s)"
    else
        echo "FAILED  $1 ($((SECONDS - start)) s)"; touch "$logs/$1.failed"
    fi
}
export -f run; export logs; export config_str="${config[*]}"
# Bash cannot export arrays; rebuild config inside each worker.
xargs -P "$jobs" -I{} bash -c 'config=($config_str); run "$1"' _ {} <<<"$ordered"

failed=0
for s in $ordered; do
    [ -e "$logs/$s.failed" ] || continue
    failed=1
    [ -n "${GITHUB_ACTIONS:-}" ] && echo "::group::$s"
    cat "$logs/$s.log"
    [ -n "${GITHUB_ACTIONS:-}" ] && echo "::endgroup::"
done
exit $failed
