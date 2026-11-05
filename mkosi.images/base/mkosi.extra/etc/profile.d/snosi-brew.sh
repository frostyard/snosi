# shellcheck shell=sh
# Homebrew environment for login shells (snosi ADR-0028).
#
# SNOW First Setup appended these lines to each user's ~/.bashrc. The image
# now owns them for every user and shell; the Fish equivalent is
# /usr/share/fish/vendor_conf.d/ublue-brew.fish. A GNOME session starts
# through a login shell, so its applications and terminals inherit PATH.
#
# Guards: brew must be installed and executable, and root never takes the
# prefix: /home/linuxbrew is owned by UID 1000, so a brew directory first in
# root's PATH would let that user run code as root.
if [ "$(id -u)" != 0 ] && [ -x /home/linuxbrew/.linuxbrew/bin/brew ]; then
    eval "$(/home/linuxbrew/.linuxbrew/bin/brew shellenv)"
fi
