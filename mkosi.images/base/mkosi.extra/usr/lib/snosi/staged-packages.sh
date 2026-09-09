#!/bin/bash
# SPDX-License-Identifier: LGPL-2.1-or-later
# Shared staged-package inventory for `snosi-update-status --pkg-diff`
# (docs/adr/0014-update-status-pkg-diff.md). Sourced by both stagers
# (publish side) and by snosi-update-status (resolve + parse + diff side).
# Deliberately does NOT set shell options: it must be safe to source into a
# caller running under `set -euo pipefail` without changing its behavior.
#
# The staged sidecar is an identity-bound, write-once backing directory with a
# single mutating name (the symlink):
#
#   $RUN_DIR/staged-packages -> staged-packages.sha256-<64hex>   # bootc
#   $RUN_DIR/staged-packages -> staged-packages.<14-digit>       # native
#   $RUN_DIR/staged-packages.<id>/identity      # exactly one of digest=/version=
#   $RUN_DIR/staged-packages.<id>/packages.txt  # exact bytes from the staged image
#
# The backing name never contains a colon (bootc uses "sha256-" + 64 hex, not
# "sha256:"). identity uses the SAME exclusive invariant as update-staged:
# bootc writes "digest=sha256:<64hex>", native writes "version=<14-digit>",
# never both. A backing directory is created complete and never mutated; only
# the symlink is swapped, atomically, with `mv -T` (rename(2) of a symlink).

SNOSI_STAGED_PACKAGES_RUN_DIR="${SNOSI_RUN_DIR:-/run/snosi}"

# staged_packages_backing_name KIND VALUE -- the backing directory basename for
# an identity. KIND is "digest" (VALUE = sha256:<64hex>) or "version"
# (VALUE = <14-digit>). Prints nothing and returns 1 on a malformed identity.
staged_packages_backing_name() { # kind value
    local kind=$1 value=$2
    case "$kind" in
    digest)
        [[ $value =~ ^sha256:[[:xdigit:]]{64}$ ]] || return 1
        # sha256:<hex> -> sha256-<hex>; the on-disk name must never hold a colon.
        printf 'staged-packages.sha256-%s\n' "${value#sha256:}"
        ;;
    version)
        [[ $value =~ ^[0-9]{14}$ ]] || return 1
        printf 'staged-packages.%s\n' "$value"
        ;;
    *)
        return 1
        ;;
    esac
}

# staged_packages_publish KIND VALUE SRC_PACKAGES_FILE -- publish the sidecar
# for an identity from an already-captured packages.txt file. Idempotent: an
# existing backing directory of the same identity is left untouched; only the
# symlink is (re-)swapped. Never `rm`s the live symlink or a previous backing
# directory first, and never `mv -T`s a directory onto the published name (that
# would fail with "Directory not empty" on every publish after the first).
# Returns non-zero without mutating the published symlink on any error.
staged_packages_publish() { # kind value src_packages_file
    local kind=$1 value=$2 src=$3
    local run_dir="$SNOSI_STAGED_PACKAGES_RUN_DIR"
    local name backing tmpdir identity_line linktmp

    name="$(staged_packages_backing_name "$kind" "$value")" || {
        echo "staged-packages: refusing to publish a malformed $kind identity: '$value'" >&2
        return 1
    }
    case "$kind" in
    digest) identity_line="digest=$value" ;;
    version) identity_line="version=$value" ;;
    esac

    [[ -r $src ]] || {
        echo "staged-packages: source package list is missing: $src" >&2
        return 1
    }

    mkdir -p "$run_dir" || return 1
    backing="$run_dir/$name"

    # Step 1: create the backing directory complete, then rename it into place
    # under a name that must not already exist. If it exists, leave it.
    if [[ ! -e $backing ]]; then
        tmpdir="$(mktemp -d "$run_dir/.staged-packages.XXXXXX")" || return 1
        {
            printf '%s\n' "$identity_line" >"$tmpdir/identity" &&
                cp -- "$src" "$tmpdir/packages.txt"
        } || {
            rm -rf "$tmpdir"
            return 1
        }
        # `mv -T` onto a NEW name; if a racing publisher created it first, keep
        # the winner and discard ours (never overwrite an existing backing dir).
        if ! mv -T "$tmpdir" "$backing" 2>/dev/null; then
            rm -rf "$tmpdir"
            [[ -e $backing ]] || return 1
        fi
    fi

    # Steps 2-3: point the published symlink at the backing directory by
    # creating a fresh symlink and atomically renaming it over the live name.
    # `mv -T` of a symlink is an ordinary atomic rename(2) of a file; because
    # the target it clobbers is always a symlink (this being the only writer),
    # it never hits the directory case. The link target is the bare basename so
    # it resolves within run_dir regardless of how run_dir is reached.
    linktmp="$(mktemp -u "$run_dir/.staged-packages-link.XXXXXX")" || return 1
    ln -s "$name" "$linktmp" || return 1
    mv -T "$linktmp" "$run_dir/staged-packages" || {
        rm -f "$linktmp"
        return 1
    }
}

# staged_packages_resolve KIND VALUE -- resolve the published sidecar for an
# EXPECTED identity. Prints the backing directory path and returns 0 only when
# the symlink resolves to a real directory whose identity file matches the
# expected KIND/VALUE. Prints nothing and returns 1 on a missing symlink,
# dangling target, or identity mismatch (a manual stage that replaced the
# deployment cannot reuse an older inventory).
staged_packages_resolve() { # kind value
    local kind=$1 value=$2
    local run_dir="$SNOSI_STAGED_PACKAGES_RUN_DIR"
    local link="$run_dir/staged-packages" resolved expected got

    [[ -L $link || -e $link ]] || return 1
    resolved="$(readlink -f "$link" 2>/dev/null)" || return 1
    [[ -n $resolved && -d $resolved && -r "$resolved/identity" && -r "$resolved/packages.txt" ]] || return 1

    case "$kind" in
    digest) expected="digest=$value" ;;
    version) expected="version=$value" ;;
    *) return 1 ;;
    esac
    got="$(head -n1 "$resolved/identity" 2>/dev/null)" || return 1
    [[ $got == "$expected" ]] || return 1
    printf '%s\n' "$resolved"
}

# apt_list_parse FILE -- emit "<arch-qualified-name><TAB><version>" for each
# package line of an `apt list --installed` file (core ADR-0003 packages.txt).
# The comparison key is everything before the first "/" (so libfoo:amd64 and
# libfoo:i386 stay distinct; :arch is neither stripped nor invented). The
# version is the second whitespace field. `Listing...` header lines are
# skipped. This is the ONE parser; both status backends call it.
apt_list_parse() { # file
    local file=$1
    awk '
        /^Listing/ { next }
        NF == 0 { next }
        {
            split($1, a, "/")
            print a[1] "\t" $2
        }
    ' "$file"
}

# _staged_packages_section HEADER ARRAYNAME -- print an rpm-ostree-shaped
# section (header, then two-space-indented sorted entries) iff the named array
# is non-empty. Returns 0 when it printed, 1 when the array was empty.
_staged_packages_section() { # header arrayname
    local header=$1
    local -n _entries=$2
    ((${#_entries[@]})) || return 1
    printf '%s\n' "$header"
    printf '  %s\n' "${_entries[@]}" | sort
}

# pkg_diff OLD_FILE NEW_FILE -- print the Debian-package delta between two
# packages.txt files in rpm-ostree `db diff` shape. Version ordering uses
# `dpkg --compare-versions` (the dpkg database is never read). Equal versions
# are omitted; a higher new version is Upgraded, a lower one Downgraded (never
# folded together). Prints nothing when the two lists are identical.
pkg_diff() { # old_file new_file
    local old=$1 new=$2
    local -A _old=() _new=()
    local key ver ov nv
    local -a _upgraded=() _downgraded=() _added=() _removed=()

    while IFS=$'\t' read -r key ver; do
        [[ -n $key ]] && _old["$key"]=$ver
    done < <(apt_list_parse "$old")
    while IFS=$'\t' read -r key ver; do
        [[ -n $key ]] && _new["$key"]=$ver
    done < <(apt_list_parse "$new")

    for key in "${!_new[@]}"; do
        if [[ -z ${_old[$key]+x} ]]; then
            _added+=("$key ${_new[$key]}")
            continue
        fi
        ov=${_old[$key]}
        nv=${_new[$key]}
        [[ $ov == "$nv" ]] && continue
        # Order with dpkg, never by string; a dpkg-equal pair that differs only
        # textually (e.g. "1.0" vs "1.0-0") is not a change and is omitted.
        if dpkg --compare-versions "$ov" lt "$nv"; then
            _upgraded+=("$key $ov -> $nv")
        elif dpkg --compare-versions "$ov" gt "$nv"; then
            _downgraded+=("$key $ov -> $nv")
        fi
    done
    for key in "${!_old[@]}"; do
        [[ -z ${_new[$key]+x} ]] && _removed+=("$key ${_old[$key]}")
    done

    _staged_packages_section "Upgraded:" _upgraded || true
    _staged_packages_section "Downgraded:" _downgraded || true
    _staged_packages_section "Added:" _added || true
    _staged_packages_section "Removed:" _removed || true
}
