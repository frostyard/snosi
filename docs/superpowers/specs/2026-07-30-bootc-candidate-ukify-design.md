# Bootc Candidate-Image Ukify Design

## Problem

Protected `build-images.yml` run `30568330831` proved that all three secure
profiles now pass the target-library bootc version gate, prepare the signed
systemd-boot source, package a first-pass OCI image, and compute its storage
digest. Cayo, Snow, and Snowfield then fail at the same next boundary:

```text
assemble-uki.sh: line 272: ukify: command not found
Error: ukify failed
```

Each built rootfs contains the deliberately selected
`systemd-ukify 261.1-3` package from Forky. The GitHub Ubuntu host does not
provide `ukify`. The assembler's bare `ukify` invocation therefore makes the
maintained direct-ukify compatibility contract accidentally depend on an
unselected host systemd family.

This was latent while earlier gates stopped packaging before direct ukify.
No immutable image push, signature, or `latest` promotion ran in the failed
build.

## Decision

Run direct `/usr/bin/ukify` inside the already-packaged first-pass candidate
OCI image. The packager passes that local image reference to the assembler via
`SNOSI_BOOTC_SECURE_UKIFY_IMAGE`. The assembler uses `podman run --rm` with
network disabled, all Linux capabilities dropped, the existing unconfined-label convention, and explicit
`--entrypoint=/usr/bin/ukify` so future image CMD/ENTRYPOINT changes cannot
intercept the ukify arguments.

The path is verified against Debian Forky package
`systemd-ukify_261.1-3_all.deb` (SHA-256
`817b8ea0a8953f9fb4b42d91f04ed1511bbb1e76cee466497dfb955cb246aa34`):
its file list contains executable `/usr/bin/ukify` and the
`/usr/lib/systemd/ukify -> ../../bin/ukify` compatibility symlink. This is a
pinned compatibility observation, not an assumed package layout.

Ukify reads these immutable inputs directly from the candidate image:

- `/usr/lib/modules/<kernel>/vmlinuz`;
- `/usr/lib/modules/<kernel>/initramfs.img`;
- `/usr/lib/os-release`;
- the candidate's pinned `systemd-ukify` and all of its dependencies.

The assembler rejects a discovered kernel or initrd path outside the supplied
rootfs, then translates every host-side path in the current ukify arguments:

- kernel and initrd become their absolute paths below `/usr/lib/modules`;
- os-release becomes `@/usr/lib/os-release`;
- active and previous PCR private keys become fixed credential mount paths;
- MOK private key and certificate become fixed credential mount paths;
- PCR public key becomes `/run/snosi-ukify-work/pcr.pub`;
- output becomes `/run/snosi-ukify-work/uki.efi`.

No host-rootfs or host-work path may remain in the container command.

## Ephemeral Mount Contract

The candidate receives only these bind mounts:

- MOK private key, read-only;
- MOK certificate, read-only;
- active PCR private key, read-only;
- previous PCR private key, read-only only in dual-key mode;
- one assembler-owned temporary work directory, writable.

Each credential is mounted at a fixed `/run/snosi-ukify-*.key|crt` path. The
work directory is mounted at `/run/snosi-ukify-work`; it carries the generated
public PCR keys into the container and returns only `uki.efi`. The authoritative
active and optional previous public identities remain in the unmounted assembler
gate directory; the exposed copies are compared with them after successful
candidate execution before UKI validation. Public inputs do not need separate
credential mounts when already present in the work directory or candidate rootfs.

Credential mounts are never copied into the rootfs or OCI layers. The
container is removed by Podman, the first-pass image remains under the existing
packager cleanup trap, and the host work directory remains under the existing
assembler RETURN cleanup. Do not mount a credential directory wholesale, use
Podman secrets, create a retained container, or relabel credential files.

Use `--security-opt label=type:unconfined_t`, matching existing candidate-image
storage probes, rather than `:z`/`:Z` bind suffixes that mutate host labels.
Use `--network=none` and `--cap-drop=all`; ukify requires neither network nor
Linux capabilities.

The writable work directory is public-output-only by invariant. Before exposing
it to the container, run the existing caller-credential gate over the directory
and reject any private-key match. Future code must not place a private temporary
file there. After successful Podman execution, require a nonempty `uki.efi`
through its host-side bind path before continuing.

## Command And Diagnostics

The direct command remains `ukify build`; this change relocates its execution
without changing its pinned options, phases, command line, signing inputs, PCR
policy, or output validation. The container command uses fixed in-container
credential paths and the in-image kernel/initrd paths.

Preserve the current pipeline status handling: Podman's exit status is the
ukify status, any nonzero result fails assembly, and diagnostics pass through
credential redaction before reaching stderr or the sanitized retained log.
Redaction must cover both caller-side credential paths and fixed in-container
credential paths. Concretely, pass the host MOK/PCR/previous-key paths and the
fixed mounted MOK/PCR/previous-key paths to `redact_credentials`; continue its
content-based PEM block removal unchanged. The diagnostic stream and retained
log must not contain private key bytes or unredacted private-key paths.

`SNOSI_BOOTC_SECURE_UKIFY_IMAGE` is required only for an actual assembly call;
self-tests that do not assemble remain independent. An unavailable image,
missing `/usr/bin/ukify`, mount failure, command failure, or missing output is
fail-closed.

## Authority Boundaries

The first-pass candidate already determines the pre-injection storage digest.
Running ukify inside it does not make ukify a digest authority and does not
change the digest sequence:

1. Package pristine first-pass candidate.
2. Compute storage digest with bootc inside that candidate.
3. Run direct ukify inside that same candidate using ephemeral mounts.
4. Inject only the UKI and signed second stage into the directory rootfs.
5. Package the final probe image.
6. Recompute the digest with bootc inside the final candidate and require
   equality.

The first-pass candidate cannot retain output or credentials in a committed
layer because `podman run` writes only to its disposable container layer and
the explicit work bind. Existing final rootfs, OCI config/filesystem, sanitized
log, and retained-state credential scans remain authoritative.

## Rejected Alternatives

### Install Host Ukify

Ubuntu's host package belongs to a different systemd family than selected
Forky `261.1-3`. Installing it would reintroduce host/target version drift and
would require a new workflow prerequisite. It is not acceptable.

### Chroot The Directory Rootfs

Chroot would require several temporary credential and output mounts in the
mutable directory rootfs, plus procfs for any target helpers that inspect
namespaces. Candidate execution needs fewer mutable host-side boundaries and
cannot accidentally package the mount targets.

### Copy Target Ukify To The Host

`systemd-ukify` is Python and depends on its selected Python modules and target
systemd helpers. Copying only the script does not establish a coherent runtime;
copying its dependency closure duplicates the candidate image poorly.

## Test Design

Factor the Podman invocation into a focused assembler helper. Extend assembler
self-tests with a PATH-controlled Podman fixture that:

- records every argument without recording credential contents;
- asserts the exact first-pass image is selected;
- requires `--rm`, `--network=none`, `--entrypoint=/usr/bin/ukify`, and the
  unconfined label option;
- requires each private credential as an individual read-only mount;
- separately requires the MOK certificate as an individual read-only mount;
- rejects a previous-key mount in single-key mode and requires it in dual-key
  mode;
- requires exactly one writable work-directory mount;
- requires in-image kernel, initrd, os-release, PCR-public-key, and output
  paths rather than host rootfs paths;
- creates `uki.efi` only through the work mount to model successful output;
- rejects a zero-byte or absent `uki.efi` even when Podman exits zero;
- proves a nonzero Podman/ukify status propagates and retains a safe diagnostic;
- proves fixed in-container credential paths and credential values are removed
  from the sanitized log.

Extend package cleanup fixtures to require that the packager passes its exact
first-pass image reference to the controlled assembler. Keep all existing
failure cleanup and rerun coverage.

Run the assembler fixture and negative fixture suites, package cleanup fixture,
publication guard, ShellCheck, and `git diff --check`. The protected main-branch
run is the production proof against all three newly built candidate images.

## Documentation

Update `CLAUDE.md`, `README.md`, `yeti/build-pipeline.md`, and
`docs/bootc-secure-assembly-compatibility.md` to say that direct ukify executes
inside the first-pass candidate. Preserve the distinction between direct ukify
as UKI construction and candidate bootc as storage-digest authority. Record
that final host-side `.linux` and `.initrd` byte comparisons remain valid only
because the first-pass image is a byte-identical `cp -a` snapshot of those same
directory-rootfs files; changing first-pass construction requires revalidating
that invariant.

## Evidence Boundary

A green protected rerun yields one signed secure candidate set for Cayo, Snow,
and Snowfield. It is not distinct `N`, `N+1`, and `N+2` evidence, installed
Task 9 evidence, key-rotation evidence, or representative Snowfield hardware
evidence.
