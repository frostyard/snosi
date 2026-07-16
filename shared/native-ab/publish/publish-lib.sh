#!/bin/bash
# SPDX-License-Identifier: LGPL-2.1-or-later
#
# Shared helpers for the Phase 7 publication/signing pipeline scripts
# (publish-candidate.sh, verify-remote.sh, promote.sh, withdraw.sh). Sourced,
# never executed directly.
#
# DEST addressing (docs/native-ab-contracts.md §5, plan "R2 Publication
# Contract"): every pipeline script takes a DEST argument identifying the
# publication origin's root (i.e. what R2 bucket root/custom domain root
# would be), in one of two forms, detected by literal pattern -- no probing,
# no guessing:
#
#   /absolute/or/relative/path        -- a local directory, used for the
#                                         rehearsal origin. Created if
#                                         missing. All writes are atomic
#                                         (temp file + rename) exactly like
#                                         prepare-native-publication.sh.
#   rclone:<remote>:<bucket>[/prefix] -- a real remote. Everything after the
#                                         literal "rclone:" prefix is passed
#                                         to rclone verbatim as its own
#                                         "<remote>:<path>" destination
#                                         argument. Never invoked for local
#                                         rehearsal DESTs.
#
# Every script appends the frozen path
# "os/native/v1/<product>/x86-64/" (docs/native-ab-contracts.md §5) itself,
# so DEST is always the bucket/origin root, matching the real
# repository.frostyard.org layout 1:1.
#
# Local-rehearsal Cache-Control intent: a plain `python3 -m http.server`
# origin cannot be told to emit custom response headers, so local writes
# additionally produce a "<name>.meta.json" sidecar recording the intended
# header (e.g. {"Cache-Control": "public, max-age=31536000, immutable"}).
# Real-remote uploads set the header directly via rclone's
# --header-upload flag; no sidecar is written for the rclone path.
set -euo pipefail

# ---------------------------------------------------------------------------
# Atomic local-write bookkeeping (same pattern as prepare-native-
# publication.sh: temp file next to the destination, renamed into place only
# once fully written; anything still pending on exit is removed).
# ---------------------------------------------------------------------------

declare -a _PUBLISH_LIB_PENDING_TMPFILES=()
declare -a _PUBLISH_LIB_EXTRA_CLEANUP=()

_publish_lib_cleanup() {
    local f cmd
    for f in "${_PUBLISH_LIB_PENDING_TMPFILES[@]+"${_PUBLISH_LIB_PENDING_TMPFILES[@]}"}"; do
        [[ -n "$f" && -e "$f" ]] && rm -f "$f"
    done
    for cmd in "${_PUBLISH_LIB_EXTRA_CLEANUP[@]+"${_PUBLISH_LIB_EXTRA_CLEANUP[@]}"}"; do
        eval "$cmd" || true
    done
}
trap _publish_lib_cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# register_cleanup cmd -- run `cmd` (via eval) during the shared EXIT trap,
# in addition to pending temp-file removal. Used e.g. to remove an ephemeral
# GNUPGHOME.
register_cleanup() { # cmd
    _PUBLISH_LIB_EXTRA_CLEANUP+=("$1")
}

# new_tmpfile dst -- creates+registers a temp file next to dst, result in
# $NEW_TMPFILE. Not invoked via command substitution: see
# prepare-native-publication.sh's identical note (a subshell would swallow
# the array append).
new_tmpfile() { # dst
    local dst="$1"
    mkdir -p "$(dirname "$dst")"
    NEW_TMPFILE="$(mktemp --suffix=.tmp "${dst}.XXXXXX")"
    _PUBLISH_LIB_PENDING_TMPFILES+=("$NEW_TMPFILE")
}

# commit_tmpfile tmp dst -- rename tmp into place and stop tracking it.
commit_tmpfile() { # tmp dst
    local tmp="$1" dst="$2" i
    mv -f "$tmp" "$dst"
    for i in "${!_PUBLISH_LIB_PENDING_TMPFILES[@]}"; do
        [[ "${_PUBLISH_LIB_PENDING_TMPFILES[$i]}" == "$tmp" ]] && unset '_PUBLISH_LIB_PENDING_TMPFILES[i]'
    done
}

# ---------------------------------------------------------------------------
# DEST parsing
# ---------------------------------------------------------------------------

# dest_parse dest -- sets DEST_KIND (local|rclone) and either
# DEST_LOCAL_ROOT (local) or DEST_RCLONE_TARGET (rclone, the raw
# "<remote>:<path>" string to hand to rclone).
dest_parse() { # dest
    local dest="$1"
    if [[ "$dest" == rclone:* ]]; then
        DEST_KIND=rclone
        DEST_RCLONE_TARGET="${dest#rclone:}"
        [[ -n "$DEST_RCLONE_TARGET" ]] || { echo "Error: empty rclone target in DEST '$dest'" >&2; exit 1; }
        command -v rclone >/dev/null || { echo "Error: DEST requests rclone but rclone is not installed" >&2; exit 1; }
    else
        DEST_KIND=local
        mkdir -p "$dest"
        DEST_LOCAL_ROOT="$(cd "$dest" && pwd)"
    fi
}

# product_path product -- the frozen "os/native/v1/<product>/x86-64"
# sub-path (docs/native-ab-contracts.md §5), relative to DEST root.
product_path() { # product
    echo "os/native/v1/$1/x86-64"
}

# candidate_subpath version -- relative to the product path, where
# publish-candidate.sh stages objects (this repo's own convention; not part
# of the frozen public names, never a final name).
candidate_subpath() { # version
    echo ".candidate/$1"
}

# history_subpath version -- relative to the product path, where promote.sh
# archives an outgoing signed index pair before overwriting it, and where
# withdraw.sh restores one from.
history_subpath() { # version
    echo ".history/$1"
}

# ---------------------------------------------------------------------------
# Writes: dest_put_file local-src relpath [cache-control]
# Copies local-src to DEST/relpath. For local DEST: atomic copy + optional
# ".meta.json" Cache-Control sidecar. For rclone DEST: rclone copyto with
# --header-upload when cache-control is given.
# ---------------------------------------------------------------------------

dest_put_file() { # local-src relpath [cache-control]
    local src="$1" relpath="$2" cache_control="${3:-}"
    case "$DEST_KIND" in
    local)
        local dst="$DEST_LOCAL_ROOT/$relpath" tmp
        new_tmpfile "$dst"
        tmp="$NEW_TMPFILE"
        cp --sparse=always "$src" "$tmp"
        commit_tmpfile "$tmp" "$dst"
        if [[ -n "$cache_control" ]]; then
            local meta_dst="${dst}.meta.json"
            new_tmpfile "$meta_dst"
            tmp="$NEW_TMPFILE"
            printf '{\n  "Cache-Control": "%s"\n}\n' "$cache_control" >"$tmp"
            commit_tmpfile "$tmp" "$meta_dst"
        fi
        ;;
    rclone)
        local -a args=(copyto "$src" "$DEST_RCLONE_TARGET/$relpath")
        [[ -z "$cache_control" ]] || args+=(--header-upload "Cache-Control: $cache_control")
        rclone "${args[@]}"
        ;;
    *)
        echo "Error: dest_put_file called before dest_parse" >&2
        exit 1
        ;;
    esac
}

# dest_copy_object src-relpath dst-relpath [cache-control] -- copy an object
# already present at DEST/src-relpath to DEST/dst-relpath (server-side copy
# for rclone where the backend supports it; a filesystem copy for local).
# Carries the meta.json sidecar along for local DEST.
dest_copy_object() { # src-relpath dst-relpath [cache-control]
    local src_rel="$1" dst_rel="$2" cache_control="${3:-}"
    case "$DEST_KIND" in
    local)
        [[ -f "$DEST_LOCAL_ROOT/$src_rel" ]] || {
            echo "Error: candidate object missing, cannot promote: $DEST_LOCAL_ROOT/$src_rel" >&2
            exit 1
        }
        dest_put_file "$DEST_LOCAL_ROOT/$src_rel" "$dst_rel" "$cache_control"
        ;;
    rclone)
        local -a args=(copyto "$DEST_RCLONE_TARGET/$src_rel" "$DEST_RCLONE_TARGET/$dst_rel")
        [[ -z "$cache_control" ]] || args+=(--header-upload "Cache-Control: $cache_control")
        rclone "${args[@]}"
        ;;
    esac
}

# dest_read_object relpath outfile -- fetch DEST/relpath's bytes into
# outfile, without going through HTTP (used by withdraw.sh to gpgv-verify an
# archived pair directly against the storage backend, not the public edge).
dest_read_object() { # relpath outfile
    local relpath="$1" outfile="$2"
    case "$DEST_KIND" in
    local)
        [[ -f "$DEST_LOCAL_ROOT/$relpath" ]] || return 1
        cp "$DEST_LOCAL_ROOT/$relpath" "$outfile"
        ;;
    rclone)
        rclone cat "$DEST_RCLONE_TARGET/$relpath" >"$outfile"
        ;;
    esac
}

dest_object_exists() { # relpath
    local relpath="$1"
    case "$DEST_KIND" in
    local)
        [[ -f "$DEST_LOCAL_ROOT/$relpath" ]]
        ;;
    rclone)
        rclone lsf "$DEST_RCLONE_TARGET/$relpath" >/dev/null 2>&1
        ;;
    esac
}

# ---------------------------------------------------------------------------
# HTTP verification helpers (verify-remote.sh, promote.sh)
# ---------------------------------------------------------------------------

# http_size url -- prints Content-Length via a HEAD request.
http_size() { # url
    curl -fsSL --connect-timeout 10 --max-time 30 -I "$1" |
        tr -d '\r' | awk -F': ' 'tolower($1) == "content-length" {print $2; found=1} END {if (!found) exit 1}'
}

# http_get_sha256 url -- downloads the full body and prints its sha256sum
# (the download itself is discarded; callers that also need the bytes
# should call http_get_to_file instead).
http_get_sha256() { # url
    local tmp
    tmp="$(mktemp /var/tmp/publish-lib-http.XXXXXX)"
    register_cleanup "rm -f '$tmp'"
    curl -fsSL --connect-timeout 10 --max-time 600 "$1" -o "$tmp"
    sha256sum "$tmp" | cut -d' ' -f1
}

# http_get_to_file url outfile -- full GET, saved to outfile.
http_get_to_file() { # url outfile
    curl -fsSL --connect-timeout 10 --max-time 600 "$1" -o "$2"
}

# http_range_sha256 url start end -- GETs byte range [start,end] (inclusive,
# HTTP Range semantics) and prints its sha256sum. Requires the server to
# actually honor Range (asserted by the caller via the response, since curl
# --fail treats a non-206/200 as an error only when -f catches non-2xx; a
# server that silently ignores Range and returns 200+full-body would still
# "succeed" here, so callers must additionally confirm the returned length).
http_range_sha256() { # url start end
    local tmp
    tmp="$(mktemp /var/tmp/publish-lib-http.XXXXXX)"
    register_cleanup "rm -f '$tmp'"
    curl -fsSL --connect-timeout 10 --max-time 60 -r "$2-$3" "$1" -o "$tmp"
    sha256sum "$tmp" | cut -d' ' -f1
}

# local_range_sha256 file start end -- sha256 of the same inclusive byte
# range read directly from a local file, for comparison against
# http_range_sha256's result.
local_range_sha256() { # file start end
    local file="$1" start="$2" end="$3"
    local count=$(( end - start + 1 ))
    dd if="$file" bs=1 skip="$start" count="$count" status=none | sha256sum | cut -d' ' -f1
}

# ---------------------------------------------------------------------------
# publication-info.json / SHA256SUMS readers (prepared-dir consumers)
# ---------------------------------------------------------------------------

# read_publication_info prepared-dir -- sets PUB_PRODUCT, PUB_CHANNEL,
# PUB_VERSION, PUB_DEST_PATH from prepared-dir/publication-info.json, for use
# by the sourcing script (not read within this library itself, hence the
# disable directive immediately below).
#
# PUB_DEST_PATH is the DEST-relative directory this publication run belongs
# under (e.g. "os/native/v1/cayo/x86-64" or "isos/native/v1", docs/native-ab-
# contracts.md §5) -- both prepare-native-publication.sh (OS artifacts) and
# prepare-iso-publication.sh (installer ISO) write it explicitly, so
# publish-candidate.sh/promote.sh never have to special-case which kind of
# artifact they are handling: they just publish under PUB_DEST_PATH.
# shellcheck disable=SC2034
read_publication_info() { # prepared-dir
    local info="$1/publication-info.json"
    [[ -f "$info" ]] || { echo "Error: publication-info.json not found in $1 (run prepare-native-publication.sh or prepare-iso-publication.sh first)" >&2; exit 1; }
    PUB_PRODUCT="$(jq -er '.product' "$info")"
    PUB_CHANNEL="$(jq -er '.channel' "$info")"
    PUB_VERSION="$(jq -er '.version' "$info")"
    PUB_DEST_PATH="$(jq -er '.dest_path' "$info")"
}

# candidate_object_names prepared-dir -- one filename per line, read from
# prepared-dir/SHA256SUMS (the exact set of immutable versioned objects a
# publication run produced -- root/verity/disk/efi/manifest/sbom).
candidate_object_names() { # prepared-dir
    local sums="$1/SHA256SUMS"
    [[ -f "$sums" ]] || { echo "Error: SHA256SUMS not found in $1" >&2; exit 1; }
    awk '{print $2}' "$sums"
}

# candidate_object_sha256 prepared-dir name -- expected sha256 for `name`
# per the LOCAL (unsigned, pre-upload) SHA256SUMS. Used only to verify
# uploaded bytes match what was produced locally (verify-remote.sh); never
# used as the source of truth for the final signed index (promote.sh
# regenerates that from re-downloaded bytes, per docs/native-ab-
# contracts.md's "never trust local files" step).
candidate_object_sha256() { # prepared-dir name
    awk -v n="$2" '$2 == n {print $1}' "$1/SHA256SUMS"
}
