#!/bin/bash
# Shape test for the shipped installer catalog
# (shared/firn-installer/catalog.json, installed to /etc/firn/catalog.json,
# where it REPLACES firn's builtin catalog wholesale). firn tolerates
# unknown fields and missing optional ones, so a malformed entry here fails
# soft at the worst time -- on the installer ISO. Pin the contract:
#  - bare JSON array; every entry has family/name/description
#  - family=bootc entries carry ref (immutable registry path) +
#    cosign_pub_key; family=ab entries carry product; never both
#  - every entry declares default_groups (frostyard/snosi#789), a nonempty
#    string array starting with sudo -- firn preselects these in the user
#    wizard (join-where-exists at install time)
#  - desktop entries carry the device/admin set, server entries the
#    minimal set (keep in sync with firn's builtinCatalog defaults)
set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
catalog="$root/shared/firn-installer/catalog.json"

test_number=0
failures=0
ok() { test_number=$((test_number + 1)); echo "ok $test_number - $1"; }
fail() { test_number=$((test_number + 1)); failures=$((failures + 1)); echo "not ok $test_number - $1"; }

jq -e 'type == "array" and length > 0' "$catalog" >/dev/null &&
    ok "catalog is a nonempty JSON array" || fail "catalog is a nonempty JSON array"

jq -e 'all(.[]; (.family | IN("bootc", "ab")) and .name != "" and .description != "")' "$catalog" >/dev/null &&
    ok "every entry has family/name/description" || fail "every entry has family/name/description"

jq -e 'all(.[] | select(.family == "bootc");
        (.ref | test("^ghcr\\.io/frostyard/[a-z-]+:")) and .cosign_pub_key == "/usr/lib/snosi/cosign.pub" and (has("product") | not))' "$catalog" >/dev/null &&
    ok "bootc entries carry a frostyard ref + the shipped cosign key, no product" ||
    fail "bootc entries carry a frostyard ref + the shipped cosign key, no product"

jq -e 'all(.[] | select(.family == "ab"); (.product != null) and (has("ref") | not))' "$catalog" >/dev/null &&
    ok "ab entries carry product, no ref" || fail "ab entries carry product, no ref"

jq -e 'all(.[]; (.default_groups | type == "array" and length > 0 and .[0] == "sudo" and all(.[]; type == "string" and . != "")))' "$catalog" >/dev/null &&
    ok "every entry declares default_groups, sudo first" ||
    fail "every entry declares default_groups, sudo first"

desktop='["sudo","adm","video","input","render","plugdev","netdev","lpadmin","scanner"]'
server='["sudo","adm","netdev"]'
jq -e --argjson d "$desktop" --argjson s "$server" '
    all(.[]; if (.name | test("^cayo")) then .default_groups == $s else .default_groups == $d end)' "$catalog" >/dev/null &&
    ok "desktop entries carry the device/admin set, cayo entries the server set" ||
    fail "desktop entries carry the device/admin set, cayo entries the server set"

# Every preselected group must exist in the images (join-where-exists would
# silently drop it): pinned against base's group sources plus the shared
# graphical set's packages. Static approximation: require each group to be a
# well-known Debian static group or one that base/greeter packages create.
known="sudo adm video input render plugdev netdev lpadmin scanner"
missing=$(jq -r '[.[].default_groups[]] | unique | .[]' "$catalog" | grep -vxF -f <(tr ' ' '\n' <<<"$known") || true)
if [[ -z "$missing" ]]; then
    ok "all preselected groups are in the vetted known-good set"
else
    fail "unvetted groups in default_groups: $missing (verify they exist in every image's /etc/group, then extend the known list)"
fi

echo
echo "# Results: $((test_number - failures)) passed, $failures failed, $test_number total"
((failures == 0))
