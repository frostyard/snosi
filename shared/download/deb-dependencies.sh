#!/bin/bash

assert_deb_dependencies_satisfied() {
    local deb=$1
    local dependencies

    dependencies=$(dpkg-deb --field "$deb" Depends)
    if [[ -z "${dependencies//[[:space:]]/}" ]]; then
        return 0
    fi

    if ! dpkg-checkbuilddeps -d "$dependencies" /dev/null; then
        printf 'DEB dependencies are not satisfied by the buildroot; add the required runtime packages through Packages=: %s\n' \
            "$dependencies" >&2
        return 1
    fi

    return 0
}
