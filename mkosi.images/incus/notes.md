# notes

The tmpfiles.d configuration manually creates alternatives symlinks for lzma/xz utilities. In Debian-based systems, these alternatives are typically managed by the update-alternatives system, not manually created symlinks. Creating manual symlinks here could conflict with the system's update-alternatives mechanism and may cause issues during package updates. Consider removing these manual symlink entries and relying on the packages' post-installation scripts to properly configure alternatives, or use update-alternatives command in a post-installation script if custom alternatives configuration is required.

We can't do "post-installation" scripts in a sysext. Not without some strange plumbing or some one-shot service. More importantly we can't do a post-uninstall script.
