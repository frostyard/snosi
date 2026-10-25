#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/usr/libexec" "$tmp/usr/bin"
for executable in usr/libexec/gvfsd-wsdd usr/bin/wsdd; do
    printf '#!/bin/sh\nexit 0\n' > "$tmp/$executable"
    chmod +x "$tmp/$executable"
done
BUILDROOT="$tmp" shared/snow/finalize/wsdd-provider.finalize
for executable in usr/libexec/gvfsd-wsdd usr/bin/wsdd; do
    chmod -x "$tmp/$executable"
    if BUILDROOT="$tmp" shared/snow/finalize/wsdd-provider.finalize; then
        echo "FAIL: accepted missing/non-executable $executable" >&2
        exit 1
    fi
    chmod +x "$tmp/$executable"
done
echo "PASS: WSD build guard requires both executable providers"
