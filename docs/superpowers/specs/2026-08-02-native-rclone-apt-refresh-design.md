# Native Promotion rclone APT Refresh Design

## Problem

Build Native Images run 30774546708 attempt 3 failed in all four promotion
jobs before any rclone or R2 operation ran. Each fresh promotion runner used
its preloaded Ubuntu APT index and requested
`rclone_1.60.1+dfsg-3ubuntu0.24.04.5`, but that revision had already been
removed from the configured mirrors. `apt-get install` therefore returned a
404 and exited 100.

The native build jobs did not fail because their host preparation runs
`apt-get update` before installing tools. Promotion jobs have no equivalent
refresh and must not rely on a hosted runner's image-time package index,
especially when a workflow is rerun hours after its original attempt.

## Change

Keep Ubuntu's packaged rclone and add `sudo apt-get update` immediately before
`sudo apt-get install -y rclone` in each conditional `Install rclone` step:

- `promote-cayo`
- `promote-snow`
- `promote-snowfield`
- `promote-iso`

The step remains conditional on both verified-marker and prepared-metadata
downloads succeeding. Products with no verified candidate still skip package
installation and promotion exactly as before.

Do not add retries, `--fix-missing`, a third-party setup action, or an upstream
rclone binary download. Those would either mask a stale-index cause or add a
new supply-chain pin without need.

## Regression Coverage

Add an always-runnable static test that reads
`.github/workflows/build-native-images.yml`, locates exactly four steps named
`Install rclone`, and requires each step's run script to contain
`sudo apt-get update` before `sudo apt-get install -y rclone`.

Wire the test into `.github/workflows/validate.yml`. The test must fail if an
install step is added without an APT refresh, if one of the four promotion
jobs loses its install step, or if install precedes refresh.

## Documentation

Update `CLAUDE.md` and `yeti/ci-cd.md` to record that promotion jobs run on
fresh hosted runners and refresh APT immediately before installing rclone.
This is package-index hygiene; it does not change R2 authentication, transfer,
verification, or promotion semantics.

## Validation

Run the new static test, `actionlint` on both changed workflows, shell syntax
or Python compilation for the test implementation, the existing native
publication pipeline fixture, and `git diff --check`.
