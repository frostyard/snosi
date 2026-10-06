#!/bin/bash
# Contract test for the per-product core Flatpak sets (flatpaks/) and the
# org.frostyard.core-flatpaks OCI label every image build stamps from them
# (frostyard/firn ADR-0018). Firn parses the label fail-closed before it
# touches a disk, so a malformed set here would fail every opted-in install
# of that product. Pin the contract:
#  - every source file is valid and every bootc product profile is mapped
#  - snow and snowfield share one set, sundog has its own, floe has none
#  - the label value is the file's compact JSON (same bytes as `jq -c`)
#  - first-setup's generated list is in sync with snow.json
#  - check-image accepts the right label and rejects a missing, extra,
#    mismatched or malformed one
#  - producer validation rejects each malformed shape
set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
tool="$root/flatpaks/core-flatpaks.py"
label_key=org.frostyard.core-flatpaks

test_number=0
failures=0
ok() { test_number=$((test_number + 1)); echo "ok $test_number - $1"; }
fail() { test_number=$((test_number + 1)); failures=$((failures + 1)); echo "not ok $test_number - $1"; }
check() { local desc=$1; shift; if "$@" >/dev/null 2>&1; then ok "$desc"; else fail "$desc"; fi; }
refuse() { local desc=$1; shift; if "$@" >/dev/null 2>&1; then fail "$desc"; else ok "$desc"; fi; }

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

check "validate passes on the repository" "$tool" validate

label_of() { "$tool" label "$1"; }
[[ $(label_of snow) == "$label_key=$(jq -c . "$root/flatpaks/snow.json")" ]] &&
    ok "snow label is snow.json's compact JSON" || fail "snow label is snow.json's compact JSON"
[[ $(label_of snowfield) == "$(label_of snow)" ]] &&
    ok "snowfield shares snow's set" || fail "snowfield shares snow's set"
[[ $(label_of sundog) == "$label_key=$(jq -c . "$root/flatpaks/sundog.json")" ]] &&
    ok "sundog label is sundog.json's compact JSON" || fail "sundog label is sundog.json's compact JSON"
[[ -z $(label_of floe) ]] && ok "floe has no label" || fail "floe has no label"
refuse "an unknown profile is an error" "$tool" label nosuch

# check-image reads `podman image inspect` output on stdin.
inspect() { # profile label-value-or-ABSENT [nested]
    jq -n --arg k "$label_key" --arg v "$2" --arg nested "${3:-}" '
        ({"other": "x"} + (if $v == "ABSENT" then {} else {($k): $v} end)) as $labels
        | if $nested == "" then [{"Labels": $labels}] else [{"Config": {"Labels": $labels}}] end'
}
check_image() { "$tool" check-image "$1" < <(inspect "$1" "$2" "${3:-}"); }
snow_value=$(jq -c . "$root/flatpaks/snow.json")
check "check-image accepts snow's label" check_image snow "$snow_value"
check "check-image accepts a label under Config.Labels" check_image snow "$snow_value" nested
check "check-image accepts re-encoded but equal JSON" check_image snow "$(jq . "$root/flatpaks/snow.json")"
check "check-image accepts floe without the label" check_image floe ABSENT
refuse "check-image rejects floe with the label" check_image floe "$snow_value"
refuse "check-image rejects floe with an empty label" check_image floe ""
refuse "check-image rejects snow without the label" check_image snow ABSENT
refuse "check-image rejects sundog carrying snow's set" check_image sundog "$snow_value"
refuse "check-image rejects a label that is not JSON" check_image snow "not json"

# Producer validation: each malformed shape is rejected.
reject_set() { # description json
    python3 - "$tool" "$2" <<'PY' >/dev/null 2>&1 && fail "$1" || ok "$1"
import importlib.util, json, sys
spec = importlib.util.spec_from_file_location("cf", sys.argv[1])
cf = importlib.util.module_from_spec(spec)
spec.loader.exec_module(cf)
try:
    cf.check_set(json.loads(sys.argv[2]), "fixture")
except cf.Invalid:
    sys.exit(1)
PY
}
good='{"id":"org.example.App","name":"App"}'
reject_set "rejects a missing version" "{\"flatpaks\":[$good]}"
reject_set "rejects version 2" "{\"version\":2,\"flatpaks\":[$good]}"
reject_set "rejects version true" "{\"version\":true,\"flatpaks\":[$good]}"
reject_set "rejects an empty flatpaks array" '{"version":1,"flatpaks":[]}'
reject_set "rejects a null flatpaks" '{"version":1,"flatpaks":null}'
reject_set "rejects an unknown top-level field" "{\"version\":1,\"flatpaks\":[$good],\"extra\":1}"
reject_set "rejects an unknown entry field" '{"version":1,"flatpaks":[{"id":"org.example.App","name":"App","x":1}]}'
reject_set "rejects a missing name" '{"version":1,"flatpaks":[{"id":"org.example.App"}]}'
reject_set "rejects an empty name" '{"version":1,"flatpaks":[{"id":"org.example.App","name":" "}]}'
reject_set "rejects a two-element id" '{"version":1,"flatpaks":[{"id":"org.App","name":"App"}]}'
reject_set "rejects an element starting with a digit" '{"version":1,"flatpaks":[{"id":"org.1example.App","name":"App"}]}'
reject_set "rejects '-' before the last element" '{"version":1,"flatpaks":[{"id":"org.ex-ample.App","name":"App"}]}'
reject_set "rejects an id with a space" '{"version":1,"flatpaks":[{"id":"org.example.My App","name":"App"}]}'
reject_set "rejects a duplicate id" "{\"version\":1,\"flatpaks\":[$good,$good]}"
python3 - "$tool" <<'PY' >/dev/null 2>&1 && ok "accepts '-' in the last element" || fail "accepts '-' in the last element"
import importlib.util, sys
spec = importlib.util.spec_from_file_location("cf", sys.argv[1])
cf = importlib.util.module_from_spec(spec)
spec.loader.exec_module(cf)
cf.check_set({"version": 1, "flatpaks": [{"id": "org.example.my-app", "name": "App"}]}, "fixture")
PY

# validate catches an unmapped product profile, an unmapped file and a stale
# first-setup list, using a scratch copy of the repository layout.
scratch() {
    rm -rf "$tmp/repo"
    mkdir -p "$tmp/repo/mkosi.profiles"
    cp -r "$root/flatpaks" "$tmp/repo/flatpaks"
    for p in "$root"/mkosi.profiles/*/; do mkdir -p "$tmp/repo/mkosi.profiles/$(basename "$p")"; done
}
scratch
check "validate passes on a scratch copy" "$tmp/repo/flatpaks/core-flatpaks.py" validate
mkdir -p "$tmp/repo/mkosi.profiles/newproduct"
refuse "validate rejects an unmapped product profile" "$tmp/repo/flatpaks/core-flatpaks.py" validate
scratch
cp "$root/flatpaks/sundog.json" "$tmp/repo/flatpaks/orphan.json"
refuse "validate rejects a file mapped to no product" "$tmp/repo/flatpaks/core-flatpaks.py" validate
scratch
jq '.flatpaks |= .[:-1]' "$root/flatpaks/snow.json" > "$tmp/repo/flatpaks/snow.json"
refuse "validate rejects a stale first-setup list" "$tmp/repo/flatpaks/core-flatpaks.py" validate
"$tmp/repo/flatpaks/core-flatpaks.py" generate-first-setup
check "generate-first-setup brings it back in sync" "$tmp/repo/flatpaks/core-flatpaks.py" validate
jq -e '.core | length > 0 and all(.[]; has("id") and has("name"))' "$root/flatpaks/first-setup/core.json" >/dev/null &&
    ok "first-setup list has first-setup's {core:[{name,id}]} shape" ||
    fail "first-setup list has first-setup's {core:[{name,id}]} shape"

echo "# Results: $((test_number - failures)) passed, $failures failed, $test_number total"
[[ $failures -eq 0 ]]
