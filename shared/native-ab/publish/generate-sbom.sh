#!/bin/bash
# SPDX-License-Identifier: LGPL-2.1-or-later
#
# Generates a real SPDX 2.3 JSON SBOM directly from an mkosi package
# manifest (ManifestFormat=json), closing the docs/native-ab-contracts.md §4
# gap ("`.sbom.spdx.json` generation is not yet wired into this pipeline").
#
# Deliberately does NOT shell out to syft or any other external SBOM tool:
# mkosi's own manifest.json already carries the exact package/version/
# architecture list that was actually installed into the image (it is what
# `<channel>_<version>.manifest.json` in the publication is built from), so
# a syft (or equivalent) scan of a mounted/extracted root would only be
# re-deriving data this script already has, at the cost of a host-tool
# dependency, network access to fetch it, and (for a raw disk image) root to
# mount it. This script needs none of that and is fully deterministic and
# testable with a fake manifest fixture (see test/native-publish-test.sh).
#
# Usage: generate-sbom.sh <manifest.json> <output.sbom.spdx.json> <channel> <version>
set -euo pipefail

usage() {
    echo "Usage: $0 <manifest.json> <output.sbom.spdx.json> <channel> <version>" >&2
    exit 2
}

[[ $# -eq 4 ]] || usage
MANIFEST="$1"
OUTPUT="$2"
CHANNEL="$3"
VERSION="$4"

for command in jq python3; do
    command -v "$command" >/dev/null || { echo "Error: required command not found: $command" >&2; exit 1; }
done
[[ -f "$MANIFEST" ]] || { echo "Error: manifest not found: $MANIFEST" >&2; exit 1; }

version_regex='^[0-9]{14}$'
[[ "$VERSION" =~ $version_regex ]] || {
    echo "Error: version '$VERSION' does not match the frozen grammar $version_regex (docs/native-ab-contracts.md §2)" >&2
    exit 1
}

# Atomic write, matching the rest of this pipeline: temp file next to the
# destination, renamed into place only once fully written.
mkdir -p "$(dirname "$OUTPUT")"
tmp="$(mktemp --suffix=.tmp "${OUTPUT}.XXXXXX")"
cleanup() { [[ -e "$tmp" ]] && rm -f "$tmp"; }
trap cleanup EXIT

python3 - "$MANIFEST" "$tmp" "$CHANNEL" "$VERSION" <<'PYEOF'
import json
import re
import sys
import uuid
from datetime import datetime, timezone

manifest_path, out_path, channel, version = sys.argv[1:5]

with open(manifest_path) as f:
    manifest = json.load(f)

packages = manifest.get("packages", [])

def spdx_id(name, seen):
    # SPDX SPDXID charset is [A-Za-z0-9.-] only.
    safe = re.sub(r"[^A-Za-z0-9.-]", "-", name)
    candidate = f"SPDXRef-Package-{safe}"
    n = candidate
    i = 2
    while n in seen:
        n = f"{candidate}-{i}"
        i += 1
    seen.add(n)
    return n

def purl(pkg_type, name, ver, arch):
    # deb-family purl (RFC: pkg:deb/debian/<name>@<version>?arch=<arch>).
    # Anything not typed "deb" (there is none today, but manifests are
    # data, not a closed enum) falls back to a generic "generic" purl type
    # rather than mislabeling it as deb.
    t = "deb" if pkg_type == "deb" else "generic"
    q = f"?arch={arch}" if arch else ""
    return f"pkg:{t}/debian/{name}@{ver}{q}"

seen_ids = {"SPDXRef-DOCUMENT"}
root_id = spdx_id(channel, seen_ids)

spdx_packages = [{
    "SPDXID": root_id,
    "name": channel,
    "versionInfo": version,
    "downloadLocation": "NOASSERTION",
    "supplier": "NOASSERTION",
    "licenseConcluded": "NOASSERTION",
    "licenseDeclared": "NOASSERTION",
    "copyrightText": "NOASSERTION",
    "primaryPackagePurpose": "OPERATING-SYSTEM",
}]

relationships = [{
    "spdxElementId": "SPDXRef-DOCUMENT",
    "relationshipType": "DESCRIBES",
    "relatedSpdxElement": root_id,
}]

for pkg in packages:
    name = pkg.get("name")
    ver = pkg.get("version", "")
    arch = pkg.get("architecture", "")
    pkg_type = pkg.get("type", "deb")
    if not name:
        continue
    pid = spdx_id(name, seen_ids)
    spdx_packages.append({
        "SPDXID": pid,
        "name": name,
        "versionInfo": ver,
        "downloadLocation": "NOASSERTION",
        "supplier": "NOASSERTION",
        "licenseConcluded": "NOASSERTION",
        "licenseDeclared": "NOASSERTION",
        "copyrightText": "NOASSERTION",
        "externalRefs": [{
            "referenceCategory": "PACKAGE-MANAGER",
            "referenceType": "purl",
            "referenceLocator": purl(pkg_type, name, ver, arch),
        }],
    })
    relationships.append({
        "spdxElementId": root_id,
        "relationshipType": "CONTAINS",
        "relatedSpdxElement": pid,
    })

doc = {
    "spdxVersion": "SPDX-2.3",
    "dataLicense": "CC0-1.0",
    "SPDXID": "SPDXRef-DOCUMENT",
    "name": f"{channel}-{version}",
    "documentNamespace": f"https://repository.frostyard.org/spdx/{channel}/{version}-{uuid.uuid4()}",
    "creationInfo": {
        "created": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "creators": [
            "Tool: snosi-generate-sbom",
            "Organization: Frostyard",
        ],
    },
    "packages": spdx_packages,
    "relationships": relationships,
}

with open(out_path, "w") as f:
    json.dump(doc, f, indent=2, sort_keys=True)
    f.write("\n")
PYEOF

mv -f "$tmp" "$OUTPUT"
trap - EXIT
echo "Wrote $OUTPUT ($(jq '.packages | length' "$OUTPUT") packages)"
