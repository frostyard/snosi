#!/bin/bash
# SPDX-License-Identifier: LGPL-2.1-or-later
# Fail if frostyard-nbc is installed according to a dpkg status file.
set -euo pipefail
f=${1:-}
if [[ $# -ne 1 || ! -s $f ]]; then
    echo "usage: $0 DPKG_STATUS_FILE (must exist and be non-empty)" >&2
    exit 2
fi
statuses=$(tr -d '\r' < "$f" | awk -v RS= -F'\n' '{p="";s=""; for(i=1;i<=NF;i++){if($i ~ /^Package: /)p=substr($i,10); if($i ~ /^Status: /)s=substr($i,9)} if(p=="frostyard-nbc"){print "found\t" s}}')
[[ -z $statuses ]] && exit 0
while IFS= read -r entry; do
    status=${entry#*$'\t'}
    if [[ $status == 'deinstall ok config-files' || $status == 'purge ok config-files' ||
        $status =~ ^[^[:space:]]+[[:space:]]+[^[:space:]]+[[:space:]]+not-installed$ ]]; then
        continue
    fi
    echo "frostyard-nbc is installed (Status: ${status:-<missing>})" >&2
    exit 1
done <<< "$statuses"
