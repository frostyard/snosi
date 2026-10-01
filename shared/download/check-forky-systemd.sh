#!/bin/bash
# SPDX-License-Identifier: LGPL-2.1-or-later
# Detect a Debian Forky migration of the systemd source package.
#
# The secure bootc (shared/bootc-secure) and Firn installer
# (shared/firn-installer) compositions take their whole
# systemd family from unpinned <pkg>/forky selections, so the family changes
# whenever Forky migrates systemd, with no repository change.
# forky-versions.json records the systemd source version whose AGENTS.md
# recheck obligations were last discharged. When Forky serves a strictly newer
# version, this rewrites the sentinel and writes a pull-request body that names
# those obligations. check-packages.yml opens the PR.
set -euo pipefail

usage() {
    echo "usage: $0 <pr-body-output>" >&2
    exit 2
}

[[ $# -eq 1 ]] || usage
body_file=$1

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# Test hook: fixtures point this at a throwaway copy.
sentinel=${FORKY_VERSIONS_FILE:-$script_dir/forky-versions.json}
sources_url=https://deb.debian.org/debian/dists/forky/main/source/Sources.gz

# Forky's main Sources index decompressed to ~60 MiB on 2026-09-29, over the
# helper's 50 MiB default. Raise only the decompressed cap, only for this
# index. The compressed cap (index is ~15 MiB) and 60-second limit stay.
forky_index_max_decompressed_bytes=134217728

# Debian policy version grammar: [epoch:]upstream[-revision]. The value reaches
# JSON, GITHUB_OUTPUT, and a PR title, so anything else fails closed.
version_re='^([0-9]+:)?[0-9][A-Za-z0-9.+~-]*$'

current=$(jq -er '.systemd | strings' "$sentinel") || {
    echo "ERROR: $sentinel has no string .systemd version" >&2
    exit 1
}
[[ $current =~ $version_re ]] || {
    echo "ERROR: $sentinel .systemd is not a Debian version: $current" >&2
    exit 1
}

latest=$(APT_INDEX_MAX_DECOMPRESSED_BYTES=$forky_index_max_decompressed_bytes \
    "$script_dir/latest-apt-version.sh" "$sources_url" systemd)
[[ $latest =~ $version_re ]] || {
    echo "ERROR: Forky Sources index served a non-Debian systemd version: $latest" >&2
    exit 1
}

has_update=false
if [[ $latest == "$current" ]]; then
    echo "Forky systemd unchanged: $current"
elif dpkg --compare-versions "$latest" gt "$current"; then
    has_update=true
    echo "Forky systemd changed: $current -> $latest"
else
    # deb.debian.org is a CDN whose backends sync independently; main run
    # 36479923888 installed 262-1 and 261.2-1 in different jobs. An older
    # reading is a stale backend, not a downgrade to report.
    echo "::warning::deb.debian.org served Forky systemd $latest, older than the acknowledged $current; treating it as a stale mirror"
fi

if [[ $has_update == true ]]; then
    tmp=$(mktemp -d)
    trap 'rm -rf "$tmp"' EXIT
    jq --arg v "$latest" '.systemd = $v' "$sentinel" >"$tmp/forky-versions.json"
    cat >"$body_file" <<EOF
Debian Forky migrated the \`systemd\` source package: **${current} -> ${latest}**.

The secure bootc profiles (\`shared/bootc-secure/mkosi.conf\`) and the Firn installer ISO (\`shared/firn-installer/mkosi.conf\`) take their whole systemd family from unpinned \`<pkg>/forky\` selections. Every build since the migration installs ${latest} whether or not this PR merges. A build that ran while deb.debian.org was mid-sync can mix ${current} and ${latest} across jobs in the same run.

\`shared/download/forky-versions.json\` records the systemd version whose AGENTS.md recheck obligations were last discharged. **Merge only after all three pass on ${latest}:**

- [ ] **Bootc secure composition (Task 4): bwrap build/root check.** Build one secure bootc image (for example \`just floe\`) on the new family, then run \`bootc --version\` and \`bootc container --help\` in a bwrap root that contains only that output. Frostyard's bootc/libostree debs on Forky's systemd family are a deliberate cross-suite compatibility risk, not a package guarantee. Record the result as the Task 4 paragraph's "Last repeated" entry in AGENTS.md.
- [ ] **Issue 517: dracut gpt-auto udev drop-in.** Confirm that the udev rules creating \`/dev/gpt-auto-root-luks\` still ship in \`/usr/lib/udev/rules.d/90-image-dissect.rules\` and that \`shared/bootc-secure/tree/usr/lib/dracut/dracut.conf.d/35-gpt-auto-udev-rules.conf\` still installs the file that carries them. \`test/bootc-secure-artifact-test.sh\`, run by \`build-images.yml\` \`secure-build\` on main, fails any assembled UKI whose initramfs lacks the rule. The drop-in becomes redundant, but not harmful, once the image dracut is 108 or newer.
- [ ] **NvPCR masks.** Compare the new family's \`/usr/lib/nvpcr/*.nvpcr\` definitions and NvPCR units (\`systemd-pcrproduct.service\`, \`systemd-pcrlogin@.service\`) against \`shared/bootc-secure/finalize/disable-nvpcr.chroot\`. Since systemd 262 the masks exist because NvPCRs are created in the initrd under a write policy that needs every definition inside the UKI and a \`ukify --sign-initrd-pcrs\` initrd policy, and snosi UKIs carry neither. Confirm that is still true, that the definition and unit names are unchanged, and that no new definition or writer escapes the masks.

This PR's CI runs only if it was opened with \`WORKFLOW_PAT\`, because PRs opened with \`GITHUB_TOKEN\` trigger no workflows. When it runs, \`build-images.yml\` \`mechanics-build\` builds and packages all four bootc profiles on the new family. This job does not replace the three rechecks. Merging this PR triggers the bootc image workflow on main, which rebuilds the bootc images on ${latest}. The Firn installer ISO is not rebuilt by this sentinel change.

- Changelog: https://metadata.ftp-master.debian.org/changelogs/main/s/systemd/systemd_${latest#*:}_changelog
- Package tracker: https://tracker.debian.org/pkg/systemd
EOF
    # Replace the sentinel only after every other write has succeeded.
    cat "$tmp/forky-versions.json" >"$sentinel"
fi

if [[ -n ${GITHUB_OUTPUT:-} ]]; then
    {
        printf 'has_update=%s\n' "$has_update"
        printf 'previous=%s\n' "$current"
        printf 'latest=%s\n' "$latest"
    } >>"$GITHUB_OUTPUT"
fi
