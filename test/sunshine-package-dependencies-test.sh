#!/bin/bash
set -euo pipefail

repo_root=$(cd "$(dirname "$0")/.." && pwd)
config="$repo_root/mkosi.images/sunshine/mkosi.conf"

grep -qx '[[:space:]]*miniupnpc' "$config"

printf 'sunshine-package-dependencies-test: PASSED\n'
