#!/bin/bash
# SPDX-License-Identifier: LGPL-2.1-or-later
# Static, network-free guard for secure bootc profile publication.
set -euo pipefail

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
guard_root=${SNOSI_BOOTC_GUARD_ROOT:-$script_dir}
fail=0

fail_check() {
    printf 'FAIL: %s\n' "$1" >&2
    fail=1
}

require_file() {
    [[ -f "$guard_root/$1" ]] || fail_check "missing required public file: $1"
}

require_text() {
    local context=$1 text=$2 marker=$3
    grep -Fqx "$marker" <<<"$text" >/dev/null || fail_check "$context: missing $marker"
}

step_line() {
    local workflow=$1 name=$2 lines
    lines=$(grep -n -F -- "- name: $name" "$workflow" || true)
    if [[ -z $lines || $(wc -l <<<"$lines") -ne 1 ]]; then
        fail_check "$workflow: expected exactly one step named $name"
        return 1
    fi
    cut -d: -f1 <<<"$lines"
}

if [[ ! -d $guard_root ]]; then
    fail_check "guard root does not exist: $guard_root"
    exit "$fail"
fi

profiles=(cayo snow snowfield)
secure_include='Include=%D/shared/bootc-secure/mkosi.conf'
for profile in "${profiles[@]}"; do
    conf="$guard_root/mkosi.profiles/$profile/mkosi.conf"
    if [[ ! -f $conf ]]; then
        fail_check "missing bootc profile: mkosi.profiles/$profile/mkosi.conf"
    elif ! grep -Fqx "$secure_include" "$conf" >/dev/null; then
        fail_check "$conf: missing $secure_include"
    fi
done

shopt -s nullglob
native_profiles=("$guard_root"/mkosi.profiles/*-ab*/mkosi.conf)
for conf in "${native_profiles[@]}"; do
    if grep -Fqx "$secure_include" "$conf" >/dev/null; then
        fail_check "$conf: native profile must not include shared/bootc-secure/mkosi.conf"
    fi
done

required_files=(
    cosign.pub
    shared/native-ab/keys/mok-2026.crt
    shared/native-ab/keys/pcr-signing-2026.pub
    shared/bootc-secure/tree/etc/containers/policy.json
    shared/bootc-secure/tree/etc/containers/registries.d/frostyard.yaml
    shared/bootc-secure/tree/usr/lib/snosi/bootc-secure.json
    shared/bootc-secure/ci/resolve-snow-release-predecessor.sh
)
for required in "${required_files[@]}"; do
    require_file "$required"
done

workflow="$guard_root/.github/workflows/build-images.yml"
if [[ ! -f $workflow ]]; then
    fail_check "missing publication workflow: .github/workflows/build-images.yml"
else
    if grep -Fq 'GHCR_PAT' "$workflow"; then
        fail_check "$workflow: long-lived GHCR_PAT references are forbidden"
    fi

    secure_job=$(awk '
        /^  secure-build:$/ { capture=1 }
        capture && /^  [A-Za-z0-9_-]+:$/ && $0 != "  secure-build:" { exit }
        capture { print }
    ' "$workflow")

    if [[ -z $secure_job ]]; then
        fail_check "$workflow: missing protected secure-build job"
    else
        job_condition=$(awk '
            /^    if: / { capture=1 }
            capture && !/^    if: / && /^    [A-Za-z0-9_-]+:/ { exit }
            capture { print }
        ' <<<"$secure_job")
        require_text "$workflow secure-build" "$secure_job" '    environment: native-build'
        require_text "$workflow secure-build permissions" "$secure_job" '      packages: write'
        require_text "$workflow secure-build condition" "$job_condition" "      github.event_name != 'pull_request' &&"
        require_text "$workflow secure-build condition" "$job_condition" "      github.ref == 'refs/heads/main'"
        if grep -Fq '||' <<<"$job_condition"; then
            fail_check "$workflow secure-build: publishing condition must not permit pull requests"
        fi

        secrets=(
            NATIVE_SECURE_BOOT_KEY
            NATIVE_SECURE_BOOT_CERTIFICATE
            NATIVE_PCR_SIGNING_KEY
            NATIVE_PCR_SIGNING_CERTIFICATE
        )
        for secret in "${secrets[@]}"; do
            require_text "$workflow secure-build" "$secure_job" "          $secret: \${{ secrets.$secret }}"
        done

        secure_variables=(
            '          SNOSI_BOOTC_SECURE: "1"'
            '          SNOSI_BOOTC_MOK_KEY: /var/tmp/bootc-secure-credentials/mok.key'
            '          SNOSI_BOOTC_MOK_CERT: /var/tmp/bootc-secure-credentials/mok.crt'
            '          SNOSI_BOOTC_PCR_KEY: /var/tmp/bootc-secure-credentials/pcr.key'
            '          SNOSI_BOOTC_PCR_CERT: /var/tmp/bootc-secure-credentials/pcr.pub'
        )
        for variable in "${secure_variables[@]}"; do
            require_text "$workflow secure-build" "$secure_job" "$variable"
        done

        package_step=$(awk '
            /^      - name: Package image$/ { capture=1 }
            capture && /^      - name: / && $0 != "      - name: Package image" { exit }
            capture { print }
        ' <<<"$secure_job")
        forwarded_variables=(
            SOURCE_DATE_EPOCH
            MAX_LAYERS
            SNOSI_BOOTC_SECURE
            SNOSI_BOOTC_MOK_KEY
            SNOSI_BOOTC_MOK_CERT
            SNOSI_BOOTC_PCR_KEY
            SNOSI_BOOTC_PCR_CERT
        )
        for variable in "${forwarded_variables[@]}"; do
            forwarded_line=$(printf '            %s="$%s" %s' \
                "$variable" "$variable" "\\")
            require_text "$workflow protected package sudo environment" \
                "$package_step" "$forwarded_line"
        done
        require_text "$workflow protected package environment" \
            "$package_step" '          MAX_LAYERS: 128'
        # shellcheck disable=SC2016 # This is a literal workflow marker.
        require_text "$workflow protected package epoch derivation" \
            "$package_step" '          SOURCE_DATE_EPOCH=$(git log -1 --format=%ct)'
        sudo_tmpdir_line=$(printf '%s%s' "          sudo TMPDIR=\"\$TMPDIR\" " "\\")
        require_text "$workflow protected package sudo environment" \
            "$package_step" "$sudo_tmpdir_line"

        if grep -Eq '(^|[[:space:]])\./shared/outformat/image/chunkah-package\.sh([[:space:]]|$)' <<<"$secure_job"; then
            fail_check "$workflow secure-build: must not invoke chunkah-package.sh directly"
        fi

        cleanup_step=$(awk '
            /^      - name: Remove protected bootc signing credentials$/ { capture=1 }
            capture && /^      - name: / && $0 != "      - name: Remove protected bootc signing credentials" { exit }
            capture { print }
        ' <<<"$secure_job")
        if [[ -z $cleanup_step ]]; then
            fail_check "$workflow secure-build: missing protected credential cleanup step"
        else
            require_text "$workflow credential cleanup" "$cleanup_step" '        if: always()'
        fi

        local_validation=$(awk '
            /^      - name: Validate locally assembled secure artifact$/ { capture=1 }
            capture && /^      - name: / && $0 != "      - name: Validate locally assembled secure artifact" { exit }
            capture { print }
        ' <<<"$secure_job")
        # shellcheck disable=SC2016 # GitHub expression is an exact literal marker.
        if ! grep -Fq './test/bootc-secure-artifact-test.sh' <<<"$local_validation" ||
                ! grep -Fq '"output/${{ matrix.profile }}"' <<<"$local_validation"; then
            fail_check "$workflow secure-build: missing local secure artifact validation"
        fi

        remote_validation=$(awk '
            /^      - name: Validate policy-copied secure artifact$/ { capture=1 }
            capture && /^      - name: / && $0 != "      - name: Validate policy-copied secure artifact" { exit }
            capture { print }
        ' <<<"$secure_job")
        # shellcheck disable=SC2016 # Shell variable reference is an exact literal marker.
        if ! grep -Fq './test/bootc-secure-artifact-test.sh' <<<"$remote_validation" ||
                ! grep -Fq '"$LOCAL_REF"' <<<"$remote_validation"; then
            fail_check "$workflow secure-build: missing policy-copied artifact validation"
        fi

        verifier_step=$(awk '
            /^      - name: Verify pushed secure image$/ { capture=1 }
            capture && /^      - name: / && $0 != "      - name: Verify pushed secure image" { exit }
            capture { print }
        ' <<<"$secure_job")
        if ! grep -Fq './shared/bootc-secure/ci/verify-published-image.sh' <<<"$verifier_step"; then
            fail_check "$workflow secure-build: missing secure image verifier call"
        fi
        # shellcheck disable=SC2016 # Match the literal workflow shell source.
        require_text "$workflow secure verifier auth path" \
            "$verifier_step" '          AUTH_FILE="${DOCKER_CONFIG:-$HOME/.docker}/config.json"'
        # shellcheck disable=SC2016 # Match the literal workflow shell source.
        require_text "$workflow secure verifier auth argument" \
            "$verifier_step" '            "$IMAGE" "$VERSION_TAG" "$DIGEST" "$LOCAL_REF" "$AUTH_FILE"'

        push_step=$(awk '
            /^      - name: Push immutable version tag$/ { capture=1 }
            capture && /^      - name: / && $0 != "      - name: Push immutable version tag" { exit }
            capture { print }
        ' <<<"$secure_job")
        require_text "$workflow secure push token" "$push_step" \
            '          GH_TOKEN: ${{ secrets.GITHUB_TOKEN }}'
        push_login_line=$(cat <<'EOF'
          printf '%s' "$GH_TOKEN" | sudo buildah login -u "${{ github.actor }}" --password-stdin ghcr.io
EOF
)
        require_text "$workflow secure Buildah login" "$push_step" "$push_login_line"

        login_step=$(awk '
            /^      - name: Log in to ghcr.io$/ { capture=1 }
            capture && /^      - name: / && $0 != "      - name: Log in to ghcr.io" { exit }
            capture { print }
        ' <<<"$secure_job")
        require_text "$workflow secure registry login" "$login_step" \
            '        uses: docker/login-action@c94ce9fb468520275223c153574b00df6fe4bcc9 # v3'
        require_text "$workflow secure registry token" "$login_step" \
            '          password: ${{ secrets.GITHUB_TOKEN }}'

        oras_login_step=$(awk '
            /^      - name: Login to GHCR with ORAS$/ { capture=1 }
            capture && /^      - name: / && $0 != "      - name: Login to GHCR with ORAS" { exit }
            capture { print }
        ' <<<"$secure_job")
        require_text "$workflow secure ORAS token" "$oras_login_step" \
            '          GH_TOKEN: ${{ secrets.GITHUB_TOKEN }}'
        oras_login_line=$(cat <<'EOF'
          printf '%s' "$GH_TOKEN" | oras login ghcr.io -u "${{ github.actor }}" --password-stdin
EOF
)
        require_text "$workflow secure ORAS login" "$oras_login_step" "$oras_login_line"

        promotion_step=$(awk '
            /^      - name: Promote validated digest to latest$/ { capture=1 }
            capture && /^      - name: / && $0 != "      - name: Promote validated digest to latest" { exit }
            capture { print }
        ' <<<"$secure_job")
        if ! grep -Fq './shared/bootc-secure/ci/promote-published-image.sh' <<<"$promotion_step"; then
            fail_check "$workflow secure-build: missing authenticated promotion helper call"
        fi
        # shellcheck disable=SC2016 # Match the literal workflow shell source.
        require_text "$workflow secure promotion auth path" \
            "$promotion_step" '          AUTH_FILE="${DOCKER_CONFIG:-$HOME/.docker}/config.json"'
        # shellcheck disable=SC2016 # Match the literal workflow shell source.
        require_text "$workflow secure promotion auth argument" \
            "$promotion_step" '            "$IMAGE" "${{ steps.push.outputs.digest }}" "$AUTH_FILE"'
    fi

    ordered_steps=(
        'Push immutable version tag'
        'Log in to ghcr.io'
        'Sign immutable image digest'
        'Verify pushed secure image'
        'Validate policy-copied secure artifact'
        'Promote validated digest to latest'
    )
    previous=0
    for name in "${ordered_steps[@]}"; do
        line=$(step_line "$workflow" "$name" || true)
        if [[ -n $line && $line -le $previous ]]; then
            fail_check "$workflow: $name must follow the prior secure publication step"
        fi
        [[ -n $line ]] && previous=$line
    done

    metadata_steps=(
        'Upload SBOM'
        'Sign SBOM'
        'Attest build provenance'
        'Upload manifests to R2'
        'Record snow tag for release job'
        'Upload snow tag artifact'
    )
    previous=0
    for name in "${metadata_steps[@]}"; do
        line=$(step_line "$workflow" "$name" || true)
        if [[ -n $line && $line -le $previous ]]; then
            fail_check "$workflow: $name must follow the prior secure metadata step"
        fi
        [[ -n $line ]] && previous=$line
    done

    snow_tag_record_step=$(awk '
        /^      - name: Record snow tag for release job$/ { capture=1 }
        capture && /^      - name: / && $0 != "      - name: Record snow tag for release job" { exit }
        capture { print }
    ' "$workflow")
    require_text "$workflow Snow tag record" "$snow_tag_record_step" \
        "        if: matrix.profile == 'snow'"
    snow_tag_artifact_step=$(awk '
        /^      - name: Upload snow tag artifact$/ { capture=1 }
        capture && /^      - name: / && $0 != "      - name: Upload snow tag artifact" { exit }
        capture { print }
    ' "$workflow")
    require_text "$workflow Snow tag artifact" "$snow_tag_artifact_step" \
        "        if: matrix.profile == 'snow'"

    release_job=$(awk '
        /^  release:$/ { capture=1 }
        capture && /^  [A-Za-z0-9_-]+:$/ && $0 != "  release:" { exit }
        capture { print }
    ' "$workflow")
    if [[ -z $release_job ]]; then
        fail_check "$workflow: missing release job"
    else
        require_text "$workflow release permissions" "$release_job" '      packages: read'

        release_checkout=$(awk '
            /^      - name: Checkout repository$/ { capture=1 }
            capture && /^      - name: / && $0 != "      - name: Checkout repository" { exit }
            capture { print }
        ' <<<"$release_job")
        require_text "$workflow release checkout" "$release_checkout" "        if: steps.current.outputs.tag != ''"
        require_text "$workflow release checkout" "$release_checkout" \
            '        uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1'
        require_text "$workflow release checkout" "$release_checkout" '          persist-credentials: false'

        release_oras_login=$(awk '
            /^      - name: Login to GHCR with ORAS$/ { capture=1 }
            capture && /^      - name: / && $0 != "      - name: Login to GHCR with ORAS" { exit }
            capture { print }
        ' <<<"$release_job")
        require_text "$workflow release ORAS token" "$release_oras_login" \
            '          GH_TOKEN: ${{ secrets.GITHUB_TOKEN }}'
        release_oras_login_line=$(cat <<'EOF'
          printf '%s' "$GH_TOKEN" | oras login ghcr.io -u "${{ github.actor }}" --password-stdin
EOF
)
        require_text "$workflow release ORAS login" \
            "$release_oras_login" "$release_oras_login_line"

        resolver_step=$(awk '
            /^      - name: Resolve previous and current snow tags$/ { capture=1 }
            capture && /^      - name: / && $0 != "      - name: Resolve previous and current snow tags" { exit }
            capture { print }
        ' <<<"$release_job")
        require_text "$workflow release predecessor resolver path" "$resolver_step" \
            "          ./shared/bootc-secure/ci/resolve-snow-release-predecessor.sh \\"
        require_text "$workflow release predecessor resolver arguments" "$resolver_step" \
            "            \"\$GITHUB_REPOSITORY\" \"\$IMAGE\" \"\$CURRENT\" \"\$GITHUB_OUTPUT\""
        if grep -Fq 'oras repo tags' <<<"$release_job"; then
            fail_check "$workflow release: must not fall back to oras repo tags"
        fi
    fi
fi

verifier="$guard_root/shared/bootc-secure/ci/verify-published-image.sh"
if [[ ! -f $verifier ]]; then
    fail_check "missing secure image verifier: shared/bootc-secure/ci/verify-published-image.sh"
else
    verifier_text=$(<"$verifier")
    require_text "$verifier" "$verifier_text" '    .Labels["io.snosi.bootc.secureboot-capable"] == "true" and'
    require_text "$verifier" "$verifier_text" '    .Labels["io.snosi.bootc.secureboot-assembly"] == "bootc-1.16.3-storage-digest-v1"'
    # shellcheck disable=SC1003,SC2016 # Match the literal verifier shell source.
    require_text "$verifier" "$verifier_text" \
        'inspection=$(skopeo inspect --authfile "$AUTH_FILE" \'
    tag_inspect_line=$(cat <<'EOF'
tag_digest=$(skopeo inspect --authfile "$AUTH_FILE" --format '{{.Digest}}' \
EOF
)
    require_text "$verifier tag inspect auth" "$verifier_text" "$tag_inspect_line"
    # shellcheck disable=SC2016 # Match the literal verifier shell source.
    require_text "$verifier" "$verifier_text" \
        'if [[ $tag_digest != "$EXPECTED_DIGEST" ]]; then'
    # shellcheck disable=SC1003,SC2016 # Match the literal verifier shell source.
    require_text "$verifier" "$verifier_text" \
        'DOCKER_CONFIG=$auth_dir cosign verify --key "$ROOT_DIR/cosign.pub" \'
    # shellcheck disable=SC1003,SC2016 # Match the literal verifier shell source.
    require_text "$verifier" "$verifier_text" \
        'sudo skopeo copy --src-authfile "$AUTH_FILE" \'
fi

promotion_helper="$guard_root/shared/bootc-secure/ci/promote-published-image.sh"
if [[ ! -f $promotion_helper ]]; then
    fail_check "missing secure image promotion helper: shared/bootc-secure/ci/promote-published-image.sh"
else
    promotion_text=$(<"$promotion_helper")
    # shellcheck disable=SC1003 # Match the literal promotion shell source.
    require_text "$promotion_helper" "$promotion_text" \
        'skopeo copy --all \'
    # shellcheck disable=SC1003,SC2016 # Match the literal promotion shell source.
    require_text "$promotion_helper promotion source auth" "$promotion_text" \
        '    --src-authfile "$AUTH_FILE" --dest-authfile "$AUTH_FILE" \'
    promotion_inspect_line=$(cat <<'EOF'
latest_digest=$(skopeo inspect --authfile "$AUTH_FILE" \
EOF
)
    require_text "$promotion_helper promotion inspect auth" "$promotion_text" "$promotion_inspect_line"
fi

if ((fail)); then
    exit 1
fi

printf 'PASS: bootc publication guard satisfied\n'
