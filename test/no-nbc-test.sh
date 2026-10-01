#!/bin/bash
# Guard the build inputs against reintroducing NBC into bootc images.
set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$root"

failures=0
if git ls-files -z '*mkosi.conf' | xargs -0 -r grep -lE '(^|[[:space:]])frostyard-nbc([[:space:]]|$)' -- 2>/dev/null; then
    printf 'not ok - tracked mkosi config still installs frostyard-nbc\n'
    failures=$((failures + 1))
else
    printf 'ok - no tracked mkosi config installs frostyard-nbc\n'
fi

# Native A/B's /dev/null masks are retired with that lane in a later task.
units=()
while IFS= read -r -d '' path; do
    if [[ -e "$path" || -L "$path" ]]; then
        units+=("$path")
    fi
done < <(git ls-files -z 'mkosi.images/base/**/nbc-update-download.*')
if ((${#units[@]})); then
    printf 'not ok - tracked base nbc-update-download units remain: %s\n' "${units[*]}"
    failures=$((failures + 1))
else
    printf 'ok - no tracked base nbc-update-download units remain\n'
fi

((failures == 0))
