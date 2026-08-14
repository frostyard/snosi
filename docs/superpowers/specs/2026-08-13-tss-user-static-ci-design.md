# TSS User Initrd Static CI Design

## Problem

PR #731 adds `test/tss-user-initrd-static-test.sh`, but its GitHub App token
could not modify workflow files. Without explicit workflow wiring, the static
contract does not run in per-PR validation and can silently regress.

## Change

Add a separately named step to the existing `shell-lint` job in
`.github/workflows/validate.yml`. Place it immediately after the step that runs
`test/native-ab-static-test.sh`, and run:

```sh
./test/tss-user-initrd-static-test.sh
```

Keeping a separate step gives the initrd contract clear CI attribution. Do not
create another job or combine the command with the native A/B static test.

## Validation

Run `test/tss-user-initrd-static-test.sh`, validate the workflow with
`actionlint`, and run `git diff --check` before pushing the commit to PR #731.
