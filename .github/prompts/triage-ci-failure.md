# Prompt: triage a CI failure

Goal: find the root cause of the failure in `<workflow / run URL>`.

Steps:

1. List recent runs of the workflow and identify the failing run and job.
2. Fetch the failing job's logs and quote the first genuine error, not the
   final summary line — later failures in this repository's workflows are
   usually cascades of an earlier one.
3. Map the job back to the script it calls. The workflows are thin callers:
   `validate.yml` runs shellcheck, `check-runtime-etc-guard.sh`,
   `check-native-publication-guard.sh`, and the fixture tests in `test/`;
   `build-native-images.yml` calls `shared/native-ab/publish/*.sh` and
   `shared/native-ab/ci/*.sh`; `build-images.yml` calls
   `shared/outformat/image/buildah-package.sh`.
4. Reproduce locally with the smallest command that exercises the same code
   path — usually a single script from `test/` — before changing anything.
5. Fix the root cause in the script or configuration. Do not weaken, skip, or
   delete an assertion to make a job green; if an assertion is genuinely wrong,
   say so explicitly and explain why in the pull request.

Report back with: the failing job, the first real error, the root cause, the
fix, and the command that now passes locally.
