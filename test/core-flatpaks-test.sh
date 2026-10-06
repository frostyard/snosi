#!/bin/bash
# Contract test for the per-product core Flatpak sets (flatpaks/) and the
# org.frostyard.core-flatpaks OCI label every image build stamps from them
# (frostyard/firn ADR-0018). Firn parses the label fail-closed before it
# touches a disk, so a malformed set here would fail every opted-in install
# of that product. Pin the contract:
#  - every source file is valid and every bootc product profile is mapped
#  - snow and snowfield share one set, sundog has its own, floe has none
#  - the label value is the file's compact JSON (same bytes as `jq -c`)
#  - the generated legacy list is in sync with snow.json, and label refuses
#    to print while it is stale
#  - check-image accepts the right label and rejects a missing, extra,
#    mismatched or malformed one, and input that is not an image inspection
#  - producer validation rejects each malformed shape (as Invalid, not a crash)
set -euo pipefail
export PYTHONDONTWRITEBYTECODE=1

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
        ({"containers.bootc": "1"} + (if $v == "ABSENT" then {} else {($k): $v} end)) as $labels
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
raw_check() { "$tool" check-image "$1" <<<"$2"; }
refuse "check-image rejects an empty Labels map for floe" raw_check floe '[{"Labels":{}}]'
refuse "check-image rejects an inspection without labels for floe" raw_check floe '[{}]'
refuse "check-image rejects a raw manifest for floe" raw_check floe '{"schemaVersion":2,"layers":[]}'
refuse "check-image rejects null Config for floe" raw_check floe '[{"Config":null}]'
refuse "check-image rejects top-level null for floe" raw_check floe 'null'
refuse "check-image rejects labels without containers.bootc for floe" raw_check floe '{"Labels":{"x":"y"}}'
check "check-image accepts skopeo's top-level Labels object" raw_check floe '{"Labels":{"containers.bootc":"1"}}'
# None of those may crash: a traceback means an unhandled input shape.
for input in '[{"Labels":{}}]' '[{}]' '[{"Config":null}]' 'null' '[1]' '"x"'; do
    if "$tool" check-image floe <<<"$input" 2>&1 | grep -q Traceback; then
        fail "check-image handles $input without a traceback"
    else
        ok "check-image handles $input without a traceback"
    fi
done

# Producer validation: each malformed shape is rejected as Invalid (exit 3).
# Any other failure (a crash, a failed import) exits differently and fails.
reject_set() { # description json
    local rc=0
    python3 - "$tool" "$2" <<'PY' >/dev/null 2>&1 || rc=$?
import importlib.util, json, sys
spec = importlib.util.spec_from_file_location("cf", sys.argv[1])
cf = importlib.util.module_from_spec(spec)
spec.loader.exec_module(cf)
try:
    cf.check_set(json.loads(sys.argv[2]), "fixture")
except cf.Invalid:
    sys.exit(3)
PY
    if [[ $rc -eq 3 ]]; then ok "$1"; else fail "$1 (exit $rc, expected 3)"; fi
}
good='{"id":"org.example.App","name":"App"}'
reject_set "rejects a missing version" "{\"flatpaks\":[$good]}"
reject_set "rejects version 2" "{\"version\":2,\"flatpaks\":[$good]}"
reject_set "rejects version true" "{\"version\":true,\"flatpaks\":[$good]}"
reject_set "rejects version 1.0" "{\"version\":1.0,\"flatpaks\":[$good]}"
reject_set "rejects version \"1\"" "{\"version\":\"1\",\"flatpaks\":[$good]}"
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
# legacy list, using a scratch copy of the repository layout.
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
refuse "validate rejects a stale legacy list" "$tmp/repo/flatpaks/core-flatpaks.py" validate
refuse "label refuses to print while the legacy list is stale" "$tmp/repo/flatpaks/core-flatpaks.py" label sundog
"$tmp/repo/flatpaks/core-flatpaks.py" generate-legacy
check "generate-legacy brings it back in sync" "$tmp/repo/flatpaks/core-flatpaks.py" validate
check "label prints again once in sync" "$tmp/repo/flatpaks/core-flatpaks.py" label sundog
jq -e '.core | length > 0 and all(.[]; has("id") and has("name"))' "$root/flatpaks/legacy/firn-core-flatpaks.json" >/dev/null &&
    ok "legacy list has the {core:[{name,id}]} shape" ||
    fail "legacy list has the {core:[{name,id}]} shape"

# Every workflow lane that packages an image must compute the label, pass it
# to buildah-package.sh and check the packaged image in the very next step,
# so a new or edited lane cannot silently ship without it.
lanes=$(python3 - "$root/.github/workflows" <<'PY'
import re, sys
from pathlib import Path
found = 0
for wf in sorted(Path(sys.argv[1]).glob("*.yml")):
    steps = re.split(r"\n(?=      - name: )", wf.read_text())
    for i, step in enumerate(steps):
        if "./shared/outformat/image/buildah-package.sh" not in step:
            continue
        found += 1
        name = step.split("\n", 1)[0].strip()
        nxt = steps[i + 1].split("\n", 1)[0] if i + 1 < len(steps) else ""
        if ("core-flatpaks.py label" not in step
                or '"${core_flatpaks_label[@]}"' not in step
                or nxt.strip() != "- name: Check core Flatpak label"):
            print(f"BAD {wf.name}: {name}")
print(f"LANES {found}")
PY
)
if grep -q '^BAD' <<<"$lanes"; then
    fail "every packaging lane passes and checks the label: $(grep '^BAD' <<<"$lanes" | tr '\n' ' ')"
elif [[ $(sed -n 's/^LANES //p' <<<"$lanes") -ge 3 ]]; then
    ok "every packaging lane passes and checks the label ($(sed -n 's/^LANES //p' <<<"$lanes") lanes)"
else
    fail "every packaging lane passes and checks the label (found too few lanes: $lanes)"
fi
grep -q 'name: Check core Flatpak label on pushed digest' "$root/.github/workflows/build-images.yml" &&
    ok "the secure lane checks the label on the pushed digest" ||
    fail "the secure lane checks the label on the pushed digest"

echo "# Results: $((test_number - failures)) passed, $failures failed, $test_number total"
[[ $failures -eq 0 ]]
