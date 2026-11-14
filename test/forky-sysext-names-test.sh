#!/bin/bash
# SPDX-License-Identifier: LGPL-2.1-or-later
# Fixture test for shared/suite/forky/check-sysext-names.sh (ADR-0037).
#
# The forky mechanics sysext leg passes only when every sysext of the forky
# configuration has exactly 1 versioned file with OS version 14 and no other
# versioned file exists. Each rule gets a fixture output directory that only
# that rule rejects, so a check that is dropped makes this test fail.
#
# No root, no network, no build.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
check=${CHECK_SYSEXT_NAMES:-$root/shared/suite/forky/check-sysext-names.sh}

PASS=0
FAIL=0
pass() { printf 'ok - %s\n' "$1"; PASS=$((PASS + 1)); }
fail() { printf 'not ok - %s\n' "$1" >&2; FAIL=$((FAIL + 1)); }

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

ids=(1password-cli lodge notesd)

# A complete forky output directory as sysext-postoutput.sh leaves it: the
# unversioned mkosi output, the versioned copy, the symlink <id> to it, the
# mkosi manifest and the versioned manifest, beside the base image tree.
make_output() { # directory
    local dir=$1 id
    mkdir -p "$dir/base" "$dir/gui-base"
    : >"$dir/base.manifest"
    for id in "${ids[@]}"; do
        : >"$dir/$id.raw.zst"
        : >"$dir/${id}_1.2.3+r1_14_x86-64.raw.zst"
        ln -s "${id}_1.2.3+r1_14_x86-64.raw.zst" "$dir/$id"
        : >"$dir/$id.manifest"
        : >"$dir/$id.1.2.3+r1.manifest.json"
    done
}

case_dir() { # name -> a fresh complete fixture directory
    local dir=$tmp/$1
    make_output "$dir"
    printf '%s\n' "$dir"
}

expect() { # description pass|reject|usage directory [id...] -- [text the output must name]
    local description=$1 want=$2 dir=$3
    shift 3
    local -a args=()
    while (($# > 0)) && [[ $1 != -- ]]; do
        args+=("$1")
        shift
    done
    [[ ${1:-} == -- ]] && shift
    local named=${1:-} status=0 out
    out=$("$check" "$dir" ${args[@]+"${args[@]}"} 2>&1) || status=$?
    local ok=1
    case $want in
    pass) ((status == 0)) || ok=0 ;;
    reject) ((status == 1)) || ok=0 ;;
    usage) ((status == 2)) || ok=0 ;;
    esac
    if ((ok)) && [[ -n $named ]] && ! grep -Fq -- "$named" <<<"$out"; then
        ok=0
    fi
    if ((ok)); then
        pass "$description"
    else
        fail "$description (exit $status, want $want${named:+, naming '$named'}): $(tail -n 3 <<<"$out" | paste -sd' ' -)"
    fi
}

# Positive: the complete set passes and the count is printed. The unversioned
# copy, the symlink <id>, both manifests and the base tree are not checked.
dir=$(case_dir complete)
expect "a complete forky set passes" pass "$dir" "${ids[@]}" -- \
    "3 versioned file(s) checked, 3 sysext(s) expected"

# Positive: a Debian epoch (written as <epoch>+), a tilde and a revision suffix
# stay one underscore-free field; every compression suffix is accepted.
dir=$tmp/versions
mkdir -p "$dir"
: >"$dir/lodge_1+2.0~rc1+r3_14_x86-64.raw"
: >"$dir/notesd_0.6.0_14_x86-64.raw.xz"
expect "epoch, tilde, revision and compression suffixes pass" pass "$dir" lodge notesd -- \
    "2 versioned file(s) checked"

# Mixed suites: one sysext names OS version 12 beside the forky ones.
dir=$(case_dir mixed)
rm "$dir/notesd_1.2.3+r1_14_x86-64.raw.zst"
: >"$dir/notesd_1.2.3+r1_12_x86-64.raw.zst"
expect "a _12_ file beside _14_ files is rejected" reject "$dir" "${ids[@]}" -- \
    "notesd_1.2.3+r1_12_x86-64.raw.zst names OS version 12"

# A trixie (_13_) file of an expected sysext beside its forky file.
dir=$(case_dir trixie)
: >"$dir/lodge_1.2.3+r1_13_x86-64.raw.zst"
expect "a _13_ file is rejected" reject "$dir" "${ids[@]}" -- \
    "lodge_1.2.3+r1_13_x86-64.raw.zst names OS version 13"

# A sysext of the forky configuration made no versioned file.
dir=$(case_dir missing)
rm "$dir/notesd_1.2.3+r1_14_x86-64.raw.zst"
expect "a missing expected sysext is rejected" reject "$dir" "${ids[@]}" -- \
    "no versioned file for the expected sysext 'notesd'"

# A versioned file of a sysext that the forky configuration does not build
# (sunshine is trixie-only).
dir=$(case_dir unexpected)
: >"$dir/sunshine_2026.914.233613+r1_14_x86-64.raw.zst"
expect "a sysext the forky configuration does not build is rejected" reject "$dir" "${ids[@]}" -- \
    "belongs to sysext 'sunshine'"

# Two versioned forky files for one sysext.
dir=$(case_dir duplicate)
: >"$dir/lodge_1.2.4_14_x86-64.raw.zst"
expect "2 versioned files for one sysext are rejected" reject "$dir" "${ids[@]}" -- \
    "2 versioned files for the sysext 'lodge'"

# A name with an underscore and .raw that is not the 4-field shape.
dir=$(case_dir malformed)
: >"$dir/lodge_1.2.3_x86-64.raw.zst"
expect "a versioned name without 4 fields is rejected" reject "$dir" "${ids[@]}" -- \
    "lodge_1.2.3_x86-64.raw.zst is not <id>_<version>_<os-version>_<arch>"

# Usage: no expected id (an empty derivation from the configuration), a
# missing directory, and an id that cannot be a sysext image id.
dir=$(case_dir usage)
expect "no expected id is a usage error" usage "$dir"
expect "a missing output directory is a usage error" usage "$tmp/absent" lodge
expect "an expected id with '_' is a usage error" usage "$dir" lodge bad_id

printf '# Results: %d passed, %d failed, %d total\n' "$PASS" "$FAIL" "$((PASS + FAIL))"
[[ $FAIL -eq 0 ]]
