#!/bin/bash
# SPDX-License-Identifier: LGPL-2.1-or-later
# Finalize script for the five Lodge suite sysexts (lodge, notesd, maild,
# porterd, readd): fail the build if the delta breaks the account contract of
# the Lodge suite. Lodge's own sysusers line creates
# the system user lodge; a Lodge app daemon resolves that user at start, and a
# unit may name an account only if the delta declares it.
#
# Why (snosi#1245): lodgeapp.LoadEnv in frostyard/lodge resolves the system
# user lodge at start. maild 0.2.0 and notesd 0.2.0 declared only the GROUP
# lodge in their sysusers.d file. With `updex features enable maild notesd
# --now` and without the lodge feature, frostmail.service crash-looped with
# "unknown user lodge" and the notesd units hit their start limits.
# systemd-sysusers creates no user for a group line, so each app sysext must
# declare the user itself.
#
# $BUILDROOT is the delta, and $IMAGE_ID names the sysext. The rules are:
#
#  1. A delta that ships usr/lib/sysusers.d/lodge.conf (the lodge sysext
#     itself) holds LODGE_USER_LINE as an exact full line there.
#  2. A delta that ships a Lodge app manifest (usr/share/lodge/apps/*/app.json)
#     holds LODGE_USER_LINE as an exact full line in at least one of its
#     usr/lib/sysusers.d/*.conf files. The line is byte-identical to lodge's
#     own, so the first merge of any suite sysext creates the same account.
#  3. Every account the delta's system units name is declared by the delta's
#     sysusers.d files. The units are the *.service and *.socket files under
#     usr/lib/systemd/system, plus every unit name that has a drop-in
#     directory <unit>.d there (a drop-in for a unit base ships still names
#     accounts). The effective settings of a unit are read as systemd reads
#     them: the unit file, then the drop-ins of <unit>.d/*.conf, and for an
#     instance a@b.service also those of a@.service.d/*.conf, all sorted by
#     file name; a line ending with \ joins the next line; a comment starts
#     with # or ;. Only the keys of their own section count: User=, Group=,
#     SupplementaryGroups= and DynamicUser= in [Service], SocketUser= and
#     SocketGroup= in [Socket]. Of the scalar keys the last assignment wins
#     and an empty value unsets it; SupplementaryGroups= accumulates and an
#     empty assignment clears the list. A user is declared by a u or u! line
#     or the first field of an m line, a group by a u, u! or g line or the
#     second field of an m line. An effective DynamicUser=yes skips the user
#     and group checks of that unit, but not its socket's SocketUser= and
#     SocketGroup=. An empty value, root, a numeric id and a value with a %
#     specifier are skipped.
set -euo pipefail

ID=${IMAGE_ID:?sysext-lodge-accounts-guard: IMAGE_ID not set}
DELTA=${BUILDROOT:?sysext-lodge-accounts-guard: BUILDROOT not set}
SYSUSERS=usr/lib/sysusers.d
SYSTEM_UNITS=usr/lib/systemd/system
LODGE_CONF=$SYSUSERS/lodge.conf
APPS=usr/share/lodge/apps
# The exact line lodge's own usr/lib/sysusers.d/lodge.conf ships. Every suite
# sysext repeats it unchanged, so all of them declare one account.
LODGE_USER_LINE="u lodge - \"lodge, the tailnet web shell for frostyard's apps\" /var/lib/lodge"

die() {
    echo "sysext-lodge-accounts-guard: $*" >&2
    exit 1
}

[[ -d $DELTA ]] || die "delta buildroot $DELTA is not a directory"

shopt -s nullglob dotglob

apps=()
for file in "$DELTA/$APPS"/*/app.json; do
    [[ -f $file ]] || continue
    apps+=("$file")
done

sysusers=()
for file in "$DELTA/$SYSUSERS"/*.conf; do
    [[ -f $file ]] || continue
    sysusers+=("$file")
done

has_lodge_user_line() { # file
    grep -Fxq -- "$LODGE_USER_LINE" "$1"
}

# 1. The lodge sysext itself.
if [[ -f $DELTA/$LODGE_CONF ]] && ! has_lodge_user_line "$DELTA/$LODGE_CONF"; then
    die "/$LODGE_CONF of $ID has no line: $LODGE_USER_LINE (lodge's own sysusers line, byte for byte)"
fi

# 2. A Lodge app sysext.
if ((${#apps[@]} > 0)); then
    found=0
    for file in "${sysusers[@]}"; do
        if has_lodge_user_line "$file"; then
            found=1
            break
        fi
    done
    if ((found == 0)); then
        die "$ID ships the Lodge app ${apps[0]#"$DELTA"/} but no /$SYSUSERS/*.conf declares user lodge with lodge's own line: $LODGE_USER_LINE. The app daemon resolves the system user lodge at start, so without the line its unit fails at start while the lodge feature is not enabled (snosi#1245; docs/design/sysexts.md)"
    fi
fi

# 3. Every account the system units and their drop-ins name.
# The unit names: every shipped service and socket, and every name that has a
# drop-in directory. Other unit types name no account of ours.
declare -A seen=()
unit_names=()
add_unit() { # unit name
    [[ -z ${seen[$1]:-} ]] || return 0
    seen[$1]=1
    unit_names+=("$1")
}
for entry in "$DELTA/$SYSTEM_UNITS"/*; do
    name=${entry##*/}
    if [[ -f $entry ]]; then
        [[ $name == *.service || $name == *.socket ]] || continue
        add_unit "$name"
    elif [[ -d $entry && $name == *.d ]]; then
        name=${name%.d}
        [[ $name == *.service || $name == *.socket ]] || continue
        add_unit "$name"
    fi
done

if ((${#unit_names[@]} == 0)); then
    if ((${#apps[@]} == 0)) && [[ ! -f $DELTA/$LODGE_CONF ]]; then
        echo "sysext-lodge-accounts-guard: $ID OK (no Lodge app, no lodge.conf, no system units)"
    else
        echo "sysext-lodge-accounts-guard: $ID OK (system units: 0, sysusers files: ${#sysusers[@]}, Lodge apps: ${#apps[@]})"
    fi
    exit 0
fi

declare -A users=() groups=()
for file in "${sysusers[@]}"; do
    while IFS= read -r line; do
        read -ra fields <<<"$line"
        type=${fields[0]:-}
        name=${fields[1]:-}
        [[ -n $name ]] || continue
        case $type in
            'u!' | u)
                users[$name]=1
                groups[$name]=1
                ;;
            g) groups[$name]=1 ;;
            m)
                group=${fields[2]:-}
                [[ -n $group ]] || continue
                users[$name]=1
                groups[$group]=1
                ;;
        esac
    done < <(grep -Ev '^[[:space:]]*(#|$)' "$file" || true)
done

# The template of an instance unit: a@b.service -> a@.service. Empty for
# anything else, and for a template itself.
unit_template() { # unit name
    local name=$1
    if [[ $name =~ ^(.+)@[^@]*\.(service|socket)$ ]]; then
        printf '%s@.%s\n' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}"
    fi
}

# The files systemd reads for a unit, in its order: the unit file, then the
# drop-in files of <unit>.d and, for an instance, of <template>.d, sorted by
# file name.
unit_files() { # unit name -> one path per line
    local name=$1 dir=$DELTA/$SYSTEM_UNITS template files=() file
    [[ -f $dir/$name ]] && printf '%s\n' "$dir/$name"
    for file in "$dir/$name.d"/*.conf; do
        [[ -f $file ]] && files+=("$file")
    done
    template=$(unit_template "$name")
    if [[ -n $template && $template != "$name" ]]; then
        for file in "$dir/$template.d"/*.conf; do
            [[ -f $file ]] && files+=("$file")
        done
    fi
    ((${#files[@]} > 0)) || return 0
    while IFS= read -r file; do
        printf '%s\n' "$file"
    done < <(for file in "${files[@]}"; do
        printf '%s\t%s\n' "${file##*/}" "$file"
    done | sort | cut -f2-)
}

# The effective settings of one unit, from its files in systemd's order:
# KIND<TAB>VALUE lines. An empty value means unset.
unit_settings() { # files...
    (($# > 0)) || return 0
    awk '
        function trim(text) {
            sub(/^[[:space:]]+/, "", text)
            sub(/[[:space:]]+$/, "", text)
            return text
        }
        FNR == 1 { section = "" }
        {
            line = $0
            while (line ~ /\\$/) {
                if ((getline more) > 0) {
                    sub(/\\$/, " ", line)
                    line = line more
                } else {
                    sub(/\\$/, "", line)
                }
            }
            line = trim(line)
            if (line == "" || line ~ /^[#;]/) next
            if (line ~ /^\[/) {
                bracket = index(line, "]")
                if (bracket > 0) {
                    section = substr(line, 2, bracket - 2)
                    next
                }
            }
            eq = index(line, "=")
            if (eq == 0) next
            key = trim(substr(line, 1, eq - 1))
            value = trim(substr(line, eq + 1))
            if (section == "Service") {
                if (key == "User") user = value
                else if (key == "Group") group = value
                else if (key == "SupplementaryGroups")
                    sup = (value == "") ? "" : ((sup == "") ? value : sup " " value)
                else if (key == "DynamicUser") dynamic = value
            } else if (section == "Socket") {
                if (key == "SocketUser") socketuser = value
                else if (key == "SocketGroup") socketgroup = value
            }
        }
        END {
            printf "dynamic\t%s\n", dynamic
            printf "user\t%s\n", user
            printf "group\t%s\n", group
            printf "sup\t%s\n", sup
            printf "socketuser\t%s\n", socketuser
            printf "socketgroup\t%s\n", socketgroup
        }
    ' "$@"
}

checked=0
for name in "${unit_names[@]}"; do
    checked=$((checked + 1))
    files=()
    while IFS= read -r file; do
        files+=("$file")
    done < <(unit_files "$name")
    declare -A setting=()
    if ((${#files[@]} > 0)); then
        while IFS=$'\t' read -r key value; do
            setting[$key]=$value
        done < <(unit_settings "${files[@]}")
    fi
    skip_accounts=0
    dynamic=${setting[dynamic]:-}
    case ${dynamic,,} in
        yes | true | 1 | on) skip_accounts=1 ;;
    esac
    accounts=()
    if ((skip_accounts == 0)); then
        if [[ -n ${setting[user]:-} ]]; then accounts+=("user"$'\t'"${setting[user]}"); fi
        if [[ -n ${setting[group]:-} ]]; then accounts+=("group"$'\t'"${setting[group]}"); fi
        read -ra supplementary <<<"${setting[sup]:-}"
        for account in "${supplementary[@]}"; do
            accounts+=("group"$'\t'"$account")
        done
    fi
    if [[ -n ${setting[socketuser]:-} ]]; then accounts+=("user"$'\t'"${setting[socketuser]}"); fi
    if [[ -n ${setting[socketgroup]:-} ]]; then accounts+=("group"$'\t'"${setting[socketgroup]}"); fi
    for account in "${accounts[@]}"; do
        kind=${account%%$'\t'*}
        value=${account#*$'\t'}
        [[ -n $value ]] || continue
        [[ $value != root ]] || continue
        [[ ! $value =~ ^[0-9]+$ ]] || continue
        [[ $value != *%* ]] || continue
        if [[ $kind == user ]]; then
            [[ -n ${users[$value]:-} ]] || die "/$SYSTEM_UNITS/$name (with its drop-ins) names user $value, which no /$SYSUSERS/*.conf in the delta declares: add a u line for it (or an m line whose first field is $value)"
        else
            [[ -n ${groups[$value]:-} ]] || die "/$SYSTEM_UNITS/$name (with its drop-ins) names group $value, which no /$SYSUSERS/*.conf in the delta declares: add a g or u line for it (or an m line whose second field is $value)"
        fi
    done
done

echo "sysext-lodge-accounts-guard: $ID OK (system units: $checked, sysusers files: ${#sysusers[@]}, Lodge apps: ${#apps[@]})"
