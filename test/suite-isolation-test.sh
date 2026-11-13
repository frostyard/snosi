#!/bin/bash
# SPDX-License-Identifier: LGPL-2.1-or-later
# Guard: the Debian release is a build input, and a trixie build is unchanged
# (ADR-0037).
#
# `mkosi --release forky --profile floe ...` overrides Release= for all images,
# and the suite-matched fragments then apply. mkosi has no way to remove a list
# item, so every suite-specific package or tree lives in a file whose [Match]
# section names one release. That makes one failure mode new: a fragment that
# matches the wrong suite, or that leaks into a trixie build.
#
# Three checks, no root, no network, no image build:
#   (a) static     every suite-matched fragment starts with [Match] and its
#                  only match is Release=<its suite>.
#   (b) isolation  in a copy of the tree with every forky-matched fragment cut
#                  down to its [Match] section, the resolved trixie summary of
#                  every profile (and of the default build) equals the summary
#                  of the real tree.
#   (c) smoke      the resolved forky Floe summary has Release=forky in every
#                  image, no trixie-backports pin, no trixie-only package, no
#                  trixie isolation pin, and the forky sandbox and extra trees
#                  (the secure contract copy too) after the trees they replace.
#
# MKOSI selects the binary (validate.yml sets MKOSI=mkosi).
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# Resolve the binary now: the isolation check runs mkosi from a copied tree.
mkosi=${MKOSI:-mkosi}
if [[ $mkosi == */* ]]; then
    mkosi=$(cd "$(dirname "$mkosi")" && pwd)/$(basename "$mkosi")
else
    mkosi=$(command -v "$mkosi")
fi
if [[ ! -x $mkosi ]]; then
    echo "not ok - mkosi binary '${MKOSI:-mkosi}' is not executable" >&2
    exit 1
fi
profiles=(floe snow snowfield sundog firn-installer)

PASS=0
FAIL=0
pass() { printf 'ok - %s\n' "$1"; PASS=$((PASS + 1)); }
fail() { printf 'not ok - %s\n' "$1" >&2; FAIL=$((FAIL + 1)); }

# ---------------------------------------------------------------------------
# (a) static: every suite-matched fragment is gated on its own release only.
# ---------------------------------------------------------------------------

suite_files() { # suite -> matching fragment paths, relative to the root
    {
        # shared/suite/<suite>/*.conf
        find shared/suite -mindepth 2 -maxdepth 2 -path "shared/suite/$1/*.conf" -print
        # any fragment named after the suite: mkosi.conf.d/<suite>.conf and
        # the <suite>.conf files that a shared mkosi.conf includes (the kernel
        # selection, the bootc pair, the secure composition)
        find . -path ./.git -prune -o -type f -name "$1.conf" -print
    } | sed 's|^\./||' | sort -u
}

check_match_section() { # file expected-release
    local file=$1 suite=$2 section="" first_section="" line
    local -a matches=()
    if [[ ! -f $file ]]; then
        fail "missing suite fragment $file"
        return 1
    fi
    while IFS= read -r line; do
        line=${line#"${line%%[![:space:]]*}"}
        line=${line%"${line##*[![:space:]]}"}
        [[ -z $line || $line == \#* ]] && continue
        if [[ $line =~ ^\[([A-Za-z0-9_.-]+)\]$ ]]; then
            section=${BASH_REMATCH[1]}
            [[ -z $first_section ]] && first_section=$section
            continue
        fi
        [[ $section == Match ]] && matches+=("$line")
    done <"$file"

    local status=0
    if [[ $first_section != Match ]]; then
        fail "$file must start with a [Match] section (first section: ${first_section:-none})"
        status=1
    fi
    if ((${#matches[@]} != 1)); then
        fail "$file [Match] must hold exactly one line, Release=$suite; found ${#matches[@]}"
        status=1
    elif [[ ${matches[0]} != "Release=$suite" ]]; then
        fail "$file [Match] is '${matches[0]}', not 'Release=$suite'"
        status=1
    fi
    ((status == 0)) || return 1
    pass "$file matches only Release=$suite"
}

# Negative self-checks: a guard that cannot fail is not a guard.
self_check_static() {
    local tmp dir
    tmp=$(mktemp -d)
    # shellcheck disable=SC2064
    trap "rm -rf '$tmp'" RETURN
    dir=$tmp/fixture
    mkdir -p "$dir/shared/suite/forky" "$dir/shared/kernel/backports"
    printf '%s\n' '[Match]' 'Release=trixie' '' '[Content]' 'Packages=x' \
        >"$dir/shared/suite/forky/mkosi.conf"
    if (check_match_section "$dir/shared/suite/forky/mkosi.conf" forky) >/dev/null 2>&1; then
        fail "self-check: a wrong Release= was not detected"
    else
        pass "self-check: a wrong Release= is detected"
    fi
    printf '%s\n' '[Content]' 'Packages=x' '' '[Match]' 'Release=forky' \
        >"$dir/shared/suite/forky/mkosi.conf"
    if (check_match_section "$dir/shared/suite/forky/mkosi.conf" forky) >/dev/null 2>&1; then
        fail "self-check: a [Match] section that is not first was not detected"
    else
        pass "self-check: a [Match] section that is not first is detected"
    fi
    printf '%s\n' '[Match]' 'Release=forky' 'Distribution=debian' '' '[Content]' 'Packages=x' \
        >"$dir/shared/suite/forky/mkosi.conf"
    if (check_match_section "$dir/shared/suite/forky/mkosi.conf" forky) >/dev/null 2>&1; then
        fail "self-check: a second [Match] line was not detected"
    else
        pass "self-check: a second [Match] line is detected"
    fi
    printf '%s\n' '[Match]' 'Release=forky' '' '[Content]' 'Packages=x' \
        >"$dir/shared/suite/forky/mkosi.conf"
    if (check_match_section "$dir/shared/suite/forky/mkosi.conf" forky) >/dev/null 2>&1; then
        pass "self-check: a correct fragment passes"
    else
        fail "self-check: a correct fragment was rejected"
    fi
}

check_static() {
    local suite file found=0
    for suite in forky trixie; do
        while IFS= read -r file; do
            [[ -n $file ]] || continue
            found=$((found + 1))
            check_match_section "$file" "$suite" || true
        done < <(suite_files "$suite")
    done
    if ((found == 0)); then
        fail "no suite-matched fragments found; the discovery pattern is stale"
    fi
    # shared/suite/<name>/ is the convention for a suite's own files: every
    # *.conf below such a directory must be a matched fragment above.
    while IFS= read -r file; do
        [[ -n $file ]] || continue
        case $file in
        shared/suite/forky/* | shared/suite/trixie/*) ;;
        *) fail "$file lives in a suite directory but matches no known suite" ;;
        esac
    done < <(find shared/suite -mindepth 2 -maxdepth 2 -name '*.conf' -print | sort)
    self_check_static
}

# ---------------------------------------------------------------------------
# (b) isolation: the forky content cannot change a trixie resolution.
# ---------------------------------------------------------------------------

copy_tree() { # destination
    local dest=$1 rel
    mkdir -p "$dest"
    while IFS= read -r -d '' rel; do
        mkdir -p "$dest/$(dirname "$rel")"
        cp -a "$rel" "$dest/$rel"
    done < <(git -C "$root" ls-files -co --exclude-standard -z)
}

# Cut a fragment down to its [Match] section: the file then matches forky and
# contributes nothing else, so a leak of its settings into trixie shows up as a
# difference between the two summaries.
cut_to_match() { # source destination
    awk '
        /^[[:space:]]*\[/ { inmatch = ($0 ~ /^\[Match\][[:space:]]*$/) }
        inmatch { print }
    ' "$1" >"$2"
}

normalise() { # file real-root copy-root
    # Two runs of one configuration still differ in the config directory name
    # (mkosi's "Machine"), its absolute path, the random repart seed and the
    # temporary tools-tree extract path.
    sed -e "s|$2|<ROOT>|g" -e "s|$3|<ROOT>|g" \
        -e 's|/tmp/tmp[A-Za-z0-9_]*/|<EXTRACT>/|g' \
        -e 's|"Seed": "[0-9a-f-]*"|"Seed": "<SEED>"|g' \
        "$1"
}

summary() { # directory [extra mkosi argument...]
    local dir=$1
    shift
    ( cd "$dir" && "$mkosi" --image-version 0 "$@" --json summary )
}

check_isolation() {
    local tmp copy rel diffcount=0
    tmp=$(mktemp -d)
    # shellcheck disable=SC2064
    trap "rm -rf '$tmp'" RETURN
    copy=$tmp/$(basename "$root")
    copy_tree "$copy"
    while IFS= read -r rel; do
        [[ -n $rel ]] || continue
        cut_to_match "$root/$rel" "$copy/$rel"
    done < <(suite_files forky)
    if [[ ! -f $copy/mkosi.conf ]]; then
        fail "the isolation copy is incomplete: no mkosi.conf in $copy"
        return 1
    fi

    local -a args
    for profile in "${profiles[@]}" default; do
        args=()
        [[ $profile == default ]] || args=(--profile "$profile")
        if ! summary "$root" ${args[@]+"${args[@]}"} >"$tmp/$profile.real" 2>"$tmp/$profile.err"; then
            fail "trixie summary of $profile failed in the real tree: $(tail -n 3 "$tmp/$profile.err" | paste -sd' ' -)"
            diffcount=$((diffcount + 1))
            continue
        fi
        if ! summary "$copy" ${args[@]+"${args[@]}"} >"$tmp/$profile.copy" 2>"$tmp/$profile.err"; then
            fail "trixie summary of $profile failed in the isolation copy: $(tail -n 3 "$tmp/$profile.err" | paste -sd' ' -)"
            diffcount=$((diffcount + 1))
            continue
        fi
        normalise "$tmp/$profile.real" "$root" "$copy" >"$tmp/$profile.real.n"
        normalise "$tmp/$profile.copy" "$root" "$copy" >"$tmp/$profile.copy.n"
        if diff -u "$tmp/$profile.real.n" "$tmp/$profile.copy.n" >"$tmp/$profile.diff"; then
            pass "the forky fragments cannot change the trixie $profile summary"
        else
            fail "the forky fragments change the trixie $profile summary:"
            head -n 20 "$tmp/$profile.diff" >&2
            diffcount=$((diffcount + 1))
        fi
    done
    ((diffcount == 0))
}

# ---------------------------------------------------------------------------
# (c) smoke: the forky resolution is the one the build needs.
# ---------------------------------------------------------------------------

check_forky_smoke() {
    local tmp json status=0 out
    tmp=$(mktemp -d)
    # shellcheck disable=SC2064
    trap "rm -rf '$tmp'" RETURN
    json=$tmp/forky.json
    if ! summary "$root" --release forky --profile floe >"$json" 2>"$tmp/err"; then
        fail "the forky Floe summary failed: $(tail -n 3 "$tmp/err" | paste -sd' ' -)"
        return 1
    fi
    out=$(python3 - "$root" "$json" <<'PY'
import json
import sys

root, path = sys.argv[1], sys.argv[2]
images = json.load(open(path, encoding="utf-8"))["Images"]
suite = f"{root}/shared/suite/forky"
bad = False


def ok(message):
    print(f"ok - {message}")


def not_ok(message):
    global bad
    bad = True
    print(f"not ok - {message}")


for image in images:
    name = image.get("Image") or "<root>"
    if image.get("Release") != "forky":
        not_ok(f"{name}: Release is {image.get('Release')!r}, not 'forky'")
    else:
        ok(f"{name}: Release is forky")

suffixed = sorted(
    {
        package
        for image in images
        for package in image.get("Packages") or []
        if package.endswith("/trixie-backports")
    }
)
if suffixed:
    not_ok(f"a trixie-backports pin survives a forky build: {suffixed}")
else:
    ok("no package pins trixie-backports")

low_memory = sorted(
    image.get("Image") or "<root>"
    for image in images
    if "low-memory-monitor" in (image.get("Packages") or [])
)
if low_memory:
    not_ok(f"low-memory-monitor is trixie-only but is installed for: {low_memory}")
else:
    ok("low-memory-monitor is absent")

def trees(image, key):
    return [entry.get("Source") for entry in image.get(key) or []]


for image in images:
    name = image.get("Image") or "<root>"
    sandbox = trees(image, "SandboxTrees")
    ours = f"{suite}/sandbox"
    if ours not in sandbox:
        not_ok(f"{name}: SandboxTrees has no {ours}")
        continue
    if sandbox.index(ours) < sandbox.index(f"{root}/mkosi.sandbox"):
        not_ok(f"{name}: {ours} comes before mkosi.sandbox")
    else:
        ok(f"{name}: the forky sandbox comes after mkosi.sandbox")

base = next((i for i in images if i.get("Image") == "base"), None)
if base is None:
    not_ok("no base image in the forky Floe summary")
else:
    extra = trees(base, "ExtraTrees")
    ours = f"{suite}/base-tree"
    if ours not in extra:
        not_ok(f"base: ExtraTrees has no {ours}")
    elif extra.index(ours) < extra.index(f"{root}/mkosi.images/base/mkosi.extra"):
        not_ok(f"base: {ours} comes before mkosi.images/base/mkosi.extra")
    else:
        ok("base: the forky base tree comes after mkosi.images/base/mkosi.extra")

main = next((i for i in images if i.get("Image") == "main"), None)
if main is None:
    not_ok("no main image in the forky Floe summary")
else:
    extra = trees(main, "ExtraTrees")
    ours = f"{suite}/floe-tree"
    if ours not in extra:
        not_ok(f"main: ExtraTrees has no {ours}")
    elif extra.index(ours) < extra.index(f"{root}/shared/floe/tree"):
        not_ok(f"main: {ours} comes before shared/floe/tree")
    else:
        ok("main: the forky Floe tree comes after shared/floe/tree")
    # The forky secure contract must replace the trixie contract.
    secure = f"{root}/shared/bootc-secure/tree"
    ours = f"{root}/shared/bootc-secure/suite/forky/tree"
    if ours not in extra or secure not in extra:
        not_ok(f"main: ExtraTrees needs both {secure} and {ours}")
    elif extra.index(ours) < extra.index(secure):
        not_ok(f"main: {ours} comes before {secure}")
    else:
        ok("main: the forky secure contract tree comes after shared/bootc-secure/tree")

# The trixie isolation pin (a low-priority forky source) is trixie-only: the
# forky sandbox gives a forky build its sources.
isolation = f"{root}/shared/bootc-secure/package-manager"
leaked = sorted(
    image.get("Image") or "<root>"
    for image in images
    if isolation in trees(image, "SandboxTrees")
)
if leaked:
    not_ok(f"the trixie isolation pin {isolation} reaches a forky build: {leaked}")
else:
    ok("the trixie isolation pin of shared/bootc-secure is absent")

trixie_libgpgme = sorted(
    image.get("Image") or "<root>"
    for image in images
    if "libgpgme11t64" in (image.get("Packages") or [])
)
if trixie_libgpgme:
    not_ok(f"libgpgme11t64 is trixie-only but is installed for: {trixie_libgpgme}")
else:
    ok("libgpgme11t64 is absent")

sys.exit(1 if bad else 0)
PY
) || status=$?
    while IFS= read -r line; do
        case $line in
        "ok - "*) pass "${line#ok - }" ;;
        "not ok - "*) fail "${line#not ok - }" ;;
        esac
    done <<<"$out"
    if ((status != 0 && FAIL == 0)); then
        fail "the forky Floe check exited $status without a verdict"
    fi
    ((status == 0))
}

check_static
check_isolation || true
check_forky_smoke || true

printf '# Results: %d passed, %d failed, %d total\n' "$PASS" "$FAIL" "$((PASS + FAIL))"
[[ $FAIL -eq 0 ]]
