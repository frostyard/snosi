#!/bin/bash
# Fetch a bounded APT Packages.gz index and print the newest package version.
set -euo pipefail

usage() {
    echo "usage: $0 <Packages.gz URL> <package>" >&2
    exit 2
}

[[ $# -eq 2 ]] || usage
url=$1
package=$2

# Test-overridable, but deliberately bounded so a bad environment cannot turn
# the safety limit into another resource-exhaustion vector.
max_compressed_bytes=${APT_INDEX_MAX_COMPRESSED_BYTES:-52428800}
max_decompressed_bytes=${APT_INDEX_MAX_DECOMPRESSED_BYTES:-52428800}
curl_max_time=${APT_INDEX_CURL_MAX_TIME:-60}
for value in "$max_compressed_bytes" "$max_decompressed_bytes" "$curl_max_time"; do
    [[ $value =~ ^[1-9][0-9]*$ ]] && ((value <= 1073741824)) || {
        echo "ERROR: invalid APT index resource limit: $value" >&2
        exit 2
    }
done

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
compressed=$tmp/Packages.gz
packages_file=$tmp/Packages

# Enforce the compressed limit in the stream as well as with curl. The stream
# cap remains effective when a server omits or lies about Content-Length.
set +e
curl --retry 3 --connect-timeout 10 --max-time "$curl_max_time" \
    --max-filesize "$max_compressed_bytes" -fsSL "$url" |
    head -c "$((max_compressed_bytes + 1))" >"$compressed"
download_status=("${PIPESTATUS[@]}")
set -e

compressed_size=$(wc -c <"$compressed")
if ((compressed_size > max_compressed_bytes)); then
    echo "ERROR: compressed APT index exceeds ${max_compressed_bytes} bytes" >&2
    exit 1
fi
if ((${download_status[0]} != 0 || ${download_status[1]} != 0)); then
    echo "ERROR: failed to download bounded APT index: $url" >&2
    exit 1
fi

# A small gzip can expand enormously. Cap decompressed output independently;
# writing one extra byte lets us distinguish an exact-limit file from a bomb.
set +e
gzip -dc "$compressed" |
    head -c "$((max_decompressed_bytes + 1))" >"$packages_file"
decompress_status=("${PIPESTATUS[@]}")
set -e

decompressed_size=$(wc -c <"$packages_file")
if ((decompressed_size > max_decompressed_bytes)); then
    echo "ERROR: decompressed APT index exceeds ${max_decompressed_bytes} bytes" >&2
    exit 1
fi
if ((${decompress_status[0]} != 0 || ${decompress_status[1]} != 0)); then
    echo "ERROR: invalid or truncated APT Packages.gz index" >&2
    exit 1
fi

latest=""
while IFS= read -r version; do
    if [[ -z $latest ]] || dpkg --compare-versions "$version" gt "$latest"; then
        latest=$version
    fi
done < <(awk -v pkg="$package" '
    /^Package: / { current = $2 }
    /^Version: / && current == pkg { print $2 }
' "$packages_file")

if [[ -z $latest ]]; then
    echo "ERROR: no version found for ${package}" >&2
    exit 1
fi
printf '%s\n' "$latest"
