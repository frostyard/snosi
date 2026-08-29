#!/bin/bash
# Fixture coverage for the two publication output-organizer scripts,
# manifestmv.sh and sysextmv.sh, run by build.yml / build-images.yml to sort
# freshly built artifacts into $OUTPUTDIR subdirectories before R2 upload.
#
# These scripts are otherwise untested, yet a regression in either glob pattern
# or in manifestmv's IMAGE_ID extraction (`cut -d'.' -f1`) would silently misfile
# or drop published artifacts. Both are driven entirely by $OUTPUTDIR, so they
# run unchanged here against a temp directory (no root, no build).
set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
manifestmv="$root/manifestmv.sh"
sysextmv="$root/sysextmv.sh"

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

test_number=0
failures=0

# ok <name> <condition-cmd...> — assert the command succeeds (TAP line).
ok() {
    local name=$1
    shift
    test_number=$((test_number + 1))
    if "$@"; then
        printf 'ok %d - %s\n' "$test_number" "$name"
    else
        printf 'not ok %d - %s\n' "$test_number" "$name"
        failures=$((failures + 1))
    fi
}

# fresh_out — make and echo a clean per-case OUTPUTDIR under $work.
fresh_out() {
    local d
    d=$(mktemp -d "$work/out.XXXXXX")
    printf '%s' "$d"
}

is_file() { [[ -f $1 ]]; }
not_exists() { [[ ! -e $1 ]]; }
contains() { [[ $1 == *"$2"* ]]; }

printf '1..19\n'

# --- manifestmv.sh ------------------------------------------------------------

# Single manifest is moved into a per-IMAGE_ID subdirectory.
out=$(fresh_out)
: >"$out/snow.manifest.json"
mv_out=$(OUTPUTDIR="$out" "$manifestmv")
ok "manifestmv: places snow.manifest.json under manifests/snow/" \
    is_file "$out/manifests/snow/snow.manifest.json"
ok "manifestmv: removes the manifest from the OUTPUTDIR root" \
    not_exists "$out/snow.manifest.json"

# IMAGE_ID is the text before the FIRST dot, so a dotted version stays grouped
# under the image id, not the version.
out=$(fresh_out)
: >"$out/cayo.1.2.3.manifest.json"
OUTPUTDIR="$out" "$manifestmv" >/dev/null
ok "manifestmv: IMAGE_ID is the prefix before the first dot" \
    is_file "$out/manifests/cayo/cayo.1.2.3.manifest.json"

# Distinct image ids get distinct subdirectories.
out=$(fresh_out)
: >"$out/snow.manifest.json"
: >"$out/cayo.manifest.json"
OUTPUTDIR="$out" "$manifestmv" >/dev/null
ok "manifestmv: groups snow manifest under manifests/snow/" \
    is_file "$out/manifests/snow/snow.manifest.json"
ok "manifestmv: groups cayo manifest under manifests/cayo/" \
    is_file "$out/manifests/cayo/cayo.manifest.json"

# Non-manifest artifacts are left untouched.
out=$(fresh_out)
: >"$out/snow.manifest.json"
: >"$out/snow_20260101_trixie_amd64.raw"
OUTPUTDIR="$out" "$manifestmv" >/dev/null
ok "manifestmv: leaves non-manifest artifacts in place" \
    is_file "$out/snow_20260101_trixie_amd64.raw"

# Empty directory: exit 0, friendly message, manifests/ dir still created.
out=$(fresh_out)
mv_out=$(OUTPUTDIR="$out" "$manifestmv")
status=$?
ok "manifestmv: succeeds when no manifests are present" test "$status" -eq 0
ok "manifestmv: reports the empty case" contains "$mv_out" "No manifest files found"
ok "manifestmv: creates the manifests/ directory even when empty" \
    test -d "$out/manifests"

# --- sysextmv.sh --------------------------------------------------------------

# A well-formed sysext artifact name is moved into sysexts/ (flat, not nested).
out=$(fresh_out)
: >"$out/docker_1.2.3_trixie_amd64.raw"
sx_out=$(OUTPUTDIR="$out" "$sysextmv")
ok "sysextmv: moves a sysext artifact into sysexts/" \
    is_file "$out/sysexts/docker_1.2.3_trixie_amd64.raw"
ok "sysextmv: removes the sysext artifact from the OUTPUTDIR root" \
    not_exists "$out/docker_1.2.3_trixie_amd64.raw"

# Multiple sysext artifacts all land flat in sysexts/.
out=$(fresh_out)
: >"$out/docker_1_trixie_amd64.raw"
: >"$out/k3s_2_trixie_amd64.raw"
OUTPUTDIR="$out" "$sysextmv" >/dev/null
ok "sysextmv: moves the docker sysext" is_file "$out/sysexts/docker_1_trixie_amd64.raw"
ok "sysextmv: moves the k3s sysext" is_file "$out/sysexts/k3s_2_trixie_amd64.raw"

# Names that do not match <id>_<version>_<os>_<arch>.<ext> are left alone.
out=$(fresh_out)
: >"$out/base.manifest.json"   # no underscores
: >"$out/README.txt"           # no underscores, no version fields
: >"$out/foo_bar.raw"          # only one underscore
OUTPUTDIR="$out" "$sysextmv" >/dev/null
ok "sysextmv: leaves dotted manifest names in place" is_file "$out/base.manifest.json"
ok "sysextmv: leaves plain files in place" is_file "$out/README.txt"
ok "sysextmv: leaves under-fielded names in place" is_file "$out/foo_bar.raw"

# Empty / no-match directory: exit 0, friendly message, sysexts/ still created.
out=$(fresh_out)
sx_out=$(OUTPUTDIR="$out" "$sysextmv")
status=$?
ok "sysextmv: succeeds when no sysext artifacts are present" test "$status" -eq 0
ok "sysextmv: reports the empty case" contains "$sx_out" "No sysext files found"
ok "sysextmv: creates the sysexts/ directory even when empty" test -d "$out/sysexts"

exit "$failures"
