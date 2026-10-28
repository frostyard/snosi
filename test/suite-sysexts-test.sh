#!/bin/bash
# SPDX-License-Identifier: LGPL-2.1-or-later
# Static checks for the Frostyard suite sysexts lodge, notesd, maild, porterd
# and readd: unit sets, presets, extension-release, required paths, pinned
# releases with their attestation metadata, and the sysupdate component. No
# root, no network, no image build.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CHECKSUMS="$ROOT_DIR/shared/download/sysext-checksums.json"

PASS=0
FAIL=0
pass() { printf 'ok - %s\n' "$1"; PASS=$((PASS + 1)); }
fail() { printf 'not ok - %s\n' "$1" >&2; FAIL=$((FAIL + 1)); }

# check <description> <command...>: counts the command's status as one test.
check() {
    local description=$1
    shift
    if "$@"; then
        pass "$description"
    else
        fail "$description"
    fi
}

has_line() { grep -Fxq -- "$2" "$1"; }
lacks_text() { local f; for f in "${@:2}"; do ! grep -Fq -- "$1" "$f" || return 1; done; }

# Upholds= units of a drop-in, sorted, one per line.
upheld_units() {
    sed -n 's/^Upholds=//p' "$1" | tr ' ' '\n' | grep -v '^$' | sort
}

# Units of the `enable` lines of a preset, sorted. Any other non-comment line
# is printed whole, so it breaks the comparison.
enabled_units() {
    grep -Ev '^[[:space:]]*(#|$)' "$1" | awk '$1 == "enable" { print $2; next } { print }' | sort
}

sorted_words() {
    printf '%s\n' "$@" | sort
}

same_set() { [[ "$1" == "$2" ]]; }

has_all() { local f=$1 l; shift; for l in "$@"; do has_line "$f" "$l" || return 1; done; }
contains() { grep -Fq -- "$2" "$1"; }
differs() { [[ "$1" != "$2" ]]; }
line_no() { grep -n -- "$2" "$1" | head -n1 | cut -d: -f1; }
runs_before() { local a b; a=$(line_no "$1" "$2"); b=$(line_no "$1" "$3"); [[ -n "$a" && -n "$b" && "$a" -lt "$b" ]]; }
count_is() { [[ $(grep -Ec -- "$2" "$1" || true) -eq $3 ]]; }
matches() { [[ "$1" =~ $2 ]]; }

check_sysext() {
    local name=$1 keypackage=$2 sysusers=$3 app=$4
    shift 4
    local units=("$@")
    local dir="$ROOT_DIR/mkosi.images/$name"
    local extra="$dir/mkosi.extra/usr/lib"
    local dropin="$extra/systemd/system/multi-user.target.d/10-$name.conf"
    local preset="$extra/systemd/system-preset/40-$name.preset"
    local release="$extra/extension-release.d/extension-release.$name"
    local required="$dir/required-paths.txt"
    local sysupdate="$ROOT_DIR/mkosi.images/base/mkosi.extra/usr/lib/sysupdate.$name.d"
    local transfer="$sysupdate/$name.transfer" feature="$sysupdate/$name.feature"
    local expected unit path suffix
    expected=$(sorted_words "${units[@]}")

    check "$name: KEYPACKAGE is $keypackage" has_line "$dir/mkosi.conf" "Environment=KEYPACKAGE=$keypackage"
    check "$name: built on base as a compressed overlay sysext" has_all "$dir/mkosi.conf" \
        Dependencies=base BaseTrees=%O/base Overlay=yes Format=sysext CompressOutput=zstd CompressLevel=19 \
        "ImageId=$name" "Output=$name"
    check "$name: root mkosi.conf builds it by default" grep -Eq "^[[:space:]]+$name\$" "$ROOT_DIR/mkosi.conf"

    check "$name: postinst is executable" test -x "$dir/mkosi.postinst.chroot"
    check "$name: postinst downloads the pin with verified_download" \
        grep -Fq "verified_download \"$name\" " "$dir/mkosi.postinst.chroot"
    check "$name: postinst checks the deb dependencies before dpkg -i" \
        runs_before "$dir/mkosi.postinst.chroot" '^assert_deb_dependencies_satisfied ' '^dpkg -i '
    check "$name: no mkosi.finalize (nothing is captured from /etc)" test ! -e "$dir/mkosi.finalize"

    check "$name: Upholds= names exactly the socket and the service" \
        same_set "$(upheld_units "$dropin")" "$expected"
    check "$name: the preset enables exactly the socket and the service" \
        same_set "$(enabled_units "$preset")" "$expected"
    check "$name: frostmail-secrets-key.service is neither upheld nor enabled" \
        lacks_text frostmail-secrets-key "$dropin" "$preset"
    check "$name: extension-release sets EXTENSION_RELOAD_MANAGER=1" \
        has_line "$release" 'EXTENSION_RELOAD_MANAGER=1'

    for unit in "${units[@]}"; do
        check "$name: required-paths lists $unit" has_line "$required" "/usr/lib/systemd/system/$unit"
    done
    for path in \
        "/usr/lib/sysusers.d/$sysusers.conf" \
        "/usr/lib/systemd/system-preset/40-$name.preset" \
        "/usr/lib/systemd/system/multi-user.target.d/10-$name.conf" \
        "/usr/lib/extension-release.d/extension-release.$name"; do
        check "$name: required-paths lists $path" has_line "$required" "$path"
    done
    # lodge is the shell itself and ships no Lodge app manifest.
    if [[ -n "$app" ]]; then
        for path in \
            "/usr/share/lodge/apps/$app/app.json" \
            "/usr/share/lodge/apps/$app/web/index.html"; do
            check "$name: required-paths lists $path" has_line "$required" "$path"
        done
    fi

    check "$name: transfer selects the component, verifies, and sets the current link" \
        has_all "$transfer" "Features=$name" Verify=true "CurrentSymlink=$name.raw"
    for suffix in 'raw\.zst' 'raw\.xz' 'raw\.gz' 'raw( \\)?$'; do
        check "$name: transfer lists $suffix in Source and Target" \
            count_is "$transfer" "${name}_@v_%w_%a\\.$suffix" 2
    done
    check "$name: feature is disabled by default" has_line "$feature" 'Enabled=false'
    check "$name: no RequisiteFeatures= (core ADR-0058)" lacks_text 'RequisiteFeatures=' "$transfer" "$feature"
}

# check_pin <key> <repository> <package>
check_pin() {
    local key=$1 repository=$2 package=$3 version url sha
    version=$(jq -r --arg k "$key" '.[$k].version // ""' "$CHECKSUMS")
    url=$(jq -r --arg k "$key" '.[$k].url // ""' "$CHECKSUMS")
    sha=$(jq -r --arg k "$key" '.[$k].sha256 // ""' "$CHECKSUMS")
    check "$key: the pin has a plain version" matches "$version" '^[0-9]+\.[0-9]+\.[0-9]+$'
    check "$key: the pinned URL is the release asset of that version" \
        same_set "$url" "https://github.com/$repository/releases/download/v$version/${package}_${version}_amd64.deb"
    check "$key: the pin has a SHA-256" matches "$sha" '^[0-9a-f]{64}$'
    # shellcheck disable=SC2016  # jq variables, not shell expansions
    check "$key: attestation names its repository and release workflow" \
        jq -e --arg k "$key" --arg r "$repository" \
        '.[$k].attestation == {"repository": $r, "signer_workflow": ".github/workflows/release.yml"}' "$CHECKSUMS" >/dev/null
}

check_sysext notesd frostyard-notesd frostnotes notes frostnotes-lodge.socket frostnotes.service
check_sysext maild frostyard-maild frostmail mail frostmail.socket frostmail.service
check_sysext lodge frostyard-lodge lodge '' lodge.service
check_sysext porterd frostyard-porterd frostporter porter frostporter.socket frostporter.service
check_sysext readd frostyard-readd frostread read frostread.socket frostread.service

check_pin notesd frostyard/frostnotes frostyard-notesd
check_pin maild frostyard/frostmail frostyard-maild
check_pin lodge frostyard/lodge frostyard-lodge
check_pin porterd frostyard/porter frostyard-porterd
check_pin readd frostyard/frostread frostyard-readd

notesd_required="$ROOT_DIR/mkosi.images/notesd/required-paths.txt"
maild_required="$ROOT_DIR/mkosi.images/maild/required-paths.txt"
lodge_required="$ROOT_DIR/mkosi.images/lodge/required-paths.txt"
porterd_required="$ROOT_DIR/mkosi.images/porterd/required-paths.txt"
readd_required="$ROOT_DIR/mkosi.images/readd/required-paths.txt"
check 'notesd: required-paths lists notesd and notesctl' \
    has_all "$notesd_required" /usr/bin/notesd /usr/bin/notesctl
check 'maild: required-paths lists maild and mailctl' \
    has_all "$maild_required" /usr/bin/maild /usr/bin/mailctl
check 'lodge: required-paths lists lodge and lodgectl' \
    has_all "$lodge_required" /usr/bin/lodge /usr/bin/lodgectl
check 'porterd: required-paths lists porterd' \
    has_all "$porterd_required" /usr/bin/porterd
check 'readd: required-paths lists readd and readctl' \
    has_all "$readd_required" /usr/bin/readd /usr/bin/readctl
# The secrets-key oneshot ships and frostmail.service pulls it, but it has a
# condition and no [Install]: it must stay out of Upholds= and the preset.
check 'maild: required-paths lists the secrets-key unit and its helper' \
    has_all "$maild_required" /usr/lib/systemd/system/frostmail-secrets-key.service /usr/libexec/frostmail/make-secrets-key
# lodge.service must not use RuntimeDirectory= (systemd would remove /run/lodge
# and the apps' sockets with it), so the deb's tmpfiles.d fragment ships, with
# the shell and its example configuration; /etc/lodge stays the administrator's.
check 'lodge: required-paths lists the tmpfiles fragment, the shell and the example config' \
    has_all "$lodge_required" /usr/lib/tmpfiles.d/lodge.conf /usr/share/lodge/shell/index.html /usr/share/lodge/config.example.json

# The comparison helpers must reject a wrong set, not only accept the right one.
scratch=$(mktemp -d "${TMPDIR:-/tmp}/suite-sysexts-test.XXXXXX")
trap 'rm -rf "$scratch"' EXIT
printf '[Unit]\nUpholds=a.socket b.service frostmail-secrets-key.service\n' >"$scratch/dropin.conf"
printf 'enable a.socket\nenable b.service\nmask c.service\n' >"$scratch/p.preset"
printf 'enable a.socket\nenable b.service\n' >"$scratch/ok.preset"
check 'self-test: an extra upheld unit is detected' \
    differs "$(upheld_units "$scratch/dropin.conf")" "$(sorted_words a.socket b.service)"
check 'self-test: an extra preset line is detected' \
    differs "$(enabled_units "$scratch/p.preset")" "$(sorted_words a.socket b.service)"
check 'self-test: a matching preset passes' \
    same_set "$(enabled_units "$scratch/ok.preset")" "$(sorted_words a.socket b.service)"
check 'self-test: the secrets-key unit is detected' contains "$scratch/dropin.conf" frostmail-secrets-key

printf '# Results: %d passed, %d failed, %d total\n' "$PASS" "$FAIL" "$((PASS + FAIL))"
[[ $FAIL -eq 0 ]]
