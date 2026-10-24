#!/bin/bash
# SPDX-License-Identifier: LGPL-2.1-or-later
# Contract test for the image version manifest annotation
# (frostyard/snosi#1125).
#
# bootc 1.16.8 reads org.opencontainers.image.version from the OCI manifest
# annotation. Published snosi images carried only the config label, so
# `bootc status` showed a null version. Pin the contract:
#  - check-image-version.sh accepts a matching annotation and label, and
#    rejects a missing annotation, a wrong annotation, a mismatched label,
#    an image index, and bad arguments; it passes --authfile to skopeo
#  - buildah-package.sh writes the annotation on the plain path, refuses a
#    label that differs from os-release IMAGE_VERSION before touching
#    Buildah, and stays silent when no version label is passed
#  - every packaging lane passes the version label, checks the local image
#    with a containers-storage reference, and checks the pushed digest with
#    a docker:// reference before `latest` promotion
#
# Hermetic: no root, no network, no image build; skopeo and buildah are PATH
# shims.
set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
checker="$root/shared/outformat/image/check-image-version.sh"
packager="$root/shared/outformat/image/buildah-package.sh"
key=org.opencontainers.image.version
version=20261024123456
ref="containers-storage:ghcr.io/frostyard/snow:$version"

test_number=0
failures=0
ok() { test_number=$((test_number + 1)); echo "ok $test_number - $1"; }
fail() { test_number=$((test_number + 1)); failures=$((failures + 1)); echo "not ok $test_number - $1"; }
check() { local desc=$1; shift; if "$@" >/dev/null 2>&1; then ok "$desc"; else fail "$desc"; fi; }
refuse() { local desc=$1; shift; if "$@" >/dev/null 2>&1; then fail "$desc"; else ok "$desc"; fi; }

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

state="$tmp/state"
mkdir -p "$state/bin"

cat >"$state/bin/skopeo" <<'EOF'
#!/bin/bash
set -euo pipefail
printf '%s\n' "$*" >>"$IMAGE_VERSION_TEST_STATE/skopeo-args"
[[ ${1:-} == inspect ]] || { echo "unexpected skopeo invocation: $*" >&2; exit 99; }
mode=""
for argument in "$@"; do
    case $argument in
        --raw) mode=raw ;;
        --config) mode=config ;;
    esac
done
[[ -n $mode ]] || { echo "skopeo shim needs --raw or --config: $*" >&2; exit 99; }
[[ -z ${IMAGE_VERSION_TEST_SKOPEO_FAIL:-} ]] || { echo "fixture skopeo failure" >&2; exit 1; }
cat "$IMAGE_VERSION_TEST_STATE/$mode.json"
EOF
cat >"$state/bin/buildah" <<'EOF'
#!/bin/bash
set -euo pipefail
touch "$IMAGE_VERSION_TEST_STATE/buildah-invoked"
printf '%s\n' "$*" >>"$IMAGE_VERSION_TEST_STATE/buildah-commands"
case $1 in
    from) printf '%s\n' fixture-container ;;
    mount) mkdir -p "$IMAGE_VERSION_TEST_STATE/fs"; printf '%s\n' "$IMAGE_VERSION_TEST_STATE/fs" ;;
    umount | config | commit | rm) : ;;
    *) echo "unexpected buildah invocation: $*" >&2; exit 99 ;;
esac
EOF
chmod +x "$state/bin/skopeo" "$state/bin/buildah"

status_of() {
    local status
    set +e
    "$@" >/dev/null 2>&1
    status=$?
    set -e
    printf '%s' "$status"
}

# --- check-image-version.sh -------------------------------------------------

manifest_json() { # annotation-value-or-ABSENT
    jq -n --arg key "$key" --arg value "$1" '
        {schemaVersion: 2, mediaType: "application/vnd.oci.image.manifest.v1+json"}
        + (if $value == "ABSENT" then {} else {annotations: {($key): $value}} end)'
}
config_json() { # label-value-or-ABSENT
    jq -n --arg key "$key" --arg value "$1" '
        {config: {Labels: ({"containers.bootc": "1"}
            + (if $value == "ABSENT" then {} else {($key): $value} end))}}'
}
write_fixture() { # manifest-value config-value
    manifest_json "$1" >"$state/raw.json"
    config_json "$2" >"$state/config.json"
}
run_check() {
    PATH="$state/bin:$PATH" IMAGE_VERSION_TEST_STATE="$state" "$checker" "$@"
}

write_fixture "$version" "$version"
check "checker accepts a matching annotation and label" run_check "$ref" "$version"

write_fixture ABSENT "$version"
refuse "checker rejects a missing manifest annotation" run_check "$ref" "$version"

write_fixture 20200101000000 "$version"
refuse "checker rejects a wrong annotation value" run_check "$ref" "$version"

write_fixture "$version" 20200101000000
refuse "checker rejects a mismatched config label" run_check "$ref" "$version"

jq -n --arg key "$key" --arg value "$version" '
    {schemaVersion: 2, mediaType: "application/vnd.oci.image.index.v1+json",
     manifests: [{mediaType: "application/vnd.oci.image.manifest.v1+json",
                  digest: ("sha256:" + ("0" * 64)), size: 1}],
     annotations: {($key): $value}}' >"$state/raw.json"
config_json "$version" >"$state/config.json"
refuse "checker rejects an OCI image index" run_check "$ref" "$version"

jq -n --arg key "$key" --arg value "$version" '
    {schemaVersion: 2,
     mediaType: "application/vnd.docker.distribution.manifest.list.v2+json",
     manifests: [{mediaType: "application/vnd.docker.distribution.manifest.v2+json",
                  digest: ("sha256:" + ("0" * 64)), size: 1}],
     annotations: {($key): $value}}' >"$state/raw.json"
refuse "checker rejects a Docker manifest list" run_check "$ref" "$version"

write_fixture "$version" "$version"
rm -f "$state/skopeo-args"
auth_file="$tmp/docker-config.json"
printf '{}\n' >"$auth_file"
check "checker accepts a matching image with an auth file" \
    run_check "$ref" "$version" "$auth_file"
if grep -Fxq "inspect --raw --authfile $auth_file $ref" "$state/skopeo-args" &&
    grep -Fxq "inspect --config --authfile $auth_file $ref" "$state/skopeo-args"; then
    ok "the auth file reaches skopeo as --authfile FILE"
else
    fail "the auth file reaches skopeo as --authfile FILE"
fi

expect_status() { # description expected-status command...
    local desc=$1 expected=$2 status
    shift 2
    status=$(status_of "$@")
    if [[ $status == "$expected" ]]; then ok "$desc"; else fail "$desc (exit $status, expected $expected)"; fi
}
assert_annotation() { # value description
    if annotation_recorded "$1"; then ok "$2"; else fail "$2"; fi
}
assert_no_buildah() { # description
    if [[ -e "$state/buildah-invoked" ]]; then fail "$1"; else ok "$1"; fi
}

expect_status "checker exits 2 without arguments" 2 run_check
expect_status "checker exits 2 with one argument" 2 run_check "$ref"
expect_status "checker exits 2 with an empty expected version" 2 run_check "$ref" ""
expect_status "checker exits 2 with too many arguments" 2 \
    run_check "$ref" "$version" "$auth_file" extra
run_check_skopeo_failure() {
    PATH="$state/bin:$PATH" IMAGE_VERSION_TEST_STATE="$state" IMAGE_VERSION_TEST_SKOPEO_FAIL=1 \
        "$checker" "$@"
}
expect_status "checker exits 1 when skopeo cannot read the manifest" 1 \
    run_check_skopeo_failure "$ref" "$version"

# --- buildah-package.sh plain path -----------------------------------------

pack_root="$tmp/rootfs"
mkdir -p "$pack_root/usr/lib"
write_os_release() { printf 'ID=snosi\nIMAGE_VERSION="%s"\n' "$1" >"$pack_root/usr/lib/os-release"; }
package() {
    PATH="$state/bin:$PATH" IMAGE_VERSION_TEST_STATE="$state" "$packager" "$@"
}
reset_packaging() {
    rm -rf -- "$state/buildah-invoked" "$state/buildah-commands" "$state/fs"
}
annotation_recorded() {
    [[ -f "$state/buildah-commands" ]] &&
        grep -Fxq "config --annotation $key=$1 fixture-container" "$state/buildah-commands"
}

write_os_release "$version"
reset_packaging
check "packager succeeds with a matching os-release version" \
    package "$pack_root" localhost/fixture:1 "$key=$version"
assert_annotation "$version" "packager writes the version manifest annotation"
if [[ -f "$state/buildah-commands" ]] &&
    grep -Fxq "config --label $key=$version fixture-container" "$state/buildah-commands"; then
    ok "packager keeps the version config label"
else
    fail "packager keeps the version config label"
fi

reset_packaging
check "packager succeeds without a version label" \
    package "$pack_root" localhost/fixture:1 "org.opencontainers.image.title=fixture"
if [[ -f "$state/buildah-commands" ]] && grep -q -- '--annotation' "$state/buildah-commands"; then
    fail "packager writes no annotation without a version label"
else
    ok "packager writes no annotation without a version label"
fi

write_os_release 20200101000000
reset_packaging
refuse "packager refuses a label that differs from os-release IMAGE_VERSION" \
    package "$pack_root" localhost/fixture:1 "$key=$version"
assert_no_buildah "the mismatch is refused before any buildah call"

printf 'ID=snosi\n' >"$pack_root/usr/lib/os-release"
reset_packaging
refuse "packager refuses os-release without IMAGE_VERSION" \
    package "$pack_root" localhost/fixture:1 "$key=$version"
assert_no_buildah "the missing IMAGE_VERSION is refused before any buildah call"

write_os_release "single-$version"
sed -i "s/IMAGE_VERSION=\"single-$version\"/IMAGE_VERSION='single-$version'/" "$pack_root/usr/lib/os-release"
reset_packaging
check "packager accepts a single-quoted os-release IMAGE_VERSION" \
    package "$pack_root" localhost/fixture:1 "$key=single-$version"
assert_annotation "single-$version" "single-quoted os-release value still drives the annotation"

rm -f "$pack_root/usr/lib/os-release"
reset_packaging
check "packager succeeds on a fixture rootfs without os-release" \
    package "$pack_root" localhost/fixture:1 "$key=$version"
assert_annotation "$version" "a fixture without os-release still gets the annotation"

# --- workflow wiring --------------------------------------------------------

wiring=$(python3 - "$root" <<'PY'
import re
import sys
from pathlib import Path

root = Path(sys.argv[1])
workflows = root / ".github" / "workflows"
packager = "./shared/outformat/image/buildah-package.sh"
checker = "check-image-version.sh"
label = '"org.opencontainers.image.version=${{ steps.version.outputs.tag }}"'

problems = []
lanes = 0
for workflow in sorted(workflows.glob("*.yml")):
    steps = re.split(r"\n(?=      - name: )", workflow.read_text())
    package_steps = 0
    local_checks = 0
    pushes = []
    remote_checks = []
    for index, step in enumerate(steps):
        name = step.split("\n", 1)[0].strip()
        if packager in step:
            lanes += 1
            package_steps += 1
            if label not in step:
                problems.append(f"{workflow.name}: {name} does not pass the version label")
        if checker in step:
            if "containers-storage:" in step:
                local_checks += 1
            if "docker://" in step:
                remote_checks.append(index)
        if "buildah push" in step:
            pushes.append(index)
    if local_checks < package_steps:
        problems.append(
            f"{workflow.name}: {local_checks} local version checks for {package_steps} packaging lanes")
    for push in pushes:
        if not any(remote > push for remote in remote_checks):
            problems.append(f"{workflow.name}: no pushed-image version check after the push step at {push}")

images = (workflows / "build-images.yml").read_text()
remote_step = images.find("- name: Check image version annotation on pushed digest")
promote_step = images.find("- name: Promote validated digest to latest")
if remote_step < 0:
    problems.append("build-images.yml: no Check image version annotation on pushed digest step")
elif promote_step < 0:
    problems.append("build-images.yml: no Promote validated digest to latest step")
elif remote_step > promote_step:
    problems.append("build-images.yml: the pushed-digest version check comes after latest promotion")

for problem in problems:
    print(f"BAD {problem}")
print(f"LANES {lanes}")
PY
)
if grep -q '^BAD' <<<"$wiring"; then
    fail "every packaging lane passes and checks the version annotation: $(grep '^BAD' <<<"$wiring" | tr '\n' ' ')"
elif [[ $(sed -n 's/^LANES //p' <<<"$wiring") -ge 3 ]]; then
    ok "every packaging lane passes and checks the version annotation ($(sed -n 's/^LANES //p' <<<"$wiring") lanes)"
else
    fail "every packaging lane passes and checks the version annotation (found too few lanes: $wiring)"
fi

echo "# Results: $((test_number - failures)) passed, $failures failed, $test_number total"
[[ $failures -eq 0 ]]
