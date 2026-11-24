#!/usr/bin/env bash
# SPDX-License-Identifier: LGPL-2.1-or-later
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

if (( $# > 1 )) || { (( $# == 1 )) && [[ $1 != --list ]]; }; then
  echo "Usage: $0 [--list]" >&2
  exit 2
fi

if (( $# == 0 )) && ! command -v shellcheck >/dev/null 2>&1; then
  echo "shellcheck not found: run mise install" >&2
  exit 1
fi

if (( $# == 0 )); then
  pin=$(sed -n 's/^shellcheck = "\([^"]*\)"$/\1/p' mise.toml)
  if [[ -z "$pin" ]]; then
    echo "shellcheck: no shellcheck pin in mise.toml" >&2
    exit 1
  fi
  found=$(shellcheck --version 2>/dev/null | sed -n 's/^version: //p') || found=
  if [[ "$found" != "$pin" ]]; then
    echo "shellcheck: found version ${found:-unknown}, mise.toml pins $pin: run mise install" >&2
    exit 1
  fi
fi

file_list=$(mktemp)
trap 'rm -f "$file_list"' EXIT
{
  git ls-files '*.sh' '*.chroot'
  git ls-files -z | while IFS= read -r -d '' file; do
    if [[ -f "$file" ]]; then
      awk 'FNR==1 && /^#!\/(usr\/)?bin\/(env )?(ba)?sh/ {print FILENAME} {nextfile}' "$file" 2>/dev/null
    fi
  done
} | awk '!/^saved-unused\//' | sort -u > "$file_list"
mapfile -t files < "$file_list"
if (( $# == 0 )); then
  echo "shellcheck: ${#files[@]} files"
fi
if (( ${#files[@]} == 0 )); then
  echo "::error::shellcheck: no shell scripts found" >&2
  exit 1
fi

if (( $# == 1 )); then
  printf '%s\n' "${files[@]}"
  exit 0
fi

shellcheck -S warning -x "${files[@]}"
