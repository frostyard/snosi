#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")"

mkosi=mkosi
if [[ -x .mkosi/bin/mkosi ]]; then
    mkosi=.mkosi/bin/mkosi
fi

read_root_dependencies() {
    awk '
        function emit(line, fields, count, i) {
            sub(/#.*/, "", line)
            gsub(/,/, " ", line)
            count = split(line, fields, /[[:space:]]+/)
            for (i = 1; i <= count; i++)
                if (fields[i] != "")
                    print fields[i]
        }
        /^\[Config\][[:space:]]*$/ {
            in_config = 1
            next
        }
        /^\[/ {
            if (in_config)
                exit
        }
        in_config && /^[[:space:]]*Dependencies=/ {
            line = $0
            sub(/^[[:space:]]*Dependencies=[[:space:]]*/, "", line)
            emit(line)
            collecting = 1
            next
        }
        in_config && collecting && /^[[:space:]]+/ {
            emit($0)
            next
        }
        in_config && collecting {
            collecting = 0
        }
    ' mkosi.conf
}

mapfile -t profile_configs < <(git ls-files -- 'mkosi.profiles/*/mkosi.conf' | sort)
((${#profile_configs[@]} > 0)) || {
    echo "No tracked profiles found." >&2
    exit 1
}

mapfile -t root_dependencies < <(read_root_dependencies)
declare -A sysexts=()
base_count=0
for dependency in "${root_dependencies[@]}"; do
    if [[ $dependency == base ]]; then
        base_count=$((base_count + 1))
    else
        sysexts["$dependency"]=1
    fi
done

((base_count == 1)) || {
    echo "Root mkosi.conf must list base exactly once in Dependencies=." >&2
    exit 1
}
((${#sysexts[@]} > 0)) || {
    echo "Root mkosi.conf has no sysext dependencies to guard." >&2
    exit 1
}

installer_profiles=(
    firn-installer
    native-installer
)

failed=0

for profile_config in "${profile_configs[@]}"; do
    profile=${profile_config#mkosi.profiles/}
    profile=${profile%/mkosi.conf}

    if ! summary=$("$mkosi" -f --profile "$profile" summary); then
        echo "Failed to resolve profile ${profile}." >&2
        failed=1
        continue
    fi
    mapfile -t image_dependencies < <(sed -n 's/^IMAGE: //p' <<<"$summary")

    for dependency in "${image_dependencies[@]}"; do
        if [[ -n ${sysexts["$dependency"]+x} ]]; then
            echo "Profile ${profile} unexpectedly includes sysext dependency ${dependency}." >&2
            failed=1
        fi
    done

    is_installer=0
    for installer_profile in "${installer_profiles[@]}"; do
        if [[ $profile == "$installer_profile" ]]; then
            is_installer=1
            break
        fi
    done

    if ((is_installer)); then
        if ((${#image_dependencies[@]} != 0)); then
            echo "Installer profile ${profile} must have no image dependencies." >&2
            failed=1
        fi
    elif ((${#image_dependencies[@]} != 1)) || [[ ${image_dependencies[0]:-} != base ]]; then
        echo "Product profile ${profile} must depend only on base." >&2
        failed=1
    fi
done

if (( failed )); then
    exit 1
fi

echo "Checked ${#profile_configs[@]} profiles against ${#sysexts[@]} sysext dependencies."
