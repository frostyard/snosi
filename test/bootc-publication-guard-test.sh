#!/bin/bash
# SPDX-License-Identifier: LGPL-2.1-or-later
set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
guard="$root/check-bootc-publication-guard.sh"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

pass=0
fail=0

ok() {
    printf 'ok %d - %s\n' "$((++pass))" "$1"
}

not_ok() {
    printf 'not ok %d - %s\n' "$((++fail))" "$1" >&2
}

make_fixture() {
    local fixture=$1 profile
    mkdir -p "$fixture/mkosi.profiles" \
        "$fixture/shared/native-ab/keys" \
        "$fixture/shared/bootc-secure/tree/etc/containers/registries.d" \
        "$fixture/shared/bootc-secure/tree/usr/lib/snosi" \
        "$fixture/shared/bootc-secure/ci" \
        "$fixture/.github/workflows"

    for profile in cayo snow snowfield; do
        mkdir -p "$fixture/mkosi.profiles/$profile"
        printf 'Include=%%D/shared/bootc-secure/mkosi.conf\n' >"$fixture/mkosi.profiles/$profile/mkosi.conf"
    done
    mkdir -p "$fixture/mkosi.profiles/cayo-ab"
    printf 'Include=%%D/shared/outformat/ab-root/mkosi.conf\n' >"$fixture/mkosi.profiles/cayo-ab/mkosi.conf"

    : >"$fixture/cosign.pub"
    : >"$fixture/shared/native-ab/keys/mok-2026.crt"
    : >"$fixture/shared/native-ab/keys/pcr-signing-2026.pub"
    : >"$fixture/shared/bootc-secure/tree/etc/containers/policy.json"
    : >"$fixture/shared/bootc-secure/tree/etc/containers/registries.d/frostyard.yaml"
    : >"$fixture/shared/bootc-secure/tree/usr/lib/snosi/bootc-secure.json"

    cat >"$fixture/shared/bootc-secure/ci/verify-published-image.sh" <<'EOF'
inspection=$(skopeo inspect --authfile "$AUTH_FILE" \
    "docker://$IMAGE@$EXPECTED_DIGEST")
tag_digest=$(skopeo inspect --authfile "$AUTH_FILE" --format '{{.Digest}}' \
    "docker://$IMAGE:$VERSION_TAG")
if [[ $tag_digest != "$EXPECTED_DIGEST" ]]; then
    exit 1
fi
auth_dir=$(dirname -- "$AUTH_FILE")
DOCKER_CONFIG=$auth_dir cosign verify --key "$ROOT_DIR/cosign.pub" \
    "$IMAGE@$EXPECTED_DIGEST" >/dev/null
sudo skopeo copy --src-authfile "$AUTH_FILE" \
    "docker://$IMAGE@$EXPECTED_DIGEST" "containers-storage:$LOCAL_REF"
jq -e --arg digest "$EXPECTED_DIGEST" '
    .Digest == $digest and
    .Labels["io.snosi.bootc.secureboot-capable"] == "true" and
    .Labels["io.snosi.bootc.secureboot-assembly"] == "bootc-1.16.3-storage-digest-v1"
' <<<"$inspection" >/dev/null
EOF

    cat >"$fixture/shared/bootc-secure/ci/promote-published-image.sh" <<'EOF'
skopeo copy --all \
    --src-authfile "$AUTH_FILE" --dest-authfile "$AUTH_FILE" \
    "docker://$IMAGE@$EXPECTED_DIGEST" "docker://$IMAGE:latest"
latest_digest=$(skopeo inspect --authfile "$AUTH_FILE" \
    --format '{{.Digest}}' "docker://$IMAGE:latest")
if [[ $latest_digest != "$EXPECTED_DIGEST" ]]; then
    exit 1
fi
EOF

    : >"$fixture/shared/bootc-secure/ci/resolve-snow-release-predecessor.sh"

    cat >"$fixture/.github/workflows/build-images.yml" <<'EOF'
jobs:
  secure-build:
    if: >-
      github.event_name != 'pull_request' &&
      github.ref == 'refs/heads/main'
    environment: native-build
    permissions:
      packages: write
    steps:
      - name: Materialize protected bootc signing credentials
        env:
          NATIVE_SECURE_BOOT_KEY: ${{ secrets.NATIVE_SECURE_BOOT_KEY }}
          NATIVE_SECURE_BOOT_CERTIFICATE: ${{ secrets.NATIVE_SECURE_BOOT_CERTIFICATE }}
          NATIVE_PCR_SIGNING_KEY: ${{ secrets.NATIVE_PCR_SIGNING_KEY }}
          NATIVE_PCR_SIGNING_CERTIFICATE: ${{ secrets.NATIVE_PCR_SIGNING_CERTIFICATE }}
      - name: Package image
        env:
          MAX_LAYERS: 128
          SNOSI_BOOTC_SECURE: "1"
          SNOSI_BOOTC_MOK_KEY: /var/tmp/bootc-secure-credentials/mok.key
          SNOSI_BOOTC_MOK_CERT: /var/tmp/bootc-secure-credentials/mok.crt
          SNOSI_BOOTC_PCR_KEY: /var/tmp/bootc-secure-credentials/pcr.key
          SNOSI_BOOTC_PCR_CERT: /var/tmp/bootc-secure-credentials/pcr.pub
        run: |
          SOURCE_DATE_EPOCH=$(git log -1 --format=%ct)
          sudo TMPDIR="$TMPDIR" \
            SOURCE_DATE_EPOCH="$SOURCE_DATE_EPOCH" \
            MAX_LAYERS="$MAX_LAYERS" \
            SNOSI_BOOTC_SECURE="$SNOSI_BOOTC_SECURE" \
            SNOSI_BOOTC_MOK_KEY="$SNOSI_BOOTC_MOK_KEY" \
            SNOSI_BOOTC_MOK_CERT="$SNOSI_BOOTC_MOK_CERT" \
            SNOSI_BOOTC_PCR_KEY="$SNOSI_BOOTC_PCR_KEY" \
            SNOSI_BOOTC_PCR_CERT="$SNOSI_BOOTC_PCR_CERT" \
            ./shared/outformat/image/buildah-package.sh output/cayo localhost/cayo:version
      - name: Validate locally assembled secure artifact
        run: |
          sudo ./test/bootc-secure-artifact-test.sh \
            "output/${{ matrix.profile }}" localhost/cayo:version mok.crt pcr.pub
       - name: Remove protected bootc signing credentials
        if: always()
        run: sudo rm -rf /var/tmp/bootc-secure-credentials
       - name: Push immutable version tag
        env:
          GH_TOKEN: ${{ secrets.GITHUB_TOKEN }}
        run: |
          printf '%s' "$GH_TOKEN" | sudo buildah login -u "${{ github.actor }}" --password-stdin ghcr.io
       - name: Log in to ghcr.io
        uses: docker/login-action@c94ce9fb468520275223c153574b00df6fe4bcc9 # v3
        with:
          password: ${{ secrets.GITHUB_TOKEN }}
       - name: Sign immutable image digest
      - name: Verify pushed secure image
        run: |
          AUTH_FILE="${DOCKER_CONFIG:-$HOME/.docker}/config.json"
          ./shared/bootc-secure/ci/verify-published-image.sh \
            "$IMAGE" "$VERSION_TAG" "$DIGEST" "$LOCAL_REF" "$AUTH_FILE"
      - name: Validate policy-copied secure artifact
        run: |
          sudo ./test/bootc-secure-artifact-test.sh \
            "output/${{ matrix.profile }}" "$LOCAL_REF" mok.crt pcr.pub
       - name: Promote validated digest to latest
        run: |
          AUTH_FILE="${DOCKER_CONFIG:-$HOME/.docker}/config.json"
          ./shared/bootc-secure/ci/promote-published-image.sh \
            "$IMAGE" "${{ steps.push.outputs.digest }}" "$AUTH_FILE"
       - name: Login to GHCR with ORAS
        env:
          GH_TOKEN: ${{ secrets.GITHUB_TOKEN }}
        run: |
          printf '%s' "$GH_TOKEN" | oras login ghcr.io -u "${{ github.actor }}" --password-stdin
       - name: Upload SBOM
       - name: Sign SBOM
       - name: Attest build provenance
       - name: Upload manifests to R2
       - name: Record snow tag for release job
        if: matrix.profile == 'snow'
       - name: Upload snow tag artifact
        if: matrix.profile == 'snow'
  release:
    permissions:
      packages: read
    steps:
      - name: Read snow tag
      - name: Checkout repository
        if: steps.current.outputs.tag != ''
        uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1
        with:
          persist-credentials: false
      - name: Install ORAS
        uses: oras-project/setup-oras@38de303aac69abb66f3e6255b7198bff35f323e3 # v2
      - name: Login to GHCR with ORAS
        env:
          GH_TOKEN: ${{ secrets.GITHUB_TOKEN }}
        run: |
          printf '%s' "$GH_TOKEN" | oras login ghcr.io -u "${{ github.actor }}" --password-stdin
      - name: Resolve previous and current snow tags
        run: |
          ./shared/bootc-secure/ci/resolve-snow-release-predecessor.sh \
            "$GITHUB_REPOSITORY" "$IMAGE" "$CURRENT" "$GITHUB_OUTPUT"
EOF
    perl -pi -e 's/^       - /      - /' "$fixture/.github/workflows/build-images.yml"
}

assert_guard() {
    local description=$1 expected=$2 fixture="$work/$pass"
    shift 2
    make_fixture "$fixture"
    "$@" "$fixture"
    if SNOSI_BOOTC_GUARD_ROOT="$fixture" "$guard" >/dev/null 2>&1; then
        status=0
    else
        status=1
    fi
    if [[ $status == "$expected" ]]; then
        ok "$description"
    else
        not_ok "$description"
    fi
}

unchanged() { :; }
remove_secure_include() { rm "$1/mkosi.profiles/cayo/mkosi.conf"; }
add_native_secure_include() { printf 'Include=%%D/shared/bootc-secure/mkosi.conf\n' >>"$1/mkosi.profiles/cayo-ab/mkosi.conf"; }
remove_required_file() { rm "$2/$1"; }
remove_environment() { perl -0pi -e 's/    environment: native-build\n//' "$1/.github/workflows/build-images.yml"; }
permit_pull_request() { perl -0pi -e "s/github\.event_name != 'pull_request'/github.event_name == 'pull_request'/" "$1/.github/workflows/build-images.yml"; }
permit_pull_request_with_or() { perl -0pi -e "s/ &&\n      github\.ref == 'refs\/heads\/main'/ || github.ref == 'refs\/heads\/main'/" "$1/.github/workflows/build-images.yml"; }
remove_main_condition() { perl -0pi -e "s/      github\.ref == 'refs\/heads\/main'\n//" "$1/.github/workflows/build-images.yml"; }
allow_shell_or() { perl -0pi -e 's{(        run: sudo rm -rf /var/tmp/bootc-secure-credentials)}{$1 || exit 1}' "$1/.github/workflows/build-images.yml"; }
remove_package_variable() { perl -0pi -e "s/          $1:.*\n//" "$2/.github/workflows/build-images.yml"; }
remove_forwarded_package_variable() {
    perl -0pi -e "s/^            $1=\\\"\\\$$1\\\" \\\\\n//m" \
        "$2/.github/workflows/build-images.yml"
}
remove_sudo_tmpdir() { perl -0pi -e 's/^          sudo TMPDIR="\$TMPDIR" \\\n//m' "$1/.github/workflows/build-images.yml"; }
remove_source_epoch_forwarding() {
    perl -0pi -e 's/^            SOURCE_DATE_EPOCH="\$SOURCE_DATE_EPOCH" \\\n//m' \
        "$1/.github/workflows/build-images.yml"
}
remove_max_layers_environment() { perl -0pi -e 's/^\s+MAX_LAYERS: 128\n//m' "$1/.github/workflows/build-images.yml"; }
remove_source_epoch_derivation() { perl -0pi -e 's/^\s+SOURCE_DATE_EPOCH=\$\(git log -1 --format=%ct\)\n//m' "$1/.github/workflows/build-images.yml"; }
remove_max_layers_forwarding() {
    perl -0pi -e 's/^            MAX_LAYERS="\$MAX_LAYERS" \\\n//m' "$1/.github/workflows/build-images.yml"
}
add_post_package_chunk() {
    perl -0pi -e 's/(      - name: Validate locally assembled secure artifact)/      - name: Chunk image\n        run: .\/shared\/outformat\/image\/chunkah-package.sh image epoch\n$1/' \
        "$1/.github/workflows/build-images.yml"
}
add_direct_secure_chunk() {
    perl -0pi -e 's/(      - name: Validate locally assembled secure artifact)/      - name: Arbitrary name\n        run: .\/shared\/outformat\/image\/chunkah-package.sh image epoch\n$1/' \
        "$1/.github/workflows/build-images.yml"
}
remove_cleanup_condition() { perl -0pi -e 's/        if: always\(\)\n//' "$1/.github/workflows/build-images.yml"; }
break_label_check() { perl -0pi -e 's/== "true"/== "false"/' "$1/shared/bootc-secure/ci/verify-published-image.sh"; }
remove_label_check() { perl -0pi -e 's/    \.Labels\["io\.snosi\.bootc\.secureboot-capable"\].*\n//' "$1/shared/bootc-secure/ci/verify-published-image.sh"; }
remove_workflow_auth_handoff() {
    perl -0pi -e 's/^          AUTH_FILE=.*\n//m; s/ "\$AUTH_FILE"\n/\n/' \
        "$1/.github/workflows/build-images.yml"
}
remove_verifier_src_authfile() {
    perl -0pi -e 's/ --src-authfile "\$AUTH_FILE"//' \
        "$1/shared/bootc-secure/ci/verify-published-image.sh"
}
remove_digest_inspect_auth() {
    perl -0pi -e 's/skopeo inspect --authfile "\$AUTH_FILE"/skopeo inspect/' \
        "$1/shared/bootc-secure/ci/verify-published-image.sh"
}
remove_cosign_docker_config() {
    perl -0pi -e 's/DOCKER_CONFIG=\$auth_dir cosign/cosign/' \
        "$1/shared/bootc-secure/ci/verify-published-image.sh"
}
remove_tag_binding() {
    perl -0pi -e 's/^tag_digest=.*?^fi\n//ms' \
        "$1/shared/bootc-secure/ci/verify-published-image.sh"
}
add_ghcr_pat_reference() { printf '\n# GHCR_PAT\n' >>"$1/.github/workflows/build-images.yml"; }
remove_secure_packages_write() { perl -0pi -e 's/^      packages: write\n//m' "$1/.github/workflows/build-images.yml"; }
remove_release_packages_read() { perl -0pi -e 's/^      packages: read\n//m' "$1/.github/workflows/build-images.yml"; }
remove_push_github_token() {
    perl -0pi -e 's/(      - name: Push immutable version tag\n        env:\n)          GH_TOKEN:[^\n]*\n/$1/' \
        "$1/.github/workflows/build-images.yml"
}
replace_docker_login_token() {
    perl -0pi -e 's/password: \$\{\{ secrets\.GITHUB_TOKEN \}\}/password: \${{ secrets.SIGNING_SECRET }}/' \
        "$1/.github/workflows/build-images.yml"
}
remove_secure_oras_token() {
    perl -0pi -e 's/(      - name: Login to GHCR with ORAS\n        env:\n)          GH_TOKEN:[^\n]*\n/$1/' \
        "$1/.github/workflows/build-images.yml"
}
remove_release_oras_token() {
    perl -0pi -e 's/(  release:.*?      - name: Login to GHCR with ORAS\n        env:\n)          GH_TOKEN:[^\n]*\n/$1/s' \
        "$1/.github/workflows/build-images.yml"
}
remove_buildah_password_stdin() {
    perl -0pi -e 's/ --password-stdin ghcr\.io/ ghcr.io/' \
        "$1/.github/workflows/build-images.yml"
}
move_promotion_early() {
    perl -0pi -e 's/      - name: Promote validated digest to latest\n//; s/(      - name: Push immutable version tag\n)/$1      - name: Promote validated digest to latest\n/' "$1/.github/workflows/build-images.yml"
}
remove_login() { perl -0pi -e 's/      - name: Log in to ghcr\.io\n        uses: docker\/login-action\@[^\n]+\n//' "$1/.github/workflows/build-images.yml"; }
move_login_after_verification() {
    perl -0pi -e 's/      - name: Log in to ghcr\.io\n        uses: docker\/login-action\@[^\n]+\n//; s/(      - name: Validate policy-copied secure artifact\n)/$1      - name: Log in to ghcr.io\n        uses: docker\/login-action\@c94ce9fb468520275223c153574b00df6fe4bcc9 # v3\n/' "$1/.github/workflows/build-images.yml"
}
remove_promotion_src_authfile() { perl -0pi -e 's/ --src-authfile "\$AUTH_FILE"//' "$1/shared/bootc-secure/ci/promote-published-image.sh"; }
remove_promotion_dest_authfile() { perl -0pi -e 's/ --dest-authfile "\$AUTH_FILE"//' "$1/shared/bootc-secure/ci/promote-published-image.sh"; }
remove_promotion_inspect_authfile() { perl -0pi -e 's/skopeo inspect --authfile "\$AUTH_FILE"/skopeo inspect/' "$1/shared/bootc-secure/ci/promote-published-image.sh"; }
inline_promotion_copy() {
    perl -0pi -e 's|\./shared/bootc-secure/ci/promote-published-image\.sh|skopeo copy --all|' "$1/.github/workflows/build-images.yml"
}
move_snow_tag_before_signing() {
    perl -0pi -e 's/(      - name: Sign SBOM\n)(      - name: Attest build provenance\n)(      - name: Upload manifests to R2\n)(      - name: Record snow tag for release job\n)/$4$1$2$3/' "$1/.github/workflows/build-images.yml"
}
move_snow_tag_artifact_before_manifests() {
    perl -0pi -e "s/(      - name: Upload manifests to R2\\n)(      - name: Record snow tag for release job\\n        if: matrix\\.profile == 'snow'\\n)(      - name: Upload snow tag artifact\\n        if: matrix\\.profile == 'snow'\\n)/\$2\$3\$1/" "$1/.github/workflows/build-images.yml"
}
remove_release_resolver() {
    perl -0pi -e 's{^          \./shared/bootc-secure/ci/resolve-snow-release-predecessor\.sh.*?^            "\$GITHUB_REPOSITORY" "\$IMAGE" "\$CURRENT" "\$GITHUB_OUTPUT"\n}{}ms' "$1/.github/workflows/build-images.yml"
}
add_oras_tag_fallback() {
    printf "          oras repo tags \"\$IMAGE\"\n" >>"$1/.github/workflows/build-images.yml"
}
remove_release_checkout() {
    perl -0pi -e 's/^        uses: actions\/checkout\@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7\.0\.1\n//m' "$1/.github/workflows/build-images.yml"
}
remove_snow_tag_record_condition() {
    perl -0pi -e "s/(      - name: Record snow tag for release job\\n)        if: matrix\\.profile == 'snow'\\n/\$1/" "$1/.github/workflows/build-images.yml"
}
remove_snow_tag_artifact_condition() {
    perl -0pi -e "s/(      - name: Upload snow tag artifact\\n)        if: matrix\\.profile == 'snow'\\n/\$1/" "$1/.github/workflows/build-images.yml"
}
corrupt_release_resolver_arguments() {
    perl -0pi -e 's/"\$GITHUB_REPOSITORY" "\$IMAGE" "\$CURRENT" "\$GITHUB_OUTPUT"/"\$GITHUB_REPOSITORY" "\$IMAGE" "\$BROKEN" "\$GITHUB_OUTPUT"/' "$1/.github/workflows/build-images.yml"
}

assert_guard 'baseline secure publication fixture passes' 0 unchanged
assert_guard 'missing bootc secure include fails' 1 remove_secure_include
assert_guard 'native secure include fails' 1 add_native_secure_include
for required in \
    cosign.pub \
    shared/native-ab/keys/mok-2026.crt \
    shared/native-ab/keys/pcr-signing-2026.pub \
    shared/bootc-secure/tree/etc/containers/policy.json \
    shared/bootc-secure/tree/etc/containers/registries.d/frostyard.yaml \
    shared/bootc-secure/tree/usr/lib/snosi/bootc-secure.json; do
    assert_guard "missing $required fails" 1 remove_required_file "$required"
done
assert_guard 'missing protected environment fails' 1 remove_environment
assert_guard 'pull-request publishing condition fails' 1 permit_pull_request
assert_guard 'permissive publishing condition with || fails' 1 permit_pull_request_with_or
assert_guard 'missing main publishing condition fails' 1 remove_main_condition
assert_guard 'shell || in a secure-build run block passes' 0 allow_shell_or
assert_guard 'long-lived GHCR PAT reference fails' 1 add_ghcr_pat_reference
assert_guard 'missing secure packages write permission fails' 1 remove_secure_packages_write
assert_guard 'missing release packages read permission fails' 1 remove_release_packages_read
assert_guard 'missing secure push GITHUB_TOKEN fails' 1 remove_push_github_token
assert_guard 'wrong Docker login token fails' 1 replace_docker_login_token
assert_guard 'missing secure ORAS GITHUB_TOKEN fails' 1 remove_secure_oras_token
assert_guard 'missing release ORAS GITHUB_TOKEN fails' 1 remove_release_oras_token
assert_guard 'Buildah login without password stdin fails' 1 remove_buildah_password_stdin
for variable in SNOSI_BOOTC_SECURE SNOSI_BOOTC_MOK_KEY SNOSI_BOOTC_MOK_CERT SNOSI_BOOTC_PCR_KEY SNOSI_BOOTC_PCR_CERT; do
    assert_guard "missing $variable fails" 1 remove_package_variable "$variable"
done
for variable in SNOSI_BOOTC_SECURE SNOSI_BOOTC_MOK_KEY SNOSI_BOOTC_MOK_CERT SNOSI_BOOTC_PCR_KEY SNOSI_BOOTC_PCR_CERT; do
    assert_guard "missing sudo-forwarded $variable fails" 1 \
        remove_forwarded_package_variable "$variable"
done
assert_guard 'missing sudo TMPDIR forwarding fails' 1 remove_sudo_tmpdir
assert_guard 'missing sudo SOURCE_DATE_EPOCH forwarding fails' 1 remove_source_epoch_forwarding
assert_guard 'missing MAX_LAYERS environment fails' 1 remove_max_layers_environment
assert_guard 'missing SOURCE_DATE_EPOCH derivation fails' 1 remove_source_epoch_derivation
assert_guard 'missing sudo MAX_LAYERS forwarding fails' 1 remove_max_layers_forwarding
assert_guard 'post-package secure chunking fails' 1 add_post_package_chunk
assert_guard 'direct secure chunking under any step name fails' 1 add_direct_secure_chunk
assert_guard 'missing unconditional cleanup fails' 1 remove_cleanup_condition
assert_guard 'false secure label check fails' 1 break_label_check
assert_guard 'missing secure label check fails' 1 remove_label_check
assert_guard 'missing workflow auth handoff fails' 1 remove_workflow_auth_handoff
assert_guard 'missing verifier source auth option fails' 1 remove_verifier_src_authfile
assert_guard 'missing verifier digest inspect auth fails' 1 remove_digest_inspect_auth
assert_guard 'missing Cosign Docker config fails' 1 remove_cosign_docker_config
assert_guard 'missing version tag binding fails' 1 remove_tag_binding
assert_guard 'early latest promotion fails' 1 move_promotion_early
assert_guard 'missing registry login fails' 1 remove_login
assert_guard 'login after verification fails' 1 move_login_after_verification
assert_guard 'missing promotion source auth fails' 1 remove_promotion_src_authfile
assert_guard 'missing promotion destination auth fails' 1 remove_promotion_dest_authfile
assert_guard 'missing promotion inspect auth fails' 1 remove_promotion_inspect_authfile
assert_guard 'inline promotion copy fails' 1 inline_promotion_copy
assert_guard 'snow tag recorded before SBOM signing fails' 1 move_snow_tag_before_signing
assert_guard 'snow tag artifact uploaded before manifests fails' 1 move_snow_tag_artifact_before_manifests
assert_guard 'missing release predecessor resolver fails' 1 remove_release_resolver
assert_guard 'ORAS tag fallback in release fails' 1 add_oras_tag_fallback
assert_guard 'missing release checkout fails' 1 remove_release_checkout
assert_guard 'missing Snow record condition fails' 1 remove_snow_tag_record_condition
assert_guard 'missing Snow artifact condition fails' 1 remove_snow_tag_artifact_condition
assert_guard 'corrupt release resolver arguments fails' 1 corrupt_release_resolver_arguments

printf '%d passing assertions, %d failures\n' "$pass" "$fail"
((fail == 0))
