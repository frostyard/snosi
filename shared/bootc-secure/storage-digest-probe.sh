# shellcheck shell=bash
# SPDX-License-Identifier: LGPL-2.1-or-later
# Shared host-podman execution of the candidate image's pinned bootc
# storage-digest probe. Sourced by buildah-package.sh, assemble-uki.sh, and
# test/bootc-secure-spike-test.sh — the probe invocation must exist in exactly
# ONE place (sibling copies of this shape have drifted before; see CLAUDE.md
# "move the behaviour rather than copying the fix").
#
# The /var/tmp bind mount is load-bearing: bootc 1.16.7 hardcodes its
# temporary composefs repository at /var/tmp INSIDE the container
# (tempfile::tempdir_in("/var/tmp") in bootc_composefs/digest.rs; TMPDIR is
# ignored), and composefs object writes open temp files with O_TMPFILE, which
# fuse-overlayfs does not support (EOPNOTSUPP, "os error 95"). GitHub runner
# image ubuntu24/20260810.271 (podman 5.8.4) sets
# mount_program = fuse-overlayfs in storage.conf, so without the bind the
# container rootfs is fuse-overlayfs and every secure packaging digest probe
# fails. Binding a host-filesystem scratch directory over /var/tmp keeps the
# objects directory on a filesystem with O_TMPFILE support. The mount changes
# only the execution environment; the digest is computed from the image in
# containers-storage, which the mount cannot affect (root-caused and fix
# proven on runner image 20260810.271, 2026-08-13).

snosi_storage_composefs_digest() { # local-image-reference
    local image=$1 scratch digest status=0
    scratch=$(mktemp -d /var/tmp/snosi-storage-digest-XXXXXX) || return 1
    digest=$(podman run --rm --privileged --pid=host \
        -v /var/lib/containers:/var/lib/containers \
        -v "$scratch":/var/tmp \
        --security-opt label=type:unconfined_t \
        "$image" \
        bootc container compute-composefs-digest-from-storage "$image" | tr -d '\n') || status=$?
    rm -rf -- "$scratch"
    [[ $status -eq 0 ]] || return "$status"
    printf '%s' "$digest"
}
