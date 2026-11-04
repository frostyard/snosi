#!/bin/bash
# SPDX-License-Identifier: LGPL-2.1-or-later
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VALIDATE="$ROOT_DIR/.github/workflows/validate.yml"
BUILD_IMAGES="$ROOT_DIR/.github/workflows/build-images.yml"
BUILD_MECHANICS="$ROOT_DIR/.github/workflows/build-mechanics.yml"
CHECK_DEPS="$ROOT_DIR/.github/workflows/check-dependencies.yml"

PASS=0
FAIL=0
CASES=0
pass() { printf 'ok - %s\n' "$1"; PASS=$((PASS + 1)); }
fail() { printf 'not ok - %s\n' "$1" >&2; FAIL=$((FAIL + 1)); }
case_done() { CASES=$((CASES + 1)); }

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

extract_run_step() {
    local workflow=$1 name=$2 output=$3
    awk -v header="      - name: $name" '
        $0 == header {
            in_step = 1
            next
        }
        in_step && $0 == "        run: |" {
            found = 1
            in_run = 1
            next
        }
        in_run && $0 == "" {
            print
            next
        }
        in_run && substr($0, 1, 10) == "          " {
            print substr($0, 11)
            next
        }
        in_run {
            exit
        }
        END {
            if (!found) {
                exit 1
            }
        }
    ' "$workflow" >"$output"
}

extract_flatpak_bodies() {
    local workflow=$1
    awk '
        /^[ ]*run: \|$/ {
            in_run = 1
            block = ""
            matched = 0
            next
        }
        in_run && substr($0, 1, 10) == "          " {
            block = block substr($0, 11) "\n"
            if ($0 ~ /podman image inspect|skopeo inspect/ && $0 ~ /core-flatpaks\.py check-image/) {
                matched = 1
            }
            if ($0 ~ /core-flatpaks\.py check-image/) {
                matched = 1
            }
            next
        }
        in_run {
            if (matched) {
                print "---FLATPAK-BODY---"
                printf "%s", block
            }
            in_run = 0
            matched = 0
        }
        END {
            if (in_run && matched) {
                print "---FLATPAK-BODY---"
                printf "%s", block
            }
        }
    ' "$workflow"
}

extract_run_step "$VALIDATE" 'Lint shell scripts' "$work/lint.sh"

mkdir -p "$work/lint-empty"
(
    cd "$work/lint-empty"
    git init -q
)
mkdir -p "$work/lint-stub-empty"
cat >"$work/lint-stub-empty/shellcheck" <<'EOF'
#!/bin/bash
exit 99
EOF
chmod +x "$work/lint-stub-empty/shellcheck"
set +e
(
    cd "$work/lint-empty"
    PATH="$work/lint-stub-empty:$PATH" bash -e "$work/lint.sh"
) >"$work/lint-empty.log" 2>&1
lint_empty_status=$?
set -e
case_done
if [[ $lint_empty_status -ne 0 ]] && grep -Fq '::error::shellcheck: no shell scripts found' "$work/lint-empty.log"; then
    pass 'lint exits non-zero for an empty shell-script list'
else
    fail 'lint exits non-zero for an empty shell-script list'
fi

mkdir -p "$work/lint-one"
(
    cd "$work/lint-one"
    git init -q
    git config user.email fixture@example.invalid
    git config user.name fixture
    cat >fixture.sh <<'EOF'
#!/bin/bash
echo ok
EOF
    git add fixture.sh
)
mkdir -p "$work/lint-stub-one"
cat >"$work/lint-stub-one/shellcheck" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >"${SHELLCHECK_LOG}"
exit 0
EOF
chmod +x "$work/lint-stub-one/shellcheck"
set +e
(
    cd "$work/lint-one"
    SHELLCHECK_LOG="$work/shellcheck.args" PATH="$work/lint-stub-one:$PATH" bash -e "$work/lint.sh"
) >"$work/lint-one.log" 2>&1
lint_one_status=$?
set -e
case_done
if [[ $lint_one_status -eq 0 ]] &&
   grep -Fq 'shellcheck: 1 files' "$work/lint-one.log" &&
   grep -Fq 'fixture.sh' "$work/shellcheck.args" &&
   grep -Fq -- '-S warning -x' "$work/shellcheck.args"; then
    pass 'lint checks one discovered shell script with shellcheck flags'
else
    fail 'lint checks one discovered shell script with shellcheck flags'
fi

# The '*.sh' listing works and finds fixture.sh; only the full listing (the
# shebang scan) fails. Without pipefail that failure is masked and the step
# passes on a partial list.
mkdir -p "$work/lint-git-failure"
REAL_GIT=$(command -v git)
cat >"$work/lint-git-failure/git" <<EOF
#!/bin/bash
if [[ "\$1" == "ls-files" && "\$*" != *'*.sh'* ]]; then
    exit 9
fi
exec "$REAL_GIT" "\$@"
EOF
chmod +x "$work/lint-git-failure/git"
set +e
(
    cd "$work/lint-one"
    SHELLCHECK_LOG="$work/shellcheck-git.args" PATH="$work/lint-git-failure:$work/lint-stub-one:$PATH" bash -e "$work/lint.sh"
) >"$work/lint-git.log" 2>&1
lint_git_status=$?
set -e
case_done
if [[ $lint_git_status -ne 0 ]]; then
    pass 'lint exits non-zero when the git ls-files shebang scan fails'
else
    fail 'lint exits non-zero when the git ls-files shebang scan fails'
fi

# A tracked dangling symlink sorts before an extensionless script. The old
# `xargs awk` aborted the whole batch on it ("cannot open file") and silently
# dropped every later script from the lint.
mkdir -p "$work/lint-dangling"
(
    cd "$work/lint-dangling"
    git init -q
    ln -s does-not-exist a-dangling-link
    printf '#!/bin/bash\necho ok\n' >b-script
    git add a-dangling-link b-script
)
set +e
(
    cd "$work/lint-dangling"
    SHELLCHECK_LOG="$work/shellcheck-dangling.args" PATH="$work/lint-stub-one:$PATH" bash -e "$work/lint.sh"
) >"$work/lint-dangling.log" 2>&1
lint_dangling_status=$?
set -e
case_done
if [[ $lint_dangling_status -eq 0 ]] &&
   grep -Fq 'shellcheck: 1 files' "$work/lint-dangling.log" &&
   grep -Fq 'b-script' "$work/shellcheck-dangling.args" 2>/dev/null; then
    pass 'lint still finds an extensionless script after a dangling symlink'
else
    fail 'lint still finds an extensionless script after a dangling symlink'
fi

{
    extract_flatpak_bodies "$BUILD_IMAGES"
    extract_flatpak_bodies "$BUILD_MECHANICS"
} >"$work/flatpak-bodies.raw"

flatpak_count=$(grep -c '^---FLATPAK-BODY---$' "$work/flatpak-bodies.raw")
case_done
if [[ $flatpak_count -eq 4 ]]; then
    pass 'four Flatpak label run bodies are found'
else
    fail 'four Flatpak label run bodies are found'
fi

mkdir -p "$work/flatpak-stub"
cat >"$work/flatpak-stub/sudo" <<'EOF'
#!/bin/bash
exec "$@"
EOF
chmod +x "$work/flatpak-stub/sudo"
cat >"$work/flatpak-stub/podman" <<'EOF'
#!/bin/bash
printf '%s\n' '{"Labels":{"containers.bootc":"1"}}'
exit "${INSPECT_STATUS:-0}"
EOF
chmod +x "$work/flatpak-stub/podman"
cat >"$work/flatpak-stub/skopeo" <<'EOF'
#!/bin/bash
printf '%s\n' '{"Labels":{"containers.bootc":"1"}}'
exit "${INSPECT_STATUS:-0}"
EOF
chmod +x "$work/flatpak-stub/skopeo"

body_index=0
while IFS= read -r line; do
    if [[ "$line" == '---FLATPAK-BODY---' ]]; then
        body_index=$((body_index + 1))
        body_file="$work/flatpak-$body_index.sh"
        : >"$body_file"
        in_body=1
        continue
    fi
    if [[ ${in_body:-0} -eq 1 ]]; then
        printf '%s\n' "$line" >>"$body_file"
    fi
done <"$work/flatpak-bodies.raw"

for body_file in "$work"/flatpak-[0-9]*.sh; do
    body_index=$(basename "$body_file" .sh)
    sed -i 's/${{[^}]*}}/floe/g' "$body_file"

    set +e
    (
        cd "$ROOT_DIR"
        INSPECT_STATUS=125 PATH="$work/flatpak-stub:$PATH" bash -e "$body_file"
    ) >"$work/flatpak-negative.log" 2>&1
    negative_status=$?
    set -e
    case_done
    if [[ $negative_status -ne 0 ]]; then
        pass "$body_index exits non-zero when inspect exits 125"
    else
        fail "$body_index exits non-zero when inspect exits 125"
    fi

    set +e
    (
        cd "$ROOT_DIR"
        INSPECT_STATUS=0 PATH="$work/flatpak-stub:$PATH" bash -e "$body_file"
    ) >"$work/flatpak-positive.log" 2>&1
    positive_status=$?
    set -e
    case_done
    if [[ $positive_status -eq 0 ]]; then
        pass "$body_index positive control passes"
    else
        fail "$body_index positive control passes"
    fi
done

extract_run_step "$CHECK_DEPS" 'Check for sysext dependency updates' "$work/sysext-check.sh"
extract_run_step "$CHECK_DEPS" 'Check for image dependency updates' "$work/image-check.sh"

mkdir -p "$work/curl-stub"
# Like real curl -f: no body on an HTTP error, but a -w write-out (the k3s
# check reads %{url_effective}) is still printed.
cat >"$work/curl-stub/curl" <<'EOF'
#!/bin/bash
write_out=""
url=""
while (($#)); do
    case "$1" in
        -w) write_out=$2; shift ;;
        -H|-o|--max-time|--retry|--retry-delay) shift ;;
        -*) ;;
        *) url=$1 ;;
    esac
    shift
done
if [[ "$write_out" == '%{url_effective}' ]]; then
    printf '%s' "$url"
fi
exit 22
EOF
chmod +x "$work/curl-stub/curl"

sysext_keys='bitwarden obsidian localsend github-copilot gitdesktop sunshine code-server coder k3s lemonade paseo pilothouse notesd maild lodge porterd readd microsoft-edge-stable 1password'
GITHUB_OUTPUT="$work/sysext-output" GH_TOKEN=dummy PATH="$work/curl-stub:$PATH" bash -e "$work/sysext-check.sh" >"$work/sysext-check.log" 2>&1
sysext_status=$?
case_done
if [[ $sysext_status -eq 0 ]] &&
   grep -Fq 'has_updates=false' "$work/sysext-output" &&
   grep -Fq 'checked 19 dependencies, 19 could not be read' "$work/sysext-check.log"; then
    sysext_failed=$(awk -F= '/^check_failed=/ {print $2}' "$work/sysext-output")
    if [[ "$sysext_failed" == "$sysext_keys" ]]; then
        pass 'sysext check reports every unreadable dependency and stays successful'
    else
        fail 'sysext check reports every unreadable dependency and stays successful'
    fi
else
    fail 'sysext check reports every unreadable dependency and stays successful'
fi

image_keys='brew-install hotedge logomenu bazaar syft cosign chunkah'
GITHUB_OUTPUT="$work/image-output" GH_TOKEN=dummy PATH="$work/curl-stub:$PATH" bash -e "$work/image-check.sh" >"$work/image-check.log" 2>&1
image_status=$?
case_done
if [[ $image_status -eq 0 ]] &&
   grep -Fq 'has_updates=false' "$work/image-output" &&
   grep -Fq 'checked 7 dependencies, 7 could not be read' "$work/image-check.log"; then
    image_failed=$(awk -F= '/^check_failed=/ {print $2}' "$work/image-output")
    if [[ "$image_failed" == "$image_keys" ]]; then
        pass 'image check reports every unreadable dependency and stays successful'
    else
        fail 'image check reports every unreadable dependency and stays successful'
    fi
else
    fail 'image check reports every unreadable dependency and stays successful'
fi

sysext_pr_line=$(awk '/- name: Create sysext dependency PR/{print NR; exit}' "$CHECK_DEPS")
sysext_final_line=$(awk -v pr="$sysext_pr_line" '/- name: Fail when dependency latest values could not be read/{if(NR > pr){print NR; exit}}' "$CHECK_DEPS")
if [[ -n "$sysext_pr_line" && -n "$sysext_final_line" ]] &&
   (( sysext_final_line > sysext_pr_line )) &&
   grep -Fq "if: \${{ !cancelled() && steps.check.outputs.check_failed != '' }}" "$CHECK_DEPS"; then
    pass 'sysext job has final check_failed fail step after PR step'
else
    fail 'sysext job has final check_failed fail step after PR step'
fi

image_pr_line=$(awk '/- name: Create image dependency PR/{print NR; exit}' "$CHECK_DEPS")
image_final_line=$(awk -v pr="$image_pr_line" '/- name: Fail when dependency latest values could not be read/{if(NR > pr){print NR; exit}}' "$CHECK_DEPS")
if [[ -n "$image_pr_line" && -n "$image_final_line" ]] &&
   (( image_final_line > image_pr_line )) &&
   grep -Fq "if: \${{ !cancelled() && steps.check.outputs.check_failed != '' }}" "$CHECK_DEPS"; then
    pass 'image job has final check_failed fail step after PR step'
else
    fail 'image job has final check_failed fail step after PR step'
fi

printf '# Summary: %d cases, %d passed, %d failed, %d total assertions\n' "$CASES" "$PASS" "$FAIL" "$((PASS + FAIL))"
[[ $FAIL -eq 0 ]]
