#!/bin/bash
# SPDX-License-Identifier: LGPL-2.1-or-later
# Guard: the Frostyard APT source enables the `image` component in the build
# sandbox, and nowhere else (frostyard/core ADR-0059, amended by ADR-0061).
#
# `image` holds Frostyard builds that replace Debian packages (bootc,
# libostree-1-1, incus*). Only image and sysext builds may enable it, so
# installed images ship no Frostyard APT source.
#
# Usage:
#   frostyard-apt-image-component-test.sh
#       Static: no root, no network, no image build.
#   frostyard-apt-image-component-test.sh --live IMAGE_REF [--sources FILE]
#       Run as root in CI; needs podman and network. Runs IMAGE_REF (already
#       in local storage) with mkosi.sandbox/etc/apt mounted read-only, and
#       runs `apt-get update --error-on=any` with only the Frostyard source.
#       --sources FILE replaces the sandbox frostyard.sources (negative tests).
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
sources_rel=mkosi.sandbox/etc/apt/sources.list.d/frostyard.sources

PASS=0
FAIL=0
pass() { printf 'ok - %s\n' "$1"; PASS=$((PASS + 1)); }
fail() { printf 'not ok - %s\n' "$1" >&2; FAIL=$((FAIL + 1)); }

live() { # image_ref [sources_file]
    local image=$1 sources=${2:-$root/$sources_rel}
    local apt_dir=$root/mkosi.sandbox/etc/apt

    if [[ ! -f $sources || ! -f $apt_dir/keyrings/frostyard.gpg ]]; then
        fail "missing $sources or $apt_dir/keyrings/frostyard.gpg"
        return 1
    fi
    # The container script is POSIX sh: it must also run in a minimal image.
    # shellcheck disable=SC2016
    podman run --rm --pull=never --entrypoint /bin/sh \
        -v "$apt_dir:/snosi-apt:ro" \
        -v "$sources:/snosi-frostyard.sources:ro" \
        "$image" -c '
set -eu
echo "# image /etc/apt/sources.list.d:"
ls -l /etc/apt/sources.list.d
if grep -rl repository.frostyard.org /etc/apt/sources.list /etc/apt/sources.list.d 2>/dev/null; then
    echo "not ok - the image ships a Frostyard APT source" >&2
    exit 1
fi
echo "ok - the image ships no Frostyard APT source"

mkdir -p /etc/apt/keyrings
cp /snosi-apt/keyrings/frostyard.gpg /etc/apt/keyrings/frostyard.gpg
tmp=$(mktemp -d)
mkdir -p "$tmp/sources.list.d" "$tmp/lists/partial" "$tmp/cache"
cp /snosi-frostyard.sources "$tmp/sources.list.d/frostyard.sources"
echo "# sources file under test:"
cat "$tmp/sources.list.d/frostyard.sources"

# APT::Sandbox::User=root: the _apt user cannot write the temp dir.
status=0
apt-get update --error-on=any \
    -o Dir::Etc::SourceList=/dev/null \
    -o Dir::Etc::SourceParts="$tmp/sources.list.d" \
    -o Dir::State::Lists="$tmp/lists" \
    -o Dir::Cache="$tmp/cache" \
    -o APT::Sandbox::User=root >"$tmp/apt.out" 2>&1 || status=$?
echo "# apt-get update output (rc=$status):"
cat "$tmp/apt.out"

fetched=$(ls "$tmp"/lists/*_InRelease 2>/dev/null | head -n 1 || true)
components=""
if [ -n "$fetched" ]; then
    components=$(grep -m1 "^Components:" "$fetched" || true)
fi
echo "# fetched InRelease: ${fetched:-none}"
echo "# ${components:-no Components: line}"

bad=0
source_components=$(grep -m1 "^Components:" "$tmp/sources.list.d/frostyard.sources" || true)
for want in main image; do
    case " $source_components " in
    *" $want "*) ;;
    *)
        echo "not ok - the build source lacks component $want" >&2
        bad=1
        ;;
    esac
done
if [ "$status" -ne 0 ]; then
    echo "not ok - apt-get update exited $status" >&2
    bad=1
fi
if grep -E "^(W|E|Err):" "$tmp/apt.out" >&2; then
    echo "not ok - apt-get update printed W:, E: or Err: lines" >&2
    bad=1
fi
for want in main image; do
    case " $components " in
    *" $want "*) ;;
    *)
        echo "not ok - the fetched InRelease lacks component $want" >&2
        bad=1
        ;;
    esac
done
[ "$bad" -eq 0 ] || exit 1
echo "ok - the image build source lists \`main image\` and apt-get update passed against the live repository"
'
}

scan() { # root -> "ok - "/"not ok - " lines; status 1 on any not ok
    python3 - "$1" "$sources_rel" <<'PY'
import os
import subprocess
import sys

root = os.path.abspath(sys.argv[1])
sandbox_rel = sys.argv[2]
HOST = "repository.frostyard.org"
SKIP_DIRS = ("docs/", ".memory/", "test/")
SKIP_SUFFIXES = (".md",)

failed = False


def bad(message):
    global failed
    failed = True
    print(f"not ok - {message}")


# (i) The sandbox source: one stanza, exact URIs, Suites and Components.
try:
    with open(os.path.join(root, sandbox_rel), encoding="utf-8") as f:
        text = f.read()
except OSError as err:
    text = None
    bad(f"cannot read {sandbox_rel}: {err}")

if text is not None:
    stanzas, current = [], {}
    for line in text.splitlines():
        if not line.strip():
            if current:
                stanzas.append(current)
                current = {}
        elif line.lstrip().startswith("#"):
            continue
        elif ":" in line and not line[0].isspace():
            key, _, value = line.partition(":")
            current[key.strip()] = value.strip()
    if current:
        stanzas.append(current)
    if len(stanzas) != 1:
        bad(f"{sandbox_rel} has {len(stanzas)} stanzas; it must have 1")
    else:
        stanza = stanzas[0]
        if stanza.get("URIs") != f"https://{HOST}/debian/":
            bad(f"{sandbox_rel}: URIs is {stanza.get('URIs')!r}, not "
                f"'https://{HOST}/debian/'")
        if stanza.get("Suites") != "trixie":
            bad(f"{sandbox_rel}: Suites is {stanza.get('Suites')!r}, not 'trixie'")
        tokens = stanza.get("Components", "").split()
        if sorted(tokens) != ["image", "main"]:
            bad(f"{sandbox_rel}: Components is {' '.join(tokens)!r}; it must "
                "list exactly 'main image' (core ADR-0059)")
        if not failed:
            print(f"ok - {sandbox_rel} has one stanza with Components: main image")

# (ii) No other tracked APT source names the Frostyard repository.
listed = subprocess.run(
    ["git", "-C", root, "ls-files", "-z"], check=True, capture_output=True
).stdout.decode()


def is_apt_source(path):
    return (
        path.endswith((".sources", ".list"))
        or "etc/apt/sources.list.d/" in path
    )


scanned = 0
leaks = []
for rel in sorted(p for p in listed.split("\0") if p):
    if (
        rel == sandbox_rel
        or rel.startswith(SKIP_DIRS)
        or rel.endswith(SKIP_SUFFIXES)
        or not is_apt_source(rel)
        or not os.path.isfile(os.path.join(root, rel))
    ):
        continue
    scanned += 1
    with open(os.path.join(root, rel), encoding="utf-8", errors="replace") as f:
        if HOST in f.read():
            leaks.append(rel)
for rel in leaks:
    bad(f"{rel}: an APT source other than the build sandbox names {HOST}; "
        "installed images must ship no Frostyard APT source (core ADR-0059)")
if not leaks:
    print(f"ok - no other tracked APT source names {HOST} ({scanned} files)")
sys.exit(1 if failed else 0)
PY
}

static() {
    local status=0 out
    out=$(scan "$root") || status=$?
    # Count each ok/not ok line the scan printed.
    while IFS= read -r line; do
        case $line in
        "ok - "*) pass "${line#ok - }" ;;
        "not ok - "*) fail "${line#not ok - }" ;;
        esac
    done <<<"$out"
    if ((status != 0 && FAIL == 0)); then
        fail "scan exited $status without a verdict: $out"
    fi

    # Self-checks: a guard that cannot fail is not a guard.
    local tmp
    tmp=$(mktemp -d)
    # shellcheck disable=SC2064
    trap "rm -rf '$tmp'" EXIT

    mkfixture() { # name components -> dir
        local dir=$tmp/$1
        mkdir -p "$dir/$(dirname "$sources_rel")"
        cat >"$dir/$sources_rel" <<FIX
Types: deb
URIs: https://repository.frostyard.org/debian/
Suites: trixie
Components: $2
Architectures: all amd64
Enabled: yes
Signed-By: /etc/apt/keyrings/frostyard.gpg
FIX
        git -C "$dir" init -q
        printf '%s\n' "$dir"
    }
    expect() { # description pass|reject dir [text the rejection must name]
        local description=$1 want=$2 dir=$3 named=${4:-} res=0 out
        git -C "$dir" add -A
        out=$(scan "$dir" 2>&1) || res=$?
        if [[ $want == pass && $res -eq 0 ]]; then
            pass "self-check: $description passes"
        elif [[ $want == reject && $res -ne 0 && $out == *"$named"* ]]; then
            pass "self-check: $description is detected"
        else
            fail "self-check: $description should $want (scan exit $res)"
        fi
    }

    expect "Components: main image" pass "$(mkfixture ok 'main image')"
    expect "Components: main only" reject "$(mkfixture main-only 'main')" "Components is 'main'"
    expect "Components: main image bogus" reject "$(mkfixture bogus 'main image bogus')" "Components is 'main image bogus'"
    local dir
    dir=$(mkfixture shipped 'main image')
    mkdir -p "$dir/shared/x/tree/etc/apt/sources.list.d"
    cp "$dir/$sources_rel" "$dir/shared/x/tree/etc/apt/sources.list.d/frostyard.sources"
    expect "a shipped tree frostyard.sources" reject "$dir" "shared/x/tree/etc/apt/sources.list.d/frostyard.sources: an APT source"
}

case ${1:-} in
"")
    static
    printf '# %d passed, %d failed\n' "$PASS" "$FAIL"
    ((FAIL == 0))
    ;;
--live)
    image=${2:?usage: $0 --live IMAGE_REF [--sources FILE]}
    sources=
    if [[ ${3:-} == --sources ]]; then
        sources=${4:?--sources needs a file}
    fi
    live "$image" "$sources"
    ;;
*)
    echo "usage: $0 [--live IMAGE_REF [--sources FILE]]" >&2
    exit 2
    ;;
esac
