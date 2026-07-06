# mkosi Tools Tree Sandbox

`mkosi.sandbox/` configures the normal build sandbox, but it does not configure the automatically built default tools tree from `ToolsTree=default`. Files needed by the tools-tree package manager must be placed in a separate sandbox and wired with `ToolsTreeSandboxTrees=` in the root `mkosi.conf`.

This matters for apt hardening: retry/timeout settings under `mkosi.sandbox/etc/apt/apt.conf.d/` help target-image package operations, while tools-tree package downloads need their own `/etc/apt/apt.conf.d/` supplied through `ToolsTreeSandboxTrees=`.
