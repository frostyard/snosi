#!/bin/bash
# SPDX-License-Identifier: LGPL-2.1-or-later
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
finalize="$repo_root/mkosi.images/lemonade/mkosi.finalize"
tmpfiles="$repo_root/mkosi.images/lemonade/mkosi.extra/usr/lib/tmpfiles.d/lemonade.conf"
required_paths="$repo_root/mkosi.images/lemonade/required-paths.txt"
checksums="$repo_root/shared/download/sysext-checksums.json"
work_dir="$(mktemp -d)"
trap 'rm -rf "$work_dir"' EXIT

version="$(jq -er '.lemonade.version' "$checksums")"
if ! dpkg --compare-versions "$version" ge 11.8.1; then
    printf 'expected pinned Lemonade version >= 11.8.1, found %s\n' "$version" >&2
    exit 1
fi

buildroot="$work_dir/buildroot"
source_file="$buildroot/etc/default/lemond"
factory_file="$buildroot/usr/share/factory/etc/default/lemond"
mkdir -p "$(dirname "$source_file")"
printf '#HF_TOKEN=\n#LEMONADE_API_KEY=\n' >"$source_file"
chmod 0640 "$source_file"

BUILDROOT="$buildroot" "$finalize"
cmp "$source_file" "$factory_file"
[[ $(stat -c '%a' "$factory_file") == 640 ]]

grep -qx 'C /etc/default/lemond - - - - -' "$tmpfiles"
grep -qx '/usr/share/factory/etc/default/lemond' "$required_paths"

if grep -Fq '/etc/lemonade/conf.d' "$tmpfiles" "$required_paths"; then
    echo 'legacy Lemonade conf.d contract is still present' >&2
    exit 1
fi

echo 'lemonade-sysext-test: PASSED'
